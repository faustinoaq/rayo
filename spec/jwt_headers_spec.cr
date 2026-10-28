require "./spec_helper"
require "../src/rayo/jwt"
require "openssl/hmac"

# Independent HMAC implementation lets malformed headers carry valid signatures.
private def signed_token(header : String, payload : String) : String
  storage = uninitialized UInt8[4096]
  h = Rayo::JWT.encode(header.to_slice, storage.to_slice)
  storage[h] = 46
  p = Rayo::JWT.encode(payload.to_slice, storage.to_slice[h + 1..])
  signed = String.new(storage.to_unsafe, h + p + 1)
  mac = OpenSSL::HMAC.digest(:sha256, "secret", signed)
  storage[h + p + 1] = 46
  n = Rayo::JWT.encode(mac, storage.to_slice[h + p + 2..])
  String.new(storage.to_unsafe, h + p + 2 + n)
end

describe Rayo::JWT::Key do
  it "rejects authenticated malformed or unsupported headers and payloads" do
    key = Rayo::JWT::Key.new("secret")
    scratch = uninitialized UInt8[4096]
    [%q({"alg":"none"}), %q({"alg":"HS512"}), %q({"alg":1}), %q({"alg":"HS256","alg":"HS256"}), %q({"alg":"HS256","crit":[]}), %q({"alg":"HS256","b64":false}), %q({}), %q([]), %q({"alg":"HS256",})].each do |header|
      key.verify(signed_token(header, "{}"), scratch.to_slice, 150).should be_nil
    end
    [%q([]), %q(null), %q({"a":}), %q({"exp":null})].each do |payload|
      key.verify(signed_token(%q({"alg":"HS256"}), payload), scratch.to_slice, 150).should be_nil
    end
    token = signed_token(%q({"\u0061lg":"HS\u003256"}), "{}")
    key.verify(token, scratch.to_slice, 150).should_not be_nil
  end
end
