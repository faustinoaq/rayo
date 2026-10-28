module Rayo::PG
  # Can wrap externally driven Conns, or own standalone blocking transports.
  class Pool
    getter connections : Array(Conn)
    @transports : Array(BlockingTransport)?
    @rr = 0

    def initialize(@connections : Array(Conn))
      raise ArgumentError.new("empty pool") if @connections.empty?
    end

    def initialize(url : String, size : Int32 = 4, max_depth : Int32 = 1024)
      raise ArgumentError.new("pool size must be positive") unless size > 0
      @connections = Array(Conn).new(size)
      transports = Array(BlockingTransport).new(size)
      @transports = transports
      begin
        size.times do
          transport = BlockingTransport.new(url, max_depth)
          transports << transport
          @connections << transport.conn
        end
      rescue ex
        transports.each(&.close)
        raise ex
      end
    end

    # Least queued; ties rotate, preserving fairness at low load.
    def pick : Conn?
      best = nil.as(Conn?)
      best_depth = Int32::MAX
      n = @connections.size
      n.times do |i|
        c = @connections[(@rr + i) % n]
        if c.available? && c.pending < best_depth
          best = c
          best_depth = c.pending
        end
      end
      @rr = (@rr &+ 1) % n
      best
    end

    def query(stmt : Statement, *args, state : Int64 = 0_i64, &callback : Result, Int64 -> Nil) : Nil
      c = pick || raise DepthError.new("no available Postgres connection")
      c.query(stmt, *args, state: state, &callback)
    end

    def query(stmt : Statement, *args, state : Pointer(T), &callback : Result, Void* -> Nil) : Nil forall T
      c = pick || raise DepthError.new("no available Postgres connection")
      c.query(stmt, *args, state: state, &callback)
    end

    def flush : Nil
      transports = @transports || raise Error.new("external transport must flush connections")
      transports.each(&.flush)
    end

    def drain : Nil
      transports = @transports || raise Error.new("external transport must drain connections")
      transports.each(&.drain)
    end

    def close : Nil
      if transports = @transports
        transports.each(&.close)
      else
        @connections.each(&.close)
      end
    end
  end
end
