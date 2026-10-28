require "./spec_helper"
require "../src/rayo/bcrypt"

describe Rayo::Bcrypt do
  it "matches a cost-10 vector in all six interleaved lanes" do
    engine = Rayo::Bcrypt::Lanes::Engine(6).new
    seed = "$2b$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
    values = StaticArray["password123", "", "a", "a" * 72, "雪", "password"]
    passwords = StaticArray(UInt8*, 6).new { |i| values[i].to_unsafe }
    settings = StaticArray(UInt8*, 6).new(seed.to_unsafe)
    lengths = StaticArray(Int32, 6).new { |i| values[i].bytesize }
    output = uninitialized UInt8[366]
    begin
      engine.hash(passwords.to_unsafe, lengths.to_unsafe, settings.to_unsafe, output.to_unsafe)
      data = Bytes.new(32768)
      6.times do |i|
        theirs = Rayo::Bcrypt::LibCrypt.crypt_rn(passwords[i], seed.to_unsafe, data.to_unsafe, data.size)
        Bytes.new(output.to_unsafe + i * 61, 60).should eq(Bytes.new(theirs, 60))
      end
      Bytes.new(output.to_unsafe, 60).should eq(seed.to_slice)
    ensure
      engine.free
    end
  end

  it "runs bounded jobs in helpers and dispatches non-capturing callbacks" do
    pool = Rayo::Bcrypt::Pool.new(threads: 2, capacity: 4, cost: 4, window_ms: 0)
    done = 0_u64
    hash = Bytes.new(60)
    begin
      pool.hash("hello".to_slice, state: hash.to_unsafe.address) do |res, state|
        res.ok?.should be_true
        Pointer(UInt8).new(state).copy_from(res.hash.to_unsafe, 60)
      end
      bytes = uninitialized UInt8[32]
      n = LibC.read(pool.fd, bytes.to_unsafe, 32).to_i32
      n.should eq(8)
      # Exercise the same fragmented stream decoder as io_uring.
      n.times { |i| pool.on_data(bytes.to_unsafe + i, 1) }
      pool.verify("hello".to_slice, hash, state: pointerof(done).address) do |res, state|
        res.ok?.should be_true
        Pointer(UInt64).new(state).value &+= 1
      end
      pool.verify("wrong".to_slice, hash, state: pointerof(done).address) do |res, state|
        res.ok?.should be_false
        Pointer(UInt64).new(state).value &+= 1
      end
      while done < 2
        n = LibC.read(pool.fd, bytes.to_unsafe, 32).to_i32
        n.should be > 0
        pool.on_data(bytes.to_unsafe, n)
      end
      4.times do
        pool.hash("hello".to_slice, state: pointerof(done).address) do |res, state|
          Pointer(UInt64).new(state).value &+= res.ok? ? 1_u64 : 1000_u64
        end
      end
      expect_raises(Exception, "queue full") { pool.hash("hello".to_slice) { |_, _| } }
      while done < 6
        n = LibC.read(pool.fd, bytes.to_unsafe, 32).to_i32
        pool.on_data(bytes.to_unsafe, n)
      end
      # Blocking reads let SYSMON allocate in the default runtime: keep the
      # quietest of several windows, as the coalescer spec does.
      minimum = UInt64::MAX
      4.times do
        GC.stats
        before = GC.stats.total_bytes
        8.times do
          pool.hash("hello".to_slice, state: pointerof(done).address) do |res, state|
            Pointer(UInt64).new(state).value &+= res.ok? ? 1_u64 : 1000_u64
          end
          n = LibC.read(pool.fd, bytes.to_unsafe, 32).to_i32
          pool.on_data(bytes.to_unsafe, n)
        end
        minimum = Math.min(minimum, GC.stats.total_bytes - before)
      end
      assert_no_request_allocations(minimum)
      done.should eq(38)
      expect_raises(ArgumentError, "72 bytes") { pool.hash(Bytes.new(73)) { |_, _| } }
      expect_raises(ArgumentError, "invalid bcrypt hash") { pool.verify("hi".to_slice, "bad".to_slice) { |_, _| } }
      value = [] of Bool
      expect_raises(ArgumentError, "capture") { pool.hash("hi".to_slice) { |res, _| value << res.ok? } }
    ensure
      pool.close
    end
  end
end
