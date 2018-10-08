require 'test_helper'
require 'tmpdir'

describe "Resque::Worker" do

  class LongRunningJob
    @queue = :long_running_job

    def self.perform
      Resque.redis.rpush('long-test:start', Process.pid)
      sleep 5
      Resque.redis.rpush('long-test:result', 'Finished Normally')
    ensure
      Resque.redis.rpush('long-test:ensure_block_executed', 'exiting.')
    end
  end

  def hostname
    @hostname ||= Socket.gethostname
  end

  def start_worker
    Resque.enqueue LongRunningJob

    worker_pid = Kernel.fork do
      worker = Resque::Worker.new(:long_running_job)
      suppress_warnings do
        worker.work(0)
      end
      exit!
    end

    # ensure the worker is started
    start_status = Resque.redis.blpop('long-test:start', 5)
    refute_nil start_status
    child_pid = start_status[1].to_i
    assert child_pid > 0, "worker child process not created"

    [worker_pid, child_pid]
  end

  def assert_child_not_running(child_pid)
    assert (`ps -p #{child_pid.to_s} -o pid=`).empty?
  end

  it "kills off the child when killed" do
    worker_pid, child_pid = start_worker
    assert worker_pid != child_pid
    Process.kill('TERM', worker_pid)
    Process.waitpid(worker_pid)

    result = Resque.redis.lpop('long-test:result')
    assert_nil result
    assert_child_not_running child_pid
    assert_equal('Resque::DirtyExit', Resque::Failure.all['exception'])
    assert_equal('Job was killed', Resque::Failure.all['error'])
  end

  it "kills workers via the remote kill mechanism" do
    worker_pid, _child_pid = start_worker
    thread = Resque::WorkerManager.threads_working.first
    thread.kill
    sleep 3

    result = Resque.redis.lpop('long-test:result')
    assert_nil result
    assert_equal('Resque::DirtyExit', Resque::Failure.all['exception'])
    assert_equal('Job was killed', Resque::Failure.all['error'])
  end

  it "runs if not killed" do
    _worker_pid, _child_pid = start_worker

    result = Resque.redis.blpop('long-test:result')
    assert 'Finished Normally' == result.last
  end
end
