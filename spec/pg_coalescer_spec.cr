require "./pg_spec"
require "../src/rayo/pg/coalescer"

module CoalescerSpec
  MULTI = Rayo::PG::Statement.new("SELECT n,v,s FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v,s,n) ORDER BY n")
  STMT  = Rayo::PG::Statement.new("SELECT n, v FROM unnest($1::int8[]) WITH ORDINALITY r(v,n) WHERE v <> 0 ORDER BY n")
  class_property conn : Rayo::PG::Conn? = nil
  class_property sent = 0
  class_property seen = 0
  class_property held : Rayo::PG::Coalescer::Group(Int64)? = nil
end

describe Rayo::PG::Coalescer do
  it "merges arrays, duplicates and empty partitions against Postgres" do
    db = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    CoalescerSpec.conn = db.conn
    CoalescerSpec.sent = 0
    CoalescerSpec.seen = 0
    c = Rayo::PG::Coalescer(Int64).new(batch_size: 8) do |g|
      CoalescerSpec.sent += 1
      g.query(CoalescerSpec.conn.not_nil!, CoalescerSpec::STMT, g.param(0))
    end
    begin
      {42_i64, 0_i64, 42_i64, -9_i64}.each do |value|
        c.enqueue(value, value) do |res, state|
          res.error?.should be_false
          res.size.should eq(state == 0 ? 0 : 1)
          res.first?.try { |r| r.i64(1).should eq(state) }
          CoalescerSpec.seen += 1
        end
      end
      c.flush.should be_nil
      db.drain
      CoalescerSpec.sent.should eq(1)
      CoalescerSpec.seen.should eq(4)
      c.in_flight.should eq(0)
    ensure
      db.close
      c.close
      CoalescerSpec.conn = nil
    end
  end

  it "copies several array columns before caller buffers are reused" do
    db = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    CoalescerSpec.conn = db.conn
    CoalescerSpec.seen = 0
    c = Rayo::PG::Coalescer(Int64).new(parameters: 2) do |g|
      g.query(CoalescerSpec.conn.not_nil!, CoalescerSpec::MULTI, g.param(0), g.param(1))
    end
    begin
      text = "comma, quote\" slash\\".to_slice.dup
      2.times do |i|
        c.enqueue(i.to_i64, 42_i64, text) do |res, state|
          row = res.first?.not_nil!
          row.i64(1).should eq(42)
          row.str(2).should eq("comma, quote\" slash\\".to_slice)
          CoalescerSpec.seen += 1
        end
      end
      text.fill(0_u8)
      c.flush
      db.drain
      CoalescerSpec.seen.should eq(2)
    ensure
      db.close
      c.close
      CoalescerSpec.conn = nil
    end
  end

  it "adds no idle delay and bounds busy collection by in-flight depth" do
    c = Rayo::PG::Coalescer(Int64).new(parameters: 0, depth: 3, groups: 5, window_us: 1000, max_window_us: 1500) do |g|
      CoalescerSpec.held = g
    end
    begin
      c.enqueue(1_i64)
      c.flush(10_000_000_i64).should be_nil
      first = CoalescerSpec.held.not_nil!
      c.enqueue(2_i64)
      c.flush(10_100_000_i64).should eq(11_000_000_i64)
      c.flush(11_000_000_i64).should be_nil
      second = CoalescerSpec.held.not_nil!
      c.enqueue(3_i64)
      c.flush(11_100_000_i64).should eq(12_500_000_i64)
      first.done
      second.done
      c.flush(11_100_000_i64).should eq(12_500_000_i64)
      c.flush(12_500_000_i64).should be_nil
      CoalescerSpec.held.not_nil!.done
    ensure
      c.close
      CoalescerSpec.held = nil
    end
  end
end

