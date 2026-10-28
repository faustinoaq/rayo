require "./spec_helper"
require "../src/rayo/bcrypt"
require "../src/rayo/sqlite/group_commit"
require "socket"

module WorkerFeatures
  class_property index = -1
  class_property database : Rayo::SQLite::Database? = nil
  class_property group : Rayo::SQLite::GroupCommit? = nil
  class_property count : Rayo::SQLite::Statement? = nil
  class_property passwords : Rayo::Bcrypt::Pool? = nil

  def self.app
    app = Rayo::App.new
    app.gzip = true
    app.on_worker_start do |index|
      WorkerFeatures.index = index
      db = Rayo::SQLite::Database.new(":memory:")
      db.exec("CREATE TABLE items(id INTEGER PRIMARY KEY)")
      WorkerFeatures.database = db
      WorkerFeatures.count = db.prepare("SELECT count(*) FROM items")
      group = Rayo::SQLite::GroupCommit.new(db)
      group.attach
      WorkerFeatures.group = group
      pool = Rayo::Bcrypt::Pool.new(cost: 4)
      GC.collect
      pool.attach
      WorkerFeatures.passwords = pool
    end
    app.get("/") { |ctx| ctx.output << WorkerFeatures.index }
    app.get("/hash") do |ctx|
      WorkerFeatures.passwords.not_nil!.hash(ctx, "hello".to_slice) do |res, ctx|
        WorkerFeatures.passwords.not_nil!.verify(ctx, "hello".to_slice, res.hash) do |checked, ctx|
          ctx.json(ok: checked.ok?)
        end
      end
    end
    app.get("/write") do |ctx|
      WorkerFeatures.group.not_nil!.transaction(ctx) do |db|
        db.exec("INSERT INTO items VALUES (1)")
        ctx.text("committed")
      end
    end
    app.get("/fail") do |ctx|
      WorkerFeatures.group.not_nil!.transaction(ctx) do |db|
        db.exec("INSERT INTO items VALUES (2)")
        db.exec("INSERT INTO items VALUES (1)")
        ctx.text("must not escape")
      end
    end
    app.get("/count") do |ctx|
      query = WorkerFeatures.count.not_nil!
      begin
        query.step
        ctx.output << query.i64(0)
      ensure
        query.reset
      end
    end
    app.get("/collect") { |ctx| GC.collect; ctx.text("collected") }
    app.get("/gzip") { |ctx| 1024.times { ctx.text("compress me ") } }
    app.get("/plain") { |ctx| ctx.compress = false; 1024.times { ctx.text("compress me ") } }
    app
  end
end

private def feature_response(socket)
  status = socket.gets("\r\n", chomp: true).not_nil!
  length = 0
  headers = ""
  loop do
    line = socket.gets("\r\n", chomp: true).not_nil!
    break if line.empty?
    headers += line + "\r\n"
    length = line[16..].to_i if line.starts_with?("Content-Length: ")
  end
  bytes = Bytes.new(length)
  socket.read_fully(bytes)
  {status, headers, String.new(bytes)}
end

if ENV["RAYO_SPEC_FIXTURE"]? == "features"
  ports = ENV["RAYO_SPEC_PORTS"].split(',').map(&.to_i)
  WorkerFeatures.app.run(host: "127.0.0.1", ports: ports, workers: 1, database: nil)
end

describe "worker features" do
  it "initializes after fork, serves both listeners, wakes bcrypt and commits before responses" do
    listeners = Array.new(2) { TCPServer.new("127.0.0.1", 0) }
    ports = listeners.map(&.local_address.port)
    listeners.each &.close
    process = start_fixture("features", {"RAYO_SPEC_PORTS" => ports.join(',')})
    begin
      ports.each do |port|
        socket = nil.as(TCPSocket?)
        400.times do
          begin
            socket = TCPSocket.new("127.0.0.1", port)
            break
          rescue Socket::ConnectError
            sleep 5.milliseconds
          end
        end
        peer = socket.not_nil!
        peer.read_timeout = 5.seconds
        peer << "GET / HTTP/1.1\r\n\r\n"
        feature_response(peer)[2].should eq("0")
        peer << "GET /collect HTTP/1.1\r\n\r\n"
        feature_response(peer)[2].should eq("collected")
        peer << "GET /hash HTTP/1.1\r\n\r\n"
        feature_response(peer)[2].should eq(%q({"ok":true}))
        peer.close
      end
      peer = TCPSocket.new("127.0.0.1", ports[0])
      peer.read_timeout = 5.seconds
      # The second request is dispatched as the first deferred response finishes.
      peer << "GET /write HTTP/1.1\r\n\r\nGET /fail HTTP/1.1\r\n\r\nGET /count HTTP/1.1\r\n\r\n"
      feature_response(peer)[2].should eq("committed")
      feature_response(peer)[0].should contain("500")
      feature_response(peer)[2].should eq("1")
      peer << "GET /gzip HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\nGET /plain HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n"
      zipped = feature_response(peer)
      zipped[1].should contain("Content-Encoding: gzip")
      zipped[2].bytesize.should be < 1024
      plain = feature_response(peer)
      plain[1].should_not contain("Content-Encoding:")
      plain[2].bytesize.should eq(12 * 1024)
      peer.close
    ensure
      process.signal(Signal::TERM) if process.exists?
      process.wait
    end
  end
end
