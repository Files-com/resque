class LongJob
  class JobConfiguration
    attr_reader :name, :options

    def initialize(name, options, enqueuer, runs, backlog_count)
      @name = name
      @options = OpenStruct.new(options)
      @enqueuer = enqueuer
      @last_runs = runs
      @backlog_count = backlog_count
      @jobs = []
    end

    def args
      if options.args.is_a?(Array)
        options.args
      elsif options.args
        [ options.args ]
      else
        []
      end
    end

    def bulk_enqueue_jobs
      return if @jobs.empty?

      if @jobs.select { |job| job[:args_hash] }.empty?
        shard_ids = @jobs.map { |job| job[:shard_id] }.uniq.compact
        shard_ids = nil if shard_ids == []
        LongJobRun.update_all({ job: @name, shard_id: shard_ids, args_hash: nil, most_recent: true }, { most_recent: false, state: nil, state_cleared: true })
      elsif @jobs.select { |job| job[:shard_id] }.empty?
        hashes = @jobs.map { |job| job[:args_hash] }.uniq.compact
        LongJobRun.update_all({ job: @name, shard_id: nil, args_hash: hashes, most_recent: true }, { most_recent: false, state: nil, state_cleared: true })
      else
        @jobs.each do |job|
          LongJobRun.update_all({ job: @name, shard_id: job[:shard_id], args_hash: job[:args_hash], most_recent: true }, { most_recent: false, state: nil, state_cleared: true })
        end
      end

      LongJobRun.bulk_import(@jobs)
      @jobs.each do |job|
        Resque.enqueue_to @name.constantize.enqueue_to_queue, @name.constantize, job[:uuid]
      end
    end

    def enqueue
      if options.each_with_interval
        enqueue_for_proc_with_interval(options.each_with_interval)
      elsif options.each == :shard
        enqueue_for_shards
      elsif options.each.respond_to?(:call)
        enqueue_for_proc(options.each)
      else
        enqueue_one
      end
      bulk_enqueue_jobs
    end

    def enqueue_one
      return if num_to_enqueue == 0
      return if !@last_runs.empty? and @last_runs.select { |run| run_needed?(run, interval) }.empty?

      @jobs << LongJob.enqueue_bulk(@name, nil, *args)
    end

    def enqueue_for_arg_ids(arg_ids)
      num_to_enqueue.times do
        arg_id = arg_ids.shift
        break unless arg_id

        new_args = args.dup
        new_args.unshift(arg_id)
        @jobs << LongJob.enqueue_bulk(@name, nil, *new_args)
      end
    end

    def enqueue_for_proc(proc)
      enqueue_for_arg_ids(sorted_arg_ids(proc.call))
    end

    def enqueue_for_proc_with_interval(proc)
      enqueue_for_arg_ids(sorted_arg_ids_with_intervals(proc.call))
    end

    def enqueue_for_shards
      shard_ids = sorted_shard_ids

      num_to_enqueue.times do
        shard_id = shard_ids.shift
        break unless shard_id

        @jobs << LongJob.enqueue_bulk(@name, shard_id, *args)
      end
    end

    def interval
      options.interval
    end

    def last_runs_indexed_by_arg_id
      @last_runs_indexed_by_arg_id ||= @last_runs.map { |run| [ run.args.first, run ] }.to_h
    end

    def last_runs_indexed_by_shard_id
      @last_runs_indexed_by_shard_id ||= @last_runs.map { |run| [ run.shard_id, run ] }.to_h
    end

    def max_backlog_job_count
      [ 2 * num_per_run, options.max_backlog ].compact.min
    end

    def run_needed?(last_run, interval)
      # 1 minute grace period to account for Enqueuing time
      (!last_run or last_run.failed? or (last_run.created_at - 1.minute) < interval.ago) and !last_run&.in_progress?
    end

    def shard_count
      @enqueuer&.shard_count
    end

    def num_per_run
      @num_per_run ||= (shard_count.to_f / interval * ENQUEUE_INTERVAL).ceil
    end

    def num_to_enqueue
      [ num_per_run, max_backlog_job_count - @backlog_count ].min
    end

    def shard_ids
      shards = @enqueuer.shards.dup
      shards.select! { |shard| options.if.call(shard) } if options.if
      shards.map(&:id)
    end

    def sorted_arg_ids(ids)
      sorted_arg_ids_with_intervals(ids.map { |id| [ interval, id ] })
    end

    def sorted_arg_ids_with_intervals(ids_with_intervals)
      ids_with_intervals.map { |interval, id|
        [ id, interval, last_runs_indexed_by_arg_id[id] ]
      }.select { |_id, interval, last_run|
        run_needed?(last_run, interval)
      }.sort_by { |_id, _interval, last_run|
        last_run&.created_at || 1.year.ago
      }.map(&:first)
    end

    def sorted_shard_ids
      shard_ids.map { |id|
        [ id, last_runs_indexed_by_shard_id[id] ]
      }.select { |_id, last_run|
        run_needed?(last_run, interval)
      }.sort_by { |_id, last_run|
        last_run&.created_at || 1.year.ago
      }.map(&:first)
    end
  end
end