describe "coalescer limits and lifetime" do
  it "bounds queued groups, isolates keys and reuses storage after rejection" do
    c = Rayo::PG::Coalescer(Int64).new(batch_size: 1, groups: 3, depth: 1) do |g|
      CoalescerSpec.held = g
    end
    begin
      5.times do
        expect_raises(ArgumentError) { c.enqueue(0_i64, "bad\0") }
      end
      3.times { |i| c.enqueue(i.to_i64, i.to_i64, key: i) }
      expect_raises(Rayo::PG::DepthError) { c.enqueue(4_i64, 4_i64) }
      expect_raises(Rayo::PG::Error) { c.close }
      3.times do |i|
        c.flush
        g = CoalescerSpec.held.not_nil!
        g.key.should eq(i)
        g[0].should eq(i)
        g.done
      end
      c.queued.should eq(0)
    ensure
      c.close
      CoalescerSpec.held = nil
    end
  end

  it "fans out SQL failures and continues after a throwing callback" do
    db = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    CoalescerSpec.conn = db.conn
    CoalescerSpec.seen = 0
    c = Rayo::PG::Coalescer(Int64).new(parameters: 0) do |g|
      g.query(CoalescerSpec.conn.not_nil!, Rayo::PG::Statement.new("SELECT 1/0"))
    end
    begin
      c.enqueue(1_i64) do |res, state|
        res.sqlstate.should eq("22012".to_slice)
        raise "first callback"
      end
      c.enqueue(2_i64) do |res, state|
        res.sqlstate.should eq("22012".to_slice)
        CoalescerSpec.seen += 1
      end
      c.flush
      expect_raises(Exception, "first callback") { db.drain }
      CoalescerSpec.seen.should eq(1)
      c.in_flight.should eq(0)
    ensure
      db.close
      c.close
      CoalescerSpec.conn = nil
    end
  end

  it "allocates no managed objects while collecting and dispatching warmed groups" do
    c = Rayo::PG::Coalescer(Int64).new(batch_size: 16) do |g|
      g.done
    end
    begin
      10.times do
        16.times { |i| c.enqueue(i.to_i64, i.to_i64) }
        c.flush
      end
      GC.stats
      before = GC.stats.total_bytes
      1000.times do
        16.times { |i| c.enqueue(i.to_i64, i.to_i64) }
        c.flush
      end
      assert_no_request_allocations(GC.stats.total_bytes - before)
    ensure
      c.close
    end
  end
end

module CoalescerSpec
  class_property reentrant : Rayo::PG::Coalescer(Int64)? = nil
  BAD_ORDINAL = Rayo::PG::Statement.new("SELECT 0, unnest($1::int8[])")
end

describe "coalescer fan-out safety" do
  it "broadcasts malformed ordinals and accepts reentrant work without overwriting a group" do
    db = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    CoalescerSpec.conn = db.conn
    CoalescerSpec.seen = 0
    c = Rayo::PG::Coalescer(Int64).new do |g|
      g.query(CoalescerSpec.conn.not_nil!, CoalescerSpec::BAD_ORDINAL, g.param(0))
    end
    CoalescerSpec.reentrant = c
    begin
      c.enqueue(1_i64, 10_i64) do |res, state|
        res.sqlstate.should eq("22000".to_slice)
        CoalescerSpec.reentrant.not_nil!.enqueue(3_i64, 30_i64) do |res, state|
          res.sqlstate.should eq("22000".to_slice)
          CoalescerSpec.seen += 1
        end
      end
      c.enqueue(2_i64, 20_i64) do |res, state|
        state.should eq(2)
        res.sqlstate.should eq("22000".to_slice)
        CoalescerSpec.seen += 1
      end
      c.flush
      db.drain
      c.queued.should eq(1)
      if deadline = c.flush
        c.flush(deadline)
      end
      db.drain
      CoalescerSpec.seen.should eq(2)
    ensure
      db.close
      c.close
      CoalescerSpec.conn = nil
      CoalescerSpec.reentrant = nil
    end
  end

  it "rejects capturing callbacks before reserving a group" do
    c = Rayo::PG::Coalescer(Int64).new { |g| g.done }
    begin
      captured = Random.rand(100)
      expect_raises(ArgumentError) do
        c.enqueue(1_i64, 1_i64) { |res, state| captured.should be >= 0 }
      end
      c.queued.should eq(0)
    ensure
      c.close
    end
  end
end

describe "warmed coalesced queries" do
  it "reuses arrays, protocol buffers and fan-out views without managed allocation" do
    db = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    CoalescerSpec.conn = db.conn
    CoalescerSpec.seen = 0
    c = Rayo::PG::Coalescer(Int64).new(batch_size: 8) do |g|
      g.query(CoalescerSpec.conn.not_nil!, CoalescerSpec::STMT, g.param(0))
    end
    begin
      10.times do
        8.times { |i| c.enqueue(i.to_i64, i.to_i64) { |res, state| CoalescerSpec.seen += res.size } }
        c.flush
        db.drain
      end
      minimum = UInt64::MAX
      total = 0_u64
      10.times do
        GC.stats
        before = GC.stats.total_bytes
        100.times do
          8.times { |i| c.enqueue(i.to_i64, i.to_i64) { |res, state| CoalescerSpec.seen += res.size } }
          c.flush
          db.drain
        end
        allocated = GC.stats.total_bytes - before
        minimum = Math.min(minimum, allocated)
        total += allocated
      end
      # SYSMON allocates independently in the default runtime during long IO
      # measurements. The request runtime checks every measured iteration.
      {% if flag?(:without_mt) %}
        total.should eq(0)
      {% else %}
        assert_no_request_allocations(minimum)
      {% end %}
      CoalescerSpec.seen.should eq(7070)
    ensure
      db.close
      c.close
      CoalescerSpec.conn = nil
    end
  end
end
