require "../json"
require "io/byte_format"

module Rayo::JSON
  # PostgreSQL ISO text or binary microseconds since 2000-01-01; normalized to UTC.
  struct Timestamp
    @time : Time

    def initialize(value : Bytes)
      raise Error.new("invalid timestamptz") if value.size < 20
      unless value[4] == 45 && value[7] == 45 && (value[10] == 32 || value[10] == 84) && value[13] == 58 && value[16] == 58
        raise Error.new("invalid timestamptz")
      end
      year = self.class.number(value, 0, 4)
      month = self.class.number(value, 5, 2)
      day = self.class.number(value, 8, 2)
      hour = self.class.number(value, 11, 2)
      minute = self.class.number(value, 14, 2)
      second = self.class.number(value, 17, 2)
      pos = 19
      micros = 0
      if value[pos]? == 46
        pos &+= 1
        first = pos
        while pos < value.size && 48 <= value[pos] <= 57
          raise Error.new("invalid timestamptz fraction") if pos - first == 6
          micros = micros * 10 + value[pos] - 48
          pos &+= 1
        end
        raise Error.new("invalid timestamptz fraction") if pos == first
        (6 - (pos - first)).times { micros *= 10 }
      end
      zone = value[pos..]
      offset = 0
      if zone == "Z".to_slice
      elsif (zone.size == 3 || zone.size == 6 || zone.size == 9) && (zone[0] == 43 || zone[0] == 45)
        hours = self.class.number(zone, 1, 2)
        minutes = zone.size >= 6 ? self.class.number(zone, 4, 2) : 0
        seconds = zone.size == 9 ? self.class.number(zone, 7, 2) : 0
        raise Error.new("invalid timestamptz offset") unless hours <= 15 && minutes <= 59 && seconds <= 59 && (zone.size < 6 || zone[3] == 58) && (zone.size < 9 || zone[6] == 58)
        offset = hours * 3600 + minutes * 60 + seconds
        offset = -offset if zone[0] == 45
      else
        raise Error.new("invalid timestamptz offset")
      end
      @time = Time.utc(year, month, day, hour, minute, second, nanosecond: micros * 1000) - offset.seconds
      validate_year
    end

    def initialize(@time : Time)
      @time = @time.to_utc
      validate_year
    end

    private def validate_year : Nil
      raise Error.new("timestamp outside RFC 3339 range") unless 1 <= @time.year <= 9999
    end

    def self.binary(value : Bytes) : self
      raise Error.new("invalid binary timestamptz") unless value.size == 8
      binary(IO::ByteFormat::BigEndian.decode(Int64, value))
    end

    def self.binary(microseconds : Int64) : self
      raise Error.new("infinite timestamptz") if microseconds == Int64::MIN || microseconds == Int64::MAX
      seconds = microseconds // 1_000_000
      nanos = (microseconds % 1_000_000).to_i32 * 1000
      new(Time.unix(seconds + 946684800) + nanos.nanoseconds)
    end

    protected def self.number(value : Bytes, offset : Int32, length : Int32) : Int32
      n = 0
      length.times do |i|
        c = value[offset + i]
        raise Error.new("invalid timestamptz digit") unless 48 <= c <= 57
        n = n * 10 + c - 48
      end
      n
    end

    def to_json(writer : Writer) : Nil
      bytes = uninitialized UInt8[27]
      dst = bytes.to_slice
      digits(dst, 0, @time.year, 4)
      dst[4] = 45
      digits(dst, 5, @time.month, 2)
      dst[7] = 45
      digits(dst, 8, @time.day, 2)
      dst[10] = 84
      digits(dst, 11, @time.hour, 2)
      dst[13] = 58
      digits(dst, 14, @time.minute, 2)
      dst[16] = 58
      digits(dst, 17, @time.second, 2)
      dst[19] = 46
      digits(dst, 20, @time.nanosecond // 1000, 6)
      dst[26] = 90
      writer.value(dst)
    end

    private def digits(dst : Bytes, offset : Int32, value : Int32, count : Int32) : Nil
      count.times do |i|
        dst[offset + count - i - 1] = 48_u8 &+ (value % 10).to_u8
        value //= 10
      end
    end
  end
end
