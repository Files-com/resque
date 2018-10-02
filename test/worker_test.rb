require 'test_helper'
require 'tmpdir'

describe "Resque::Worker" do
  class DummyLogger
    def initialize
      @rd, @wr = IO.pipe
    end

    def info(message); @wr << message << "\0"; end
    alias_method :debug, :info
    alias_method :warn,  :info
    alias_method :error, :info
    alias_method :fatal, :info

    def messages
      @wr.close
      @rd.read.split("\0")
    end
  end

  def attach_worker_thread_to_worker
    @worker.instance_variable_set(:@worker_threads, [ @worker_thread ])
  end

  before do
    @worker = Resque::Worker.new(:jobs)
    @worker_thread = Resque::WorkerThread.new(@worker)
    Resque::Job.create(:jobs, SomeJob, 20, '/tmp')
  end

  it "can fail jobs" do
    Resque::Job.create(:jobs, BadJob)
    @worker.work(0)
    assert_equal 1, Resque::Failure.count
  end

  it "failed jobs report exception and message" do
    Resque::Job.create(:jobs, BadJobWithSyntaxError)
    @worker.work(0)
    assert_equal('SyntaxError', Resque::Failure.all['exception'])
    assert_equal('Extra Bad job!', Resque::Failure.all['error'])
  end

  it "does not allow exceptions from failure backend to escape" do
    job = Resque::Job.new(:jobs, {})
    with_failure_backend BadFailureBackend do
      @worker_thread.perform job
    end
  end

  it "does not raise exception for completed jobs" do
    without_forking do
      @worker.work(0)
    end
    assert_equal 0, Resque::Failure.count
  end

  it "writes to ENV['PIDFILE'] when supplied and #prepare is called" do
    with_pidfile do
      tmpfile = Tempfile.new("test_pidfile")
      File.expects(:open).with(ENV["PIDFILE"], anything).returns tmpfile
      @worker.prepare
    end
  end

  it "daemonizes when ENV['BACKGROUND'] is supplied and #prepare is called" do
    Process.expects(:daemon)
    with_background do
      @worker.prepare
    end
  end

  it "does report failure for jobs with invalid payload" do
    job = Resque::Job.new(:jobs, { 'class' => 'NotAValidJobClass', 'args' => '' })
    @worker_thread.perform job
    assert_equal 1, Resque::Failure.count, 'failure not reported'
  end

  it "fails uncompleted jobs with DirtyExit by default on exit" do
    @worker_thread.job = Resque::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    attach_worker_thread_to_worker
    @worker.unregister_worker
    assert_equal 1, Resque::Failure.count
    assert_equal('Resque::DirtyExit', Resque::Failure.all['exception'])
    assert_equal('Job still being processed', Resque::Failure.all['error'])
  end

  it "fails uncompleted jobs with worker exception on exit" do
    @worker_thread.job = Resque::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    attach_worker_thread_to_worker
    @worker.unregister_worker(StandardError.new)
    assert_equal 1, Resque::Failure.count
    assert_equal('StandardError', Resque::Failure.all['exception'])
  end

  def raised_exception(klass,message)
    raise klass,message
  rescue Exception => ex
    ex
  end

  class ::SimpleJobWithFailureHandling
    def self.on_failure_record_failure(exception, *job_args)
      @@exception = exception
    end

    def self.exception
      @@exception
    end
  end

  it "fails uncompleted jobs on exit, and calls failure hook" do
    @worker_thread.job = Resque::Job.new(:jobs, {'class' => 'SimpleJobWithFailureHandling', 'args' => ""})
    attach_worker_thread_to_worker
    @worker.unregister_worker
    assert_equal 1, Resque::Failure.count
    assert_kind_of Resque::DirtyExit, SimpleJobWithFailureHandling.exception
  end

  it "fails uncompleted jobs on exit and unregisters without erroring out and logs helpful message if error occurs during a failure hook" do
    Resque.logger = DummyLogger.new

    begin
      @worker_thread.job = Resque::Job.new(:jobs, {'class' => 'BadJobWithOnFailureHookFail', 'args' => []})
      attach_worker_thread_to_worker
      @worker.unregister_worker
      messages = Resque.logger.messages
    ensure
      reset_logger
    end
    assert_equal 1, Resque::Failure.count
    error_message = messages.first
    assert_match('Additional error (RuntimeError: This job is just so bad!)', error_message)
    assert_match('occurred in running failure hooks', error_message)
    assert_match('for job (Job{jobs} | BadJobWithOnFailureHookFail | [])', error_message)
    assert_match('Original error that caused job failure was RuntimeError: Resque::DirtyExit', error_message)
  end

  class ::SimpleFailingJob
    @@exception_count = 0

    def self.on_failure_record_failure(exception, *job_args)
      @@exception_count += 1
    end

    def self.exception_count
      @@exception_count
    end

    def self.perform
      raise Exception.new
    end
  end

  it "only calls failure hook once on exception" do
    job = Resque::Job.new(:jobs, {'class' => 'SimpleFailingJob', 'args' => ""})
    @worker_thread.perform(job)
    assert_equal 1, Resque::Failure.count
    assert_equal 1, SimpleFailingJob.exception_count
  end

  it "can peek at failed jobs" do
    10.times { Resque::Job.create(:jobs, BadJob) }
    @worker.work(0)
    assert_equal 10, Resque::Failure.count

    assert_equal 10, Resque::Failure.all(0, 20).size
  end

  it "does not clear failed jobs that haven't yet been retried" do
    Resque::Job.create(:jobs, BadJob)
    @worker.work(0)
    assert_equal 1, Resque::Failure.count
    Resque::Failure.clear
    assert_equal 1, Resque::Failure.count
  end

  it "can clear failed jobs that have been retried" do
    Resque::Job.create(:jobs, BadJob)
    @worker.work(0)
    assert_equal 1, Resque::Failure.count
    job = Resque::Failure.all(0)
    job['retried_at'] = Time.now.strftime("%Y/%m/%d %H:%M:%S")
    Resque.redis.lset(:failed, 0, Resque.encode(job))
    Resque::Failure.clear
    assert_equal 0, Resque::Failure.count
  end

  it "catches exceptional jobs" do
    Resque::Job.create(:jobs, BadJob)
    Resque::Job.create(:jobs, BadJob)
    @worker.work_one_job
    @worker.work_one_job
    @worker.work_one_job
    assert_equal 2, Resque::Failure.count
  end

  it "supports setting the procline to have arbitrary prefixes and suffixes" do
    prefix = 'WORKER-TEST-PREFIX/'
    suffix = 'worker-test-suffix'
    ver = Resque::Version

    old_prefix = ENV['RESQUE_PROCLINE_PREFIX']
    ENV.delete('RESQUE_PROCLINE_PREFIX')
    old_procline = $0

    @worker.procline(suffix)
    assert_equal $0, "resque-#{ver}: #{suffix}"

    ENV['RESQUE_PROCLINE_PREFIX'] = prefix
    @worker.procline(suffix)
    assert_equal $0, "#{prefix}resque-#{ver}: #{suffix}"

    $0 = old_procline
    if old_prefix.nil?
      ENV.delete('RESQUE_PROCLINE_PREFIX')
    else
      ENV['RESQUE_PROCLINE_PREFIX'] = old_prefix
    end
  end

  it "strips whitespace from queue names" do
    queues = "critical, high, low".split(',')
    worker = Resque::Worker.new(*queues)
    assert_equal %w( critical high low ), worker.queues
  end

  it "can work on multiple queues" do
    Resque::Job.create(:high, GoodJob)
    Resque::Job.create(:critical, GoodJob)

    worker = Resque::Worker.new(:critical, :high)

    worker.work_one_job
    assert_equal 1, Resque.size(:high)
    assert_equal 0, Resque.size(:critical)

    worker.work_one_job
    assert_equal 0, Resque.size(:high)
  end

  it "can work off one job" do
    Resque::Job.create(:jobs, GoodJob)
    assert_equal 2, Resque.size(:jobs)
    assert_equal true, @worker.work_one_job
    assert_equal 1, Resque.size(:jobs)

    @worker.pause_processing
    @worker.work_one_job
    assert_equal 1, Resque.size(:jobs)

    @worker.unpause_processing
    assert_equal true, @worker.work_one_job
    assert_equal 0, Resque.size(:jobs)

    assert_equal false, @worker.work_one_job
  end

  it "the queues method avoids unnecessary calls to retrieve queue names" do
    worker = Resque::Worker.new(:critical, :high, "num*")
    actual_queues = ["critical", "high", "num1", "num2"]
    Resque.data_store.expects(:queue_names).once.returns(actual_queues)
    assert_equal actual_queues, worker.queues
  end

  it "can work on all queues" do
    Resque::Job.create(:high, GoodJob)
    Resque::Job.create(:critical, GoodJob)
    Resque::Job.create(:blahblah, GoodJob)

    @worker = Resque::Worker.new("*")
    @worker.work(0)

    assert_equal 0, Resque.size(:high)
    assert_equal 0, Resque.size(:critical)
    assert_equal 0, Resque.size(:blahblah)
  end

  it "can work with wildcard at the end of the list" do
    Resque::Job.create(:high, GoodJob)
    Resque::Job.create(:critical, GoodJob)
    Resque::Job.create(:blahblah, GoodJob)
    Resque::Job.create(:beer, GoodJob)

    @worker = Resque::Worker.new(:critical, :high, "*")
    @worker.work(0)

    assert_equal 0, Resque.size(:high)
    assert_equal 0, Resque.size(:critical)
    assert_equal 0, Resque.size(:blahblah)
    assert_equal 0, Resque.size(:beer)
  end

  it "can work with wildcard at the middle of the list" do
    Resque::Job.create(:high, GoodJob)
    Resque::Job.create(:critical, GoodJob)
    Resque::Job.create(:blahblah, GoodJob)
    Resque::Job.create(:beer, GoodJob)

    @worker = Resque::Worker.new(:critical, "*", :high)
    @worker.work(0)

    assert_equal 0, Resque.size(:high)
    assert_equal 0, Resque.size(:critical)
    assert_equal 0, Resque.size(:blahblah)
    assert_equal 0, Resque.size(:beer)
  end

  it "processes * queues in alphabetical order" do
    Resque::Job.create(:high, GoodJob)
    Resque::Job.create(:critical, GoodJob)
    Resque::Job.create(:blahblah, GoodJob)

    processed_queues = []
    @worker = Resque::Worker.new("*")
    without_forking do
      @worker.work(0) do |job|
        processed_queues << job.queue
      end
    end

    assert_equal %w( jobs high critical blahblah ).sort, processed_queues
  end

  it "works with globs" do
    Resque::Job.create(:critical, GoodJob)
    Resque::Job.create(:test_one, GoodJob)
    Resque::Job.create(:test_two, GoodJob)

    @worker = Resque::Worker.new("test_*")
    @worker.work(0)

    assert_equal 1, Resque.size(:critical)
    assert_equal 0, Resque.size(:test_one)
    assert_equal 0, Resque.size(:test_two)
  end

  it "has a unique id" do
    assert_equal "#{`hostname`.chomp}:#{$$}:jobs", @worker.to_s
  end

  it "complains if no queues are given" do
    assert_raises Resque::NoQueueError do
      Resque::Worker.new
    end
  end

  it "fails if a job class has no `perform` method" do
    Resque::Job.create(:perform_less, Object)
    assert_equal 0, Resque::Failure.count

    @worker = Resque::Worker.new(:perform_less)
    @worker.work(0)

    assert_equal 1, Resque::Failure.count
  end

  it "inserts itself into the 'workers' list on startup" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal @worker, Resque.workers[0]
      end
    end
  end

  it "removes itself from the 'workers' list on shutdown" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal @worker, Resque.workers[0]
      end
    end

    assert_equal [], Resque.workers
  end

  it "removes worker with stringified id" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        worker_id = Resque.workers[0].to_s
        Resque.remove_worker(worker_id)
        assert_equal [], Resque.workers
      end
    end
  end

  it "records what it is working on" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        task = @worker.job
        assert_equal({"args"=>[20, "/tmp"], "class"=>"SomeJob", "generation" => 1, "id" => task['payload']['id']}, task['payload'])
        assert task['run_at']
        assert_equal 'jobs', task['queue']
      end
    end
  end

  it "knows who is working" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal [@worker], Resque.working
      end
    end
  end

  it "caches the current job iff reloading is disabled" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        first_instance = @worker.job
        second_instance = @worker.job
        refute_equal first_instance.object_id, second_instance.object_id

        first_instance = @worker.job(false)
        second_instance = @worker.job(false)
        assert_equal first_instance.object_id, second_instance.object_id
      end
    end
  end

  it "keeps track of how many jobs it has processed" do
    Resque::Job.create(:jobs, BadJob)
    Resque::Job.create(:jobs, BadJob)

    3.times do
      @worker.work_one_job
    end
    assert_equal 3, @worker.processed
  end

  it "keeps track of how many failures it has seen" do
    Resque::Job.create(:jobs, BadJob)
    Resque::Job.create(:jobs, BadJob)

    3.times do
      @worker.work_one_job
    end
    assert_equal 2, @worker.failed
  end

  it "stats are erased when the worker goes away" do
    @worker.work(0)
    assert_equal 0, @worker.processed
    assert_equal 0, @worker.failed
  end

  it "knows when it started" do
    time = Time.now
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert Time.parse(@worker.started) - time < 0.1
      end
    end
  end

  it "knows whether it exists or not" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert Resque::Worker.exists?(@worker)
        assert !Resque::Worker.exists?('blah-blah')
      end
    end
  end

  it "knows what host it's running on" do
    without_forking do
      blah_worker = nil
      Socket.stub :gethostname, 'blah-blah' do
        blah_worker = Resque::Worker.new(:jobs)
        blah_worker.register_worker
      end

      @worker.extend(AssertInWorkBlock).work(0) do
        assert Resque::Worker.exists?(blah_worker)
        assert_equal Resque::Worker.find(blah_worker).hostname, 'blah-blah'
      end
    end
  end

  it "sets $0 while working" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        prefix = ENV['RESQUE_PROCLINE_PREFIX']
        ver = Resque::Version
        assert_equal "#{prefix}resque-#{ver}: Processing jobs since #{Time.now.to_i} [SomeJob]", $0
      end
    end
  end

  it "can be found" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        found = Resque::Worker.find(@worker.to_s)

        # we ensure that the found ivar @pid is set to the correct value since
        # Resque::Worker#pid will use it instead of Process.pid if present
        assert_equal @worker.pid, found.instance_variable_get(:@pid)

        assert_equal @worker.to_s, found.to_s
        assert found.working?
        assert_equal @worker.job, found.job
      end
    end
  end

  it 'can find others' do
    without_forking do
      # inject fake worker
      other_worker = Resque::Worker.new(:other_jobs)
      other_worker.pid = 123456
      other_worker.register_worker

      begin
        @worker.extend(AssertInWorkBlock).work(0) do
          found = Resque::Worker.find(other_worker.to_s)
          assert_equal other_worker.to_s, found.to_s
          assert_equal other_worker.pid, found.pid
          assert !found.working?
          assert found.job.empty?
        end
      ensure
        other_worker.unregister_worker
      end
    end
  end

  it "doesn't find fakes" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        found = Resque::Worker.find('blah-blah')
        assert_equal nil, found
      end
    end
  end

  it "doesn't write PID file when finding" do
    with_pidfile do
      File.expects(:open).never

      without_forking do
        @worker.work(0) do
          Resque::Worker.find(@worker.to_s)
        end
      end
    end
  end

  it "Processed jobs count" do
    @worker.work(0)
    assert_equal 1, Resque.info[:processed]
  end

  it "setting verbose to true" do
    @worker.verbose = true

    assert @worker.verbose
    assert !@worker.very_verbose
  end

  it "setting verbose to false" do
    @worker.verbose = false

    assert !@worker.verbose
    assert !@worker.very_verbose
  end

  it "setting very_verbose to true" do
    @worker.very_verbose = true

    assert !@worker.verbose
    assert @worker.very_verbose
  end

  it "setting setting verbose to true and then very_verbose to false" do
    @worker.very_verbose = true
    @worker.verbose      = true
    @worker.very_verbose = false

    assert @worker.verbose
    assert !@worker.very_verbose
  end

  it "verbose prints out logs" do
    messages        = StringIO.new
    Resque.logger   = Logger.new(messages)
    @worker.verbose = true

    @worker.log("omghi mom")

    assert_equal "*** omghi mom\n", messages.string
  end

  it "unsetting verbose works" do
    messages        = StringIO.new
    Resque.logger   = Logger.new(messages)
    @worker.verbose = true
    @worker.verbose = false

    @worker.log("omghi mom")

    assert_equal "", messages.string
  end

  it "very verbose works in the afternoon" do
    messages        = StringIO.new
    Resque.logger   = Logger.new(messages)

    with_fake_time(Time.parse("15:44:33 2011-03-02")) do
      @worker.very_verbose = true
      @worker.log("some log text")

      assert_match(/\*\* \[15:44:33 2011-03-02\] \d+: some log text/, messages.string)
    end
  end

  it "keeps a custom logger state after a new worker is instantiated if there is no verbose options" do
    messages                = StringIO.new
    custom_logger           = Logger.new(messages)
    custom_logger.level     = Logger::FATAL
    custom_formatter        = proc do |severity, datetime, progname, msg|
      formatter.call(severity, datetime, progname, msg.dump)
    end
    custom_logger.formatter = custom_formatter

    Resque.logger = custom_logger

    ENV.delete 'VERBOSE'
    ENV.delete 'VVERBOSE'
    @worker = Resque::Worker.new(:jobs)

    assert_equal custom_logger, Resque.logger
    assert_equal Logger::FATAL, Resque.logger.level
    assert_equal custom_formatter, Resque.logger.formatter
  end

  it "returns PID of running process" do
    assert_equal @worker.to_s.split(":")[1].to_i, @worker.pid
  end

  it "requeue failed queue" do
    queue = 'good_job'
    Resque::Failure.create(:exception => Exception.new, :worker => Resque::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    Resque::Failure.create(:exception => Exception.new, :worker => Resque::Worker.new(queue), :queue => 'some_job', :payload => {'class' => 'SomeJob'})
    Resque::Failure.requeue_queue(queue)
    assert Resque::Failure.all(0).has_key?('retried_at')
    assert !Resque::Failure.all(1).has_key?('retried_at')
  end

  it "remove failed queue" do
    queue = 'good_job'
    queue2 = 'some_job'
    Resque::Failure.create(:exception => Exception.new, :worker => Resque::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    Resque::Failure.create(:exception => Exception.new, :worker => Resque::Worker.new(queue2), :queue => queue2, :payload => {'class' => 'SomeJob'})
    Resque::Failure.create(:exception => Exception.new, :worker => Resque::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    Resque::Failure.remove_queue(queue)
    assert_equal queue2, Resque::Failure.all(0)['queue']
    assert_equal 1, Resque::Failure.count
  end

  it "logs errors with the correct logging level" do
    messages = StringIO.new
    Resque.logger = Logger.new(messages)
    @worker_thread.job = BadJobWithSyntaxError
    @worker_thread.report_failed_job(SyntaxError)

    assert_equal 0, messages.string.scan(/INFO/).count
    assert_equal 2, messages.string.scan(/ERROR/).count
  end

  it "logs info with the correct logging level" do
    messages = StringIO.new
    Resque.logger = Logger.new(messages)
    @worker.shutdown

    assert_equal 1, messages.string.scan(/INFO/).count
    assert_equal 0, messages.string.scan(/ERROR/).count
  end

  class ForkResultJob
    @queue = :jobs

    def self.perform_with_result(worker, &block)
      @rd, @wr = IO.pipe
      @block = block
      Resque.enqueue(self)
      worker.work(0)
      @wr.close
      Marshal.load(@rd.read)
    ensure
      @rd, @wr, @block = nil
    end

    def self.perform
      result = @block.call
      @wr.write(Marshal.dump(result))
      @wr.close
    end
  end

  def run_in_job(&block)
    ForkResultJob.perform_with_result(@worker, &block)
  end

end
