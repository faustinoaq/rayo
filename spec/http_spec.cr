require "./spec_helper"
require "../src/rayo/http"

private def parse_request(data : String)
  request = Rayo::HTTP::Request.new
  count = Rayo::HTTP.parse(data.to_unsafe, data.bytesize, pointerof(request))
  {count, request}
end

describe Rayo::HTTP do
  it "parses all supported methods and keeps views in the original buffer" do
    %w(GET POST PUT PATCH DELETE HEAD OPTIONS).each do |method|
      data = "#{method} /users/12?sort=new HTTP/1.1\r\nHost: local\r\nX-Test:  value \t\r\nContent-Length: 3\r\n\r\nabcNEXT"
      n, r = parse_request(data)
      n.should eq(data.bytesize - 4)
      r.method.to_s.should eq(method)
      String.new(r.path).should eq("/users/12")
      String.new(r.query).should eq("sort=new")
      String.new(r.header("x-TEST")).should eq("value")
      String.new(r.body).should eq("abc")
      r.path.to_unsafe.should eq(data.to_unsafe + method.bytesize + 1)
      r.close.should be_false
    end
  end

  it "folds ASCII letters without conflating header punctuation" do
    _, r = parse_request("GET / HTTP/1.1\r\nX^: caret\r\nX~: tilde\r\n\r\n")
    String.new(r.header("x^")).should eq("caret")
    String.new(r.header("x~")).should eq("tilde")
  end

  it "waits for every incomplete prefix including bodies" do
    data = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
    data.bytesize.times do |n|
      r = Rayo::HTTP::Request.new
      Rayo::HTTP.parse(data.to_unsafe, n, pointerof(r)).should eq(0)
    end
    parse_request(data)[0].should eq(data.bytesize)
  end

  it "handles persistent and closing connections across HTTP versions" do
    parse_request("GET / HTTP/1.0\r\n\r\n")[1].close.should be_true
    parse_request("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")[1].close.should be_false
    parse_request("GET / HTTP/1.1\r\nConnection: upgrade, CLOSE, keep-alive\r\n\r\n")[1].close.should be_true
  end

  it "rejects ambiguous framing and invalid syntax" do
    [
      "GET / HTTP/2.0\r\n\r\n",
      "GET / HTTP/1.1\r\nNo-Colon\r\n\r\n",
      "GET / HTTP/1.1\r\nBad Header: x\r\n\r\n",
      "GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
      "GET / HTTP/1.1\r\nContent-Length: \r\n\r\n",
      "GET / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\naa",
      "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
      "GET / HTTP/1.1\r\nContent-Length: 999999999999999999999\r\n\r\n",
      "GET /\t HTTP/1.1\r\n\r\n",
      "GET / HTTP/1.1\r\nX: a\nb\r\n\r\n",
      "GET / HTTP/1.1\r\nX: #{"a" * Rayo::HTTP::MAX_HEADER}\r\n\r\n",
    ].each { |data| parse_request(data)[0].should eq(Rayo::HTTP::BAD) }
  end

  it "writes cached dates and correct HEAD and empty status framing" do
    body = Rayo::Buf.new(16)
    body << "hello"
    headers = Rayo::Buf.new(16)
    dst = Rayo::Buf.new(256)
    Rayo::HTTP.response(dst, 200, body, headers, "text/plain", false, true)
    response = String.new(dst.ptr, dst.len)
    response.should contain("Content-Length: 5\r\n")
    response.should end_with("\r\n\r\n")
    date = Rayo::HTTP.date
    Rayo::HTTP.date.should be(date)
    dst.clear
    Rayo::HTTP.response(dst, 204, body, headers, "text/plain", true, false)
    String.new(dst.ptr, dst.len).should contain("Content-Length: 0\r\n")
    # Buf has explicit malloc ownership; specs release their temporary buffers too.
    {body, headers, dst}.each { |b| LibC.free(b.ptr) }
  end
end
