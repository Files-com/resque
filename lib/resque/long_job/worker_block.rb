class LongJob
  class WorkerBlock
    def initialize(interval, block)
      @interval = interval
      @block = block
      @units_remaining = interval
    end

    def all_units_worked
      @block.call
    end

    def unit_worked
      return unless @interval > 0

      @units_remaining -= 1
      if @units_remaining <= 0
        @block.call
        @units_remaining = @interval
      end
    end
  end
end
