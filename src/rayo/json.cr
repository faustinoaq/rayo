require "./buf"
require "float/printer"
require "float/fast_float"

module Rayo::JSON
  KIND_STRING =  1
  KIND_NUMBER =  2
  KIND_OTHER  =  3
  MAX_DEPTH   = 64

  struct Parser
    getter i : Int32 = 0
    @p : UInt8*
    @n : Int32

    def initialize(@p, @n)
    end

    @[AlwaysInline]
    def ws : Nil
      while @i < @n
        c = @p[@i]
        break unless c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
        @i &+= 1
      end
    end

    # Returns the value kind, or -1 if malformed.
    def value(depth : Int32) : Int32
      return -1 if @i >= @n || depth > 64
      c = @p[@i]
      case c
      when '"'.ord
        @i &+= 1
        string ? KIND_STRING : -1
      when '{'.ord
        return -1 if depth >= MAX_DEPTH
        object(depth) ? KIND_OTHER : -1
      when '['.ord
        return -1 if depth >= MAX_DEPTH
        @i &+= 1
        ws
        if @i < @n && @p[@i] == ']'.ord
          @i &+= 1
          return KIND_OTHER
        end
        loop do
          ws
          return -1 if value(depth &+ 1) < 0
          ws
          return -1 if @i >= @n
          if @p[@i] == ','.ord
            @i &+= 1
          elsif @p[@i] == ']'.ord
            @i &+= 1
            return KIND_OTHER
          else
            return -1
          end
        end
      when 't'.ord then lit("true") ? KIND_OTHER : -1
      when 'f'.ord then lit("false") ? KIND_OTHER : -1
      when 'n'.ord then lit("null") ? KIND_OTHER : -1
      else
        number ? KIND_NUMBER : -1
      end
    end

    def object(depth : Int32) : Bool
      @i &+= 1
      ws
      if @i < @n && @p[@i] == '}'.ord
        @i &+= 1
        return true
      end
      loop do
        ws
        return false if @i >= @n || @p[@i] != '"'.ord
        @i &+= 1
        return false unless string
        ws
        return false if @i >= @n || @p[@i] != ':'.ord
        @i &+= 1
        ws
        return false if value(depth &+ 1) < 0
        ws
        return false if @i >= @n
        if @p[@i] == ','.ord
          @i &+= 1
        elsif @p[@i] == '}'.ord
          @i &+= 1
          return true
        else
          return false
        end
      end
    end

    private def lit(s : String) : Bool
      l = s.bytesize
      return false if @i &+ l > @n || (@p + @i).memcmp(s.to_unsafe, l) != 0
      @i &+= l
      true
    end

    private def digits : Int32
      s = @i
      while @i < @n && @p[@i] >= 0x30 && @p[@i] <= 0x39
        @i &+= 1
      end
      @i &- s
    end

    private def number : Bool
      @i &+= 1 if @i < @n && @p[@i] == '-'.ord
      return false if @i >= @n
      if @p[@i] == '0'.ord
        @i &+= 1
      else
        return false if digits == 0
      end
      if @i < @n && @p[@i] == '.'.ord
        @i &+= 1
        return false if digits == 0
      end
      if @i < @n && (@p[@i] == 'e'.ord || @p[@i] == 'E'.ord)
        @i &+= 1
        @i &+= 1 if @i < @n && (@p[@i] == '+'.ord || @p[@i] == '-'.ord)
        return false if digits == 0
      end
      true
    end

    # After the opening quote; leaves @i after the closing quote.
    private def string : Bool
      while @i < @n
        c = @p[@i]
        if c == '"'.ord
          @i &+= 1
          return true
        elsif c == '\\'.ord
          @i &+= 1
          return false if @i >= @n
          e = @p[@i]
          if e == 'u'.ord
            return false if @i &+ 4 >= @n
            4.times do |k|
              return false if JSON.hexval(@p[@i &+ 1 &+ k]) < 0
            end
            cp = JSON.hex4(@p + @i + 1)
            @i &+= 5
            if cp >= 0xD800 && cp <= 0xDBFF
              return false unless @i + 6 <= @n && @p[@i] == 92 && @p[@i + 1] == 117
              lo = JSON.hex4(@p + @i + 2)
              return false unless lo >= 0xDC00 && lo <= 0xDFFF
              @i &+= 6
            elsif cp >= 0xDC00 && cp <= 0xDFFF
              return false
            end
          elsif e == '"'.ord || e == '\\'.ord || e == '/'.ord || e == 'b'.ord || e == 'f'.ord ||
                e == 'n'.ord || e == 'r'.ord || e == 't'.ord
            @i &+= 1
          else
            return false
          end
        elsif c < 0x20
          return false
        else
          @i &+= 1
        end
      end
      false
    end
  end

  @[AlwaysInline]
  def self.hexval(c : UInt8) : Int32
    return c.to_i32 &- 48 if c >= 0x30 && c <= 0x39
    return c.to_i32 &- 87 if c >= 0x61 && c <= 0x66
    return c.to_i32 &- 55 if c >= 0x41 && c <= 0x46
    -1
  end

  # Unescapes an already validated JSON string body into dst (dst needs n bytes). Returns length.
  def self.unescape(p : UInt8*, n : Int32, dst : UInt8*) : Int32
    i = 0
    o = 0
    while i < n
      c = p[i]
      if c != '\\'.ord
        dst[o] = c
        o &+= 1
        i &+= 1
        next
      end
      e = p[i &+ 1]
      i &+= 2
      case e
      when 'n'.ord then dst[o] = 0x0A; o &+= 1
      when 't'.ord then dst[o] = 0x09; o &+= 1
      when 'r'.ord then dst[o] = 0x0D; o &+= 1
      when 'b'.ord then dst[o] = 0x08; o &+= 1
      when 'f'.ord then dst[o] = 0x0C; o &+= 1
      when 'u'.ord
        cp = hex4(p + i)
        i &+= 4
        if cp >= 0xD800 && cp < 0xDC00 && i &+ 6 <= n && p[i] == '\\'.ord && p[i &+ 1] == 'u'.ord
          lo = hex4(p + (i &+ 2))
          if lo >= 0xDC00 && lo < 0xE000
            cp = 0x10000 &+ ((cp &- 0xD800) << 10) &+ (lo &- 0xDC00)
            i &+= 6
          end
        end
        o = utf8(dst, o, cp)
      else
        dst[o] = e
        o &+= 1
      end
    end
    o
  end

  def self.hex4(p : UInt8*) : Int32
    (hexval(p[0]) << 12) | (hexval(p[1]) << 8) | (hexval(p[2]) << 4) | hexval(p[3])
  end

  private def self.utf8(d : UInt8*, o : Int32, cp : Int32) : Int32
    if cp < 0x80
      d[o] = cp.to_u8!
      o &+ 1
    elsif cp < 0x800
      d[o] = (0xC0 | (cp >> 6)).to_u8!
      d[o &+ 1] = (0x80 | (cp & 0x3F)).to_u8!
      o &+ 2
    elsif cp < 0x10000
      d[o] = (0xE0 | (cp >> 12)).to_u8!
      d[o &+ 1] = (0x80 | ((cp >> 6) & 0x3F)).to_u8!
      d[o &+ 2] = (0x80 | (cp & 0x3F)).to_u8!
      o &+ 3
    else
      d[o] = (0xF0 | (cp >> 18)).to_u8!
      d[o &+ 1] = (0x80 | ((cp >> 12) & 0x3F)).to_u8!
      d[o &+ 2] = (0x80 | ((cp >> 6) & 0x3F)).to_u8!
      d[o &+ 3] = (0x80 | (cp & 0x3F)).to_u8!
      o &+ 4
    end
  end
