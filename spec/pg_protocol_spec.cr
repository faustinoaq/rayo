require "./spec_helper"
require "../src/rayo/pg"
require "openssl"
require "openssl/hmac"
require "openssl/pkcs5"

module PGProtocolSpec
  def self.packet(type : Char, payload : Bytes) : Bytes
    bytes = Bytes.new(payload.size + 5)
    bytes[0] = type.ord.to_u8
    Rayo::PG::Wire.put(bytes.to_unsafe + 1, payload.size + 4)
    bytes[5, payload.size].copy_from(payload)
    bytes
  end

  def self.ready(c : Rayo::PG::Conn) : Nil
    output = c.output
    c.on_sent(output.size)
    b = packet('Z', "I".to_slice)
    c.on_data(b.to_unsafe, b.size)
  end
end

describe Rayo::PG::Auth do
  it "encodes cleartext and MD5 password responses" do
    auth = Rayo::PG::Auth.new("postgres", "postgres")
    b = Rayo::Buf.new(256)
    begin
      auth.respond(0, Bytes.empty, b)
      b.len.should eq(0)
      auth.respond(3, Bytes.empty, b)
      Bytes.new(b.ptr + 5, b.len - 5).should eq("postgres\0".to_slice)
      b.clear
      salt = Bytes[1, 2, 3, 4]
      auth.respond(5, salt, b)
      inner = OpenSSL::Digest.new("MD5").update("postgrespostgres").final.hexstring
      expect = "md5" + OpenSSL::Digest.new("MD5").update(inner).update(salt).final.hexstring + "\0"
      Bytes.new(b.ptr + 5, b.len - 5).should eq(expect.to_slice)
    ensure
      LibC.free(b.ptr)
    end
  end

  it "checks SCRAM proof and server signature against independent OpenSSL helpers" do
    auth = Rayo::PG::Auth.new("postgres", "pencil")
    b = Rayo::Buf.new(1024)
    begin
      auth.respond(10, "SCRAM-SHA-256\0\0".to_slice, b)
      initial = String.new(Bytes.new(b.ptr + 5, b.len - 5))
      first_offset = "SCRAM-SHA-256".bytesize + 1 + 4
      first = initial.byte_slice(first_offset + 3)
      nonce = first.split("r=")[1]
      salt = Base64.decode("W22ZaJ0SNY7soEsUEjb6gQ==")
      server = "r=#{nonce}server,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
      b.clear
      auth.respond(11, server.to_slice, b)
      final = String.new(Bytes.new(b.ptr + 5, b.len - 5))
      without = "c=biws,r=#{nonce}server"
      message = "#{first},#{server},#{without}"
      salted = OpenSSL::PKCS5.pbkdf2_hmac("pencil", salt, 4096, OpenSSL::Algorithm::SHA256, 32)
      client = OpenSSL::HMAC.digest(:sha256, salted, "Client Key")
      stored = OpenSSL::Digest.new("SHA256").update(client).final
      signature = OpenSSL::HMAC.digest(:sha256, stored, message)
      proof = Bytes.new(32) { |i| client[i] ^ signature[i] }
      final.should eq("#{without},p=#{Base64.strict_encode(proof)}")
      key = OpenSSL::HMAC.digest(:sha256, salted, "Server Key")
      expected = "v=" + Base64.strict_encode(OpenSSL::HMAC.digest(:sha256, key, message))
      expect_raises(Rayo::PG::Error, "signature mismatch") { auth.respond(12, "v=bad".to_slice, b) }
      auth.respond(12, expected.to_slice, b)
    ensure
      LibC.free(b.ptr)
    end
  end

  it "rejects unsupported mechanisms and mismatched nonces" do
    b = Rayo::Buf.new(256)
    auth = Rayo::PG::Auth.new("postgres", "postgres")
    begin
      expect_raises(Rayo::PG::Error) { auth.respond(10, "SCRAM-SHA-256-PLUS\0".to_slice, b) }
      b.clear
      auth.respond(10, "SCRAM-SHA-256\0\0".to_slice, b)
      expect_raises(Rayo::PG::Error, "nonce mismatch") do
        auth.respond(11, "r=wrong,s=abcd,i=4096".to_slice, b)
      end
    ensure
      LibC.free(b.ptr)
    end
  end
end

