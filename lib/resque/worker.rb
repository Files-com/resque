module Resque
  module WorkerStatMethods
    def failed
      Stat["failed:#{self}"]
    end

    def heartbeat
      data_store.heartbeat(self)
    end

    def processed
      Stat["processed:#{self}"]
    end

    def started
      data_store.worker_start_time(self)
    end
  end

  class Worker
    include Resque::Helpers
    extend Resque::Helpers
    include Resque::Logging
    include WorkerStatMethods

    attr_accessor :term_timeout, :jobs_per_fork, :worker_count, :thread_count, :statsd, :statsd_key
    attr_reader :jobs_processed, :worker_pid
    attr_writer :hostname, :to_s

    def data_store
      Resque.redis
    end

    def self.data_store
      Resque.redis
    end

    def encode(object)
      Resque.encode(object)
    end

    def decode(object)
      Resque.decode(object)
    end

    def initialize(*queues)
      @shutdown = nil
      @paused = nil
      @consul_disabled = false
      @before_first_fork_hook_ran = false

      @heartbeat_thread = nil

      @worker_threads = []
      verbose_value = ENV['LOGGING'] || ENV['VERBOSE']
      self.verbose = verbose_value if verbose_value
      self.very_verbose = ENV['VVERBOSE'] if ENV['VVERBOSE']
      self.term_timeout = (ENV['RESQUE_TERM_TIMEOUT'] || 30.0).to_f
      self.jobs_per_fork = [ (ENV['JOBS_PER_FORK'] || 1).to_i, 1 ].max
      self.worker_count = [ (ENV['WORKER_COUNT'] || 1).to_i, 1 ].max
      self.thread_count = [ (ENV['THREAD_COUNT'] || 1).to_i, 1 ].max

      if ENV['STATSD_KEY'] and ENV['STATSD_HOST'] and ENV['STATSD_PORT']
        self.statsd = Statsd.new(ENV['STATSD_HOST'], ENV['STATSD_PORT'])
        self.statsd_key = ENV['STATSD_KEY']
      end

      self.queues = queues
      log_with_severity :debug, "Worker initialized"
    end

    def prepare
      if ENV['BACKGROUND']
        Process.daemon(true)
      end

      if ENV['PIDFILE']
        File.open(ENV['PIDFILE'], 'w') { |f| f << pid }
      end
    end

    WILDCARDS = ['*', '?', '{', '}', '[', ']'].freeze

    def queues=(queues)
      queues = queues.empty? ? (ENV["QUEUES"] || ENV['QUEUE']).to_s.split(',') : queues
      @queues = queues.map { |queue| queue.to_s.strip }
      @has_dynamic_queues = WILDCARDS.any? {|char| @queues.join.include?(char) }
      validate_queues
    end

    def validate_queues
      if @queues.nil? || @queues.empty?
        raise NoQueueError.new("Please give each worker at least one queue.")
      end
      if @has_dynamic_queues and @queues.any? { |queue| queue =~ /:/ }
        raise NoQueueError.new("You cannot use the colon syntax for defining max workers per queue if you are also using dynamic queues.")
      end
    end

    def queues
      if @has_dynamic_queues
        current_queues = Resque.queues
        @queues.map { |queue| glob_match(current_queues, queue) }.flatten.uniq
      else
        @queues
      end
    end

    def glob_match(list, pattern)
      list.select { |queue|
        File.fnmatch?(pattern, queue)
      }.sort
    end

    def work(interval = 0.1, &block)
      interval = Float(interval)
      startup

      if !!ENV['DONT_FORK']
        worker_process(OpenStruct.new(interval: interval, index: 0), &block)
      else
        @children = {}
        log_with_severity :debug, "Launching #{worker_count} worker(s)."
        (0..(worker_count - 1)).map { |index|
          fork_worker_process(OpenStruct.new(index: index, interval: interval), &block)
        }

        loop do
          children = @children
          children.each do |index,child|
            if child
              if Process.waitpid(child, Process::WNOHANG)
                @children[index] = nil
                fork_worker_process(OpenStruct.new(index: index, interval: interval), &block) unless interval.zero? || shutdown?
              end
            elsif shutdown?
              log_with_severity :debug, "Deleting Worker index #{index} for shutdown."
              @children.delete(index)
            end
          end

          break if (interval.zero? || shutdown?) and @children.size == 0
          sleep interval
        end
      end

      unregister_worker
    rescue Exception => exception
      return if exception.class == SystemExit && !@children
      log_with_severity :error, "Worker Error: #{exception.inspect} #{exception.backtrace}"
      unregister_worker(exception)
    end

    def fork_worker_process(process, &block)
      log_with_severity :debug, "Forking worker process index #{process.index}."
      run_hook :before_fork, process
      @children[process.index] = fork {
        @children = {}
        ActiveRecord::Base.clear_all_connections! if defined?(ActiveRecord::Base)
        log_with_severity :debug, "Successfully forked worker process index #{process.index}."
        run_hook :after_fork, process
        worker_process(process, &block)
        exit!
      }
      srand # Reseed after fork
      procline "Master Process - Worker Children PIDs: #{@children.values.join(",")} - Last Fork at #{Time.now.to_i}"
    end

    def worker_process(process, &block)
      start_heartbeat

      @mutex = Mutex.new
      @jobs_processed = 0
      @worker_pid = Process.pid
      log_with_severity :debug, "Spawning #{thread_count} threads for worker process index #{process.index}."
      @worker_threads = (0..(thread_count - 1)).map { |i| WorkerThread.new(self, process.index, i, process.interval, &block) }
      if @worker_threads.size == 1
        @worker_threads.first.work
      else
        @worker_threads.map(&:spawn).map(&:join)
      end
      run_hook :after_jobs_run, process
    end

    def total_thread_count
      thread_count * worker_count
    end

    def synchronize
      @mutex.synchronize do
        yield
      end
    end

    def job_processed
      synchronize do
        @jobs_processed += 1
        if @jobs_processed >= jobs_per_fork
          shutdown
        end
      end
    end

    def report_to_statsd(job_name)
      statsd&.increment("#{statsd_key}.#{job_name}", 1)
    end

    def set_procline
      jobs = @worker_threads.map { |thread| thread.payload_class_name }.compact
      if jobs.size > 0
        procline "Processing Job(s): #{jobs.join(", ")}"
      else
        procline paused? ? "Paused" : "Waiting for #{queues.join(',')}"
      end
    end

    def reserve(thread_index = 0, total_threads = total_thread_count)
      index_offset = 0
      queues.each do |queue_config|
        queue, max_threads = queue_config.split(":")
        if max_threads =~ /[0-9]+\%/
          max_threads = total_threads * max_threads.to_i / 100
        else
          max_threads = max_threads.to_i
        end
        offset_thread_index = (thread_index - index_offset) % total_threads
        index_offset += max_threads
        next if max_threads > 0 and offset_thread_index >= max_threads
        log_with_severity :debug, "Checking #{queue}"
        if job = Resque.reserve(queue)
          log_with_severity :debug, "Found job on #{queue}"
          return job
        end
      end

      nil
    rescue Exception => e
      log_with_severity :error, "Error reserving job: #{e.inspect}"
      log_with_severity :error, e.backtrace.join("\n")
      raise e
    end

    def startup
      $0 = "resque: Starting"

      register_signal_handlers
      WorkerManager.prune_dead_workers
      run_hook :before_first_fork
      register_worker

      $stdout.sync = true
    end

    def register_signal_handlers
      trap('TERM') { shutdown; send_child_signal('TERM'); kill_worker_threads }
      trap('INT')  { shutdown; send_child_signal('INT'); kill_worker_threads }

      begin
        trap('QUIT') { shutdown; send_child_signal('QUIT') }
        trap('USR1') { send_child_signal('USR1'); unpause_processing; kill_worker_threads }
        trap('USR2') { pause_processing; send_child_signal('USR2') }
        trap('CONT') { unpause_processing; send_child_signal('CONT') }
      rescue ArgumentError
        log_with_severity :warn, "Signals QUIT, USR1, USR2, and/or CONT not supported."
      end

      log_with_severity :debug, "Registered signals"
    end

    def send_child_signal(signal)
      if @children
        @children.values.each do |child|
          Process.kill(signal, child) rescue nil
        end
      end
    end

    def kill_worker_thread(id)
      @worker_threads.select { |thread| thread.id == id }.each { |t| t.kill }
    end

    def kill_worker_threads
      @worker_threads.each(&:kill)
    end

    def shutdown
      log_with_severity :info, 'Exiting...'
      @shutdown = true
    end

    def shutdown?
      @shutdown
    end

    def remove_heartbeat
      data_store.remove_heartbeat(self)
    end

    def heartbeat!(time = data_store.server_time)
      data_store.heartbeat!(self, time)
    end

    def start_heartbeat
      remove_heartbeat

      @heartbeat_thread = Thread.new do
        loop do
          heartbeat!
          update_consul_disabled
          data_store.check_for_kill_signals(self)
          WorkerManager.prune_dead_workers if rand(1000) == 1
          sleep Resque.heartbeat_interval
        end
      end
    end

    def update_consul_disabled
      @consul_disabled = (File.exist?("/etc/consul_disabled") or File.exist?("/tmp/consul_disabled"))
    end

    def paused?
      @paused or @consul_disabled
    end

    def pause_processing
      log_with_severity :info, "USR2 received; pausing job processing"
      run_hook :before_pause, self
      @paused = true
    end

    def unpause_processing
      log_with_severity :info, "CONT received; resuming job processing"
      @paused = false
      run_hook :after_pause, self
    end

    def register_worker
      data_store.register_worker(self)
    end

    def unregister_worker(exception = nil)
      @worker_threads.each do |thread|
        if job = thread.job
          begin
            job.fail(exception || DirtyExit.new("Job still being processed"))
          rescue RuntimeError => e
            log_with_severity :error, e.message
          end
        end
      end

      @heartbeat_thread&.kill

      data_store.unregister_worker(self) do
        Stat.clear("processed:#{self}")
        Stat.clear("failed:#{self}")
      end
    rescue Exception => exception_while_unregistering
      message = exception_while_unregistering.message
      if exception
        message += "\nOriginal Exception (#{exception.class}): #{exception.message}"
        message += "\n  #{exception.backtrace.join("  \n")}" if exception.backtrace
      end
      fail(exception_while_unregistering.class,
           message,
           exception_while_unregistering.backtrace)
    end

    def processed!
      Stat << "processed"
      Stat << "processed:#{self}"
    end

    def failed!
      Stat << "failed"
      Stat << "failed:#{self}"
    end

    def started!
      data_store.worker_started(self)
    end

    def ==(other)
      to_s == other.to_s
    end

    def inspect
      "#<Worker #{to_s}>"
    end

    def to_s
      @to_s ||= "#{hostname}:#{master_pid}:#{@queues.join(',').gsub(":", "~")}:#{worker_count}:#{thread_count}:#{jobs_per_fork}"
    end
    alias_method :id, :to_s

    def hostname
      @hostname ||= Socket.gethostname
    end

    # Returns Integer PID of master worker
    def master_pid
      @master_pid ||= Process.pid
    end

    def procline(string)
      $0 = "#{ENV['RESQUE_PROCLINE_PREFIX']}resque-#{Resque::Version}: #{string}"
      log_with_severity :debug, $0
    end

    def log(message)
      info(message)
    end

    def log!(message)
      debug(message)
    end

    attr_reader :verbose, :very_verbose

    def verbose=(value);
      if value && !very_verbose
        Resque.logger.formatter = VerboseFormatter.new
        Resque.logger.level = Logger::INFO
      elsif !value
        Resque.logger.formatter = QuietFormatter.new
      end

      @verbose = value
    end

    def very_verbose=(value)
      if value
        Resque.logger.formatter = VeryVerboseFormatter.new
        Resque.logger.level = Logger::DEBUG
      elsif !value && verbose
        Resque.logger.formatter = VerboseFormatter.new
        Resque.logger.level = Logger::INFO
      else
        Resque.logger.formatter = QuietFormatter.new
      end

      @very_verbose = value
    end

    def log_with_severity(severity, message)
      Logging.log(severity, message)
    end

    def run_hook(name, *args)
      hooks = Resque.send(name)
      return if hooks.empty?
      return if name == :before_first_fork && @before_first_fork_hook_ran
      msg = "Running #{name} hooks"
      msg << " with #{args.inspect}" if args.any?
      log_with_severity :info, msg

      hooks.each do |hook|
        begin
          args.any? ? hook.call(*args) : hook.call
        rescue StandardError => e
          log_with_severity :error, "Error running hook #{name}: #{e.message} #{e.backtrace}"
        end
        @before_first_fork_hook_ran = true if name == :before_first_fork
      end
    end
  end
end
