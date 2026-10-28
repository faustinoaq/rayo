require "./spec_helper"
require "socket"

module CoreFixture
  @@pending : Rayo::Context::Deferred? = nil
  BIG = "z" * (512 * 1024)

  def self.delay(ctx : Rayo::Context) : Nil
    @@pending = ctx.defer
    cancelled = Rayo::Uring.arm_timeout(1, ->(_tag : UInt64) { raise "cancelled timer ran" })
    Rayo::Uring.cancel_timeout(cancelled).should be_true
    Rayo::Uring.cancel_timeout(cancelled).should be_false
    Rayo::Uring.arm_timeout(10, ->(_tag : UInt64) { CoreFixture.complete })
  end

  def self.complete : Nil
    if handle = @@pending
      handle.finish do |ctx|
        ctx.write(ctx.param("id"))
        ctx.write(ctx.body)
      end.should be_true
      handle.finish.should be_false
      @@pending = nil
    end
  end

  class Peer
    include Rayo::Uring::Handler
    property fd = -1
    property tag = -1
    getter buffer = Rayo::Buf.new(64)

    def initialize(@echo : Bool)
    end

    def on_data(ptr : UInt8*, len : Int32) : Nil
      if @echo
        @buffer.clear
        @buffer.write(ptr, len)
        Rayo::Uring.send_plain(@fd, @buffer.ptr, @buffer.len, @tag)
      else
        CoreFixture.transport_done(ptr, len)
      end
    end

    def on_sent(result : Int32) : Nil
      raise "plain send failed" unless result == 9
      CoreFixture.sent
    end

    def on_closed : Nil
      CoreFixture.closed
    end
  end

  A = Peer.new(false)
  B = Peer.new(true)
  @@transport : Rayo::Context::Deferred? = nil
  @@sent = 0
  @@closed = 0

  def self.sent : Nil
    @@sent += 1
  end

  def self.closed : Nil
    @@closed += 1
  end

  def self.transport(ctx : Rayo::Context) : Nil
    pair = uninitialized Int32[2]
    raise "socketpair failed" unless LibC.socketpair(1, 1, 0, pair) == 0
    A.fd, B.fd = pair[0], pair[1]
    A.tag = Rayo::Uring.watch(A.fd, A)
    B.tag = Rayo::Uring.watch(B.fd, B)
    @@transport = ctx.defer
    Rayo::Uring.send_plain(A.fd, "transport".to_unsafe, 9, A.tag)
  end

  def self.transport_done(ptr : UInt8*, len : Int32) : Nil
    @@transport.not_nil!.finish { |ctx| ctx.write(Bytes.new(ptr, len)) }
    Rayo::Uring.unwatch(A.tag)
    Rayo::Uring.unwatch(B.tag)
  end

  def self.transport_status(ctx : Rayo::Context) : Nil
    ctx.text(@@sent == 2 && @@closed == 2 ? "done" : "pending")
  end

  def self.app : Rayo::App
    app = Rayo::App.new
    app.before { |ctx| ctx.header("X-Before", "yes") }
    app.after do |ctx|
      ctx.header("X-After", "yes")
      ctx.header("x-before", "replaced")
    end
    app.get("/") { |ctx| ctx.text("hello") }
    app.get("/users/:id") { |ctx| ctx.output << ctx.param_i64("id") }
    app.get("/files/*") { |ctx| ctx.write(ctx.param("*")) }
    app.get("/branch/static/end") { |ctx| ctx.text("static") }
    app.get("/branch/:name/fallback") { |ctx| ctx.write(ctx.param("name")) }
    app.post("/echo") { |ctx| ctx.write(ctx.body) }
    app.post("/delay/:id") { |ctx| CoreFixture.delay(ctx) }
    app.get("/big") { |ctx| ctx.text(BIG) }
    app.get("/inspect") do |ctx|
      ctx.write(ctx.query("key"))
      ctx.write(ctx.header("x-value"))
      ctx.status(201)
    end
    app.head("/head") { |ctx| ctx.text("hello") }
    app.get("/content-type") { |ctx| ctx.header("Content-Type", "application/test".to_slice); ctx.text("typed") }
    app.get("/transport") { |ctx| CoreFixture.transport(ctx) }
    app.get("/transport-status") { |ctx| CoreFixture.transport_status(ctx) }
    app.get("/error") { |_ctx| raise "handler error" }
    app
  end
end

private def core_connect(port)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 3.seconds
  socket.write_timeout = 3.seconds
  socket
end

