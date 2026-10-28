require "./http"
require "./router"
require "./json"

module Rayo
  # Views expire when the response finishes. A deferred response keeps its input pinned.
  class Context
    getter request = HTTP::Request.new
    getter output = Buf.new(1024)
    getter headers = Buf.new(256)
    property param_count = 0
    getter code = 200
    getter content_type : String | Bytes = "text/plain; charset=utf-8"
    property compress = true
    getter deferred = false
    getter serial = 0_u64
    @names = StaticArray(String, Router::MAX_PARAMS).new("")
    @values = StaticArray(Bytes, Router::MAX_PARAMS).new(Bytes.empty)

    @json_writer : JSON::Writer

    private def json_writer : JSON::Writer
      @json_writer.reset
    end

    def initialize(@id : Int32)
      @json_writer = JSON::Writer.new(@output)
    end

    def reset(@request : HTTP::Request) : Nil
      @serial &+= 1
      @param_count = 0
      @code = 200
      @content_type = "text/plain; charset=utf-8"
      @deferred = false
      @compress = true
      @output.clear
      @headers.clear
    end

    def method : HTTP::Method
      @request.method
    end

    def path : Bytes
      @request.path
    end

    def body : Bytes
      @request.body
    end

    def query : Bytes
      @request.query
    end

    def query(name : String) : Bytes
      HTTP.field(@request.query, name)
    end

    def header(name : String) : Bytes
      @request.header(name)
    end

    def header(name : String, value : String | Bytes) : Nil
      bytes = value.is_a?(String) ? value.to_slice : value
      raise ArgumentError.new("invalid response header") if name.empty? || name.to_slice.any? { |c| !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || "!#$%&'*+-.^_`|~".to_slice.includes?(c)) } || bytes.any? { |c| (c < 32 && c != 9) || c == 127 }
      if HTTP.equal(name.to_slice, "content-type", true)
        @content_type = value
        return
      end
      if HTTP.equal(name.to_slice, "content-length", true) || HTTP.equal(name.to_slice, "transfer-encoding", true) || HTTP.equal(name.to_slice, "connection", true) || HTTP.equal(name.to_slice, "date", true)
        raise ArgumentError.new("response framing headers belong to the server")
      end
      # Replace an existing field in place; callers can set headers from both hooks.
      offset = 0
      while offset < @headers.len
        p = @headers.ptr + offset
        e = LibSys.memmem(p, @headers.len - offset, "\r\n".to_unsafe, 2).as(UInt8*)
        colon = LibC.memchr(p, 58, e - p).as(UInt8*)
        length = (e - p).to_i32 + 2
        if HTTP.equal(Bytes.new(p, (colon - p).to_i32), name, true)
          p.move_from(p + length, @headers.len - offset - length)
          @headers.len -= length
          break
        end
        offset += length
      end
      @headers << name << ": "
      @headers.write(bytes.to_unsafe, bytes.size)
      @headers << "\r\n"
    end

    # Borrowed response header view, valid until the next header update.
    def response_header(name : String) : Bytes
      offset = 0
      while offset < @headers.len
        p = @headers.ptr + offset
        e = LibSys.memmem(p, @headers.len - offset, "\r\n".to_unsafe, 2).as(UInt8*)
        colon = LibC.memchr(p, 58, e - p).as(UInt8*)
        if HTTP.equal(Bytes.new(p, (colon - p).to_i32), name, true)
          return Bytes.new(colon + 2, (e - colon - 2).to_i32)
        end
        offset += (e - p).to_i32 + 2
      end
      Bytes.empty
    end

    def capture(name : String, value : Bytes) : Nil
      @names[@param_count] = name
      @values[@param_count] = value
      @param_count &+= 1
    end

    def param(name : String) : Bytes
      @param_count.times { |i| return @values[i] if @names[i] == name }
      Bytes.empty
    end

    def param_i64(name : String) : Int64
      value = param(name)
      raise ArgumentError.new("missing integer parameter") if value.empty?
      neg = value[0] == 45
      i = neg ? 1 : 0
      raise ArgumentError.new("invalid integer parameter") if i == value.size
      n = 0_i64
      while i < value.size
        c = value[i]
        raise ArgumentError.new("invalid integer parameter") unless c >= 48 && c <= 57
        # Accumulate negatively to allow Int64::MIN.
        n = n * 10 - (c - 48)
        i &+= 1
      end
      neg ? n : -n
    end

    def status : Int32
      @code
    end

    def cancel_defer : Nil
      @deferred = false
    end

    def status(@code : Int32) : Nil
    end

    def text(value : String) : Nil
      @output << value
    end

    def write(value : Bytes) : Nil
      @output.write(value.to_unsafe, value.size)
    end

    def content_type(value : String | Bytes) : Nil
      header("Content-Type", value)
    end

    def defer : Deferred
      @deferred = true
      Deferred.new(@id, Server.conn(@id).gen, @serial)
    end

    struct Deferred
      def initialize(@id : Int32, @generation : UInt16, @serial : UInt64)
      end

      def context : Context?
        c = Server.conn(@id)
        c.open && c.gen == @generation && c.busy && c.context.serial == @serial ? c.context : nil
      end

      def finish : Bool
        return false unless context
        Server.finish(@id)
        true
      end

      def finish(&block : Context ->) : Bool
        return false unless ctx = context
        yield ctx
        finish
      end
    end
  end
end
