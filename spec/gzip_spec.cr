require "./spec_helper"
require "compress/gzip"

describe Rayo::Gzip do
  it "negotiates tokens, wildcards and quality values" do
    {"gzip", "br, GZip; q=0.5", "*;q=1", "gzip;q=1.000"}.each do |header|
      Rayo::Gzip.accepted?(header.to_slice).should be_true
    end
    {"", "xgzip", "gzip;q=0", "gzip;q=0.000", "*;q=1, gzip;q=0", "gzip;q=2", "gzip;q=no", "gzip;q=1.01", "gzip;q=0.0001"}.each do |header|
      Rayo::Gzip.accepted?(header.to_slice).should be_false
    end
  end

  it "compresses reusable bodies and respects status, threshold and route opt-out" do
    gzip = Rayo::Gzip.new(min_size: 128)
    ctx = Rayo::Context.new(0)
    req = Rayo::HTTP::Request.new
    req.headers = "Accept-Encoding: gzip\r\n".to_slice
    body = "hello compression " * 100
    begin
      ctx.reset(req)
      ctx.header("Vary", "Origin")
      ctx.text(body)
      gzip.apply(ctx)
      ctx.response_header("Content-Encoding").should eq("gzip".to_slice)
      ctx.response_header("Vary").should eq("Origin, Accept-Encoding".to_slice)
      compressed = IO::Memory.new(Bytes.new(ctx.output.ptr, ctx.output.len))
      Compress::Gzip::Reader.open(compressed) { |r| r.gets_to_end.should eq(body) }
      ctx.output.len.should be < body.bytesize
      {204, 304, 206}.each do |code|
        ctx.reset(req)
        ctx.status(code)
        ctx.text(body)
        gzip.apply(ctx)
        ctx.output.len.should eq(body.bytesize)
      end
      ctx.reset(req)
      ctx.compress = false
      ctx.text(body)
      gzip.apply(ctx)
      ctx.output.len.should eq(body.bytesize)
      ctx.reset(req)
      ctx.text("small")
      gzip.apply(ctx)
      ctx.output.len.should eq(5)
      ctx.reset(req)
      ctx.header("Content-Encoding", "br")
      ctx.text(body)
      gzip.apply(ctx)
      ctx.output.len.should eq(body.bytesize)
      # Warm the high-water marks, then measure the ordinary response path.
      100.times do
        ctx.reset(req)
        ctx.text(body)
        gzip.apply(ctx)
      end
      GC.stats
      before = GC.stats.total_bytes
      100.times do
        ctx.reset(req)
        ctx.text(body)
        gzip.apply(ctx)
      end
      assert_no_request_allocations(GC.stats.total_bytes - before)
    ensure
      gzip.close
      LibC.free(ctx.output.ptr)
      LibC.free(ctx.headers.ptr)
    end
  end
end
