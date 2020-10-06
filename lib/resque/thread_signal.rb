class Resque::ThreadSignal
  def initialize
    @mutex = Mutex.new
    @signaled = false
    @received = ConditionVariable.new
  end

  def signal
    @mutex.synchronize do
      @signaled = true
      @received.signal
    end
  end

  def wait_for_signal(timeout)
    @mutex.synchronize do
      @received.wait(@mutex, timeout) unless @signaled

      @signaled
    end
  end
end
