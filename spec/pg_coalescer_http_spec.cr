require "./pg_coalescer_spec"
require "socket"

class Rayo::Context
  property coalescer_allocation_before = 0_u64
end

module CoalescerHTTPFixture
  FIND = Rayo::PG::Statement.new("SELECT n,v FROM unnest($1::int8[]) WITH ORDINALITY r(v,n) ORDER BY n")
  BAD  = Rayo::PG::Statement.new("SELECT 1/0 WHERE cardinality($1::int8[]) > 0")

  class Driver
    include Rayo::Uring::Flusher
    getter transport : Rayo::PG::RingTransport
    getter reads : Rayo::PG::Coalescer(Rayo::PG::ReadRequest)
    getter bad : Rayo::PG::Coalescer(Rayo::PG::ReadRequest)

    def initialize
      @transport = Rayo::PG::RingTransport.new(ENV["RAYO_SPEC_DB_URL"], 16)
      @reads = Rayo::PG::Coalescer(Rayo::PG::ReadRequest).new do |g|
        g.query(CoalescerHTTPFixture.driver.not_nil!.transport.conn, FIND, g.param(0))
      end
      @bad = Rayo::PG::Coalescer(Rayo::PG::ReadRequest).new do |g|
        g.query(CoalescerHTTPFixture.driver.not_nil!.transport.conn, BAD, g.param(0))
      end
      @reads.attach
      @bad.attach
      Rayo::Uring.add_flusher(self)
    end

    def flush : Nil
      @transport.flush
    end
  end

  class_property driver : Driver? = nil

  def self.app
    app = Rayo::App.new
    app.on_worker_start { |_| CoalescerHTTPFixture.driver = Driver.new }
    app.get("/read/:id") do |ctx|
      CoalescerHTTPFixture.driver.not_nil!.reads.enqueue(ctx, ctx.param_i64("id")) do |res, ctx|
        ctx.json(id: res.first?.not_nil!.i64(1)) unless res.error?
      end
    end
    app.get("/allocation") do |ctx|
      GC.stats
      ctx.coalescer_allocation_before = GC.stats.total_bytes
      CoalescerHTTPFixture.driver.not_nil!.reads.enqueue(ctx, 1_i64) do |res, ctx|
        ctx.json(allocated: GC.stats.total_bytes - ctx.coalescer_allocation_before)
      end
    end
    app.get("/error") do |ctx|
      CoalescerHTTPFixture.driver.not_nil!.bad.enqueue(ctx, 1_i64) { |res, ctx| }
    end
    app.get("/raise") do |ctx|
      CoalescerHTTPFixture.driver.not_nil!.reads.enqueue(ctx, 1_i64) { |res, ctx| raise "callback" }
    end
    app.get("/chain") do |ctx|
      CoalescerHTTPFixture.driver.not_nil!.reads.enqueue(ctx, 1_i64) do |res, ctx|
        CoalescerHTTPFixture.driver.not_nil!.reads.enqueue(ctx, 2_i64) do |res, ctx|
          ctx.db.query(FIND, Rayo::PG::ArrayParam.new("{3}".to_slice)) do |res, ctx|
            ctx.json(id: res.first?.not_nil!.i64(1))
          end
        end
      end
    end
    app
  end
end

if ENV["RAYO_SPEC_FIXTURE"]? == "coalescer"
  CoalescerHTTPFixture.app.run(host: "127.0.0.1", port: ENV["RAYO_SPEC_PORT"].to_i,
    workers: 1, database: ENV["RAYO_SPEC_DB_URL"], pool: 1)
end

private def coalescer_response(socket)
  status = socket.gets("\r\n", chomp: true).not_nil!
  length = 0
  loop do
    line = socket.gets("\r\n", chomp: true).not_nil!
    break if line.empty?
    length = line[16..].to_i if line.starts_with?("Content-Length: ")
  end
  bytes = Bytes.new(length)
  socket.read_fully(bytes)
  {status, String.new(bytes)}
end

describe "HTTP read coalescing" do
  it "preserves response order, survives disconnects/errors and composes pending work" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.port
    listener.close
    process = start_fixture("coalescer", {"RAYO_SPEC_PORT" => port.to_s, "RAYO_SPEC_DB_URL" => PGSpec::DB_URL})
    begin
      ready = false
      200.times do
        begin
          TCPSocket.new("127.0.0.1", port).close
          ready = true
          break
        rescue Socket::ConnectError
          sleep 5.milliseconds
        end
      end
      ready.should be_true
      socket = TCPSocket.new("127.0.0.1", port)
      socket.read_timeout = 3.seconds
      begin
        socket << "GET /chain HTTP/1.1\r\nHost: test\r\n\r\nGET /read/9 HTTP/1.1\r\nHost: test\r\n\r\n"
        coalescer_response(socket)[1].should eq(%({"id":3}))
        coalescer_response(socket)[1].should eq(%({"id":9}))
        10.times do
          socket << "GET /allocation HTTP/1.1\r\nHost: test\r\n\r\n"
          response = coalescer_response(socket)[1]
          allocated = response.delete("^0-9").to_u64
          assert_no_request_allocations(allocated)
        end
        {"error", "raise"}.each do |path|
          socket << "GET /#{path} HTTP/1.1\r\nHost: test\r\n\r\n"
          coalescer_response(socket)[0].should contain("500")
        end
        16.times do
          peer = TCPSocket.new("127.0.0.1", port)
          peer << "GET /read/1 HTTP/1.1\r\nHost: test\r\n\r\n"
          peer.close
        end
        20.times do |i|
          socket << "GET /read/#{i} HTTP/1.1\r\nHost: test\r\n\r\n"
          coalescer_response(socket)[1].should eq(%({"id":#{i}}))
        end
      ensure
        socket.close
      end
    ensure
      process.terminate unless process.terminated?
      process.wait
    end
  end
end
