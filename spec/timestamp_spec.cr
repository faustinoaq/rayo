require "./spec_helper"
require "../src/rayo/json/timestamp"

describe Rayo::JSON::Timestamp do
  it "normalizes text offsets and binary epochs to RFC 3339 with microseconds" do
    ctx = Rayo::Context.new(0)
    begin
      {
        {"2024-02-29 03:30:01.123456+03:30", "2024-02-29T00:00:01.123456Z"},
        {"1999-12-31 23:00:00-01", "2000-01-01T00:00:00.000000Z"},
        {"2026-10-28T01:02:03.1Z", "2026-10-28T01:02:03.100000Z"},
      }.each do |(text, expected)|
        ctx.output.clear
        ctx.json(time: Rayo::JSON::Timestamp.new(text.to_slice))
        String.new(ctx.output.ptr, ctx.output.len).should eq(%({"time":"#{expected}"}))
      end
      {-1_i64, 0_i64, 1_i64}.each do |micros|
        ctx.output.clear
        bytes = uninitialized UInt8[8]
        IO::ByteFormat::BigEndian.encode(micros, bytes.to_slice)
        ctx.json(time: Rayo::JSON::Timestamp.binary(bytes.to_slice))
        expected = micros < 0 ? "1999-12-31T23:59:59.999999Z" : "2000-01-01T00:00:00.00000#{micros}Z"
        String.new(ctx.output.ptr, ctx.output.len).should eq(%({"time":"#{expected}"}))
      end
      {"infinity", "2024-01-01 00:00:00", "2024-01-01 00:00:00+00:99", "2024-01-01 00:00:00.1234567Z"}.each do |text|
        expect_raises(Rayo::JSON::Error) { Rayo::JSON::Timestamp.new(text.to_slice) }
      end
      expect_raises(Rayo::JSON::Error) { Rayo::JSON::Timestamp.binary(Int64::MAX) }
    ensure
      LibC.free(ctx.output.ptr)
      LibC.free(ctx.headers.ptr)
    end
  end
end