private def core_response(socket, head = false)
  status = socket.gets("\r\n", chomp: true).not_nil!
  length = 0
  headers = ""
  loop do
    line = socket.gets("\r\n", chomp: true).not_nil!
    break if line.empty?
    headers += line + "\r\n"
    length = line[16..].to_i if line.starts_with?("Content-Length: ")
  end
  body = Bytes.new(head ? 0 : length)
  socket.read_fully(body)
  {status, String.new(body), headers}
end

if ENV["RAYO_SPEC_FIXTURE"]? == "core"
  ENV["URING_SLOTS"] = "32"
  CoreFixture.app.run(host: "127.0.0.1", port: ENV["RAYO_SPEC_PORT"].to_i, workers: 1, database: nil)
end

describe "core HTTP integration" do
  it "serves pipelines, deferred work, spill-over rings and persistent connections" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.port
    listener.close
    process = start_fixture("core", {"RAYO_SPEC_PORT" => port.to_s})
    begin
      ready = false
      200.times do
        begin
          core_connect(port).close
          ready = true
          break
        rescue Socket::ConnectError
          sleep 5.milliseconds
        end
      end
      ready.should be_true
      s = core_connect(port)
      s << "GET / HTTP/1.1\r\n\r\nGET /users/42 HTTP/1.1\r\n\r\nGET /missing HTTP/1.1\r\n\r\nPUT / HTTP/1.1\r\n\r\n"
      {"hello", "42", "", ""}.each_with_index do |body, i|
        status, actual, headers = core_response(s)
        status.should contain({"200", "200", "404", "405"}[i])
        actual.should eq(body)
        headers.should contain("x-before: replaced")
        headers.should_not contain("X-Before: yes")
        headers.should contain("Allow: GET") if i == 3
        headers.should contain("X-After: yes")
      end
      s << "GET /files/a/b HTTP/1.1\r\n\r\nGET /branch/static/fallback HTTP/1.1\r\n\r\nGET /inspect?key=abc HTTP/1.1\r\nX-Value: def\r\n\r\n"
      core_response(s)[1].should eq("a/b")
      core_response(s)[1].should eq("static")
      status, body, _ = core_response(s)
      status.should contain("201")
      body.should eq("abcdef")

      # Data received during a deferred request must not move its param/body views.
      s << "POST /delay/77 HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"
      sleep 2.milliseconds
      s << "GET / HTTP/1.1\r\n\r\n" * 100
      core_response(s)[1].should eq("77abc")
      100.times { core_response(s)[1].should eq("hello") }
      s << "GET /transport HTTP/1.1\r\n\r\n"
      core_response(s)[1].should eq("transport")
      sleep 10.milliseconds
      s << "GET /transport-status HTTP/1.1\r\n\r\n"
      core_response(s)[1].should eq("done")
      large = "a" * (256 * 1024)
      s << "POST /echo HTTP/1.1\r\nContent-Length: #{large.bytesize}\r\n\r\n"
      s << large
      core_response(s)[1].should eq(large)
      s << "HEAD /head HTTP/1.1\r\n\r\nGET /error HTTP/1.1\r\n\r\n"
      core_response(s, true)[2].should contain("Content-Length: 5")
      core_response(s)[0].should contain("500")
      s << "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
      core_response(s)[1].should eq("hello")
      s.read_byte.should be_nil
      s.close

      half = core_connect(port)
      half << "POST /delay/88 HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"
      half << "GET / HTTP/1.1\r\n\r\n"
      LibC.shutdown(half.fd, 1)
      core_response(half)[1].should eq("88abc")
      core_response(half)[1].should eq("hello")
      half.read_byte.should be_nil
      half.close
      sockets = Array.new(200) { core_connect(port) }
      sockets.each { |client| client << "GET / HTTP/1.1\r\n\r\n" }
      sockets.each_with_index do |client, i|
        core_response(client)[1].should eq("hello")
      end
      sockets.each &.close
      # Fill the peer's send window to exercise queued output and short sends.
      s = core_connect(port)
      s << ("GET /big HTTP/1.1\r\n\r\n" * 6)
      sleep 20.milliseconds
      6.times { core_response(s)[1].should eq(CoreFixture::BIG) }
      s.close
      50.times do
        peer = core_connect(port)
        peer << "GET /big HTTP/1.1\r\n\r\n"
        peer.close
      end
      s = core_connect(port)
      s << "GET / HTTP/1.1\r\n\r\n"
      core_response(s)[1].should eq("hello")
      s.close
      typed = core_connect(port)
      typed << "GET /content-type HTTP/1.1\r\nConnection: close\r\n\r\n"
      _, _, headers = core_response(typed)
      headers.should contain("Content-Type: application/test")
      headers.should_not contain("text/plain")
      typed.close
    ensure
      process.signal(Signal::TERM) if process.exists?
      process.wait
    end
  end
end
