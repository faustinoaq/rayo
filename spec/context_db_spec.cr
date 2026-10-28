require "./spec_helper"
require "socket"
require "random/secure"

class Rayo::Context
  property allocation_before = 0_u64
end

module ContextDBFixture
  URL    = ENV["RAYO_PG_URL"]? || "postgres://postgres:postgres@127.0.0.1:5432/postgres"
  NAME   = "rayo_int_spec_#{Random::Secure.hex(8)}"
  DB_URL = begin
    url = URI.parse(URL)
    url.path = "/#{NAME}"
    url.to_s
  end
  ONE  = Rayo::PG::Statement.new("SELECT $1::int8, 'Ana'::text")
  ROWS = Rayo::PG::Statement.new("SELECT generate_series(1, 3)::int8")
  BAD  = Rayo::PG::Statement.new("SELECT 1 / 0")

  def self.execute(sql)
    admin = Rayo::PG::BlockingTransport.new(URL)
    begin
      admin.query(Rayo::PG::Statement.new(sql)) do |res|
        raise String.new(res.message) if res.error?
      end
      admin.drain
    ensure
      admin.close
    end
  end

  def self.capture(ctx)
    value = ctx.param_count
    ctx.db.query(ONE, 1) { |res, ctx| ctx.json(value: value) }
  end

  def self.app
    app = Rayo::App.new
    app.get("/one/:id") do |ctx|
      ctx.db.query(ONE, ctx.param_i64("id")) do |res, ctx|
        if row = res.first?
          ctx.json(id: row.i64(0), name: row.str(1))
        end
      end
    end
    app.get("/allocation") do |ctx|
      GC.stats
      ctx.allocation_before = GC.stats.total_bytes
      ctx.db.query(ONE, 1) do |res, ctx|
        allocated = GC.stats.total_bytes - ctx.allocation_before
        ctx.json(allocated: allocated)
      end
    end
    app.get("/capture") { |ctx| ContextDBFixture.capture(ctx) }
    app.get("/rows") do |ctx|
      ctx.db.query(ROWS) do |res, ctx|
        ctx.json_array(res) { |row| {id: row.i64(0)} }
      end
    end
    app.get("/error") do |ctx|
      ctx.db.query(BAD) { |res, ctx| }
    end
    app.get("/handled") do |ctx|
      ctx.db.query(BAD) do |res, ctx|
        if res.error?
          ctx.status(422)
          ctx.json(error: res.sqlstate)
        end
      end
    end
    app.get("/raise") do |ctx|
      ctx.db.query(ONE, 1) { |res, ctx| raise "callback failed" }
    end
    app.get("/chain") do |ctx|
      ctx.db.query(ONE, 1) do |res, ctx|
        ctx.db.query(ONE, 2) do |res, ctx|
          ctx.json(id: res.first?.not_nil!.i64(0))
        end
      end
    end
    app
  end
end

Spec.before_suite { ContextDBFixture.execute("CREATE DATABASE #{ContextDBFixture::NAME}") }
Spec.after_suite { ContextDBFixture.execute("DROP DATABASE #{ContextDBFixture::NAME}") }

private def db_connect(port)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 3.seconds
  socket.write_timeout = 3.seconds
  socket
end

private def db_response(socket)
  status = socket.gets("\r\n", chomp: true).not_nil!
  length = 0
  type = ""
  loop do
    line = socket.gets("\r\n", chomp: true).not_nil!
    break if line.empty?
    length = line[16..].to_i if line.starts_with?("Content-Length: ")
    type = line if line.starts_with?("Content-Type:")
  end
  bytes = Bytes.new(length)
  socket.read_fully(bytes)
  {status, String.new(bytes), type}
end

describe "Context database integration" do
  it "fails clearly without a configured database" do
    expect_raises(Rayo::PG::Error, "database is not configured") { Rayo::Context.new(0).db }
  end

  it "finishes queries, preserves pipeline order, serves concurrent peers and recovers after errors" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.port
    listener.close
    pid = LibC.fork
    raise "fork failed" if pid < 0
    if pid == 0
      LibC.signal(15, LibC::SIG_DFL)
      begin
        ContextDBFixture.app.run(host: "127.0.0.1", port: port, workers: {{ flag?(:without_mt) ? 2 : 1 }}, database: ContextDBFixture::DB_URL, pool: 2)
      rescue ex
        STDERR.puts ex.inspect_with_backtrace
        LibC._exit(1)
      end
    end
    process = Process.new(Crystal::System::Process.new(pid))
    begin
      ready = false
      400.times do
        begin
          socket = db_connect(port)
          socket << "GET /one/42 HTTP/1.1\r\nConnection: close\r\n\r\n"
          db_response(socket)[1].should eq(%q({"id":42,"name":"Ana"}))
          socket.close
          ready = true
          break
        rescue Socket::ConnectError
          sleep 5.milliseconds
        end
      end
      ready.should be_true
      socket = db_connect(port)
      128.times { |i| socket << "GET /one/#{i} HTTP/1.1\r\n\r\n" }
      128.times { |i| db_response(socket)[1].should eq(%({"id":#{i},"name":"Ana"})) }
      socket << "GET /rows HTTP/1.1\r\n\r\nGET /error HTTP/1.1\r\n\r\nGET /handled HTTP/1.1\r\n\r\nGET /raise HTTP/1.1\r\n\r\nGET /chain HTTP/1.1\r\n\r\n"
      rows = db_response(socket)
      rows[1].should eq(%q([{"id":1},{"id":2},{"id":3}]))
      rows[2].should eq("Content-Type: application/json")
      error = db_response(socket)
      error[0].should contain("500")
      error[1].should eq(%q({"error":"database error"}))
      handled = db_response(socket)
      handled[0].should contain("422")
      handled[1].should eq(%q({"error":"22012"}))
      db_response(socket)[0].should contain("500")
      db_response(socket)[1].should eq(%q({"id":2}))
      16.times do
        socket << "GET /allocation HTTP/1.1\r\n\r\n"
        db_response(socket)[1].should eq(%q({"allocated":0}))
      end
      socket << "GET /capture HTTP/1.1\r\n\r\nGET /one/7 HTTP/1.1\r\n\r\n"
      db_response(socket)[0].should contain("500")
      db_response(socket)[1].should eq(%q({"id":7,"name":"Ana"}))
      socket.close
      peers = Array.new(32) { db_connect(port) }
      peers.each_with_index do |peer, i|
        peer << "GET /one/#{i} HTTP/1.1\r\nConnection: close\r\n\r\n"
      end
      peers.each_with_index do |peer, i|
        db_response(peer)[1].should eq(%({"id":#{i},"name":"Ana"}))
        peer.close
      end
      # A callback arriving after disconnect must not complete a reused HTTP slot.
      16.times do
        peer = db_connect(port)
        peer << "GET /rows HTTP/1.1\r\n\r\n"
        peer.close
      end
      peer = db_connect(port)
      peer << "GET /one/99 HTTP/1.1\r\nConnection: close\r\n\r\n"
      db_response(peer)[1].should eq(%q({"id":99,"name":"Ana"}))
      peer.close
    ensure
      process.signal(Signal::TERM) if process.exists?
      process.wait
    end
  end
end
