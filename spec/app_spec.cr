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
    expect_raises(ArgumentError) { Rayo::App.new.run(ports: [] of Int32) }
    expect_raises(ArgumentError) { Rayo::App.new.run(ports: [3000, -1]) }
  end

  it "stops the remaining workers when one exits" do
    {% unless flag?(:without_mt) %}
      expect_raises(Exception, "multiple workers require -Dwithout_mt") do
        Rayo::App.new.run(workers: 2, database: nil)
      end
      next
    {% end %}
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.port
    listener.close
    hook_pipe = uninitialized Int32[2]
    LibC.pipe(hook_pipe).should eq(0)
    pid = LibC.fork
    raise "fork failed" if pid < 0
    if pid == 0
      LibC.signal(15, LibC::SIG_DFL)
      begin
        LibC.close(hook_pipe[0])
        supervisor = LibC.getpid
        app = Rayo::App.new
        app.on_worker_start do |index|
          record = StaticArray[index, LibC.getpid]
          raise "hook ran before fork" if record[1] == supervisor
          LibC.write(hook_pipe[1], record.to_unsafe, 8)
        end
        app.get("/") { |ctx| ctx.text("hello") }
        app.run(host: "127.0.0.1", port: port, workers: 2)
      rescue
        LibC._exit(1)
      end
    end
    LibC.close(hook_pipe[1])
    hook_reader = IO::FileDescriptor.new(hook_pipe[0])
    hook_reader.read_timeout = 3.seconds
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
      records = uninitialized Int32[4]
      hook_reader.read_fully(Slice(UInt8).new(records.to_unsafe.as(UInt8*), 16))
      {records[0], records[2]}.to_a.sort.should eq([0, 1])
      {records[1], records[3]}.to_a.sort.should eq(children.sort)
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
      hook_reader.close
      unless reaped
        process.signal(Signal::KILL) if process.exists?
        process.wait
      end
    end
  end
end
