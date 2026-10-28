require "../coalescer"
require "../../uring"

module Rayo::PG
  class Coalescer(T)
    # The loop owns this adapter until worker exit. Only one timer is ever armed.
    class Driver(T)
      include Uring::Flusher
      @timer = 0_u64

      def initialize(@coalescer : Coalescer(T))
      end

      def flush : Nil
        if deadline = @coalescer.flush
          if @timer == 0
            ns = deadline - Sys.now_ns(Sys::CLOCK_MONOTONIC)
            ms = ((ns + 999_999) // 1_000_000).clamp(0_i64, Int32::MAX.to_i64).to_i32
            @timer = Uring.arm_timeout(ms, ->(state : UInt64) {
              Pointer(Void).new(state).as(Driver(T)).wake
            }, self.as(Void*).address)
          end
        elsif @timer != 0
          Uring.cancel_timeout(@timer)
          @timer = 0_u64
        end
      end

      def wake : Nil
        @timer = 0_u64
        flush
      end
    end

    @driver : Driver(T)?

    def attach : Nil
      raise Error.new("coalescer already attached") if @driver
      @driver = driver = Driver(T).new(self)
      Uring.add_flusher(driver)
    end
  end
end
