require "./sys"
require "c/sys/mman"
require "c/sys/eventfd"

module Rayo
  lib LibUring
    struct Sqe
      opcode : UInt8
      flags : UInt8
      ioprio : UInt16
      fd : Int32
      off : UInt64
      addr : UInt64
      len : UInt32
      op_flags : UInt32
      user_data : UInt64
      buf_group : UInt16
      personality : UInt16
      file_index : Int32
      addr3 : UInt64
      pad : UInt64
    end

    struct Cqe
      user_data : UInt64
      res : Int32
      flags : UInt32
    end

    struct SqOff
      head : UInt32
      tail : UInt32
      ring_mask : UInt32
      ring_entries : UInt32
      flags : UInt32
      dropped : UInt32
      array : UInt32
      resv1 : UInt32
      user_addr : UInt64
    end

    struct CqOff
      head : UInt32
      tail : UInt32
      ring_mask : UInt32
      ring_entries : UInt32
      overflow : UInt32
      cqes : UInt32
      flags : UInt32
      resv1 : UInt32
      user_addr : UInt64
    end

    struct Params
      sq_entries : UInt32
      cq_entries : UInt32
      flags : UInt32
      sq_thread_cpu : UInt32
      sq_thread_idle : UInt32
      features : UInt32
      wq_fd : UInt32
      resv : UInt32[3]
      sq_off : SqOff
      cq_off : CqOff
    end

    # io_uring_getevents_arg and __kernel_timespec have fixed-width fields.
    struct GeteventsArg
      sigmask : UInt64
      sigmask_sz : UInt32
      pad : UInt32
      ts : UInt64
    end

    struct KernelTimespec
      sec : Int64
      nsec : Int64
    end

    struct RsrcReg
      nr : UInt32
      flags : UInt32
      resv2 : UInt64
      data : UInt64
      tags : UInt64
    end

    struct FilesUpdate
      offset : UInt32
      reserved : UInt32
      fds : UInt64
    end

    struct BufReg
      ring_addr : UInt64
      ring_entries : UInt32
      bgid : UInt16
      flags : UInt16
      resv : UInt64[3]
    end
  end

  class Ring
    getter fd : Int32
    getter base : Int32 # connection id of slot 0
    getter slots : Int32
    property to_submit = 0_u32
    property accepting = 0 # multishot accepts armed here (one per listener)
    property used = 0      # slots taken: accepted and not yet closed by the kernel

    @efd = -1
    @ring_mem : UInt8*
    @ring_size : UInt64
    @free_slots : Int32*
    @free_head = 0
    @sqes : LibUring::Sqe*
    @sq_head : UInt32*
    @sq_tail : UInt32*
    @sq_mask : UInt32
    @sq_entries : UInt32
    @stail : UInt32
    @cq_head : UInt32*
    @cq_tail : UInt32*
    @cq_mask : UInt32
    @cqes : LibUring::Cqe*
    @bring : UInt8*
    @bufs : UInt8*
    @btail : UInt16 = 0
    @legacy = false                         # buffers given back with PROVIDE_BUFFERS: the kernel refused a buffer ring
    @retry : UInt64* = Pointer(UInt64).null # receives that ran out of buffers: (gen << 32) | id
    @nretry = 0
    @retry_cap = 0

    # Returns nil when the kernel refuses (no io_uring, or older than 6.1).
    def self.create(base : Int32, slots : Int32, sq : UInt32, cq : UInt32) : Ring?
      pa = LibUring::Params.new
      pa.cq_entries = cq
      pa.flags = Uring::SETUP_CQSIZE | Uring::SETUP_SUBMIT_ALL | Uring::SETUP_SINGLE_ISSUER | Uring::SETUP_DEFER_TASKRUN
      fd = LibC.syscall(Uring::SYS_SETUP, sq, pointerof(pa)).to_i32
      return nil if fd < 0
      r = new(fd, base, slots, pointerof(pa))
      return r if r.init
      r.dispose
      nil
    end

    def initialize(@fd : Int32, @base : Int32, @slots : Int32, pa : LibUring::Params*)
      @free_slots = LibC.malloc(@slots.to_u64 * 4).as(Int32*)
      @slots.times { |i| @free_slots[i] = i + 1 }
      so = pa.value.sq_off
      co = pa.value.cq_off
      @sq_entries = pa.value.sq_entries
      sz = {so.array.to_u64 + @sq_entries.to_u64 * 4, co.cqes.to_u64 + pa.value.cq_entries.to_u64 * 16}.max
      rw = LibC::PROT_READ | LibC::PROT_WRITE
      sh = LibC::MAP_SHARED | LibC::MAP_POPULATE
      m = Pointer(UInt8).null
      m = LibC.mmap(Pointer(Void).null, sz, rw, sh, @fd, 0).as(UInt8*) if pa.value.features & Uring::FEAT_SINGLE_MMAP != 0
      m = Pointer(UInt8).null if m.address == ~0_u64
      sq = Pointer(Void).null
      sq = LibC.mmap(Pointer(Void).null, @sq_entries.to_u64 * 64, rw, sh, @fd, Uring::OFF_SQES) unless m.null?
      sq = Pointer(Void).null if sq.address == ~0_u64
      @ring_mem = m
      @ring_size = sz
      if m.null? || sq.null?
        @sqes = Pointer(LibUring::Sqe).null
      else
        @sqes = sq.as(LibUring::Sqe*)
      end
      @sq_head = (m + so.head).as(UInt32*)
      @sq_tail = (m + so.tail).as(UInt32*)
      @sq_mask = @sqes.null? ? 0_u32 : (m + so.ring_mask).as(UInt32*).value
      @stail = @sqes.null? ? 0_u32 : @sq_tail.value
      unless @sqes.null?
        array = (m + so.array).as(UInt32*)
        @sq_entries.times { |i| array[i] = i.to_u32 } # identity: slot i holds sqe i
      end
      @cq_head = (m + co.head).as(UInt32*)
      @cq_tail = (m + co.tail).as(UInt32*)
      @cq_mask = @sqes.null? ? 0_u32 : (m + co.ring_mask).as(UInt32*).value
      @cqes = (m + co.cqes).as(LibUring::Cqe*)
      @bring = Pointer(UInt8).null
      @bufs = Pointer(UInt8).null
    end

    # Fixed-file table, provided-buffer ring, first accept.
    def init : Bool
      return false if @sqes.null?
      rr = LibUring::RsrcReg.new
      rr.nr = @slots.to_u32
      rr.flags = 1 # IORING_RSRC_REGISTER_SPARSE
      return false if LibC.syscall(Uring::SYS_REGISTER, @fd, Uring::REGISTER_FILES2, pointerof(rr), sizeof(LibUring::RsrcReg)) < 0
      @bring = LibC.mmap(Pointer(Void).null, (Uring::NBUF * 16).to_u64, LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, 0).as(UInt8*)
      if @bring.address == ~0_u64
        @bring = Pointer(UInt8).null
        return false
      end
      @bufs = LibC.malloc(Uring::NBUF * Uring::BUF_SIZE).as(UInt8*)
      reg = LibUring::BufReg.new
      reg.ring_addr = @bring.address
      reg.ring_entries = Uring::NBUF.to_u32
      if Uring.classic_buffers? || LibC.syscall(Uring::SYS_REGISTER, @fd, Uring::REGISTER_PBUF_RING, pointerof(reg), 1) < 0
        # Some distribution kernels reject every buffer ring registration (Ubuntu 24.04's
        # 6.8.0-136 and later return EINVAL). Classic provided buffers feed the same
        # multishot receives through the same buffer group.
        LibC.munmap(@bring, (Uring::NBUF * 16).to_u64)
        @bring = Pointer(UInt8).null
        @legacy = true
        provide(0_u16, Uring::NBUF)
      else
        Uring::NBUF.times { |i| give_buf(i.to_u16) }
        publish_bufs
      end
      true
    end

    def dispose : Nil
      LibC.close(@fd)
      LibC.close(@efd) if @efd >= 0
      LibC.munmap(@ring_mem, @ring_size) unless @ring_mem.null?
      LibC.munmap(@sqes, @sq_entries.to_u64 * 64) unless @sqes.null?
      LibC.munmap(@bring, (Uring::NBUF * 16).to_u64) unless @bring.null?
      LibC.free(@bufs)
      LibC.free(@free_slots)
      LibC.free(@retry)
    end

    def install(fd : Int32) : Int32
      return -1 if @free_head == @slots
      slot = @free_head
      update = LibUring::FilesUpdate.new
      update.offset = slot.to_u32
      update.fds = pointerof(fd).address
      result = LibC.syscall(Uring::SYS_REGISTER, @fd, 6, pointerof(update), 1)
      raise "fixed-file registration failed" unless result == 1
      @free_head = @free_slots[slot]
      @used += 1
      slot
    end

    def release_slot(slot : Int32) : Nil
      @free_slots[slot] = @free_head
      @free_head = slot
      @used -= 1
    end

    @[AlwaysInline]
    def load_acq(p : UInt32*) : UInt32
      Atomic::Ops.load(p, :acquire, true)
    end

    @[AlwaysInline]
    def store_rel(p : T*, v : T) : Nil forall T
      Atomic::Ops.store(p, v, :release, true)
    end

    # Next free SQE, zeroed. A full queue is submitted first.
    def sqe : LibUring::Sqe*
      while @stail &- load_acq(@sq_head) >= @sq_entries
        enter(0_u32, 0_u32)
      end
      e = @sqes + (@stail & @sq_mask)
      Intrinsics.memset(e.as(Void*), 0_u8, 64_u64, false)
      @stail &+= 1
      @to_submit &+= 1
      e
    end

    def enter(min : UInt32, flags : UInt32, wait : Int32 = -1) : Nil
      publish_bufs # buffers returned so far must be visible to what gets submitted now
      store_rel(@sq_tail, @stail)
      n = @to_submit
      ts = LibUring::KernelTimespec.new
      arg = LibUring::GeteventsArg.new
      if wait >= 0
        ts.sec = wait.to_i64 // 1000
        ts.nsec = (wait.to_i64 % 1000) * 1_000_000
        arg.ts = pointerof(ts).address
        # argsz is size_t: pass all 64 bits through the variadic syscall binding.
        submitted = LibC.syscall(Uring::SYS_ENTER, @fd, n, min, flags | Uring::ENTER_EXT_ARG, pointerof(arg), sizeof(LibUring::GeteventsArg).to_u64)
      else
        submitted = LibC.syscall(Uring::SYS_ENTER, @fd, n, min, flags, Pointer(Void).null, 0)
      end
      # EINTR/ETIME may follow submission; the SQ head tells what is still queued.
      @to_submit = @stail &- load_acq(@sq_head)
      if submitted < 0
        error = Sys.errno
        raise "io_uring_enter failed (errno #{error})" unless error == Sys::EINTR || (wait >= 0 && error == Uring::ETIME)
      end
    end

    @[AlwaysInline]
    def buf(bid : UInt16) : UInt8*
      @bufs + bid.to_i32 &* Uring::BUF_SIZE
    end

    @[AlwaysInline]
    def give_buf(bid : UInt16) : Nil
      return provide(bid, 1) if @legacy
      e = @bring + ((@btail & (Uring::NBUF &- 1)).to_i32 &* 16)
      e.as(UInt64*).value = buf(bid).address
      (e + 8).as(UInt32*).value = Uring::BUF_SIZE.to_u32
      (e + 12).as(UInt16*).value = bid # bytes 14..15 of entry 0 are the ring tail: untouched
      @btail &+= 1
    end

    # Register lazily: the common single-ring path waits in enter, without epoll.
    def watch(ep : Int32) : Nil
      return if @efd >= 0
      @efd = LibC.eventfd(0, 0o4000 | 0o2000000) # EFD_NONBLOCK | EFD_CLOEXEC
      raise "eventfd failed" if @efd < 0
      raise "eventfd registration failed" if LibC.syscall(Uring::SYS_REGISTER, @fd, Uring::REGISTER_EVENTFD, pointerof(@efd), 1) < 0
      raise "epoll registration failed" if Sys.epoll(ep, Sys::EPOLL_CTL_ADD, @efd, Sys::EPOLLIN | Sys::EPOLLET) < 0
    end

    # One PROVIDE_BUFFERS request for `count` consecutive buffers from `bid`. It completes
    # inline at submit, before any receive queued after it, and posts no completion.
    @[NoInline]
    def provide(bid : UInt16, count : Int32) : Nil
      e = sqe
      e.value.opcode = Uring::OP_PROVIDE_BUFFERS
      e.value.flags = Uring::SQE_CQE_SKIP_SUCCESS
      e.value.fd = count
      e.value.addr = buf(bid).address
      e.value.len = Uring::BUF_SIZE.to_u32
      e.value.off = bid.to_u64
    end

    def publish_bufs : Nil
      return if @legacy
      store_rel((@bring + 14).as(UInt16*), @btail)
    end

    def defer_recv(id : Int32) : Nil
      if @nretry == @retry_cap
        @retry_cap = @retry_cap == 0 ? 1024 : @retry_cap &* 2
        @retry = LibC.realloc(@retry, @retry_cap &* 8).as(UInt64*)
      end
      @retry[@nretry] = (Server.conn(id).gen.to_u64 << 32) | id.to_u32
      @nretry &+= 1
    end

    # Rearms the receives that hit ENOBUFS, now that this batch's buffers are back. Ones that
    # find none again just come back next batch: never a resubmit loop inside one batch.
    def retry_recvs : Nil
      n = @nretry
      @nretry = 0
      n.times do |i|
        v = @retry[i]
        id = v.to_i32!
        c = Server.conn(id)
        Uring.arm_recv(self, id) if c.open && c.gen == (v >> 32).to_u16!
      end
    end

    def ready? : Bool
      @cq_head.value != load_acq(@cq_tail)
    end

    # Runs every completion that is ready. Returns how many.
    def drain : Int32
      head = @cq_head.value
      tail = load_acq(@cq_tail)
      n = 0
      while head != tail
        while head != tail
          Uring.complete(self, @cqes[head & @cq_mask])
          head &+= 1
          n &+= 1
        end
        store_rel(@cq_head, head)
        tail = load_acq(@cq_tail)
      end
      publish_bufs if n > 0
      n
    end
  end

  module Uring
    SYS_SETUP    = 425
    SYS_ENTER    = 426
    SYS_REGISTER = 427

    SETUP_CQSIZE         = 1_u32 << 3
    SETUP_SUBMIT_ALL     = 1_u32 << 7
    SETUP_SINGLE_ISSUER  = 1_u32 << 12
    SETUP_DEFER_TASKRUN  = 1_u32 << 13
    FEAT_SINGLE_MMAP     = 1_u32 << 0
    ENTER_GETEVENTS      = 1_u32
    ENTER_EXT_ARG        = 1_u32 << 3
    REGISTER_EVENTFD     =              4
    REGISTER_FILES2      =             13
    REGISTER_PBUF_RING   =             22
    OFF_SQES             = 0x10000000_i64
    OP_ACCEPT            =          13_u8
    OP_CLOSE             =          19_u8
    OP_SEND              =          26_u8
    OP_RECV              =          27_u8
    OP_SHUTDOWN          =          34_u8
    OP_PROVIDE_BUFFERS   =          31_u8
    SQE_FIXED_FILE       =           1_u8
    SQE_BUFFER_SELECT    = 1_u8 << 5
    SQE_CQE_SKIP_SUCCESS = 1_u8 << 6
    ACCEPT_MULTISHOT     = 1_u16
    RECV_MULTISHOT       = 2_u16
    CQE_F_BUFFER         = 1_u32
    CQE_F_MORE           = 2_u32
    ENOBUFS              =   105
    ETIME                =    62

    SQ_ENTRIES =  4096_u32 # largest ring; halved together while it doesn't fit the memlock budget
    CQ_ENTRIES = 32768_u32
    NBUF       =      4096 # provided receive buffers per ring (power of two)
    BUF_SIZE   =      2048
    MAX_RINGS  =         8
    TARGET     =    524288 # connections to make room for

    # RAYO_CLASSIC_BUFFERS=1 forces the fallback, so it can be tested on any kernel.
    class_getter? classic_buffers : Bool = ENV["RAYO_CLASSIC_BUFFERS"]? == "1"

    TAG_ACCEPT     = 1_u64
    TAG_RECV       = 2_u64
    TAG_SEND       = 3_u64
    TAG_CLOSE      = 4_u64
    TAG_SHUTDOWN   = 5_u64
    TAG_PLAIN_RECV = 6_u64
    TAG_PLAIN_SEND = 7_u64

    # Drivers flush once after the previous turn's completions have all dispatched.
    module Flusher
      abstract def flush : Nil
    end

    @@flushers = [] of Flusher

    def self.add_flusher(owner : Flusher) : Nil
      @@flushers << owner
    end

    module Handler
      abstract def on_data(ptr : UInt8*, len : Int32) : Nil
      abstract def on_sent(result : Int32) : Nil
      abstract def on_closed : Nil
    end

    class Watch
      property fd = -1
      property owner : Handler? = nil
      property receiving = false
      property closing = false
      property sends = 0
    end

    struct Timer
      property deadline = 0_i64
      property callback : Proc(UInt64, Nil)? = nil
      property tag = 0_u64
      property generation = 0_u32
    end

    @@rings = Pointer(Ring).null
    @@nrings = 0
    @@slots = 0
    @@sq = 0_u32
    @@cq = 0_u32
    @@lfds = Pointer(Int32).null
    @@nlfd = 0
    @@ep = -1
    @@watches = Array(Watch).new(1024) { Watch.new }
    @@timers = Pointer(Timer).null
    @@next_deadline = Int64::MAX
    MAX_TIMERS = 4096

    def self.setup(lfds : Int32*, nlfd : Int32, nofile : UInt64, share : Int32) : Bool
      @@lfds = lfds
      @@nlfd = nlfd
      slots = {nofile, TARGET.to_u64}.min.to_i32
      if t = Sys.env("URING_SLOTS") # testing the ring spill-over with few connections
        slots = {slots, t.to_i}.min
      end
      raise ArgumentError.new("ring slots and worker share must be positive") if slots < 1 || share < 1
      raise "io_uring is already initialized" if @@nrings > 0
      want = {(TARGET &+ slots &- 1) // slots, MAX_RINGS}.min
      # Since Linux 6.13 ring memory counts against RLIMIT_MEMLOCK (8 MB by default, per user, so
      # shared by all `share` worker processes). Size and count the rings to fit this worker's part.
      budget = Sys.memlock_budget // share
      sq = SQ_ENTRIES
      cq = CQ_ENTRIES
      while sq > 256 && ring_cost(sq, cq) > budget
        sq >>= 1
        cq >>= 1
      end
      want = (budget // ring_cost(sq, cq)).clamp(1_u64, want.to_u64).to_i32
      # Ring is a managed class: native malloc would hide its only roots from GC.
      @@rings = Pointer(Ring).malloc(want)
      @@slots = slots
      @@sq = sq
      @@cq = cq
      want.times do |i|
        r = Ring.create(i &* slots, slots, sq, cq)
        break unless r
        @@rings[i] = r
        @@nrings &+= 1
      end
      return false if @@nrings == 0
      @@ep = LibC.epoll_create1(0)
      raise "epoll_create failed" if @@ep < 0
      arm_accept(@@rings[0])
      @@timers = LibSys.calloc(MAX_TIMERS, sizeof(Timer)).as(Timer*)
      true
    end

    def self.capacity : Int32
      @@nrings * @@slots
    end

    def self.describe : String
      "#{@@nrings} ring(s) x #{@@slots} fixed slots, #{@@sq}/#{@@cq} sq/cq entries"
    end

    # Bytes a ring pins: SQ array and CQEs, SQEs, provided-buffer ring.
    private def self.ring_cost(sq : UInt32, cq : UInt32) : UInt64
      sq.to_u64 * 4 + cq.to_u64 * 16 + sq.to_u64 * 64 + NBUF.to_u64 * 16 + 3 * 4096
    end

    @[AlwaysInline]
    def self.ring_of(id : Int32) : Ring
      @@rings[id // @@slots]
    end

    @[AlwaysInline]
    private def self.tag(op : UInt64, id : Int32) : UInt64
      op | (Server.conn(id).gen.to_u64 << 16) | (id.to_u64 << 32)
    end

    private def self.arm_accept(r : Ring) : Nil
      @@nlfd.times { |li| arm_accept(r, li) }
    end

    private def self.arm_accept(r : Ring, li : Int32) : Nil
      r.accepting &+= 1
      e = r.sqe
      e.value.opcode = OP_ACCEPT
      e.value.fd = @@lfds[li]
      e.value.ioprio = ACCEPT_MULTISHOT
      e.value.user_data = TAG_ACCEPT | (li.to_u64 << 8)
    end

    def self.arm_recv(r : Ring, id : Int32) : Nil
      e = r.sqe
      e.value.opcode = OP_RECV
      e.value.fd = id &- r.base
      e.value.flags = SQE_FIXED_FILE | SQE_BUFFER_SELECT
      e.value.ioprio = RECV_MULTISHOT
      e.value.user_data = tag(TAG_RECV, id)
    end

    # Plain fds share ring zero's provided buffers; their owners handle partial sends.
    # The caller keeps send memory valid until on_sent and relinquishes fd ownership.
    def self.watch(fd : Int32, owner : Handler) : Int32
      raise ArgumentError.new("fd is already watched") if @@watches.any? { |w| w.owner && w.fd == fd }
      @@watches.each_with_index do |w, i|
        next if w.owner
        w.fd = fd
        w.owner = owner
        w.closing = false
        plain_recv(i)
        return i
      end
      raise "plain fd watch table is full"
    end

    private def self.plain_recv(i : Int32) : Nil
      w = @@watches[i]
      w.receiving = true
      e = @@rings[0].sqe
      e.value.opcode = OP_RECV
      e.value.fd = w.fd
      e.value.flags = SQE_BUFFER_SELECT
      e.value.ioprio = RECV_MULTISHOT
      e.value.user_data = TAG_PLAIN_RECV | (i.to_u64 << 32)
    end

    def self.send_plain(fd : Int32, p : UInt8*, n : Int32, tag : Int32) : Nil
      w = @@watches[tag]
      raise "inactive plain fd" unless w.fd == fd && w.owner && !w.closing
      w.sends += 1
      e = @@rings[0].sqe
      e.value.opcode = OP_SEND
      e.value.fd = fd
      e.value.addr = p.address
      e.value.len = n.to_u32
      e.value.op_flags = Sys::MSG_NOSIGNAL.to_u32
      e.value.user_data = TAG_PLAIN_SEND | (tag.to_u64 << 32)
    end

    def self.unwatch(tag : Int32) : Nil
      w = @@watches[tag]
      return unless w.owner
      w.closing = true
      LibC.shutdown(w.fd, 2)
      release_watch(w)
    end

    private def self.release_watch(w : Watch) : Nil
      if w.closing && !w.receiving && w.sends == 0
        owner = w.owner
        LibC.close(w.fd)
        w.fd = -1
        w.owner = nil
        w.closing = false
        owner.try &.on_closed
      end
    end

    # Preallocated one-shot callbacks, carrying caller-owned integer state. Callbacks
    # must be non-capturing; cancel_timeout accepts the returned generation token.
    def self.arm_timeout(milliseconds : Int32, callback : Proc(UInt64, Nil), tag = 0_u64) : UInt64
      raise ArgumentError.new("negative timeout") if milliseconds < 0
      raise ArgumentError.new("timer callback must be non-capturing") if callback.closure?
      MAX_TIMERS.times do |i|
        t = @@timers + i
        next if t.value.callback
        t.value.generation &+= 1
        t.value.deadline = Sys.now_ns(Sys::CLOCK_MONOTONIC) + milliseconds.to_i64 * 1_000_000
        @@next_deadline = {t.value.deadline, @@next_deadline}.min
        t.value.callback = callback
        t.value.tag = tag
        return (t.value.generation.to_u64 << 32) | i.to_u64
      end
      raise "timer table is full"
    end

    def self.cancel_timeout(token : UInt64) : Bool
      i = token.to_u32!
      return false if i >= MAX_TIMERS
      t = @@timers + i
      return false unless t.value.generation == (token >> 32).to_u32! && t.value.callback
      t.value.callback = nil
      true
    end

    private def self.timer_wait(now : Int64) : Int32
      return -1 if @@next_deadline == Int64::MAX
      ((@@next_deadline - now + 999_999) // 1_000_000).clamp(0_i64, Int32::MAX.to_i64).to_i32
    end

    private def self.timers : Int32
      now = Sys.now_ns(Sys::CLOCK_MONOTONIC)
      return timer_wait(now) if @@next_deadline > now
      @@next_deadline = Int64::MAX
      MAX_TIMERS.times do |i|
        t = @@timers + i
        if callback = t.value.callback
          if t.value.deadline <= now
            tag = t.value.tag
            t.value.callback = nil
            callback.call(tag)
          else
            @@next_deadline = {t.value.deadline, @@next_deadline}.min
          end
        end
      end
      # Callbacks may have queued sends. Submit before waiting for the next deadline.
      0
    end

    def self.send(id : Int32, p : UInt8*, n : Int32) : Nil
      r = ring_of(id)
      e = r.sqe
      e.value.opcode = OP_SEND
      e.value.fd = id - r.base
      e.value.flags = SQE_FIXED_FILE
      e.value.addr = p.address
      e.value.len = n.to_u32
      e.value.op_flags = Sys::MSG_NOSIGNAL.to_u32
      e.value.user_data = tag(TAG_SEND, id)
    end

    def self.run : NoReturn
      evs = LibC.malloc(MAX_RINGS * sizeof(Sys::EpollEvent)).as(Sys::EpollEvent*)
      r0 = @@rings[0]
      loop do
        @@flushers.each &.flush
        wait = timers
        if multi?
          ready = false
          @@nrings.times do |i|
            r = @@rings[i]
            r.watch(@@ep)
            r.enter(0_u32, ENTER_GETEVENTS)
            ready = true if r.ready?
          end
          unless ready
            # On Linux 6.12/6.18 a DEFER_TASKRUN ring's eventfd can stop signalling
            # (the deferred signal stays marked pending). Bound epoll to 1 ms so
            # lost wakeups cannot strand work. The single-ring enter is unaffected.
            LibC.epoll_wait(@@ep, evs, MAX_RINGS, wait == 0 ? 0 : 1)
            @@nrings.times { |i| @@rings[i].enter(0_u32, ENTER_GETEVENTS) }
          end
        else
          # Plain-fd watches and sends always use ring zero, as do accepts.
          # EXT_ARG bounds the wait by the next timer without allocating an SQE.
          r0.enter(1_u32, ENTER_GETEVENTS, wait)
        end
        @@nrings.times { |i| @@rings[i].drain }
        @@nrings.times { |i| @@rings[i].retry_recvs }
        @@watches.each_with_index do |w, i|
          plain_recv(i) if w.owner && !w.receiving && !w.closing
        end
      end
    end

    private def self.multi? : Bool
      (1...@@nrings).each do |i|
        r = @@rings[i]
        # used includes closing slots until their close CQE has been drained.
        return true if r.used > 0 || r.accepting > 0 || r.to_submit > 0 || r.ready?
      end
      false
    end

    def self.complete(r : Ring, cq : LibUring::Cqe) : Nil
      ud = cq.user_data
      op = ud & 255
      return if op == 0
      if op == TAG_ACCEPT
        on_accept(r, ((ud >> 8) & 255).to_i32!, cq.res, cq.flags)
        return
      end
      id = (ud >> 32).to_i32!
      if op == TAG_CLOSE
        r.release_slot(id - r.base)
        return
      end
      if op == TAG_PLAIN_RECV || op == TAG_PLAIN_SEND
        w = @@watches[id]
        owner = w.owner
        if op == TAG_PLAIN_SEND
          w.sends -= 1
          owner.try &.on_sent(cq.res)
        else
          w.receiving = false if cq.flags & CQE_F_MORE == 0
          if cq.flags & CQE_F_BUFFER != 0
            bid = (cq.flags >> 16).to_u16!
            owner.try &.on_data(r.buf(bid), cq.res) if cq.res > 0 && !w.closing
            r.give_buf(bid)
          end
          unwatch(id) if cq.res == 0 || (cq.res < 0 && cq.res != -ENOBUFS)
        end
        release_watch(w)
        return
      end
      c = Server.conn(id)
      if op == TAG_SHUTDOWN
        c.shutting_down = false
        release(id) unless c.sending
        return
      end
      live = c.open && c.gen == ((ud >> 16) & 65535).to_u16!
      if op == TAG_RECV
        if cq.flags & CQE_F_BUFFER != 0
          bid = (cq.flags >> 16).to_u16!
          Server.on_data(id, r.buf(bid), cq.res) if live && cq.res > 0 && !c.closing
          r.give_buf(bid)
        end
        return unless live && c.open
        if cq.res == 0
          Server.on_eof(id)
        elsif cq.res < 0 && cq.res != -ENOBUFS
          close(id)
        elsif cq.flags & CQE_F_MORE == 0
          cq.res == -ENOBUFS ? r.defer_recv(id) : arm_recv(r, id)
        end
      elsif op == TAG_SEND
        # A close must leave send memory intact until its completion has arrived.
        Server.on_sent(id, cq.res) if live || c.retired
      end
    end

    # A full direct-accept table consumes and resets one peer before reporting ENFILE.
    # Accept ordinary fds, then install them in the first ring with room. Only connection
    # setup pays this registration syscall; every recv/send still uses a direct descriptor.
    private def self.on_accept(r : Ring, li : Int32, res : Int32, flags : UInt32) : Nil
      if res >= 0
        begin
          @@nrings.times do |i|
            destination = @@rings[i]
            slot = destination.install(res)
            next if slot < 0
            id = destination.base + slot
            Server.conn(id).open = true
            arm_recv(destination, id)
            break
          end
        ensure
          LibC.close(res)
        end
      end
      if flags & CQE_F_MORE == 0
        r.accepting -= 1
        arm_accept(r, li)
      end
    end

    def self.close(id : Int32) : Nil
      c = Server.conn(id)
      return unless c.open
      c.open = false
      c.busy = false
      c.retired = c.sending
      c.shutting_down = true
      r = ring_of(id)
      e = r.sqe
      e.value.opcode = OP_SHUTDOWN
      e.value.fd = id - r.base
      e.value.flags = SQE_FIXED_FILE
      e.value.len = 2
      e.value.user_data = TAG_SHUTDOWN | (id.to_u64 << 32)
      # Shutdown must finish before close, or a multishot recv can retain the socket.
    end

    def self.release(id : Int32) : Nil
      Server.conn(id).reset
      r = ring_of(id)
      e = r.sqe
      e.value.opcode = OP_CLOSE
      e.value.file_index = id - r.base + 1
      e.value.user_data = TAG_CLOSE | (id.to_u64 << 32)
    end
  end
end
