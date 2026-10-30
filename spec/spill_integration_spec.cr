require "./spec_helper"
require "socket"

if ENV["RAYO_SPEC_FIXTURE"]? == "spill"
  # Limits apply only to this exec'd server, never to the spec runner.
  {Rayo::Sys::RLIMIT_NOFILE => 512_u64, Rayo::Sys::RLIMIT_MEMLOCK => 1024_u64 * 1024}.each do |kind, limit|
    rl = uninitialized LibC::Rlimit
    raise "getrlimit failed" unless LibC.getrlimit(kind, pointerof(rl)) == 0
    rl.rlim_cur = rl.rlim_max = {rl.rlim_max, limit}.min
    raise "setrlimit failed" unless Rayo::LibSys.setrlimit(kind, pointerof(rl).as(Rayo::Sys::Rlimit*)) == 0
  end
  ENV["URING_SLOTS"] = "500"
  app = Rayo::App.new
  app.get("/") { |ctx| ctx.text("ok") }
  app.run(host: "127.0.0.1", port: ENV["RAYO_SPEC_PORT"].to_i, workers: 1, database: nil)
end

private def spill_request(socket)
  socket << "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  socket.gets("\r\n", chomp: true).should eq("HTTP/1.1 200 OK")
  length = 0
  loop do
    line = socket.gets("\r\n", chomp: true).not_nil!
    break if line.empty?
    length = line[16..].to_i if line.starts_with?("Content-Length: ")
  end
  body = Bytes.new(length)
  socket.read_fully(body)
  String.new(body).should eq("ok")
end

private def spill_connect(port)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 3.seconds
  socket.write_timeout = 3.seconds
  socket
end

describe "fixed-file ring capacity" do
  {"0", "1"}.each do |classic|
    it "serves 2000 idle keep-alives with a small memlock budget (classic=#{classic})" do
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.port
      listener.close
      process = start_fixture("spill", {"RAYO_SPEC_PORT" => port.to_s, "RAYO_CLASSIC_BUFFERS" => classic})
      sockets = [] of TCPSocket
      begin
        ready = false
        200.times do
          begin
            spill_connect(port).close
            ready = true
            break
          rescue Socket::ConnectError
            sleep 5.milliseconds
          end
        end
        ready.should be_true
        2000.times do
          socket = spill_connect(port)
          sockets << socket
          spill_request(socket)
        end
        # Exercise every ring after its connections go idle.
        sockets.each { |socket| spill_request(socket) }
        1000.times { sockets.pop.close }
        1000.times do
          socket = spill_connect(port)
          sockets << socket
          spill_request(socket)
        end
        sockets.each { |socket| spill_request(socket) }
      ensure
        sockets.each &.close
        process.signal(Signal::TERM) if process.exists?
        process.wait
      end
    end
  end
end
