require "openssl/lib_crypto"

module Rayo::PG
  @[Link("crypto")]
  lib LibCrypto
    fun sha256 = SHA256(data : UInt8*, len : LibC::SizeT, digest : UInt8*) : UInt8*
    fun md5 = MD5(data : UInt8*, len : LibC::SizeT, digest : UInt8*) : UInt8*
    fun evp_sha256 = EVP_sha256 : ::LibCrypto::EVP_MD
    fun hmac = HMAC(md : ::LibCrypto::EVP_MD, key : UInt8*, key_len : Int32, data : UInt8*, len : LibC::SizeT, digest : UInt8*, out_len : UInt32*) : UInt8*
    fun pbkdf2 = PKCS5_PBKDF2_HMAC(pass : UInt8*, pass_len : Int32, salt : UInt8*, salt_len : Int32, iterations : Int32, md : ::LibCrypto::EVP_MD, len : Int32, digest : UInt8*) : Int32
    fun random = RAND_bytes(digest : UInt8*, len : Int32) : Int32
    fun compare = CRYPTO_memcmp(a : UInt8*, b : UInt8*, n : LibC::SizeT) : Int32
  end

  # Authentication runs once; only the wire and result paths must avoid allocations.
  class Auth
    @nonce = ""
    @first = ""
    @expected = ""
    @verified = false

    def initialize(@user : String, @password : String)
    end

    private def hmac(key : Bytes, text : String) : Bytes
      digest = Bytes.new(32)
      n = 32_u32
      raise Error.new("HMAC failed") if LibCrypto.hmac(LibCrypto.evp_sha256, key.to_unsafe, key.size, text.to_unsafe, text.bytesize, digest.to_unsafe, pointerof(n)).null?
      digest
    end

    def respond(code : Int32, data : Bytes, o : Buf) : Nil
      if code == 0
        raise Error.new("SCRAM signature was not verified") if !@nonce.empty? && !@verified
        return
      end
      if code == 12
        raise Error.new("unexpected SCRAM final") if @expected.empty?
        actual = String.new(data)
        raise Error.new("SCRAM server signature mismatch") unless actual.bytesize == @expected.bytesize && LibCrypto.compare(actual.to_unsafe, @expected.to_unsafe, actual.bytesize) == 0
        @verified = true
        return
      end
      at = Wire.start(o, 'p')
      case code
      when 3
        Wire.cstr(o, @password)
      when 5
        raise Error.new("invalid MD5 salt") unless data.size == 4
        inner = Bytes.new(16)
        input = @password + @user
        LibCrypto.md5(input.to_unsafe, input.bytesize, inner.to_unsafe)
        input = inner.hexstring + String.new(data)
        outer = Bytes.new(16)
        LibCrypto.md5(input.to_unsafe, input.bytesize, outer.to_unsafe)
        Wire.cstr(o, "md5" + outer.hexstring)
      when 10
        raise Error.new("SCRAM-SHA-256 unavailable") unless String.new(data).split('\0').includes?("SCRAM-SHA-256")
        random = Bytes.new(18)
        raise Error.new("random failed") unless LibCrypto.random(random.to_unsafe, random.size) == 1
        @nonce = Base64.strict_encode(random)
        @first = "n=,r=#{@nonce}"
        first = "n,,#{@first}"
        Wire.cstr(o, "SCRAM-SHA-256")
        Wire.int(o, first.bytesize)
        o << first
      when 11
        raise Error.new("unexpected SCRAM continuation") if @nonce.empty?
        server = String.new(data)
        fields = server.split(',').to_h { |v| {v[0], v[2..]} }
        nonce = fields['r']
        raise Error.new("SCRAM nonce mismatch") unless nonce.starts_with?(@nonce) && nonce.bytesize > @nonce.bytesize
        raise Error.new("unsupported SCRAM extension") if fields.has_key?('m')
        salt = Base64.decode(fields['s'])
        iterations = fields['i'].to_i
        raise Error.new("invalid SCRAM iterations") unless 0 < iterations <= 10_000_000
        salted = Bytes.new(32)
        raise Error.new("PBKDF2 failed") unless LibCrypto.pbkdf2(@password.to_unsafe, @password.bytesize, salt.to_unsafe, salt.size, iterations, LibCrypto.evp_sha256, 32, salted.to_unsafe) == 1
        client = hmac(salted, "Client Key")
        stored = Bytes.new(32)
        LibCrypto.sha256(client.to_unsafe, client.size, stored.to_unsafe)
        final = "c=biws,r=#{nonce}"
        message = "#{@first},#{server},#{final}"
        signature = hmac(stored, message)
        proof = Bytes.new(32) { |i| client[i] ^ signature[i] }
        @expected = "v=" + Base64.strict_encode(hmac(hmac(salted, "Server Key"), message))
        o << final << ",p=" << Base64.strict_encode(proof)
      else
        raise Error.new("unsupported authentication method #{code}")
      end
      Wire.finish(o, at)
    end
  end
end
