require "../pg"
require "../uring"

module Rayo::PG
  # Only startup uses blocking IO. Once watched, every send/receive belongs to the ring.
  class RingTransport
    include Uring::Handler
    getter conn : Conn
    @fd = -1
    @tag = -1
    @sending = false

    def initialize(url : String, depth : Int32)
      startup = BlockingTransport.new(url, depth)
      @fd, @conn = startup.detach
      begin
        @tag = Uring.watch(@fd, self)
      rescue ex
        LibC.close(@fd)
        @conn.close
        raise ex
      end
    end

    def flush : Nil
      return if @sending || !@conn.alive?
      bytes = @conn.output
      return if bytes.empty?
      @sending = true
      Uring.send_plain(@fd, bytes.to_unsafe, bytes.size, @tag)
    end

    def on_data(ptr : UInt8*, len : Int32) : Nil
      @conn.on_data(ptr, len)
    end

    def on_sent(result : Int32) : Nil
      @sending = false
      @conn.on_sent(result)
      Uring.unwatch(@tag) unless @conn.alive?
    end

    def on_closed : Nil
      @conn.lost
      @conn.close
    end
  end

  class WorkerPool
    include Uring::Flusher

    class Pending
      property handle : Context::Deferred? = nil
      property callback : Proc(Result, Context, Nil)? = nil
      property next_free = -1
      getter pool : WorkerPool
      getter callback_index : Int32

      def initialize(@pool, @callback_index)
      end

      def complete(result : Result) : Nil
        handle = @handle.not_nil!
        ctx = handle.context
        begin
          if ctx
            @callback.not_nil!.call(result, ctx)
            if result.error? && ctx.status == 200 && ctx.output.len == 0
              ctx.db_failed = true
            end
          end
        rescue
          ctx.try { |context| context.db_failed = true }
        ensure
          @pool.release(self)
          if ctx
            ctx.db_pending -= 1
            if ctx.db_pending == 0
              ctx.database_error if ctx.db_failed
              handle.finish
            end
          end
        end
      end
    end

    @transports : Array(RingTransport)
    @pool : Pool
    @pending = [] of Pending
    @free = 0

    def initialize(url : String, size : Int32, depth : Int32 = 1024)
      @transports = Array(RingTransport).new(size) { RingTransport.new(url, depth) }
      @pool = Pool.new(@transports.map(&.conn))
      @pending = Array(Pending).new(size * depth) do |i|
        record = Pending.new(self, i)
        record.next_free = i + 1 < size * depth ? i + 1 : -1
        record
      end
      Uring.add_flusher(self)
    end

    def release(record : Pending) : Nil
      # Records are retained; the integer free list needs no search or allocation.
      index = record.callback_index
      record.handle = nil
      record.callback = nil
      record.next_free = @free
      @free = index
    end

    def query(ctx : Context, stmt : Statement, *args, callback : Proc(Result, Context, Nil)) : Nil
      raise DepthError.new("request query table full") if @free < 0
      conn = @pool.pick || raise DepthError.new("no available Postgres connection")
      record = @pending[@free]
      @free = record.next_free
      record.handle = ctx.defer
      record.callback = callback
      begin
        conn.query(stmt, *args, state: record.as(Void*)) do |result, state|
          state.as(Pending).complete(result)
        end
        ctx.db_pending += 1
      rescue ex
        release(record)
        raise ex
      end
    end

    def flush : Nil
      @transports.each &.flush
    end
  end
end
