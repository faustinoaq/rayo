module Rayo::PG
  # A preformatted text array. Conn copies it into Bind, so the builder may be
  # cleared immediately after query, even while a previous send is in flight.
  struct ArrayParam
    getter bytes : Bytes

    def initialize(@bytes)
    end
  end

  module Wire
    def self.param(o : Buf, v : ArrayParam) : Nil
      param(o, v.bytes)
    end
  end

  # Cross-request aggregation hook: collect IDs or strings without an Array,
  # issue one query (e.g. WHERE id = ANY($1::int8[])), then fan out in its callback
  # using caller-owned state. Transaction/group-commit policy belongs to callers.
  class Batch
    getter size = 0
    @buffer : Buf
    @finished = false
    @closed = false

    def initialize(capacity : Int32 = 4096)
      raise ArgumentError.new("capacity must be positive") unless capacity > 0
      @buffer = Buf.new(capacity)
      clear
    end

    def clear : Nil
      raise Error.new("batch closed") if @closed
      @buffer.clear
      @buffer << '{'.ord.to_u8
      @size = 0
      @finished = false
    end

    def add(value : Int64 | String | Bytes | Nil) : Nil
      raise Error.new("batch closed or finished") if @closed || @finished
      if value.is_a?(String) || value.is_a?(Bytes)
        raise ArgumentError.new("NUL in array element") if value.to_slice.includes?(0_u8)
      end
      @buffer << ','.ord.to_u8 if @size > 0
      case value
      when Int64
        @buffer << value
      when Nil
        @buffer << "NULL"
      else
        @buffer << '"'.ord.to_u8
        value.to_slice.each do |b|
          @buffer << '\\'.ord.to_u8 if b == 34 || b == 92
          @buffer << b
        end
        @buffer << '"'.ord.to_u8
      end
      @size &+= 1
    end

    def param : ArrayParam
      raise Error.new("batch closed") if @closed
      unless @finished
        @buffer << '}'.ord.to_u8
        @finished = true
      end
      ArrayParam.new(Bytes.new(@buffer.ptr, @buffer.len))
    end

    def close : Nil
      return if @closed
      @closed = true
      LibC.free(@buffer.ptr)
    end
  end
end
