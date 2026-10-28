require "./spec_helper"
require "../src/rayo/json"

describe Rayo::JSON do
  it "writes and navigates nested documents with automatic commas" do
    b = Rayo::Buf.new(1024)
    j = Rayo::JSON::Writer.new(b)
    j.object do
      j.field "a", Int64::MIN
      j.field("nested") { j.array { j.value true; j.value nil; j.object { j.field "s", "hola\n😀" } } }
      j.field "max", Int64::MAX
      j.field "float", 0.1
    end
    r = Rayo::JSON::Reader.new(Bytes.new(b.ptr, b.len))
    r["a"].i64.should eq(Int64::MIN)
    r["max"].i64.should eq(Int64::MAX)
    r["float"].f64.should eq(0.1)
    scratch = uninitialized UInt8[100]
    count = 0
    r["nested"].array do |v|
      case count
      when 0 then v.bool.should be_true
      when 1 then v.null?.should be_true
      when 2 then v["s"].string(scratch.to_slice).should eq("hola\n😀".to_slice)
      end
      count += 1
    end
    count.should eq(3)
  end
end

describe Rayo::JSON::Reader do
  it "rejects malformed syntax, escapes, UTF-8 and excessive nesting" do
    invalid = ["", "01", "-", "1.", "1e+", "true false", "[1,]", "{\"a\":}", "{a:1}", "[", "NaN", "Infinity", "\"\n\"", %q("\x"), %q("\uD800"), %q("\uDC00"), %q("\uD800\u0041"), "[" * 65 + "0" + "]" * 65]
    invalid.each do |s|
      expect_raises(Rayo::JSON::Error) { Rayo::JSON::Reader.new(s.to_slice) }
    end
    [Bytes[34, 0xC0, 0xAF, 34], Bytes[34, 0xED, 0xA0, 0x80, 34], Bytes[34, 0xF4, 0x90, 0x80, 0x80, 34], Bytes[34, 0x80, 34]].each do |b|
      expect_raises(Rayo::JSON::Error) { Rayo::JSON::Reader.new(b) }
    end
  end

  it "decodes every escape and surrogate pairs into caller scratch" do
    scratch = uninitialized UInt8[100]
    r = Rayo::JSON::Reader.new(%q("\"\\\/\b\f\n\r\t\u0000\u00e9\uD83D\uDE00").to_slice)
    r.string(scratch.to_slice).should eq("\"\\/\b\f\n\r\t\u0000é😀".to_slice)
    Rayo::JSON::Reader.new(%q({"\u0061":2}).to_slice)["a"].i64.should eq(2)
    expect_raises(Rayo::JSON::Error) { r.string(Bytes.empty) }
  end

  it "checks integer ranges and typed access" do
    ["9223372036854775808", "-9223372036854775809", "1.0", "1e1", "true"].each do |s|
      expect_raises(Rayo::JSON::Error) { Rayo::JSON::Reader.new(s.to_slice).i64 }
    end
    expect_raises(Rayo::JSON::Error) { Rayo::JSON::Reader.new("1e999".to_slice).f64 }
    expect_raises(Rayo::JSON::Error) { Rayo::JSON::Reader.new(%q({"a":1,"a":2}).to_slice)["a"] }
  end
end

describe Rayo::JSON::Writer do
  it "round trips finite float edges and rejects non-finite values" do
    b = Rayo::Buf.new(1024)
    [0.1, 1e21, -0.0, 0.0, Float64::MAX, Float64::MIN_POSITIVE, 5e-324, -1e-200, 1.2345678901234567].each do |v|
      b.clear
      Rayo::JSON::Writer.new(b).value(v)
      result = Rayo::JSON::Reader.new(Bytes.new(b.ptr, b.len)).f64
      result.unsafe_as(UInt64).should eq(v.unsafe_as(UInt64))
    end
    [Float64::NAN, Float64::INFINITY, -Float64::INFINITY].each do |v|
      expect_raises(Rayo::JSON::Error) { Rayo::JSON::Writer.new(b).value(v) }
    end
  end

  it "round trips deterministic random documents" do
    random = Random.new(42)
    b = Rayo::Buf.new(8192)
    scratch = uninitialized UInt8[1024]
    300.times do
      i = random.rand(Int64)
      v = random.rand(-1e100..1e100)
      s = String.build { |io| random.rand(0..50).times { io << ['a', '"', '\\', '\n', '\u0000', 'é', '😀'][random.rand(7)] } }
      b.clear
      j = Rayo::JSON::Writer.new(b)
      j.object do
        j.field "i", i
        j.field "f", v
        j.field "s", s.to_slice
        j.field("a") { j.array { j.value i; j.raw %q({"x":[]}) } }
      end
      r = Rayo::JSON::Reader.new(Bytes.new(b.ptr, b.len))
      r["i"].i64.should eq(i)
      r["f"].f64.should eq(v)
      r["s"].string(scratch.to_slice).should eq(s.to_slice)
    end
  end

  it "checks structure and raw values" do
    b = Rayo::Buf.new(1024)
    expect_raises(Rayo::JSON::Error) { Rayo::JSON::Writer.new(b).field("a", 1) }
    expect_raises(Rayo::JSON::Error) { Rayo::JSON::Writer.new(b).object { }; Rayo::JSON::Writer.new(b).raw("[1,]") }
    j = Rayo::JSON::Writer.new(b)
    j.value(1)
    expect_raises(Rayo::JSON::Error) { j.value(2) }
  end

  it "does not allocate on the reusable writer and reader path" do
    b = Rayo::Buf.new(8192)
    # Warm up runtime accounting before measuring.
    GC.stats
    snapshots = uninitialized UInt64[102]
    102.times do |iteration|
      snapshots[iteration] = GC.stats.total_bytes
      b.clear
      j = Rayo::JSON::Writer.new(b)
      j.object { j.field "x", 0.1; j.field "s", "hello" }
      r = Rayo::JSON::Reader.new(Bytes.new(b.ptr, b.len))
      r["x"].f64
      r["s"].string
      nil
    end
    allocated = snapshots[101] - snapshots[1]
    allocated.should eq(0)
  end
end

describe Rayo::JSON do
  it "round trips random IEEE-754 bit patterns" do
    random = Random.new(123)
    b = Rayo::Buf.new(1024)
    2000.times do
      v = random.rand(UInt64).unsafe_as(Float64)
      next unless v.finite?
      b.clear
      Rayo::JSON::Writer.new(b).value(v)
      Rayo::JSON::Reader.new(Bytes.new(b.ptr, b.len)).f64.unsafe_as(UInt64).should eq(v.unsafe_as(UInt64))
    end
  end

  it "accepts exactly 64 nested containers and writes common float notation" do
    Rayo::JSON::Reader.new(("[" * 64 + "0" + "]" * 64).to_slice)
    b = Rayo::Buf.new(1024)
    j = Rayo::JSON::Writer.new(b)
    j.array { j.value(0.1); j.value(1e21); j.value(-0.0) }
    String.new(b.ptr, b.len).should eq("[0.1,1e21,-0.0]")
  end
end
