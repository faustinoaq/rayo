module Rayo::PG
  struct Row
    def initialize(@data : Bytes)
    end

    def size : Int32
      Wire.i16(@data.to_unsafe)
    end

    private def field(col : Int32) : {UInt8*, Int32}
      raise IndexError.new unless 0 <= col < size
      p = @data.to_unsafe + 2
      col.times { p += 4 + Math.max(Wire.i32(p), 0) }
      {p + 4, Wire.i32(p)}
    end

    def null?(col : Int32) : Bool
      field(col)[1] == -1
    end

    def str(col : Int32) : Bytes
      p, n = field(col)
      raise Error.new("NULL column") if n < 0
      Bytes.new(p, n)
    end

    def i64(col : Int32) : Int64
      self.class.integer(str(col))
    end

    def i32(col : Int32) : Int32
      i64(col).to_i32
    end

    def bool(col : Int32) : Bool
      str(col) == "t".to_slice
    end

    # Accumulate negative values so Int64::MIN is representable.
    def self.integer(s : Bytes) : Int64
      raise Error.new("invalid integer") if s.empty?
      negative = s[0] == 45
      i = negative ? 1 : 0
      raise Error.new("invalid integer") if i == s.size
      n = 0_i64
      while i < s.size
        d = s[i].to_i64 - 48
        raise Error.new("invalid integer") unless 0 <= d <= 9
        n = n * 10 - d
        i &+= 1
      end
      negative ? n : -n
    end

    def each_i64(col : Int32, & : Int64? ->) : Nil
      scratch = uninitialized UInt8[32]
      each_array(col, Bytes.new(pointerof(scratch).as(UInt8*), 32)) do |value|
        yield value ? self.class.integer(value) : nil
      end
    end

    # Escaped elements are decoded into caller-owned scratch, reused at every yield.
    # Supports one-dimensional arrays, including explicit lower bounds and NULLs.
    def each_array(col : Int32, scratch : Bytes, & : Bytes? ->) : Nil
      s = str(col)
      i = 0
      while i < s.size && s[i] != 123
        i &+= 1
      end
      raise Error.new("invalid array") if i == s.size
      i &+= 1
      return if s[i]? == 125
      loop do
        quoted = s[i]? == 34
        i &+= 1 if quoted
        n = 0
        closed = !quoted
        while i < s.size
          b = s[i]
          if quoted && b == 34
            i &+= 1
            closed = true
            break
          end
          break if !quoted && (b == 44 || b == 125)
          raise Error.new("multidimensional array") if !quoted && b == 123
          if b == 92
            i &+= 1
            raise Error.new("invalid array escape") if i >= s.size
            b = s[i]
          end
          raise Error.new("array scratch too small") if n >= scratch.size
          scratch[n] = b
          n &+= 1
          i &+= 1
        end
        raise Error.new("invalid array") unless closed
        value = scratch[0, n]
        yield !quoted && value == "NULL".to_slice ? nil : value
        delimiter = s[i]?
        break if delimiter == 125
        raise Error.new("invalid array delimiter") unless delimiter == 44
        i &+= 1
      end
    end
  end

  # Views into Conn's reusable buffers: consume in the callback or copy explicitly.
  struct Result
    getter size : Int32
    getter rows_affected : Int64
    getter sqlstate : Bytes
    getter message : Bytes

    def initialize(@data : Bytes, @size : Int32, @sqlstate : Bytes, @message : Bytes, @rows_affected : Int64 = 0)
    end

    def error? : Bool
      !@sqlstate.empty?
    end

    def first? : Row?
      return nil if @size == 0
      n = Wire.i32(@data.to_unsafe)
      Row.new(@data[4, n])
    end

    def valid_partitions?(count : Int32) : Bool
      last = 0
      each do |row|
        return false if row.size == 0 || row.null?(0)
        ordinal = row.i32(0)
        return false unless last <= ordinal <= count && ordinal > 0
        last = ordinal
      end
      true
    rescue Error | OverflowError
      false
    end

    # Split sorted one-based request ordinals in one pass, including empty
    # partitions. Error metadata is shared by every waiting request.
    def each_partition(count : Int32, & : Result, Int32 ->) : Nil
      p = @data.to_unsafe
      remaining = @size
      count.times do |i|
        start = p
        rows = 0
        while remaining > 0
          n = Wire.i32(p)
          row = Row.new(Bytes.new(p + 4, n))
          ordinal = row.i32(0)
          raise Error.new("invalid batch ordinal/order") if ordinal < i + 1 || ordinal > count
          break if ordinal != i + 1
          p += 4 + n
          remaining &-= 1
          rows &+= 1
        end
        yield Result.new(Bytes.new(start, (p - start).to_i32), rows, @sqlstate, @message), i
      end
    end

    def each(& : Row ->) : Nil
      p = @data.to_unsafe
      @size.times do
        n = Wire.i32(p)
        yield Row.new(Bytes.new(p + 4, n))
        p += 4 + n
      end
    end
  end
end
