require "./spec_helper"

private def str(b : Rayo::Buf) : String
  String.new(b.ptr, b.len)
end

describe Rayo::Buf do
  it "grows past its initial capacity" do
    b = Rayo::Buf.new(4)
    b << "hello, " << "world"
    str(b).should eq("hello, world")
    b.cap.should be >= 12
  end

  it "writes integers" do
    b = Rayo::Buf.new(8)
    b << 0_i64 << ' '.ord.to_u8 << -42_i64 << ' '.ord.to_u8 << Int64::MAX
    str(b).should eq("0 -42 9223372036854775807")
  end

  it "escapes JSON strings" do
    b = Rayo::Buf.new(8)
    s = "a\"b\\c\nd\u0001 long enough to use the 8-byte path"
    b.json_escape(s.to_unsafe, s.bytesize)
    str(b).should eq(%q(a\"b\\c\nd\u0001 long enough to use the 8-byte path))
  end
end
