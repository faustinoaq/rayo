require "./spec_helper"
require "../src/rayo/jwt"

describe Rayo::JWT do
  it "encodes and strictly decodes base64url into caller buffers" do
    encoded = uninitialized UInt8[100]
    decoded = uninitialized UInt8[100]
    {"".to_slice => "", "f".to_slice => "Zg", "fo".to_slice => "Zm8", "foo".to_slice => "Zm9v", Bytes[255, 254, 253] => "__79"}.each do |input, expected|
      n = Rayo::JWT.encode(input, encoded.to_slice)
      encoded.to_slice[0, n].should eq(expected.to_slice)
      m = Rayo::JWT.decode(encoded.to_slice[0, n], decoded.to_slice)
      decoded.to_slice[0, m].should eq(input)
    end
    ["a", "Zg=", "Zh", "Zm9", "++++", "Zm 8"].each do |s|
      Rayo::JWT.decode(s.to_slice, decoded.to_slice).should eq(-1)
    end
    Rayo::JWT.decode("Zm9v".to_slice, Bytes.empty).should eq(-1)
  end

  it "signs and verifies claims and rejects tampering" do
    key = Rayo::JWT::Key.new("a secret")
    output = uninitialized UInt8[1024]
    scratch = uninitialized UInt8[1024]
    token = key.sign(%q({"sub":"123","exp":200,"nbf":100,"iat":100}), output.to_slice)
    key.verify(token, scratch.to_slice, 100).not_nil!["sub"].string.should eq("123".to_slice)
    key.verify(token, scratch.to_slice, 200).should be_nil
    key.verify(token, scratch.to_slice, 99).should be_nil
    key.verify(token, scratch.to_slice, 99, 1).should_not be_nil
    key.verify(token, scratch.to_slice, 200, 1).should_not be_nil
    Rayo::JWT::Key.new("wrong").verify(token, scratch.to_slice, 150).should be_nil
    token[10] ^= 1
    key.verify(token, scratch.to_slice, 150).should be_nil
    ["", "a.b", "a.b.c.d", "..", "none.payload."].each do |s|
      key.verify(s, scratch.to_slice, 150).should be_nil
    end
  end

  it "checks optional NumericDates and duplicate registered claims" do
    key = Rayo::JWT::Key.new("secret")
    output = uninitialized UInt8[1024]
    scratch = uninitialized UInt8[1024]
    [%q({"exp":"200"}), %q({"iat":151}), %q({"nbf":151}), %q({"exp":100,"exp":200}), %q({"\u0065xp":100}), %q({"exp":1e999})].each do |s|
      token = key.sign(s, output.to_slice)
      key.verify(token, scratch.to_slice, 150).should be_nil
    end
    token = key.sign(%q({"exp":150.5}), output.to_slice)
    key.verify(token, scratch.to_slice, 150).should_not be_nil
    key.verify(token, Bytes.empty, 150).should be_nil
    token = key.sign("{}", output.to_slice)
    key.verify(token, scratch.to_slice, 150).should_not be_nil
  end

  it "does not allocate while signing and verifying" do
    key = Rayo::JWT::Key.new("secret" * 20)
    output = uninitialized UInt8[1024]
    scratch = uninitialized UInt8[1024]
    token = key.sign(%q({"sub":"123","exp":200}), output.to_slice)
    key.verify(token, scratch.to_slice, 150)
    GC.stats
    snapshots = uninitialized UInt64[102]
    102.times do |iteration|
      snapshots[iteration] = GC.stats.total_bytes
      token = key.sign(%q({"sub":"123","exp":200}), output.to_slice)
      key.verify(token, scratch.to_slice, 150).not_nil!["sub"].string
      nil
    end
    allocated = snapshots[101] - snapshots[1]
    assert_no_request_allocations(allocated)
  end
end

describe Rayo::JWT::Key do
  it "verifies the RFC 7519 section 3.1 / RFC 7515 appendix A.1 vector" do
    key_bytes = uninitialized UInt8[64]
    n = Rayo::JWT.decode("AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow".to_slice, key_bytes.to_slice)
    n.should eq(64)
    key = Rayo::JWT::Key.new(key_bytes.to_slice)
    token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    scratch = uninitialized UInt8[1024]
    claims = key.verify(token, scratch.to_slice, 1300819379).not_nil!
    claims["iss"].string.should eq("joe".to_slice)
    claims["http://example.com/is_root"].bool.should be_true
    key.verify(token, scratch.to_slice, 1300819380).should be_nil
  end
end

describe Rayo::JWT::Key do
  it "matches independent HMAC signing vectors for short and long keys" do
    output = uninitialized UInt8[1024]
    vectors = {
      "secret"      => "HkBYQJYJ3li2-xXtL3hYOBQzr-biVXo3QyzxKJIFMrM",
      "secret" * 20 => "bsydrccGIUqd8m5-bQwzWsPxznIFPYnAQfV9sZh6JuA",
    }
    vectors.each do |secret, signature|
      token = Rayo::JWT::Key.new(secret).sign(%q({"sub":"123","exp":200}), output.to_slice)
      String.new(token).should eq("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMiLCJleHAiOjIwMH0." + signature)
    end
  end
end

describe Rayo::JWT::Key do
  it "compares integer dates exactly without overflow" do
    output = uninitialized UInt8[1024]
    scratch = uninitialized UInt8[1024]
    key = Rayo::JWT::Key.new("secret")
    token = key.sign(%q({"exp":9007199254740993}), output.to_slice)
    key.verify(token, scratch.to_slice, 9007199254740992).should_not be_nil
    key.verify(token, scratch.to_slice, 9007199254740993).should be_nil
    token = key.sign(%q({"exp":9223372036854775807}), output.to_slice)
    key.verify(token, scratch.to_slice, Int64::MAX, 1).should_not be_nil
  end
end