describe Rayo::PG::Conn do
  it "keeps send pointers stable and accepts byte-by-byte backend fragments" do
    c = Rayo::PG::Conn.new("postgres://postgres@localhost/test", max_depth: 2)
    begin
      PGProtocolSpec.ready(c)
      stmt = Rayo::PG::Statement.new("SELECT 42")
      count = 0_i64
      c.query(stmt, state: pointerof(count).address.to_i64!) do |res, state|
        res.first?.not_nil!.i32(0).should eq(42)
        Pointer(Int64).new(state.to_u64!).value &+= 1
      end
      sent = c.output
      c.on_sent(1)
      c.query(stmt) { |_| }
      c.output.to_unsafe.should eq(sent.to_unsafe + 1)
      c.output.size.should eq(sent.size - 1)
      c.on_sent(sent.size - 1)
      c.output.empty?.should be_false
      data = Bytes[0, 1, 0, 0, 0, 2, 52, 50]
      row = PGProtocolSpec.packet('D', data)
      ready = PGProtocolSpec.packet('Z', "I".to_slice)
      row.each { |v| c.on_data(pointerof(v), 1) }
      ready.each { |v| c.on_data(pointerof(v), 1) }
      count.should eq(1)
      c.pending.should eq(1)
      c.lost
      c.pending.should eq(0)
      c.alive?.should be_false
    ensure
      c.close
    end
  end

  it "completes every callback on loss even if one callback raises" do
    c = Rayo::PG::Conn.new("postgres://postgres@localhost/test")
    count = 0_i64
    begin
      PGProtocolSpec.ready(c)
      stmt = Rayo::PG::Statement.new("SELECT 1")
      c.query(stmt) { |_| raise "callback failure" }
      c.query(stmt, state: pointerof(count).address.to_i64!) do |res, state|
        res.sqlstate.should eq("08006".to_slice)
        Pointer(Int64).new(state.to_u64!).value &+= 1
      end
      expect_raises(Exception, "callback failure") { c.lost }
      count.should eq(1)
      c.pending.should eq(0)
    ensure
      c.close
    end
  end

  it "rejects capturing callbacks and unsupported TLS modes" do
    expect_raises(Rayo::PG::Error, "TLS") do
      Rayo::PG::Conn.new("postgres://postgres@localhost/test?sslmode=require")
    end
    c = Rayo::PG::Conn.new("postgres://postgres@localhost/test")
    begin
      PGProtocolSpec.ready(c)
      values = [] of Int32
      expect_raises(ArgumentError, "capture") do
        c.query(Rayo::PG::Statement.new("SELECT 1")) { |_| values << 1 }
      end
    ensure
      c.close
    end
  end
  it "decodes URL components and startup options" do
    c = Rayo::PG::Conn.new("postgresql://some%20user:some%40pass@[::1]:5433/some%20db?application_name=pg%20spec&sslmode=disable")
    begin
      c.host.should eq("::1")
      c.port.should eq(5433)
      payload = String.new(c.output[8..])
      payload.should contain("user\0some user\0")
      payload.should contain("database\0some db\0")
      payload.should contain("application_name\0pg spec\0")
    ensure
      c.close
    end
  end

  it "rejects NUL text without changing the query queue" do
    c = Rayo::PG::Conn.new("postgres://postgres@localhost/test")
    begin
      PGProtocolSpec.ready(c)
      stmt = Rayo::PG::Statement.new("SELECT $1::text")
      expect_raises(ArgumentError) { c.query(stmt, "bad\0text") { |_| } }
      expect_raises(ArgumentError) { c.query(stmt, ["bad\0text"]) { |_| } }
      expect_raises(ArgumentError) { Rayo::PG::Statement.new("SELECT 1\0") }
      c.pending.should eq(0)
      c.output.should be_empty
    ensure
      c.close
    end
  end
end

describe "CommandComplete" do
  it "retains affected counts across fragments and resets them between queued queries" do
    c = Rayo::PG::Conn.new("postgres://postgres@localhost/test")
    total = 0_i64
    begin
      PGProtocolSpec.ready(c)
      {"INSERT 0 12\0", "UPDATE 3\0", "DELETE 0\0", "CREATE TABLE\0", "SELECT 2\0"}.each do |tag|
        c.query(Rayo::PG::Statement.new("SELECT 1"), state: pointerof(total).address.to_i64!) do |res, state|
          Pointer(Int64).new(state.to_u64!).value &+= res.rows_affected
        end
        command = PGProtocolSpec.packet('C', tag.to_slice)
        command.each { |b| c.on_data(pointerof(b), 1) }
        ready = PGProtocolSpec.packet('Z', "I".to_slice)
        c.on_data(ready.to_unsafe, ready.size)
      end
      total.should eq(17)
    ensure
      c.close
    end
  end
end
