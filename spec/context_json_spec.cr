require "./spec_helper"

private struct JSONCustom
  def to_json(writer : Rayo::JSON::Writer)
    writer.value({custom: true})
  end
end

private def json_bytes(ctx)
  String.new(ctx.output.ptr, ctx.output.len)
end

describe "Context JSON" do
  it "writes all scalar widths, exact extremes, strings, bytes and containers" do
    ctx = Rayo::Context.new(0)
    begin
      ctx.json(i8: -128_i8, i16: -32768_i16, i32: Int32::MIN, i64: Int64::MIN,
        i128: Int128::MIN, u8: UInt8::MAX, u16: UInt16::MAX, u32: UInt32::MAX,
        u64: UInt64::MAX, u128: UInt128::MAX, f32: 1.5_f32, f64: -2.25,
        yes: true, no: false, absent: nil, text: "a\"\\\n\r\t\u0000雪",
        bytes: "b\"\n".to_slice, nested: {id: 1, empty: NamedTuple.new},
        tuple: {1, "a", nil}, empty_tuple: Tuple.new,
        static: StaticArray[1_i64, -2_i64], slice: Slice[2_u16, 3_u16], custom: JSONCustom.new)
      json_bytes(ctx).should eq(%q({"i8":-128,"i16":-32768,"i32":-2147483648,"i64":-9223372036854775808,"i128":-170141183460469231731687303715884105728,"u8":255,"u16":65535,"u32":4294967295,"u64":18446744073709551615,"u128":340282366920938463463374607431768211455,"f32":1.5,"f64":-2.25,"yes":true,"no":false,"absent":null,"text":"a\"\\\n\r\t\u0000雪","bytes":"b\"\n","nested":{"id":1,"empty":{}},"tuple":[1,"a",null],"empty_tuple":[],"static":[1,-2],"slice":[2,3],"custom":{"custom":true}}))
      ctx.content_type.should eq("application/json")
    ensure
      LibC.free(ctx.output.ptr)
      LibC.free(ctx.headers.ptr)
    end
  end

  it "escapes constant keys and writes empty objects, arrays and streamed fields" do
    ctx = Rayo::Context.new(0)
    begin
      ctx.json(**{"a\"\\\n\r\t\u0001": 1})
      json_bytes(ctx).should eq(%q({"a\"\\\n\r\t\u0001":1}))
      ctx.output.clear
      ctx.json
      json_bytes(ctx).should eq("{}")
      ctx.output.clear
      ctx.json_array([1, 2]) { |i| {id: i} }
      json_bytes(ctx).should eq(%q([{"id":1},{"id":2}]))
      ctx.output.clear
      ctx.json do |j|
        j.object do
          j.field("items") { j.array([3, 4]) { |i| {id: i} } }
          j.field "ok", true
        end
      end
      json_bytes(ctx).should eq(%q({"items":[{"id":3},{"id":4}],"ok":true}))
      ctx.output.clear
      ctx.json_array([] of Int32) { |i| {id: i} }
      json_bytes(ctx).should eq("[]")
    ensure
      LibC.free(ctx.output.ptr)
      LibC.free(ctx.headers.ptr)
    end
  end

  it "borrows the request body and allocates no managed bytes after warmup" do
    ctx = Rayo::Context.new(0)
    request = "POST / HTTP/1.1\r\nContent-Length: 8\r\n\r\n{\"id\":7}"
    req = Rayo::HTTP::Request.new
    Rayo::HTTP.parse(request.to_unsafe, request.bytesize, pointerof(req))
    ctx.reset(req)
    ctx.json_body.raw.to_unsafe.should eq(ctx.body.to_unsafe)
    items = [1, 2]
    begin
      100.times do
        ctx.output.clear
        ctx.json(id: 1_u64, name: "Ana", nested: {ok: true}, tuple: {nil, 1}, numbers: StaticArray[1, 2])
      end
      GC.stats
      before = GC.stats.total_bytes
      1000.times do
        ctx.output.clear
        ctx.json(id: 1_u64, name: "Ana", nested: {ok: true}, tuple: {nil, 1}, numbers: StaticArray[1, 2])
        ctx.output.clear
        ctx.json_array(items) { |i| {id: i} }
        ctx.json_body["id"].i64
      end
      (GC.stats.total_bytes - before).should eq(0)
    ensure
      LibC.free(ctx.output.ptr)
      LibC.free(ctx.headers.ptr)
    end
  end
end
