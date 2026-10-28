require "./context"

@[Link("deflate")]
lib Rayo::LibDeflate
  fun alloc = libdeflate_alloc_compressor(level : Int32) : Void*
  fun free = libdeflate_free_compressor(compressor : Void*)
  fun compress = libdeflate_gzip_compress(compressor : Void*, input : Void*, length : LibC::SizeT, output : Void*, capacity : LibC::SizeT) : LibC::SizeT
  fun bound = libdeflate_gzip_compress_bound(compressor : Void*, length : LibC::SizeT) : LibC::SizeT
end

module Rayo
  # One compressor and scratch buffer per worker; output is copied before reuse.
  class Gzip
    @compressor : Void*
    @scratch = Buf.new(4096)

    def initialize(@min_size = 1024, level = 1)
      raise ArgumentError.new("invalid gzip settings") unless @min_size >= 0 && 0 <= level <= 12
      @compressor = LibDeflate.alloc(level)
      raise "cannot allocate gzip compressor" if @compressor.null?
    end

    private def self.trim(bytes : Bytes) : Bytes
      first = 0
      last = bytes.size
      while first < last && (bytes[first] == 32 || bytes[first] == 9)
        first &+= 1
      end
      while last > first && (bytes[last - 1] == 32 || bytes[last - 1] == 9)
        last &-= 1
      end
      bytes[first, last - first]
    end

    def self.accepted?(header : Bytes) : Bool
      explicit = nil.as(Bool?)
      wildcard = false
      start = 0
      while start < header.size
        stop = start
        while stop < header.size && header[stop] != 44
          stop &+= 1
        end
        token = header[start, stop - start]
        semi = token.index(59_u8) || token.size
        name = trim(token[0, semi])
        allowed = true
        pos = semi
        while pos < token.size
          pos &+= 1
          last = pos
          while last < token.size && token[last] != 59
            last &+= 1
          end
          param = trim(token[pos, last - pos])
          eq = param.index(61_u8)
          if eq && HTTP.equal(trim(param[0, eq]), "q", true)
            value = trim(param[eq + 1..])
            # Only the HTTP qvalue grammar is accepted (at most three decimals).
            allowed = false
            if value.size >= 1 && (value[0] == 48 || value[0] == 49)
              valid = value.size == 1 || (2 <= value.size <= 5 && value[1] == 46)
              nonzero = value[0] == 49
              i = 2
              while i < value.size
                c = value[i]
                valid = false unless 48 <= c <= 57 && (value[0] == 48 || c == 48)
                nonzero ||= c > 48
                i &+= 1
              end
              allowed = valid && nonzero
            end
          end
          pos = last
        end
        explicit = allowed if HTTP.equal(name, "gzip", true)
        wildcard = allowed if name == "*".to_slice
        start = stop &+ 1
      end
      explicit.nil? ? wildcard : explicit
    end

    protected def self.varies?(bytes : Bytes) : Bool
      start = 0
      while start < bytes.size
        stop = start
        while stop < bytes.size && bytes[stop] != 44
          stop &+= 1
        end
        return true if HTTP.equal(trim(bytes[start, stop - start]), "Accept-Encoding", true)
        start = stop &+ 1
      end
      false
    end

    def apply(ctx : Context) : Nil
      raise "gzip compressor closed" if @compressor.null?
      return unless ctx.compress && ctx.output.len >= @min_size && ctx.code >= 200 && ctx.code != 204 && ctx.code != 205 && ctx.code != 304 && ctx.code != 206
      return unless ctx.response_header("Content-Encoding").empty? && ctx.response_header("Content-Range").empty?
      vary = ctx.response_header("Vary")
      if vary.empty?
        ctx.header("Vary", "Accept-Encoding")
      elsif vary != "*".to_slice && !Gzip.varies?(vary)
        # Copy to scratch before header replacement can move its borrowed bytes.
        @scratch.clear
        @scratch.write(vary.to_unsafe, vary.size) << ", Accept-Encoding"
        ctx.header("Vary", Bytes.new(@scratch.ptr, @scratch.len))
      end
      return unless Gzip.accepted?(ctx.header("Accept-Encoding"))
      @scratch.clear
      @scratch.reserve(LibDeflate.bound(@compressor, ctx.output.len).to_i32)
      n = LibDeflate.compress(@compressor, ctx.output.ptr, ctx.output.len, @scratch.ptr, @scratch.cap).to_i32
      return if n == 0 || n >= ctx.output.len
      ctx.output.clear
      ctx.output.write(@scratch.ptr, n)
      ctx.header("Content-Encoding", "gzip")
    end

    def close : Nil
      return if @compressor.null?
      LibDeflate.free(@compressor)
      @compressor = Pointer(Void).null
      LibC.free(@scratch.ptr)
    end
  end
end
