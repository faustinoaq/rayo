require "../sqlite"
require "../app"
require "../uring"

module Rayo::SQLite
  # Opt-in commit-before-response batching. Separate queues allow finishing one
  # batch to dispatch pipelined requests into the next transaction safely.
  class GroupCommit
    include Uring::Flusher
    @pending : Pointer(Context::Deferred)
    @finishing : Pointer(Context::Deferred)
    @size = 0
    @failed = false

    def initialize(@database : Database, @capacity = 1024)
      raise ArgumentError.new("capacity must be positive") if @capacity < 1
      @pending = Pointer(Context::Deferred).malloc(@capacity)
      @finishing = Pointer(Context::Deferred).malloc(@capacity)
    end

    def attach : Nil
      Uring.add_flusher(self)
    end

    def transaction(ctx : Context, &) : Nil
      flush if @size == @capacity
      @database.exec("BEGIN") if @size == 0
      @pending[@size] = ctx.defer
      @size &+= 1
      begin
        yield @database
      rescue
        @failed = true
      end
    end

    def flush : Nil
      while @size > 0
        failed = @failed
        begin
          @database.exec(failed ? "ROLLBACK" : "COMMIT")
        rescue
          failed = true
          @database.exec("ROLLBACK") rescue nil
        end
        count = @size
        @size = 0
        @failed = false
        @pending, @finishing = @finishing, @pending
        count.times do |i|
          handle = @finishing[i]
          handle.context.try &.database_error if failed
          handle.finish
        end
      end
    end
  end
end
