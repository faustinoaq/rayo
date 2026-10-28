require "./spec_helper"

# Drive sockets from another process so each empty CQ must wake a sleeping loop.
describe Rayo::Ring do
  it "wakes repeatedly for socket work on independent deferred rings" do
    commands = uninitialized Int32[2]
    data = uninitialized Int32[2]
    LibC.socketpair(1, 1, 0, commands).should eq(0)
    LibC.socketpair(1, 1, 0, data).should eq(0)
    pid = LibC.fork
    raise "fork failed" if pid < 0
    if pid == 0
      LibC.signal(15, LibC::SIG_DFL)
      LibC.close(commands[0])
      LibC.close(data[0])
      byte = 0_u8
      while LibC.read(commands[1], pointerof(byte), 1) == 1
        break unless LibC.write(data[1], pointerof(byte), 1) == 1
      end
      LibC._exit(0)
    end
    LibC.close(commands[1])
    LibC.close(data[1])
    ep = LibC.epoll_create1(0)
    rings = [] of Rayo::Ring
    begin
      2.times do |i|
        ring = Rayo::Ring.create(i * 32, 32, 256_u32, 512_u32).not_nil!
        rings << ring
        ring.watch(ep)
      end
      event = Rayo::Sys::EpollEvent.new
      16.times do |i|
        ring = rings[i % 2]
        byte = 0_u8
        sqe = ring.sqe
        sqe.value.opcode = Rayo::Uring::OP_RECV
        sqe.value.fd = data[0]
        sqe.value.addr = pointerof(byte).address
        sqe.value.len = 1
        ring.enter(0_u32, Rayo::Uring::ENTER_GETEVENTS)
        ring.ready?.should be_false
        LibC.write(commands[0], pointerof(byte), 1).should eq(1)
        deadline = Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC) + 1_000_000_000
        until ring.ready?
          # The eventfd can stop signalling on 6.12/6.18; each bounded wait
          # must still run deferred work, including on the next wakeup.
          result = LibC.epoll_wait(ep, pointerof(event), 1, 1)
          (result >= 0 || Rayo::Sys.errno == Rayo::Sys::EINTR).should be_true
          ring.enter(0_u32, Rayo::Uring::ENTER_GETEVENTS)
          (Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC) < deadline).should be_true
        end
        ring.drain.should eq(1)
      end
    ensure
      rings.each &.dispose
      LibC.close(ep)
      LibC.close(commands[0])
      LibC.close(data[0])
      LibC.kill(pid, 15)
      status = 0
      LibC.waitpid(pid, pointerof(status), 0)
    end
  end
end

module LoopTimerFixture
  def self.done(fd : UInt64) : Nil
    byte = 1_u8
    LibC.write(fd.to_i32, pointerof(byte), 1)
    LibC._exit(0)
  end
end

describe "single-ring wait" do
  it "wakes for a loop timer without socket completions" do
    pair = uninitialized Int32[2]
    LibC.socketpair(1, 1, 0, pair).should eq(0)
    pid = LibC.fork
    raise "fork failed" if pid < 0
    if pid == 0
      LibC.signal(15, LibC::SIG_DFL)
      LibC.close(pair[0])
      begin
        # No listeners or plain-fd watches: only the timer can wake this wait.
        Rayo::Uring.setup(Pointer(Int32).null, 0, 32_u64, 1) || LibC._exit(1)
        Rayo::Uring.arm_timeout(20, ->LoopTimerFixture.done(UInt64), pair[1].to_u64)
        Rayo::Uring.run
      rescue
        LibC._exit(1)
      end
    end
    LibC.close(pair[1])
    ep = LibC.epoll_create1(0)
    begin
      Rayo::Sys.epoll(ep, Rayo::Sys::EPOLL_CTL_ADD, pair[0], Rayo::Sys::EPOLLIN).should eq(0)
      event = Rayo::Sys::EpollEvent.new
      started = Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC)
      loop do
        result = LibC.epoll_wait(ep, pointerof(event), 1, 1000)
        next if result < 0 && Rayo::Sys.errno == Rayo::Sys::EINTR
        result.should eq(1)
        break
      end
      byte = 0_u8
      LibC.read(pair[0], pointerof(byte), 1).should eq(1)
      byte.should eq(1)
      elapsed = Rayo::Sys.now_ns(Rayo::Sys::CLOCK_MONOTONIC) - started
      elapsed.should be >= 15_000_000
      elapsed.should be < 1_000_000_000
    ensure
      LibC.close(ep)
      LibC.close(pair[0])
      LibC.kill(pid, 15)
      status = 0
      LibC.waitpid(pid, pointerof(status), 0)
    end
  end

  it "keeps a timed-out receive submitted exactly once" do
    pair = uninitialized Int32[2]
    LibC.socketpair(1, 1, 0, pair).should eq(0)
    ring = Rayo::Ring.create(0, 32, 256_u32, 512_u32).not_nil!
    begin
      byte = 0_u8
      sqe = ring.sqe
      sqe.value.opcode = Rayo::Uring::OP_RECV
      sqe.value.fd = pair[0]
      sqe.value.addr = pointerof(byte).address
      sqe.value.len = 1
      ring.enter(1_u32, Rayo::Uring::ENTER_GETEVENTS, 10)
      ring.to_submit.should eq(0)
      ring.ready?.should be_false
      LibC.write(pair[1], pointerof(byte), 1).should eq(1)
      ring.enter(1_u32, Rayo::Uring::ENTER_GETEVENTS, 1000)
      ring.ready?.should be_true
      ring.drain.should eq(1)
      ring.enter(0_u32, Rayo::Uring::ENTER_GETEVENTS)
      ring.ready?.should be_false
    ensure
      ring.dispose
      LibC.close(pair[0])
      LibC.close(pair[1])
    end
  end
end
