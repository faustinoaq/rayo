require "./loop"
require "../../context/db"

module Rayo::PG
  # Carries HTTP completion counters through the generic coordinator. Storage is
  # scanned by the GC, while Deferred guards connection generation and serial.
  record ReadRequest, handle : Context::Deferred, callback : Proc(Result, Context, Nil) do
    def complete(result : Result) : Nil
      return unless ctx = handle.context
      begin
        callback.call(result, ctx)
        ctx.db_failed = true if result.error? && ctx.status == 200 && ctx.output.len == 0
      rescue
        ctx.db_failed = true
      ensure
        ctx.work_pending -= 1
        if ctx.work_pending == 0 && ctx.db_pending == 0
          ctx.database_error if ctx.db_failed
          handle.finish
        end
      end
    end
  end

  class Coalescer(T)
    # Use Coalescer(ReadRequest) for the |result, ctx| HTTP overload.
    def enqueue(ctx : Context, *args, key : Int32 = 0, &callback : Result, Context -> Nil) : Nil
      raise ArgumentError.new("callback must not capture; use ctx") if callback.closure?
      raise DepthError.new("coalescer queue full or closed") unless available?(key)
      raise ArgumentError.new("wrong array parameter count") unless args.size == @parameters
      args.each do |arg|
        if arg.is_a?(String) || arg.is_a?(Bytes)
          raise ArgumentError.new("NUL in array element") if arg.to_slice.includes?(0_u8)
        end
      end
      request = ReadRequest.new(ctx.defer, callback).as(T)
      ctx.work_pending += 1
      enqueue(request, *args, key: key) do |result, state|
        state.complete(result)
      end
    end
  end
end
