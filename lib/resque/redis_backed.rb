module RedisBacked
  extend ActiveSupport::Concern

  class IndexDesyncError < StandardError; end

  BATCH_SIZE = 1_000
  MAX_RETRIES = 5

  # scan a secondary index according to min and max query parameters and return the records that match those params
  # parameters:
  #   KEYS[1] the key of the sorted set representing the secondary index to scan
  #   ARGV[1] minimum query parameter
  #   ARGV[2] maximum query parameter
  #   ARGV[3] redis namespace and collection name prefixing ids to fetch records
  #   ARGV[4] optional offset for the result set
  #   ARGV[5] optional limit for the result set
  #   ARGV[6] optional list of fields to return for each record (similar to mysql SELECT)
  REDIS_BULK_GET = <<-end_of_script.freeze
    local index_key = KEYS[1]
    local min_query = ARGV[1]
    local max_query = ARGV[2]
    local prefix = ARGV[3]
    local offset = ARGV[4]
    local limit = ARGV[5]
    local select_fields_str = ARGV[6]
    local ids
    if offset == "" then
      ids = redis.call('zrangebylex', index_key, min_query, max_query)
    else
      ids = redis.call('zrangebylex', index_key, min_query, max_query, "LIMIT", offset, limit)
    end
    local values = {}
    for i, entry in ipairs(ids) do
      local id = string.match(entry, ":(%d+)$")
      local record_key = prefix .. ':' .. id
      local record_str = redis.call("get", record_key)
      if select_fields_str == "null" then
        table.insert(values, record_str)
      else
        local select_fields = cjson.decode(select_fields_str)
        local record = cjson.decode(record_str)
        local final_record = {}
        for _, field in ipairs(select_fields) do
          final_record[field] = record[field]
        end
        table.insert(values, cjson.encode(final_record))
      end
    end
    return values
  end_of_script

  # delete records using lua (used in both bulk and single-record operations)
  # parameters:
  #   ARGV[1] namespace for records e.g. "my:production:namespace"
  #   ARGV[2] the collection/model/table name e.g. my_table
  #   ARGV[3] a json string representing index definitions of the form { "index_name": [ "field1", "field2", ... ], ... }
  #   ARGV[4] a json string representing the record ids to remove
  # returns: the string "OK"
  REDIS_BULK_DELETE = <<-end_of_script.freeze
    local namespace = ARGV[1]
    local model_name = ARGV[2]
    local index_defs = cjson.decode(ARGV[3])
    local record_ids = cjson.decode(ARGV[4])

    for _, record_id in ipairs(record_ids) do
      local rkey = namespace .. ":" .. model_name .. ":" .. record_id
      local record_str = redis.call("get", rkey)
      if record_str ~= false then
        local record = cjson.decode(record_str)
        for index_key, fields in pairs(index_defs) do
          local index_entry_value = ""
          for _, field in ipairs(fields) do
            local field_value = record[field]
            if field_value == nil or field_value == cjson.null then
              field_value = ""
            end
            index_entry_value = index_entry_value .. tostring(field_value) .. ":"
          end
          index_entry_value = index_entry_value .. record["id"]
          local full_index_key = namespace .. ":index-" .. index_key
          redis.call("zrem", full_index_key, index_entry_value)
        end

        redis.call("del", rkey)
      end
    end

    return "OK"
  end_of_script

  # insert records using lua (used in both bulk and single-record operations)
  # parameters:
  #   ARGV[1] namespace for records e.g. "my:production:namespace"
  #   ARGV[2] the collection/model/table name e.g. my_table
  #   ARGV[3] a json string representing index definitions of the form { "index_name": [ "field1", "field2", ... ], ... }
  #   ARGV[4] a json string representing the records to insert
  # returns: the string "OK"
  REDIS_BULK_IMPORT = <<-end_of_script.freeze
    local namespace = ARGV[1]
    local model_name = ARGV[2]
    local index_defs = cjson.decode(ARGV[3])
    local records = cjson.decode(ARGV[4])

    for _, record in ipairs(records) do
      for index_key, fields in pairs(index_defs) do
        local index_entry_value = ""
        for _, field in ipairs(fields) do
          local field_value = record[field]
          if field_value == nil or field_value == cjson.null then
            field_value = ""
          end
          index_entry_value = index_entry_value .. tostring(field_value) .. ":"
        end
        index_entry_value = index_entry_value .. record["id"]
        local full_index_key = namespace .. ":index-" .. index_key
        redis.call("zadd", full_index_key, 0.0, index_entry_value)
      end

      local rkey = namespace .. ":" .. model_name .. ":" .. record["id"]
      local encoded_record = cjson.encode(record)
      redis.call("set", rkey, encoded_record)
    end

    return "OK"
  end_of_script

  # perform a bulk find/update all in 1 lua call
  # parameters:
  #   KEYS[1] index for bulk search
  #   ARGV[1] array of min values to search for
  #   ARGV[2] array of max values to search for
  #   ARGV[3] namespace for records e.g. "my:production:namespace"
  #   ARGV[4] offset of the record, if using offset/limit
  #   ARGV[5] limit number of records
  #   ARGV[6] a json string representing updates to apply to each record
  #   ARGV[7] a json string representing index definitions of the form { "index_name": [ "field1", "field2", ... ], ... }
  #   ARGV[8] the collection/model/table name e.g. my_table
  #   ARGV[9] array of ids to skip updating (supporting where.not(id: id))
  #   ARGV[10] set to 1 if you want to return actual records instead of just the number of records updated
  #   ARGV[11] an array of record ids if you want to skip finding records from a secondary index
  # returns: number of records updated or the actual records
  REDIS_UPDATE_ALL = <<-end_of_script.freeze
    local search_index_key = KEYS[1]
    local min_values_str = ARGV[1]
    local max_values_str = ARGV[2]
    local namespace = ARGV[3]
    local offset = ARGV[4]
    local limit = ARGV[5]
    local updates_str = ARGV[6]
    local index_def_str = ARGV[7]
    local model_name = ARGV[8]
    local exclude_ids_str = ARGV[9]
    local returning_records = tonumber(ARGV[10])
    local ids_to_update = ARGV[11]

    -- find records for update
    local ids = {}
    local exclude_ids = cjson.decode(exclude_ids_str)
    if ids_to_update == "" then
      local min_values = cjson.decode(min_values_str)
      local max_values = cjson.decode(max_values_str)
      for i, _ in ipairs(min_values) do
        local min_value = min_values[i]
        local max_value = max_values[i]
        local index_entries
        if offset == "" then
          index_entries = redis.call('zrangebylex', search_index_key, min_value, max_value)
        else
          index_entries = redis.call('zrangebylex', search_index_key, min_value, max_value, "LIMIT", tonumber(offset), tonumber(limit))
        end
        for _, entry in ipairs(index_entries) do
          local id = string.match(entry, ":(%d+)$")
          table.insert(ids, id)
        end
      end
    else
      ids = cjson.decode(ids_to_update)
    end
    local keys = {}
    for i, id in ipairs(ids) do
      local skip_id = false
      if exclude_ids ~= cjson.null then
        for _, id_to_skip in ipairs(exclude_ids) do
          if tonumber(id) == id_to_skip then
            skip_id = true
          end
        end
      end
      if skip_id == false then
        table.insert(keys, namespace .. ":" .. model_name .. ":" .. id)
      end
    end

    -- load records
    local records = {}
    if table.getn(keys) > 0 then
      for i, _ in ipairs(keys) do
        records[i] = redis.call("get", keys[i])
      end
    else
      if returning_records == 1 then
        return records
      else
        return 0
      end
    end

    -- remove index entries that will no longer be valid
    local index_defs = cjson.decode(index_def_str)
    local updates = cjson.decode(updates_str)
    for _, raw_record in ipairs(records) do
      local record = cjson.decode(raw_record)
      for index_key, fields in pairs(index_defs) do
        -- if the index contains a field that is getting updated, add the record's current entry to the list for removal
        local contained_in_update = false
        for i, field_name in ipairs(fields) do
          if updates[field_name] ~= nil then
            local full_index_key = namespace .. ":index-" .. index_key
            local current_record_values = ""
            for _, field in ipairs(fields) do
              local current_value = record[field]
              if current_value == nil or current_value == cjson.null then
                current_value = ""
              end
              current_record_values = current_record_values .. tostring(current_value) .. ":"
            end
            current_record_values = current_record_values .. record["id"]
            redis.call("zrem", full_index_key, current_record_values)
          end
        end
      end

      -- update records
      for field_name, field_value in pairs(updates) do
        record[field_name] = field_value
      end
      local rkey = namespace .. ":" .. model_name .. ":" .. record["id"]
      local encoded_record = cjson.encode(record)
      redis.call("set", rkey, encoded_record)

      -- add new index entries, since we're already looping through records
      for index_key, fields in pairs(index_defs) do
        local full_index_key = namespace .. ":index-" .. index_key
        local index_entry_value = ""
        for _, field in ipairs(fields) do
          local field_value = record[field]
          if field_value == nil or field_value == cjson.null then
            field_value = ""
          end
          index_entry_value = index_entry_value .. tostring(field_value) .. ":"
        end
        index_entry_value = index_entry_value .. record["id"]
        redis.call("zadd", full_index_key, 0.0, index_entry_value)
      end
    end

    if returning_records == 1 then
      return records
    else
      return table.getn(records)
    end
  end_of_script

  class_methods do
    def create(attrs)
      new(attrs).tap(&:save)
    end

    def sorted_redis_indexes
      @sorted_redis_indexes ||= {}
    end

    def compressed_columns
      @compressed_columns ||= []
    end
  end

  included do
    include UseRedis

    def self.compress_column(column)
      compressed_columns << column
    end

    def self.redis_index(*columns)
      index_name = columns.join('_')
      sorted_redis_indexes[index_name] = columns

      class_eval(<<-end__, __FILE__, __LINE__ + 1)
        def self.ranges_by_#{index_name}(queries, options = {})
          index_key = "#{redis_namespace}:index-#{index_name}"

          data = []
          queries.each do |q|
            data << run_redis_script(REDIS_BULK_GET, [ index_key ], [ "[\#{q}", "(\#{q}\\xff", "#{redis_namespace}:#{model_name.collection}", "", "", JSON.dump(options[:select_fields]) ])
          end

          data.flatten.map { |d| new.load_from_json!(d) if d }
        end

        def self.range_by_#{index_name}(min_value, max_value, limit = nil, options = {})
          index_key = "#{redis_namespace}:index-#{index_name}"
          records = []
          redis_connection.with do |redis_conn|
            data = if limit
              run_redis_script(REDIS_BULK_GET, [ index_key ], [ "[\#{min_value}", "(\#{max_value}\\xff", "#{redis_namespace}:#{model_name.collection}", limit.first, limit.last, JSON.dump(options[:select_fields]) ])
            else
              run_redis_script(REDIS_BULK_GET, [ index_key ], [ "[\#{min_value}", "(\#{max_value}\\xff", "#{redis_namespace}:#{model_name.collection}", "", "", JSON.dump(options[:select_fields]) ])
            end

            records = data.map { |d| new.load_from_json!(d) if d }
            if block_given?
              yield records
            end
          end

          records
        end

        def self.get_by_#{index_name}(#{columns.join(", ")}, options = {})
          queries = []
          cols = [ #{columns.map(&:to_s).join(", ")} ]
          max_length = 1
          cols.each do |c|
            raise "Only one array-valued query parameter supported" if c.is_a?(Array) and max_length > 1

            if c.is_a?(Array) and c.length > max_length
              max_length = c.length
            end
          end
          expanded_cols = cols.map do |c|
            if c.is_a?(Array)
              c
            else
              [ c ] * max_length
            end
          end
          (0...max_length).each do |i|
            query = ""
            expanded_cols.each do |ec|
              query += ec[i].is_a?(ActiveSupport::TimeWithZone) ? ec[i].to_i.to_s : ec[i].to_s
              query += ":"
            end
            queries << query
          end
          ranges_by_#{index_name}(queries, options)
        end

        def self.count_by_#{index_name}(#{columns.join(", ")})
          value = [ #{columns.join(", ")} ].map { |c| c.is_a?(ActiveSupport::TimeWithZone) ? c.to_i : c }.join(":")
          redis_connection.zlexcount("#{redis_namespace}:index-#{index_name}", "[\#{value}:", "[\#{value}:\\xff")
        end

        def self.scan_delete_by_#{index_name}(min_value, max_value)
          keep_going = true
          while keep_going
            range_by_#{index_name}(min_value, max_value, [ 0, BATCH_SIZE ]) do |objects|
              keep_going = false if objects.empty?
              delete_all(objects)
            end
          end
        end

        def self.all_#{index_name.pluralize}
          index_key = "index-#{index_name}"

          redis.zscan_each(index_key).map(&:first).map { |i| i.split(":").first }.uniq
        end
      end__
    end

    def self.first
      get_by_id(all_ids.first)
    end

    def self.all_ids
      key_prefix = "#{model_name.collection}:*"

      redis.scan_each(match: key_prefix).map { |i| i.split(":").last }
    end

    def self.all
      all_ids.map { |id| get_by_id(id) }.compact
    end

    def self.bulk_import(record_hashes)
      return if record_hashes.empty?

      new_max_id = redis_connection.incrby("#{redis_namespace}:max-#{model_name.singular}-id", record_hashes.length)
      new_id = new_max_id - record_hashes.length + 1
      values_to_save = []

      record_hashes.each do |record_hash|
        record = new(record_hash)
        record.created_at = DateTime.now
        record.updated_at = DateTime.now
        record.id = new_id
        new_id += 1
        values_to_save << serialize_to_redis(record.attributes(enums_as: :symbols))
      end

      lua_args = [
        redis_namespace,
        model_name.collection,
        JSON.dump(sorted_redis_indexes),
        "[ #{values_to_save.join(",")} ]"
      ]

      run_redis_script(REDIS_BULK_IMPORT, [], lua_args)
    end

    def self.check_for_index_desyncs
      redis_connection.with do |redis_conn|
        cardinalities = redis_conn.multi do |r|
          sorted_redis_indexes.each do |index_name, _columns|
            index_key = "#{redis_namespace}:index-#{index_name}"
            r.zcard(index_key)
          end
        end
        raise RedisBacked::IndexDesyncError.new("Redis indexes desynced: #{cardinalities.inspect}") unless cardinalities.uniq.size == 1
      end
    end

    def self.compress_columns(attrs)
      attrs.each do |k, v|
        attrs[k] = Base64.encode64(Zlib::Deflate.deflate(JSON.dump(v), 9)) if compressed_columns.include? k.to_sym and v
      end
      attrs
    end

    def self.decompress_columns(attrs)
      attrs.each do |k, v|
        attrs[k] = JSON.parse(Zlib::Inflate.inflate(Base64.decode64(v))) if compressed_columns.include? k.to_sym and v
      end
      attrs
    end

    def self.delete_all(records)
      delete_by_ids(records.map(&:id))
    end

    def self.delete_by_ids(record_ids)
      return if record_ids.empty?

      lua_args = [
        redis_namespace,
        model_name.collection,
        JSON.dump(sorted_redis_indexes),
        JSON.dump(record_ids)
      ]

      run_redis_script(REDIS_BULK_DELETE, [], lua_args)
    end

    def self.deserialize_from_redis(data)
      ints_to_times(decompress_columns(JSON.parse(data)))
    end

    def self.get_by_id(id)
      rkey = "#{redis_namespace}:#{model_name.collection}:#{id}"
      record = nil
      if data = redis_connection.get(rkey)
        record = new.load_from_json!(data)
      end
      record
    end

    def self.ints_to_times(attrs)
      attrs.each do |k, v|
        attrs[k] = if fields.select { |_field, definition| definition.type == :datetime }.keys.include?(k.to_s) and !v.nil?
                     Time.zone.at(v)
                   else
                     v
                   end
      end
      attrs
    end

    def self.range_update_all(min_query_params, max_query_params, updates, options = {})
      raise "Minimum and maximum query parameters must use the same keys" unless min_query_params.keys == max_query_params.keys

      index_name = nil
      sorted_redis_indexes.each do |idx_name, columns|
        index_name = idx_name if (min_query_params.keys - columns).empty? and (columns - min_query_params.keys).empty?
      end

      raise "No index matches query params" unless index_name

      min_args = sorted_redis_indexes[index_name].map { |col| min_query_params[col] }.join(":").concat(":")
      max_args = sorted_redis_indexes[index_name].map { |col| max_query_params[col] }.join(":").concat(":")

      min_query_values = JSON.dump([ "[#{min_args}" ])
      max_query_values = JSON.dump([ "(#{max_args}\\xff" ])

      limit = options[:limit] || []

      index_key = "#{redis_namespace}:index-#{index_name}"
      lua_args = [
        min_query_values,
        max_query_values,
        redis_namespace,
        limit.first,
        limit.last,
        serialize_to_redis(updates),
        JSON.dump(sorted_redis_indexes),
        model_name.collection,
        JSON.dump(options[:exclude_ids]),
        (options[:returning_records] ? 1 : 0),
        ""
      ]

      records_or_count = run_redis_script(REDIS_UPDATE_ALL, [ index_key ], lua_args)

      if options[:returning_records]
        records_or_count.map { |data| new.load_from_json!(data) if data }
      else
        records_or_count
      end
    end

    def self.redis_connection
      redis.redis
    end

    def self.run_redis_script(script, keys, args)
      script_sha1 = Digest::SHA1.hexdigest(script)
      begin
        redis_connection.evalsha(script_sha1, keys, args)
      rescue Redis::CommandError
        redis_connection.eval(script, keys, args)
      end
    end

    def self.scan_range_update_all(min_query_params, max_query_params, updates)
      offset = 0
      loop do
        records_updated = range_update_all(min_query_params, max_query_params, updates, limit: [ offset, BATCH_SIZE ])
        break if records_updated == 0

        offset += BATCH_SIZE
      end
    end

    def self.serialize_to_redis(attrs)
      JSON.dump(compress_columns(times_to_ints(attrs)))
    end

    def self.times_to_ints(attrs)
      attrs.each do |k, v|
        attrs[k] = if v.is_a? ActiveSupport::TimeWithZone or v.is_a? DateTime or v.is_a? Time
                     v.to_i
                   else
                     v
                   end
      end
      attrs
    end

    def self.update_all(query_params, updates, options = {})
      index_name = nil
      sorted_redis_indexes.each do |idx_name, columns|
        index_name = idx_name if (query_params.keys - columns).empty? and (columns - query_params.keys).empty?
      end

      raise "No index matches query params" unless index_name

      query_values = sorted_redis_indexes[index_name].map { |col| query_params[col] }

      queries = []
      max_length = 1
      query_values.each do |c|
        raise "Only one array-valued query parameter supported" if c.is_a?(Array) and max_length > 1

        max_length = c.length if c.is_a?(Array) and c.length > max_length
      end
      expanded_cols = query_values.map do |c|
        if c.is_a?(Array)
          c
        else
          [ c ] * max_length
        end
      end
      (0...max_length).each do |i|
        query = ""
        expanded_cols.each do |ec|
          query += ec[i].is_a?(ActiveSupport::TimeWithZone) ? ec[i].to_i.to_s : ec[i].to_s
          query += ":"
        end
        queries << query
      end

      min_query_values = JSON.dump(queries.map { |q| "[#{q}" })
      max_query_values = JSON.dump(queries.map { |q| "(#{q}\\xff" })

      updates.merge!(updated_at: DateTime.now)

      index_key = "#{redis_namespace}:index-#{index_name}"
      lua_args = [
        min_query_values,
        max_query_values,
        redis_namespace,
        "",
        "",
        serialize_to_redis(updates),
        JSON.dump(sorted_redis_indexes),
        model_name.collection,
        JSON.dump(options[:exclude_ids]),
        (options[:returning_records] ? 1 : 0),
        ""
      ]

      records_or_count = run_redis_script(REDIS_UPDATE_ALL, [ index_key ], lua_args)

      if options[:returning_records]
        records_or_count.map { |data| new.load_from_json!(data) if data }
      else
        records_or_count
      end
    end
  end

  def create_or_update(*_args)
    # Prevent saving this any way other than the #save method.
    raise "Unsupported operation on a RedisBacked model"
  end

  def destroy
    self.class.delete_all([ self ])
    @destroyed = true
    freeze
  end

  def generate_id
    self.id ||= redis_connection.incr("#{redis_namespace}:max-#{model_name.singular}-id")
  end

  def load_from_json!(data)
    self.attributes = self.class.deserialize_from_redis(data)
    changes_applied
    @new_record = false
    self
  end

  def redis_connection
    self.class.redis_connection
  end

  def redis_namespace
    self.class.redis_namespace
  end

  def reload(redis_conn = redis_connection)
    rkey = "#{redis_namespace}:#{model_name.collection}:#{id}"
    reloaded = nil
    if data = redis_conn.get(rkey)
      reloaded = self.class.new.load_from_json!(data)
    end
    raise ActiveRecord::RecordNotFound.new("Couldn't find #{self.class} with 'id'=#{id}") unless reloaded

    self.attributes = reloaded.attributes
    self
  end

  def save
    return false unless valid?

    run_callbacks :save do
      if @new_record
        run_callbacks :create do
          generate_id
          @new_record = false
          self.created_at ||= DateTime.now
          self.updated_at = DateTime.now

          lua_args = [
            redis_namespace,
            model_name.collection,
            JSON.dump(self.class.sorted_redis_indexes),
            "[ #{self.class.serialize_to_redis(attributes(enums_as: :symbols))} ]"
          ]

          self.class.run_redis_script(REDIS_BULK_IMPORT, [], lua_args)
        end
      else
        updates = {}
        changes.each do |field_name, field_values|
          updates[field_name] = field_values.last
        end
        return true if updates.empty?

        lua_args = [
          "",
          "",
          redis_namespace,
          "",
          "",
          self.class.serialize_to_redis(updates),
          JSON.dump(self.class.sorted_redis_indexes),
          self.class.model_name.collection,
          JSON.dump(nil),
          0,
          JSON.dump([ id ])
        ]
        self.class.run_redis_script(REDIS_UPDATE_ALL, [ "" ], lua_args)
      end
      changes_applied
    end
    true
  end

  def update(attributes)
    attributes.merge!(updated_at: DateTime.now)
    lua_args = [
      "",
      "",
      redis_namespace,
      "",
      "",
      self.class.serialize_to_redis(attributes),
      JSON.dump(self.class.sorted_redis_indexes),
      self.class.model_name.collection,
      JSON.dump(nil),
      0,
      JSON.dump([ id ])
    ]
    self.class.run_redis_script(REDIS_UPDATE_ALL, [ "" ], lua_args)
    assign_attributes(attributes)
    changes_applied
    true
  end
end
