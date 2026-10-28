require "./json"

module Rayo::JWT
  @[Link("crypto")]
  lib Crypto
    # OpenSSL SHA256_CTX: eight state words, bit count, block, num and md_len.
    struct SHA256
      h : UInt32[8]
      nl : UInt32
      nh : UInt32
      data : UInt32[16]
      num : UInt32
      md_len : UInt32
    end

    fun init = SHA256_Init(ctx : SHA256*) : LibC::Int
    fun update = SHA256_Update(ctx : SHA256*, data : Void*, len : LibC::SizeT) : LibC::Int
    fun final = SHA256_Final(out : UInt8*, ctx : SHA256*) : LibC::Int
  end

  ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  HEADER   = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

  B64 = begin
    t = StaticArray(Int8, 256).new(-1_i8)
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".each_byte.each_with_index { |b, i| t[b] = i.to_i8 }
    t
  end

  # Decodes unpadded base64url. Returns the length, or -1.
  def self.decode(src : Bytes, output : Bytes) : Int32
    p = src.to_unsafe
    n = src.size
    return -1 if output.size < n.to_i64 * 3 // 4
    dst = output.to_unsafe
    return -1 if n & 3 == 1
    t = B64.to_unsafe
    o = 0
    i = 0
    while i &+ 4 <= n
      a = t[p[i]]; b = t[p[i &+ 1]]; c = t[p[i &+ 2]]; d = t[p[i &+ 3]]
      return -1 if (a | b | c | d) < 0
      v = (a.to_u32 << 18) | (b.to_u32 << 12) | (c.to_u32 << 6) | d.to_u32
      dst[o] = (v >> 16).to_u8!; dst[o &+ 1] = (v >> 8).to_u8!; dst[o &+ 2] = v.to_u8!
      o &+= 3
      i &+= 4
    end
    r = n &- i
    if r == 2
      a = t[p[i]]; b = t[p[i &+ 1]]
      return -1 if (a | b) < 0 || b & 15 != 0
      dst[o] = ((a.to_u32 << 2) | (b.to_u32 >> 4)).to_u8!
      o &+= 1
    elsif r == 3
      a = t[p[i]]; b = t[p[i &+ 1]]; c = t[p[i &+ 2]]
      return -1 if (a | b | c) < 0 || c & 3 != 0
      v = (a.to_u32 << 18) | (b.to_u32 << 12) | (c.to_u32 << 6)
      dst[o] = (v >> 16).to_u8!; dst[o &+ 1] = (v >> 8).to_u8!
      o &+= 2
    end
    o
  end

  def self.encoded_size(n : Int32) : Int32
    ((n.to_i64 * 4 + 2) // 3).to_i32
  end

  # Unpadded base64url. Both codecs require distinct input and output buffers.
  def self.encode(src : Bytes, output : Bytes) : Int32
    n = encoded_size(src.size)
    raise ArgumentError.new("short output buffer") if output.size < n
    acc = 0_u32
    bits = 0
    o = 0
    src.each do |c|
      acc = (acc << 8) | c.to_u32
      bits += 8
      while bits >= 6
        bits -= 6
        output[o] = ALPHABET.to_unsafe[(acc >> bits) & 63]
        o &+= 1
      end
    end
    output[o] = ALPHABET.to_unsafe[(acc << (6 - bits)) & 63] if bits > 0
    n
  end

  # Value type: precomputed key states are copied onto the stack for every MAC.
  struct Key
    @inner : Crypto::SHA256
    @outer : Crypto::SHA256

    def initialize(secret : String)
      initialize(secret.to_slice)
    end

    def initialize(secret : Bytes)
      @inner = Crypto::SHA256.new
      @outer = Crypto::SHA256.new
      key = StaticArray(UInt8, 64).new(0_u8)
      if secret.size > 64
        ctx = Crypto::SHA256.new
        Crypto.init(pointerof(ctx))
        Crypto.update(pointerof(ctx), secret.to_unsafe, secret.size)
        Crypto.final(key.to_unsafe, pointerof(ctx))
      else
        key.to_unsafe.copy_from(secret.to_unsafe, secret.size)
      end
      pad = uninitialized UInt8[64]
      64.times { |i| pad[i] = key[i] ^ 0x36_u8 }
      Crypto.init(pointerof(@inner))
      Crypto.update(pointerof(@inner), pad.to_unsafe, 64)
      64.times { |i| pad[i] = key[i] ^ 0x5c_u8 }
      Crypto.init(pointerof(@outer))
      Crypto.update(pointerof(@outer), pad.to_unsafe, 64)
    end

    private def mac(data : Bytes, output : UInt8*)
      inner = @inner
      outer = @outer
      Crypto.update(pointerof(inner), data.to_unsafe, data.size)
      Crypto.final(output, pointerof(inner))
      Crypto.update(pointerof(outer), output, 32)
      Crypto.final(output, pointerof(outer))
    end

    # The returned slice borrows output. Payload must be a JSON object.
    def sign(payload : Bytes, output : Bytes) : Bytes
      raise JSON::Error.new("expected claims object") unless JSON::Reader.new(payload).object?
      n = HEADER.bytesize + 1 + JWT.encoded_size(payload.size)
      raise ArgumentError.new("short output buffer") if output.size < n + 44
      output.to_unsafe.copy_from(HEADER.to_unsafe, HEADER.bytesize)
      output[HEADER.bytesize] = 46
      JWT.encode(payload, output[HEADER.bytesize + 1..])
      digest = uninitialized UInt8[32]
      mac(output[0, n], digest.to_unsafe)
      output[n] = 46
      JWT.encode(digest.to_slice, output[n + 1..])
      output[0, n + 44]
    end

    def sign(payload : String, output : Bytes) : Bytes
      sign(payload.to_slice, output)
    end

    # Claims borrow scratch until it is reused. No global or per-request state.
    # Optional NumericDate claims are checked; iat in the future is rejected.
    def verify(token : Bytes, scratch : Bytes, now : Int64, leeway : Int32 = 0) : JSON::Reader?
      return nil if leeway < 0
      d1 = -1
      d2 = -1
      token.each_with_index do |c, i|
        if c == 46
          if d1 < 0
            d1 = i
          elsif d2 < 0
            d2 = i
          else
            return nil
          end
        end
      end
      return nil if d1 <= 0 || d2 <= d1 + 1 || token.size - d2 - 1 != 43
      sig = uninitialized UInt8[32]
      digest = uninitialized UInt8[32]
      return nil unless JWT.decode(token[d2 + 1..], sig.to_slice) == 32
      mac(token[0, d2], digest.to_unsafe)
      diff = 0_u8
      32.times { |i| diff |= sig[i] ^ digest[i] }
      return nil unless diff == 0
      hn = JWT.decode(token[0, d1], scratch)
      return nil if hn < 0
      header = JSON::Reader.parse?(scratch[0, hn])
      return nil unless header && header.object?
      alg = 0
      header.object do |key, value|
        if key.string_equals?("alg")
          alg += 1
          return nil unless value.string? && value.string_equals?("HS256")
        elsif key.string_equals?("crit") || key.string_equals?("b64")
          return nil
        end
      end
      return nil unless alg == 1
      pn = JWT.decode(token[d1 + 1, d2 - d1 - 1], scratch)
      return nil if pn < 0
      claims = JSON::Reader.parse?(scratch[0, pn])
      return nil unless claims && claims.object?
      seen = 0
      claims.object do |key, value|
        mask = if key.string_equals?("exp")
                 1
               elsif key.string_equals?("nbf")
                 2
               elsif key.string_equals?("iat")
                 4
               else
                 0
               end
        if mask != 0
          return nil if seen & mask != 0
          seen |= mask
          if time = value.i64?
            # Keep integer dates exact even outside the Float64 integer range.
            if mask == 1
              return nil if now.to_i128 - leeway >= time
            else
              return nil if now.to_i128 + leeway < time
            end
          else
            time = value.f64?
            return nil unless time
            if mask == 1
              return nil if now.to_f64 - leeway >= time
            else
              return nil if now.to_f64 + leeway < time
            end
          end
        end
      end
      claims
    end

    def verify(token : String, scratch : Bytes, now : Int64, leeway : Int32 = 0) : JSON::Reader?
      verify(token.to_slice, scratch, now, leeway)
    end
  end
end
