module Rayo::PG
  class Error < Exception
  end

  class DepthError < Error
  end

  # All protocol integers are network byte order, including signed NULL lengths.
  module Wire
    def self.i32(p : UInt8*) : Int32
      (p[0].to_i32 << 24) | (p[1].to_i32 << 16) | (p[2].to_i32 << 8) | p[3].to_i32
    end

    def self.i16(p : UInt8*) : Int32
      (p[0].to_i32 << 8) | p[1].to_i32
    end

    def self.put(p : UInt8*, n : Int32) : Nil
      p[0] = (n >> 24).to_u8!
      p[1] = (n >> 16).to_u8!
      p[2] = (n >> 8).to_u8!
      p[3] = n.to_u8!
    end

    def self.int(o : Buf, n : Int32) : Nil
      put(o.reserve(4), n)
      o.len &+= 4
    end

    def self.short(o : Buf, n : Int32) : Nil
      o << (n >> 8).to_u8! << n.to_u8!
    end

    def self.cstr(o : Buf, s : String) : Nil
      o << s << 0_u8
    end

    def self.start(o : Buf, type : Char) : Int32
      o << type.ord.to_u8
      at = o.len
      int(o, 0)
      at
    end

    def self.finish(o : Buf, at : Int32) : Nil
      put(o.ptr + at, o.len &- at)
    end

    def self.param(o : Buf, v : Nil) : Nil
      int(o, -1)
    end

    def self.param(o : Buf, v : String | Bytes) : Nil
      int(o, v.bytesize)
      o.write(v.to_unsafe, v.bytesize)
    end

    def self.param(o : Buf, v : Int32 | Int64) : Nil
      at = o.len
      int(o, 0)
      o << v
      put(o.ptr + at, o.len &- at &- 4)
    end

    def self.param(o : Buf, v : Bool) : Nil
      int(o, 1)
      o << (v ? 116_u8 : 102_u8)
    end

    def self.param(o : Buf, values : Array(Int64) | Array(String) | Slice(Int64) | Slice(String)) : Nil
      at = o.len
      int(o, 0)
      o << '{'.ord.to_u8
      values.each_with_index do |v, i|
        o << ','.ord.to_u8 if i > 0
        array_value(o, v)
      end
      o << '}'.ord.to_u8
      put(o.ptr + at, o.len &- at &- 4)
    end

    private def self.array_value(o : Buf, v : Int64) : Nil
      o << v
    end

    private def self.array_value(o : Buf, v : String) : Nil
      o << '"'.ord.to_u8
      v.each_byte do |b|
        o << '\\'.ord.to_u8 if b == 34 || b == 92
        o << b
      end
      o << '"'.ord.to_u8
    end
  end

  class Statement
    getter sql : String
    getter name : String
    @@next_id = 0_u64

    def initialize(@sql : String)
      raise ArgumentError.new("NUL in SQL") if @sql.to_slice.includes?(0_u8)
      @@next_id &+= 1
      @name = "rayo_#{@@next_id}"
    end
  end
end
