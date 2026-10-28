require "./spec_helper"
require "socket"

private def worker_children(pid : Int32) : Array(Int32)
  File.read("/proc/#{pid}/task/#{pid}/children").split.map(&.to_i)
rescue File::NotFoundError
  [] of Int32
end

describe Rayo::App do
  it "validates startup arguments" do
    expect_raises(ArgumentError) { Rayo::App.new.run(workers: 0) }
    expect_raises(ArgumentError) { Rayo::App.new.run(port: 65536) }
  end

  it "stops the remaining workers when one exits" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.port
    listener.close
    pid = LibC.fork
    raise "fork failed" if pid < 0
    if pid == 0
      LibC.signal(15, LibC::SIG_DFL)
      begin
        app = Rayo::App.new
        app.get("/") { |ctx| ctx.text("hello") }
        app.run(host: "127.0.0.1", port: port, workers: 2)
      rescue
        LibC._exit(1)
      end
    end
    # Register the raw-fork fixture with Crystal's SIGCHLD reaper.
    process = Process.new(Crystal::System::Process.new(pid))
    children = [] of Int32
    reaped = false
    begin
      200.times do
        children = worker_children(pid)
        break if children.size == 2
        sleep 5.milliseconds
      end
      children.size.should eq(2)
      # Both processes were started by this fixture; no unrelated child is signalled.
      LibC.kill(children[0], 9).should eq(0)
      200.times do
        if process.terminated?
          reaped = true
          break
        end
        sleep 5.milliseconds
      end
      reaped.should be_true
      process.wait.exit_code.should eq(1)
      children.each { |child| File.exists?("/proc/#{child}").should be_false }
    ensure
      unless reaped
        process.signal(Signal::KILL) if process.exists?
        process.wait
      end
    end
  end
end
