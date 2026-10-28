require "../pg"

module Rayo::PG
  # Bounded worker-local collection. Groups stay owned until their final query
  # completes, so multi-stage enrichment never borrows another round's storage.
  class Coalescer(T)
    class Group(T)
      getter size = 0
      getter key = 0
      property phase = 0 # free, collecting, in flight
      property sequence = 0_u64
      getter owner : Coalescer(T)
      @states : Pointer(T?)
      @callbacks : Pointer(Proc(Result, T, Nil)?)
      @params : Array(Batch)

      def initialize(@owner, capacity : Int32, parameters : Int32)
        @states = Pointer(T?).malloc(capacity, nil)
        @callbacks = Pointer(Proc(Result, T, Nil)?).malloc(capacity, nil)
        @params = Array(Batch).new(parameters) { Batch.new }
      end

      def begin(@key : Int32, @sequence : UInt64) : Nil
        @phase = 1
      end

      def add(state : T, args : Tuple, callback : Proc(Result, T, Nil)?) : Nil
        raise ArgumentError.new("wrong array parameter count") unless args.size == @params.size
        # Validate before changing any array; rejected inputs cannot skew ordinals.
        args.each do |arg|
          if arg.is_a?(String) || arg.is_a?(Bytes)
            raise ArgumentError.new("NUL in array element") if arg.to_slice.includes?(0_u8)
          end
        end
        args.each_with_index { |arg, i| @params[i].add(arg) }
        @states[@size] = state
        @callbacks[@size] = callback
        @size &+= 1
      end

      def [](index : Int32) : T
        raise IndexError.new unless 0 <= index < @size
        @states[index].as(T)
      end

      def each(& : T ->) : Nil
        @size.times { |i| yield self[i] }
      end

      def param(index : Int32) : ArrayParam
        @params[index].param
      end

      # Query rows carry a one-based ordinal in column zero, ordered by it.
      # Keep that column so the result remains a borrowed view, with no row copy.
      def query(conn : Conn, statement : Statement, *args) : Nil
        conn.query(statement, *args, state: self.as(Void*)) do |res, state|
          state.as(Group(T)).deliver(res)
        end
      rescue Error
        deliver(Result.new(Bytes.empty, 0, "08006".to_slice, "batch query could not be queued".to_slice))
      end

      def deliver(result : Result) : Nil
        first_error = nil.as(Exception?)
        unless result.valid_partitions?(@size)
          result = Result.new(Bytes.empty, 0, "22000".to_slice, "invalid batch ordinal/order".to_slice)
        end
        begin
          result.each_partition(@size) do |part, i|
            begin
              @callbacks[i].try &.call(part, self[i])
            rescue ex
              first_error ||= ex
            end
          end
        ensure
          done
        end
        raise first_error.not_nil! if first_error
      end

      # Custom dispatchers call done only after their last borrowed row is consumed.
      def done : Nil
        raise Error.new("group is not in flight") unless @phase == 2
        @size.times do |i|
          @states[i] = nil
          @callbacks[i] = nil
        end
        @params.each &.clear
        @size = 0
        @phase = 0
        @owner.completed
      end

      def close : Nil
        @params.each &.close
      end
    end

    getter in_flight = 0
    getter queued = 0
    getter batch_size : Int32
    getter parameters : Int32
    @groups : Array(Group(T))
    @dispatch : Proc(Group(T), Nil)
    @sequence = 0_u64
    @last = 0_i64
    @collection_depth = 0
    @closed = false

    def initialize(@batch_size = 128, groups = 32, @depth = 2, @parameters = 1,
                   @window_us = 1000, @max_window_us = 5000, &@dispatch : Group(T) -> Nil)
      raise ArgumentError.new("invalid coalescer limits") unless @batch_size > 0 && groups > @depth && @depth > 0 && @parameters >= 0 && 0 <= @window_us <= @max_window_us
      raise ArgumentError.new("dispatch must not capture") if @dispatch.closure?
      @groups = Array(Group(T)).new(groups)
      groups.times { @groups << Group(T).new(self, @batch_size, @parameters) }
    end

    def enqueue(state : T, *args, key : Int32 = 0) : Nil
      append(state, args, key, nil)
    end

    def enqueue(state : T, *args, key : Int32 = 0, &callback : Result, T -> Nil) : Nil
      raise ArgumentError.new("callback must not capture; use state") if callback.closure?
      append(state, args, key, callback)
    end

    def available?(key : Int32 = 0) : Bool
      !@closed && @groups.any? { |g| g.phase == 0 || (g.phase == 1 && g.key == key && g.size < @batch_size) }
    end

    private def append(state : T, args : Tuple, key : Int32, callback : Proc(Result, T, Nil)?) : Nil
      raise Error.new("coalescer closed") if @closed
      group = @groups.find { |g| g.phase == 1 && g.key == key && g.size < @batch_size }
      unless group
        group = @groups.find { |g| g.phase == 0 } || raise DepthError.new("coalescer queue full")
        @sequence &+= 1
        group.begin(key, @sequence)
      end
      begin
        group.add(state, args, callback)
        @collection_depth = @queued == 0 ? @in_flight : Math.max(@collection_depth, @in_flight)
        @queued &+= 1
      rescue ex
        group.phase = 0 if group.size == 0
        raise ex
      end
    end

    # Returns the next wake deadline (monotonic ns), or nil. No wait is added to
    # idle traffic. Busy pipelines collect longer, capped to bound tail latency.
    def flush(now : Int64 = Sys.now_ns(Sys::CLOCK_MONOTONIC)) : Int64?
      return nil if @closed || @queued == 0 || @in_flight >= @depth
      # A fast completion must not collapse a busy collection window: these
      # requests arrived behind work, even if that work finishes before the timer.
      collection_depth = Math.max(@collection_depth, @in_flight)
      window = Math.min(@window_us.to_i64 * collection_depth, @max_window_us.to_i64) * 1000
      deadline = @last &+ window
      return deadline if collection_depth > 0 && now < deadline
      while @in_flight < @depth
        group = nil.as(Group(T)?)
        @groups.each do |g|
          group = g if g.phase == 1 && g.size > 0 && (!group || g.sequence < group.sequence)
        end
        break unless group
        group.phase = 2
        @queued &-= group.size
        @in_flight &+= 1
        @last = now
        begin
          @dispatch.call(group)
        rescue ex
          # Default callbacks still need completion when a dispatcher fails
          # before queuing. Custom dispatchers own their retained handles.
          begin
            if group.phase == 2
              group.deliver(Result.new(Bytes.empty, 0, "08006".to_slice, "batch dispatch failed".to_slice))
            end
          rescue
            # Preserve the dispatch exception after finishing every callback.
          end
          raise ex
        end
      end
      nil
    end

    def completed : Nil
      @in_flight &-= 1
    end

    def close : Nil
      return if @closed
      raise Error.new("coalescer still has requests") unless @queued == 0 && @in_flight == 0
      @closed = true
      @groups.each &.close
    end
  end
end