end

module Rayo::JSON
  class Error < Exception
  end

  # Views borrow the input. String bytes retain JSON escapes until unescape is called.
  struct Reader
    getter raw : Bytes

    def initialize(@raw : Bytes)
      raise Error.new("invalid JSON") unless Reader.valid?(@raw)
      first = 0
      while first < @raw.size && whitespace?(@raw[first])
        first += 1
      end
      last = @raw.size
      while last > first && whitespace?(@raw[last - 1])
        last -= 1
      end
      @raw = @raw[first, last - first]
    end

    def self.valid?(raw : Bytes) : Bool
      return false unless JSON.valid_utf8?(raw)
      p = Parser.new(raw.to_unsafe, raw.size)
      p.ws
      return false if p.value(0) < 0
      p.ws
      p.i == raw.size
    end

    def self.parse?(raw : Bytes) : Reader?
      new(raw) if valid?(raw)
    end

    def string? : Bool
      @raw[0] == 34
    end

    private def whitespace?(c)
      c == 32 || c == 9 || c == 10 || c == 13
    end

    def object? : Bool
      @raw[0] == 123
    end

    def array? : Bool
      @raw[0] == 91
    end

    def string : Bytes
      raise Error.new("expected string") unless @raw[0] == 34
      @raw[1, @raw.size - 2]
    end

    def string(scratch : Bytes) : Bytes
      bytes = string
      raise Error.new("short scratch buffer") if scratch.size < bytes.size
      n = JSON.unescape(bytes.to_unsafe, bytes.size, scratch.to_unsafe)
      scratch[0, n]
    end

    def string_equals?(other : String) : Bool
      bytes = string
      # Decoding one codepoint at a time also handles escaped claim names.
      scratch = uninitialized UInt8[6]
      i = 0
      o = 0
      while i < bytes.size
        n = 1
        cp = 0
        if bytes[i] == 92
          n = bytes[i + 1] == 117 ? 6 : 2
          cp = JSON.hex4(bytes.to_unsafe + i + 2) if n == 6
          n = 12 if cp >= 0xD800 && cp <= 0xDBFF
        end
        len = JSON.unescape(bytes.to_unsafe + i, n, scratch.to_unsafe)
        return false if o + len > other.bytesize
        return false unless scratch.to_unsafe.memcmp(other.to_unsafe + o, len) == 0
        i += n
        o += len
      end
      o == other.bytesize
    end

    def i64? : Int64?
      return nil unless @raw[0] == 45 || @raw[0] >= 48 && @raw[0] <= 57
      neg = @raw[0] == 45
      i = neg ? 1 : 0
      v = 0_u64
      limit = neg ? 9223372036854775808_u64 : Int64::MAX.to_u64
      while i < @raw.size
        c = @raw[i]
        return nil unless c >= 48 && c <= 57
        d = (c - 48).to_u64
        return nil if v > (limit - d) // 10
        v = v &* 10 &+ d
        i &+= 1
      end
      neg ? (0_i64 &- v.to_i64!) : v.to_i64
    end

    def i64 : Int64
      i64? || raise Error.new("expected Int64")
    end

    def i32 : Int32
      i64.to_i32
    end

    def f64? : Float64?
      v = uninitialized Float64
      options = Float::FastFloat::ParseOptionsT(UInt8).new(format: :general)
      ret = Float::FastFloat::BinaryFormat_Float64.new.from_chars_advanced(@raw.to_unsafe, @raw.to_unsafe + @raw.size, pointerof(v), options)
      return nil unless ret.ec == Errno::NONE && ret.ptr == @raw.to_unsafe + @raw.size && v.finite?
      v
    end

    def f64 : Float64
      f64? || raise Error.new("expected finite number")
    end

    def bool : Bool
      return true if @raw == "true".to_slice
      return false if @raw == "false".to_slice
      raise Error.new("expected boolean")
    end

    def null? : Bool
      @raw == "null".to_slice
    end

    def object(&)
      raise Error.new("expected object") unless object?
      p = Parser.new(@raw.to_unsafe, @raw.size).at(1)
      p.ws
      return if @raw[p.i] == 125
      loop do
        start = p.i
        p.value(0)
        key = Reader.new(@raw[start, p.i - start])
        p.ws
        p = p.at(p.i + 1)
        p.ws
        start = p.i
        p.value(0)
        value = Reader.new(@raw[start, p.i - start])
        yield key, value
        p.ws
        break if @raw[p.i] == 125
        p = p.at(p.i + 1)
        p.ws
      end
    end

    def array(&)
      raise Error.new("expected array") unless array?
      p = Parser.new(@raw.to_unsafe, @raw.size).at(1)
      p.ws
      return if @raw[p.i] == 93
      loop do
        start = p.i
        p.value(0)
        yield Reader.new(@raw[start, p.i - start])
        p.ws
        break if @raw[p.i] == 93
        p = p.at(p.i + 1)
        p.ws
      end
    end

    def [](name : String) : Reader
      found = nil.as(Reader?)
      object do |key, value|
        if key.string_equals?(name)
          raise Error.new("duplicate field") if found
          found = value
        end
      end
      found || raise Error.new("missing field")
    end
  end

  struct Parser
    def at(@i : Int32) : self
      self
    end
  end

  class Writer
    @stack = StaticArray(UInt8, 64).new(0_u8)
    @depth = 0
    @root = false
    @pending = false

    def initialize(@buf : Rayo::Buf)
    end

    def reset : self
      @depth = 0
      @root = false
      @pending = false
      self
    end

    @[AlwaysInline]
    private def before
      if @depth == 0
        raise Error.new("multiple roots") if @root
        @root = true
      elsif @stack[@depth - 1] & 2 != 0
        raise Error.new("expected field") unless @pending
        @pending = false
      else
        @buf << 44_u8 if @stack[@depth - 1] & 1 != 0
        @stack[@depth - 1] |= 1
      end
    end

    private def container(kind : UInt8, &)
      raise Error.new("depth limit") if @depth == MAX_DEPTH
      before
      @buf << (kind == 2 ? 123_u8 : 91_u8)
      @stack[@depth] = kind
      @depth &+= 1
      yield
      @depth &-= 1
      @buf << (kind == 2 ? 125_u8 : 93_u8)
    end

    def object(&)
      container(2_u8) { yield }
    end

    def array(&)
      container(0_u8) { yield }
    end

    def field(name : String | Bytes, v)
      field(name) { value(v) }
    end

    def field(name : String | Bytes, &)
      raise Error.new("expected object") if @depth == 0 || @stack[@depth - 1] & 2 == 0 || @pending
      @buf << 44_u8 if @stack[@depth - 1] & 1 != 0
      @stack[@depth - 1] |= 1
      quoted(name)
      @buf << 58_u8
      @pending = true
      yield
      raise Error.new("missing field value") if @pending
    end

    @[AlwaysInline]
    private def quoted(v : String | Bytes)
      # Escape only: values come from the app or the database, which store UTF-8 already;
      # validating every string cost ~4% of a request. Reader.valid? checks client input.
      b = v.is_a?(String) ? v.to_slice : v
      @buf << 34_u8
      @buf.json_escape(b.to_unsafe, b.size)
      @buf << 34_u8
    end

    @[AlwaysInline]
    def value(v : String | Bytes)
      before
      quoted(v)
    end

    @[AlwaysInline]
    def value(v : Int32 | Int64)
      before
      @buf << v
    end

    @[AlwaysInline]
    def value(v : Bool)
      before
      @buf << (v ? "true" : "false")
    end

    @[AlwaysInline]
    def value(v : Nil)
      before
      @buf << "null"
    end

    # NamedTuple keys already establish a field. Scalars can finish it directly;
    # containers and custom serializers still enter through the shared state machine.
    @[AlwaysInline]
    private def field_value(v : String | Bytes)
      @pending = false
      quoted(v)
    end

    @[AlwaysInline]
    private def field_value(v : Int32 | Int64)
      @pending = false
      @buf << v
    end

    @[AlwaysInline]
    private def field_value(v : Bool)
      @pending = false
      @buf << (v ? "true" : "false")
    end

    @[AlwaysInline]
    private def field_value(v : Nil)
      @pending = false
      @buf << "null"
    end

    private def field_value(v)
      value(v)
    end

    def value(v : Float64)
      raise Error.new("non-finite float") unless v.finite?
      before
      @buf << 45_u8 if v.sign_bit < 0
      if v.zero?
        @buf << "0.0"
        return
      end
      sig, exp = Float::Printer::Dragonbox.to_decimal(v.abs)
      while sig % 10 == 0
        sig //= 10
        exp += 1
      end
      digits = uninitialized UInt8[17]
      i = 17
      while sig > 0
        i -= 1
        digits[i] = 48_u8 + (sig % 10).to_u8
        sig //= 10
      end
      n = 17 - i
      point = n + exp
      if point >= -3 && point <= 15
        if point <= 0
          @buf << "0."
          (-point).times { @buf << 48_u8 }
          @buf.write(digits.to_unsafe + i, n)
        elsif point >= n
          @buf.write(digits.to_unsafe + i, n)
          (point - n).times { @buf << 48_u8 }
        else
          @buf.write(digits.to_unsafe + i, point)
          @buf << 46_u8
          @buf.write(digits.to_unsafe + i + point, n - point)
        end
      else
        @buf << digits[i]
        if n > 1
          @buf << 46_u8
          @buf.write(digits.to_unsafe + i + 1, n - 1)
        end
        @buf << 101_u8 << (point - 1)
      end
    end

    # Keys and separators are static data; values retain normal writer validation.
    def value(v : T) : Nil forall T
      {% if T.union? %}
        case v
        {% for type in T.union_types %}
        when {{type}}
          value(v)
        {% end %}
        end
      {% elsif T <= NamedTuple %}
      object do
        {% for key, i in T.keys %}
          {% escaped = "" %}
          {% for char in key.stringify.chars %}
            {% if char == '"' || char == '\\' %}
              {% escaped = escaped + "\\" + char %}
            {% elsif char == '\n' %}
              {% escaped = escaped + "\\n" %}
            {% elsif char == '\r' %}
              {% escaped = escaped + "\\r" %}
            {% elsif char == '\t' %}
              {% escaped = escaped + "\\t" %}
            {% elsif char.ord < 32 %}
              {% escaped = escaped + "\\u00" + "0123456789abcdef".chars[char.ord // 16] + "0123456789abcdef".chars[char.ord % 16] %}
            {% else %}
              {% escaped = escaped + char %}
            {% end %}
          {% end %}
          @buf << {{(i == 0 ? "" : ",") + "\"" + escaped + "\":"}}
          @stack[@depth - 1] |= 1
          @pending = true
          field_value(v[{{key.symbolize}}])
        {% end %}
      end
      {% elsif T.has_method?(:to_json) %}
        v.to_json(self)
      {% else %}
        {% raise "Unsupported JSON value type #{T}; implement to_json(Rayo::JSON::Writer)" %}
      {% end %}
    end

    def value(v : Tuple(*T)) : Nil forall T
      array do
        {% for type, i in T %}
          value(v[{{i}}])
        {% end %}
      end
    end

    def value(v : StaticArray(T, N)) : Nil forall T, N
      array { v.each { |item| value(item) } }
    end

    def value(v : Slice(T)) : Nil forall T
      array { v.each { |item| value(item) } }
    end

    def array(enumerable, &) : Nil
      array do
        enumerable.each do |item|
          fields = yield item
          object_value(fields)
        end
      end
    end

    private def object_value(fields : NamedTuple) : Nil
      value(fields)
    end

    def value(v : Int) : Nil
      before
      # Stack digits also cover unsigned and 128-bit values without narrowing.
      negative = v < 0
      magnitude = negative ? (0_u128 &- v.to_u128!) : v.to_u128!
      @buf << 45_u8 if negative
      digits = uninitialized UInt8[39]
      i = 39
      loop do
        i &-= 1
        digits[i] = 48_u8 &+ (magnitude % 10).to_u8
        magnitude //= 10
        break if magnitude == 0
      end
      @buf.write(digits.to_unsafe + i, 39 &- i)
    end

    def value(v : Float32) : Nil
      value(v.to_f64)
    end

    def raw(v : String | Bytes)
      b = v.is_a?(String) ? v.to_slice : v
      Reader.new(b)
      before
      @buf.write(b.to_unsafe, b.size)
    end
  end
end

module Rayo::JSON
  # Reject overlong encodings, surrogate codepoints and values above U+10FFFF.
  def self.valid_utf8?(bytes : Bytes) : Bool
    i = 0
    while i < bytes.size
      c = bytes[i]
      i &+= 1
      next if c < 0x80
      if c >= 0xC2 && c <= 0xDF
        n = 1
        cp = (c & 0x1F).to_i32
        min = 0x80
      elsif c >= 0xE0 && c <= 0xEF
        n = 2
        cp = (c & 0x0F).to_i32
        min = 0x800
      elsif c >= 0xF0 && c <= 0xF4
        n = 3
        cp = (c & 7).to_i32
        min = 0x10000
      else
        return false
      end
      return false if i + n > bytes.size
      n.times do
        b = bytes[i]
        return false unless b >= 0x80 && b <= 0xBF
        cp = (cp << 6) | (b & 63)
        i &+= 1
      end
      return false if cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
    end
    true
  end
end
