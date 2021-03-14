class LongJob
  class Runner
    attr_reader :run, :shard
    attr_accessor :message

    cattr_accessor :max_work_units_per_run # primarily used by Specs for testing

    def initialize(run = nil, job_class = nil)
      @run = run
      @shard = run&.shard
      @args = run&.args.is_a?(Array) ? run.args : []
      @job_class = job_class
      @start_time = Time.now
      @watcher_thread = start_watcher_thread if run and !Rails.env.test?
      @state = (run&.state || {}).with_indifferent_access
      @work_unit_count = 0
      @work_unit_time = 0
      @worker_blocks = []
    end

    def all_units_worked
      @worker_blocks.each(&:all_units_worked)
    end

    def critical_work_unit(lock_name)
      lock_timeout, attempt_timeout, sleep_between_work = LongJob.config.critical_work.slice(:lock_timeout, :attempt_timeout, :sleep_between_work).values
      @state["critical_work_attempt"] = 1
      loop do
        work_unit do
          CriticalSection.with_exclusive_lock(lock_name, lock_timeout, 0.5, attempt_timeout) do
            yield if block_given?
            return
          end
        rescue CriticalSection::WaitTimeout
          Rails.logger.info("Failed to acquire lock, attempt #{@state["critical_work_attempt"]} for #{lock_name}")
          @state["critical_work_attempt"] += 1
        end

        sleep sleep_between_work
      end
    end

    def perform
      return unless [ :queued, :running ].include?(@run.status)

      unless @run.most_recent?
        record_completion
        return
      end

      ret = catch :requeue do
        @job_class.long_job_perform(self, @shard, *@args)
      end
      all_units_worked
      kill_watcher_thread
      if ret == :requeue
        record_completion(:queued)
        Resque.enqueue_to @job_class.requeue_to_queue, @job_class, @run.uuid
      else
        record_completion
      end
    rescue StandardError => e
      record_completion(:failed, "#{e.class}: #{e.message}\n#{e.backtrace}")
      raise
    ensure
      kill_watcher_thread
    end

    def state(key, value = nil)
      if block_given?
        if val = @state[key]
          val
        else
          @state[key] = yield
        end
      elsif value
        @state[key] = value
      else
        @state[key]
      end
    end

    def clear_state(key)
      @state.delete(key)
    end

    def uuid
      @run&.uuid
    end

    def work_each(key, values)
      raise "work_each keys must be a symbol" unless key.is_a?(Symbol)
      raise "work_each values must be an array" unless values.is_a?(Array)

      key = key.to_s
      if index = values.map(&:to_s).index(@state[key])
        values = values[index..-1]
      end

      values.each do |value|
        @state[key] = value
        work_unit do
          yield(value)
        end
      end
    end

    def work_recursive_sorted_hash(key, objects)
      raise "key must be a symbol" unless key.is_a?(Symbol)
      raise "objects must be a Hash" unless objects.is_a?(Hash)

      key = key.to_s
      if start = @state[key]
        objects = objects.select { |k, _v|
          start[0..(k.length - 1)] == k or k >= start
        }
      end

      objects.each do |k, v|
        @state[key] = k if !start or k >= start
        work_unit do
          yield(v)
        end
      end
    end

    def work_each_run(&block)
      @worker_blocks << WorkerBlock.new(0, block)
    end

    def work_every_n_chunks(n, &block)
      @worker_blocks << WorkerBlock.new(n, block)
    end

    def work_once(key)
      return if @state[key] == "1"

      yield
      @state[key] = "1"
    end

    def work_unit
      throw :requeue, :requeue if elapsed_time > TARGET_LENGTH and !rails_env_test? and !defined?(Rails::Console)
      throw :requeue, :requeue if Runner.max_work_units_per_run and @work_unit_count >= Runner.max_work_units_per_run

      start = Time.now
      yield if block_given?
      @work_unit_time += (Time.now - start)
      @work_unit_count += 1
      @worker_blocks.each(&:unit_worked)
    end

    def rails_env_test?
      Rails.env.test?
    end

    protected

    def checkin
      ActiveRecord::Base.connection_pool.with_connection do
        update_params = { last_checkin_at: Time.now, status: :running, in_progress: true, state: @state }
        update_params[:message] = @message if @message

        long_job_run = LongJobRun.get_by_id(run.id)
        long_job_run.update(update_params) if [ :queued, :running ].include? long_job_run.status
      end
    end

    def elapsed_time
      Time.now - @start_time
    end

    def kill_watcher_thread
      @running = false
    end

    def record_completion(status = :completed, message = nil)
      end_time = Time.now
      total_work_units = (@run.work_units || 0) + @work_unit_count
      total_time = (@run.work_unit_total_time || 0) + @work_unit_time
      data = {
        status: status,
        state: @state,
        message: message,
        last_checkin_at: end_time,
        elapsed_time: (@run.elapsed_time || 0) + (end_time - @start_time),
        runs: (@run.runs || 0) + 1,
        work_units: total_work_units,
        work_unit_total_time: total_time,
        work_unit_average_time: total_time / [ total_work_units, 1 ].max,
      }
      if status != :queued
        data.merge!(
          in_progress: false,
          finished_at: end_time,
        )
      end

      data.merge!(most_recent: false) if status == :completed and !LongJob.scheduled_job?(run.job)

      if [ :completed, :failed ].include? status
        data[:state] = nil
        data[:state_cleared] = true
      end

      CriticalSection.with_exclusive_lock(run.enqueue_unique_key) do
        if long_job_run = LongJobRun.get_by_id(run.id)
          long_job_run.update(data) if [ :queued, :running ].include?(long_job_run.status)
          LongJob.enqueue @job_class, @shard, *@args if long_job_run.rerun_at_completion?
        end
      end
    end

    def start_watcher_thread
      @running = true
      Thread.new {
        i = 0
        loop do
          break unless @running

          checkin if (i % CHECKIN_INTERVAL) == 0
          sleep 1
          i += 1
        end
      }
    end
  end
end
