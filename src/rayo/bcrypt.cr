require "./app"
require "./sys"
require "./buf"
require "./uring"
require "./bcrypt/lanes"
require "./pg/poll"

@[Link("crypt")]
lib Rayo::Bcrypt::LibCrypt
  fun crypt_rn(phrase : UInt8*, setting : UInt8*, data : Void*, size : Int32) : UInt8*
  fun crypt_gensalt_rn(prefix : UInt8*, count : LibC::ULong, bytes : UInt8*, n : Int32, output : UInt8*, size : Int32) : UInt8*
end

module Rayo::Bcrypt
  alias LibPoll = PG::LibPoll

  struct Result
    getter hash : Bytes
    getter? ok : Bool

    def initialize(@hash, @ok)
    end
  end

  alias Callback = Proc(Result, UInt64, Nil)

  # Only the loop owns the free list. A helper owns each submitted record until
  # its pointer returns through the completion socket (also a memory barrier).
  class Job
    getter password = LibSys.calloc(73, 1).as(UInt8*)
    getter setting = LibSys.calloc(128, 1).as(UInt8*)
    property length = 0
    property verify = false
    property ok = false
    property callback : Callback? = nil
    property context_callback : Proc(Result, Context, Nil)? = nil
    property handle : Context::Deferred? = nil
    property state = 0_u64
    property next_free : Job? = nil
  end

  class Pool
    include Uring::Handler
    getter fd : Int32
    @input : Int32
    @reader : Int32
    @output : Int32
    @threads = [] of LibC::PthreadT
    @jobs = [] of Job
    @free : Job? = nil
    @mutex = LibC::PthreadMutexT.new
    @send_mutex = LibC::PthreadMutexT.new
    @partial = 0_u64
    @received = 0
    @pending = 0
    @closed = false
    @tag = -1

    def initialize(threads = 1, capacity = 128, @cost = 10, @window_ms = 1)
      raise ArgumentError.new("invalid bcrypt settings") unless threads > 0 && 1 <= capacity <= 1024 && 4 <= @cost <= 16 && 0 <= @window_ms <= 400
      p = uninitialized Int32[2]
      s = uninitialized Int32[2]
      raise "bcrypt pipe failed" if LibC.pipe(p) != 0
      raise "bcrypt socketpair failed" if LibC.socketpair(1, 1, 0, s) != 0
      @reader, @input = p[0], p[1]
      @fd, @output = s[0], s[1]
      # Submission must never block the event loop, even at maximum capacity.
      LibC.fcntl(@input, LibC::F_SETFL, LibC::O_NONBLOCK)
      LibC.pthread_mutex_init(pointerof(@mutex), Pointer(LibC::PthreadMutexattrT).null)
      LibC.pthread_mutex_init(pointerof(@send_mutex), Pointer(LibC::PthreadMutexattrT).null)
      capacity.times do
        job = Job.new
        job.next_free = @free
        @free = job
        @jobs << job
      end
      threads.times do
        tid = uninitialized LibC::PthreadT
        fn = ->(arg : Void*) { arg.as(Pool).work; Pointer(Void).null }
        rc = LibC.pthread_create(pointerof(tid), Pointer(LibC::PthreadAttrT).null, fn, self.as(Void*))
        raise "bcrypt thread creation failed" unless rc == 0
        @threads << tid
      end
    end

    def attach : Nil
      raise "bcrypt pool already attached" unless @tag < 0
      @tag = Uring.watch(@fd, self)
    end

    def hash(password : Bytes, state = 0_u64, &callback : Result, UInt64 -> Nil) : Nil
      submit(password, nil, state, callback)
    end

    def verify(password : Bytes, hash : Bytes, state = 0_u64, &callback : Result, UInt64 -> Nil) : Nil
      validate_hash(hash)
      submit(password, hash, state, callback)
    end

    def hash(ctx : Context, password : Bytes, &callback : Result, Context -> Nil) : Nil
      submit_context(ctx, password, nil, callback)
    end

    def verify(ctx : Context, password : Bytes, hash : Bytes, &callback : Result, Context -> Nil) : Nil
      validate_hash(hash)
      submit_context(ctx, password, hash, callback)
    end

    private def validate_hash(hash : Bytes) : Nil
      raise ArgumentError.new("invalid bcrypt hash") unless hash.size == 60 && hash[0] == 36 && hash[1] == 50 && {97_u8, 98_u8, 121_u8}.includes?(hash[2]) && hash[3] == 36 && hash[6] == 36 && hash[4] >= 48 && hash[4] <= 57 && hash[5] >= 48 && hash[5] <= 57 && 4 <= (hash[4] - 48) * 10 + hash[5] - 48 <= 16 && hash[7..].all? { |c| Lanes::ALPHABET.to_slice.includes?(c) }
    end

    private def submit_context(ctx : Context, password : Bytes, hash : Bytes?, callback : Proc(Result, Context, Nil)) : Nil
      raise ArgumentError.new("bcrypt callback must not capture; use ctx") if callback.closure?
      job = submit(password, hash, 0_u64, ->Pool.complete_context(Result, UInt64))
      job.state = job.as(Void*).address
      job.context_callback = callback
      job.handle = ctx.defer
      ctx.work_pending &+= 1
    end

    def self.complete_context(result : Result, state : UInt64) : Nil
      job = Pointer(Void).new(state).as(Job)
      handle = job.handle.not_nil!
      ctx = handle.context
      begin
        job.context_callback.not_nil!.call(result, ctx) if ctx
      rescue
        ctx.try &.db_failed=(true)
      ensure
        job.handle = nil
        job.context_callback = nil
        if ctx
          ctx.work_pending &-= 1
          if ctx.work_pending == 0 && ctx.db_pending == 0
            ctx.database_error if ctx.db_failed
            handle.finish
          end
        end
      end
    end

    private def submit(password : Bytes, hash : Bytes?, state : UInt64, callback : Callback) : Job
      raise ArgumentError.new("bcrypt callback must not capture; use state") if callback.closure?
      raise ArgumentError.new("bcrypt password must be at most 72 bytes without NUL") if password.size > 72 || password.includes?(0_u8)
      raise "bcrypt pool closed" if @closed
      job = @free || raise "bcrypt queue full"
      @free = job.next_free
      job.length = password.size
      job.password.copy_from(password.to_unsafe, password.size)
      job.password[password.size] = 0
      job.setting.clear(128)
      job.setting.copy_from(hash.to_unsafe, hash.size) if hash
      job.verify = !hash.nil?
      job.ok = false
      job.callback = callback
      job.state = state
      address = job.as(Void*).address
      if LibC.write(@input, pointerof(address), 8) != 8
        job.next_free = @free
        @free = job
        raise "bcrypt submission failed"
      end
      @pending &+= 1
      job
    end

    # Raw helper threads never allocate managed objects or call application code.
    protected def work : Nil
      data = LibSys.calloc(32768, 1)
      salt = uninitialized UInt8[64]
      addresses = uninitialized UInt64[6]
      passwords = uninitialized Pointer(UInt8)[6]
      settings = uninitialized Pointer(UInt8)[6]
      lengths = uninitialized Int32[6]
      hashes = uninitialized UInt8[366]
      e1 = Lanes::Engine(1).new
      e2 = Lanes::Engine(2).new
      e3 = Lanes::Engine(3).new
      e4 = Lanes::Engine(4).new
      e5 = Lanes::Engine(5).new
      e6 = Lanes::Engine(6).new
      loop do
        LibC.pthread_mutex_lock(pointerof(@mutex))
        n = 0
        loop do
          if n > 0
            event = LibPoll::Event.new(fd: @reader, events: 1_i16, revents: 0_i16)
            break if LibPoll.poll(pointerof(event), 1, @window_ms) <= 0
          end
          rc = LibC.read(@reader, addresses.to_unsafe + n, 8)
          next if rc < 0 && Sys.errno == Sys::EINTR
          break if rc != 8
          n &+= 1
          break if n == 6
        end
        LibC.pthread_mutex_unlock(pointerof(@mutex))
        break if n == 0
        fast = 0
        n.times do |i|
          job = Pointer(Void).new(addresses[i]).as(Job)
          unless job.verify
            if LibCrypt.crypt_gensalt_rn("$2b$".to_unsafe, @cost, Pointer(UInt8).null, 0, salt.to_unsafe, 64).null?
              next
            end
            job.setting.copy_from(salt.to_unsafe, 30)
          end
          h = job.setting
          eligible = (h[2] == 98 || h[2] == 97) && h[4] == 49 && h[5] == 48
          # Historical $2a$ high-bit safety rules belong to libcrypt.
          if eligible && h[2] == 97
            job.length.times { |k| eligible = false if job.password[k] >= 128 }
          end
          decoded = uninitialized UInt8[16]
          canonical = uninitialized UInt8[22]
          eligible &&= Lanes.decode(h + 7, decoded.to_unsafe, 16)
          if eligible
            Lanes.encode(decoded.to_unsafe, 16, canonical.to_unsafe)
            22.times { |k| eligible = false if canonical[k] != h[7 + k] }
          end
          if eligible
            passwords[fast] = job.password
            settings[fast] = h
            lengths[fast] = job.length
            fast &+= 1
          else
            result = LibCrypt.crypt_rn(job.password, h, data, 32768)
            unless result.null? || LibC.strlen(result) != 60
              if job.verify
                diff = 0_u8
                60.times { |k| diff |= result[k] ^ h[k] }
                job.ok = diff == 0
              else
                h.copy_from(result, 61)
                job.ok = true
              end
            end
          end
        end
        if fast > 0
          case fast
          when 1 then e1.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          when 2 then e2.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          when 3 then e3.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          when 4 then e4.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          when 5 then e5.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          when 6 then e6.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, hashes.to_unsafe)
          end
          fast.times do |i|
            n.times do |k|
              job = Pointer(Void).new(addresses[k]).as(Job)
              next unless job.setting == settings[i]
              result = hashes.to_unsafe + i * 61
              if job.verify
                diff = 0_u8
                60.times { |b| diff |= result[b] ^ job.setting[b] }
                job.ok = diff == 0
              else
                job.setting.copy_from(result, 61)
                job.ok = true
              end
            end
          end
        end
        # Each batch fits below PIPE_BUF; a mutex prevents partial stream writes
        # from interleaving between helpers on the completion socket.
        LibC.pthread_mutex_lock(pointerof(@send_mutex))
        sent = 0
        while sent < n * 8
          rc = LibC.send(@output, addresses.to_unsafe.as(UInt8*) + sent, n * 8 - sent, 0x4000)
          next if rc < 0 && Sys.errno == Sys::EINTR
          break if rc <= 0
          sent &+= rc.to_i32
        end
        LibC.pthread_mutex_unlock(pointerof(@send_mutex))
      end
      {e1, e2, e3, e4, e5, e6}.each &.free
      LibC.free(data)
    end

    def on_data(ptr : UInt8*, len : Int32) : Nil
      first_error = nil.as(Exception?)
      len.times do |i|
        pointerof(@partial).as(UInt8*)[@received] = ptr[i]
        @received &+= 1
        next unless @received == 8
        @received = 0
        job = Pointer(Void).new(@partial).as(Job)
        @pending &-= 1
        begin
          job.callback.not_nil!.call(Result.new(Bytes.new(job.setting, job.ok ? 60 : 0), job.ok), job.state)
        rescue ex
          first_error ||= ex
        ensure
          job.callback = nil
          job.next_free = @free
          @free = job
        end
      end
      raise first_error if first_error
    end

    def on_sent(result : Int32) : Nil
    end

    def on_closed : Nil
    end

    # Close only after outstanding callbacks, before closing the worker loop.
    def close : Nil
      return if @closed
      raise "bcrypt jobs still pending" unless @pending == 0
      raise "attached bcrypt pools live until worker exit" if @tag >= 0
      @closed = true
      LibC.close(@input)
      @threads.each { |tid| LibC.pthread_join(tid, Pointer(Void*).null) }
      {@reader, @fd, @output}.each { |fd| LibC.close(fd) }
      LibC.pthread_mutex_destroy(pointerof(@mutex))
      LibC.pthread_mutex_destroy(pointerof(@send_mutex))
      @jobs.each do |job|
        LibC.free(job.password)
        LibC.free(job.setting)
      end
    end
  end
end
