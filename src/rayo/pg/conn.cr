module Rayo::PG
  alias Callback = Proc(Result, Int64, Nil) | Proc(Result, Void*, Nil)

  enum Preparation
    Queued
    Ready
    Failed
  end

  struct Query
    getter callback : Callback
    getter state : Int64
    getter statement : Statement

    def initialize(@callback, @state, @statement)
    end

    def deliver(result : Result) : Nil
      callback = @callback
      case callback
      when Proc(Result, Int64, Nil)
        callback.call(result, @state)
      when Proc(Result, Void*, Nil)
        callback.call(result, Pointer(Void).new(@state.to_u64!))
      end
    end
  end

  # Owns no socket. The driver sends output, acknowledges bytes via on_sent,
  # and feeds arbitrary receive fragments to on_data. One driver per connection.
  class Conn
    getter host : String = ""
    getter port : Int32 = 5432
    getter max_depth : Int32 = 0
    getter? ready = false
    getter? alive = true
    @closed = false
    @reading = false
    @queue = Pointer(Query).null
    @head = 0_u64
    @tail = 0_u64
    @queued = Buf.new(65536)
    @sending = Buf.new(65536)
    @sent = 0
    @input = Buf.new(65536)
    @rows = Buf.new(16384)
    @error = Buf.new(256)
    @code = Buf.new(8)
    @row_count = 0
    @rows_affected = 0_i64
    @prepared = {} of Statement => Preparation
    @auth : Auth?

    def initialize(url : String, @max_depth : Int32 = 16384)
      raise ArgumentError.new("max_depth must be positive") unless @max_depth > 0
      u = URI.parse(url)
      raise ArgumentError.new("expected postgres URL") unless u.scheme == "postgres" || u.scheme == "postgresql"
      options = URI::Params.parse(u.query || "")
      if ssl = options["sslmode"]?
        raise Error.new("TLS transport is not implemented; use sslmode=disable") unless ssl == "disable"
      end
      @host = u.host.presence || "127.0.0.1"
      @host = @host[1..-2] if @host.starts_with?('[')
      @port = u.port || 5432
      user = URI.decode(u.user || "postgres")
      database = URI.decode(u.path.lchop('/'))
      database = user if database.empty?
      @auth = Auth.new(user, URI.decode(u.password || ""))
      @queue = LibC.malloc(@max_depth.to_u64 * sizeof(Query)).as(Query*)
      Wire.int(@queued, 0)
      Wire.int(@queued, 196608)
      {"user" => user, "database" => database, "client_encoding" => "UTF8", "TimeZone" => "UTC", "DateStyle" => "ISO, MDY", "application_name" => options["application_name"]? || "rayo"}.each do |k, v|
        Wire.cstr(@queued, k)
        Wire.cstr(@queued, v)
      end
      @queued << 0_u8
      Wire.put(@queued.ptr, @queued.len)
    rescue ex
      {@queued, @sending, @input, @rows, @error, @code}.each { |b| LibC.free(b.ptr) }
      LibC.free(@queue)
      raise ex
    end

    def pending : Int32
      (@tail &- @head).to_i32
    end

    def dispatching? : Bool
      @reading
    end

    def available? : Bool
      @alive && @ready && pending < @max_depth
    end

    # First use emits Parse/Describe. Later uses only Bind/Execute/Sync.
    # State is a request ID or a pointer's address; use a non-capturing callback.
    def query(stmt : Statement, *args, state : Int64 = 0_i64, &callback : Result, Int64 -> Nil) : Nil
      enqueue(stmt, args, state, callback)
    end

    def query(stmt : Statement, *args, state : Pointer(T), &callback : Result, Void* -> Nil) : Nil forall T
      enqueue(stmt, args, state.address.to_i64!, callback)
    end

    private def enqueue(stmt : Statement, args : Tuple, state : Int64, callback : Callback) : Nil
      raise Error.new("connection is not ready") unless @alive && @ready
      raise DepthError.new("pipeline depth exceeded") if pending == @max_depth
      raise ArgumentError.new("callback must not capture; pass state instead") if callback.closure?
      args.each do |v|
        if v.is_a?(String) || v.is_a?(Bytes)
          raise ArgumentError.new("NUL in text parameter") if v.to_slice.includes?(0_u8)
        elsif v.is_a?(Array(String)) || v.is_a?(Slice(String))
          v.each { |item| raise ArgumentError.new("NUL in array element") if item.to_slice.includes?(0_u8) }
        end
      end
      o = @queued
      start = o.len
      begin
        if !@prepared.has_key?(stmt) || @prepared[stmt] == Preparation::Failed
          at = Wire.start(o, 'P')
          Wire.cstr(o, stmt.name)
          Wire.cstr(o, stmt.sql)
          Wire.short(o, 0)
          Wire.finish(o, at)
          at = Wire.start(o, 'D')
          o << 'S'.ord.to_u8
          Wire.cstr(o, stmt.name)
          Wire.finish(o, at)
          @prepared[stmt] = Preparation::Queued
        end
        at = Wire.start(o, 'B')
        o << 0_u8
        Wire.cstr(o, stmt.name)
        Wire.short(o, 0)
        Wire.short(o, args.size)
        args.each { |v| Wire.param(o, v) }
        Wire.short(o, 0)
        Wire.finish(o, at)
        o << "E\0\0\0\x09\0\0\0\0\0S\0\0\0\x04"
      rescue ex
        o.len = start
        @prepared[stmt] = Preparation::Failed if @prepared[stmt]? == Preparation::Queued
        raise ex
      end
      @queue[(@tail % @max_depth).to_i32] = Query.new(callback, state, stmt)
      @tail &+= 1
    end

    # Swapping keeps the submitted pointer stable while more queries are queued.
    # Call again after partial sends and after on_data produces auth responses.
    def output : Bytes
      return Bytes.empty unless @alive
      if @sending.len == @sent
        @sending, @queued = @queued, @sending
        @queued.clear
        @sent = 0
      end
      Bytes.new(@sending.ptr + @sent, @sending.len &- @sent)
    end

    def on_sent(res : Int32) : Nil
      raise Error.new("invalid send completion") if res > @sending.len &- @sent
      if res <= 0
        lost
        return
      end
      @sent &+= res
    end

    def on_data(p : UInt8*, n : Int32) : Nil
      raise Error.new("connection is closed") unless @alive
      raise Error.new("recursive on_data") if @reading
      raise ArgumentError.new("negative receive length") if n < 0
      @reading = true
      begin
        @input.write(p, n)
        off = 0
        while @input.len &- off >= 5
          b = @input.ptr + off
          len = Wire.i32(b + 1)
          raise Error.new("invalid backend message length") if len < 4 || len > 1_073_741_824
          break if @input.len &- off < len &+ 1
          # Advance before dispatch so a raised callback cannot replay a query.
          off &+= len &+ 1
          begin
            message(b[0], b + 5, len &- 4)
          rescue ex
            @input.ptr.move_from(@input.ptr + off, @input.len &- off)
            @input.len &-= off
            raise ex
          end
        end
        @input.ptr.move_from(@input.ptr + off, @input.len &- off)
        @input.len &-= off
      ensure
        @reading = false
      end
    end

    private def message(type : UInt8, p : UInt8*, n : Int32) : Nil
      unless @ready
        case type
        when 'R'.ord
          raise Error.new("invalid authentication message") if n < 4
          @auth.not_nil!.respond(Wire.i32(p), Bytes.new(p + 4, n - 4), @queued)
        when 'E'.ord
          read_error(p, n)
          raise Error.new(String.new(Bytes.new(@error.ptr, @error.len)))
        when 'Z'.ord
          @ready = true
        end
        return
      end
      return if pending == 0
      case type
      when '1'.ord
        @prepared[@queue[(@head % @max_depth).to_i32].statement] = Preparation::Ready
      when 'D'.ord
        validate_row(p, n)
        Wire.int(@rows, n)
        @rows.write(p, n)
        @row_count &+= 1
      when 'C'.ord
        raise Error.new("invalid CommandComplete") if n < 2 || p[n - 1] != 0
        start = n - 2
        while start >= 0 && p[start] >= 48 && p[start] <= 57
          start &-= 1
        end
        @rows_affected = start < n - 2 ? Row.integer(Bytes.new(p + start + 1, n - start - 2)) : 0_i64
      when 'E'.ord
        read_error(p, n)
      when 'Z'.ord
        q = @queue[(@head % @max_depth).to_i32]
        @head &+= 1
        @prepared[q.statement] = Preparation::Failed if @prepared[q.statement]? == Preparation::Queued
        result = Result.new(Bytes.new(@rows.ptr, @rows.len), @row_count, Bytes.new(@code.ptr, @code.len), Bytes.new(@error.ptr, @error.len), @rows_affected)
        begin
          q.deliver(result)
        ensure
          reset_result
        end
      end
    end

    private def validate_row(p : UInt8*, n : Int32) : Nil
      raise Error.new("invalid DataRow") if n < 2
      off = 2
      Wire.i16(p).times do
        raise Error.new("invalid DataRow") if off > n - 4
        len = Wire.i32(p + off)
        raise Error.new("invalid column length") if len < -1 || len > n - off - 4
        off &+= 4 &+ Math.max(len, 0)
      end
      raise Error.new("invalid DataRow trailing bytes") unless off == n
    end

    private def read_error(p : UInt8*, n : Int32) : Nil
      @error.clear
      @code.clear
      i = 0
      while i < n && p[i] != 0
        field = p[i]
        start = i &+ 1
        i = start
        while i < n && p[i] != 0
          i &+= 1
        end
        raise Error.new("invalid ErrorResponse") if i == n
        @code.write(p + start, i - start) if field == 'C'.ord
        @error.write(p + start, i - start) if field == 'M'.ord
        i &+= 1
      end
      @code << "XXXXX" if @code.len == 0
    end

    private def reset_result : Nil
      @rows.clear
      @error.clear
      @code.clear
      @row_count = 0
      @rows_affected = 0_i64
    end

    # Transport failures complete every outstanding callback in FIFO order.
    def lost : Nil
      return unless @alive
      @alive = false
      reset_result
      @code << "08006"
      @error << "connection lost"
      was_reading = @reading
      @reading = true
      first_error = nil.as(Exception?)
      while pending > 0
        q = @queue[(@head % @max_depth).to_i32]
        @head &+= 1
        begin
          q.deliver(Result.new(Bytes.empty, 0, Bytes.new(@code.ptr, @code.len), Bytes.new(@error.ptr, @error.len)))
        rescue ex
          first_error ||= ex
        end
      end
      @reading = was_reading
      raise first_error if first_error
    end

    def close : Nil
      raise Error.new("cannot close during callback") if @reading
      return if @closed
      @closed = true
      begin
        lost
      ensure
        {@queued, @sending, @input, @rows, @error, @code}.each { |b| LibC.free(b.ptr) }
        LibC.free(@queue)
      end
    end
  end
end
