require "./spec_helper"

# Drive sockets from another process so each empty CQ must wake a sleeping loop.
describe Rayo::Ring do
  it "wakes epoll repeatedly for socket work on independent rings" do
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
        loop do
          result = LibC.epoll_wait(ep, pointerof(event), 1, 1000)
          next if result < 0 && Rayo::Sys.errno == Rayo::Sys::EINTR
          result.should eq(1)
          break
        end
        event.data.u64.should eq(ring.fd.to_u64)
        ring.enter(0_u32, Rayo::Uring::ENTER_GETEVENTS)
        ring.ready?.should be_true
        ring.drain.should eq(1)
        LibC.epoll_wait(ep, pointerof(event), 1, 0).should eq(0)
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
