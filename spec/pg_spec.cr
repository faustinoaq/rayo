require "./spec_helper"
require "../src/rayo/pg"
require "random/secure"

module PGSpec
  URL    = ENV["RAYO_PG_URL"]? || "postgres://postgres:postgres@127.0.0.1:5432/postgres"
  NAME   = "rayo_pg_spec_#{Random::Secure.hex(8)}"
  DB_URL = begin
    u = URI.parse(URL)
    u.path = "/#{NAME}"
    u.to_s
  end

  def self.execute(c, sql : String) : Nil
    c.query(Rayo::PG::Statement.new(sql)) do |res|
      raise String.new(res.message) if res.error?
    end
    c.drain
  end
end

Spec.before_suite do
  admin = Rayo::PG::BlockingTransport.new(PGSpec::URL)
  begin
    PGSpec.execute(admin, "CREATE DATABASE #{PGSpec::NAME}")
  ensure
    admin.close
  end
end

Spec.after_suite do
  admin = Rayo::PG::BlockingTransport.new(PGSpec::URL)
  begin
    PGSpec.execute(admin, "DROP DATABASE #{PGSpec::NAME}")
  ensure
    admin.close
  end
end

describe Rayo::PG do
  it "authenticates and reads simple results and NULLs" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    begin
      c.query(Rayo::PG::Statement.new("SELECT 42, true, NULL, 'hello'")) do |res|
        res.error?.should be_false
        res.size.should eq(1)
        row = res.first?.not_nil!
        row.i32(0).should eq(42)
        row.bool(1).should be_true
        row.null?(2).should be_true
        row.str(3).should eq("hello".to_slice)
      end
      c.drain
    ensure
      c.close
    end
  end

  it "encodes every scalar type, integer extremes, and text arrays" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    begin
      stmt = Rayo::PG::Statement.new("SELECT $1::int4, $2::int8, $3::bool, $4::text, $5::text, $6::text, $7::int8[], $8::text[]")
      c.query(stmt, Int32::MIN, Int64::MIN, false, nil, "héllo", "bytes".to_slice,
        [Int64::MIN, 0_i64, Int64::MAX], ["a,b", "a\"b", "a\\b", "NULL", "", "雪"]) do |res|
        res.error?.should be_false
        row = res.first?.not_nil!
        row.i32(0).should eq(Int32::MIN)
        row.i64(1).should eq(Int64::MIN)
        row.bool(2).should be_false
        row.null?(3).should be_true
        row.str(4).should eq("héllo".to_slice)
        row.str(5).should eq("bytes".to_slice)
        numbers = [] of Int64?
        row.each_i64(6) { |v| numbers << v }
        numbers.should eq([Int64::MIN, 0_i64, Int64::MAX])
        texts = [] of String?
        row.each_array(7, Bytes.new(64)) { |v| texts << (v ? String.new(v) : nil) }
        texts.should eq(["a,b", "a\"b", "a\\b", "NULL", "", "雪"])
      end
      c.drain
      c.query(Rayo::PG::Statement.new("SELECT '{}'::int8[], ARRAY[NULL, '', 'NULL']::text[]")) do |res|
        row = res.first?.not_nil!
        count = 0
        row.each_i64(0) { count += 1 }
        count.should eq(0)
        values = [] of String?
        row.each_array(1, Bytes.new(16)) { |v| values << (v ? String.new(v) : nil) }
        values.should eq([nil, "", "NULL"])
      end
      c.drain
    ensure
      c.close
    end
  end

  it "recovers from SQL and preparation errors in the middle of a pipeline" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    count = 0_i64
    state = pointerof(count).address.to_i64!
    good = Rayo::PG::Statement.new("SELECT $1::int8")
    bad = Rayo::PG::Statement.new("SELECT 1/0")
    syntax = Rayo::PG::Statement.new("SELEC broken")
    begin
      c.query(good, 1_i64, state: state) do |res, id|
        Pointer(Int64).new(id.to_u64!).value += 1
        res.first?.not_nil!.i64(0).should eq(1)
      end
      c.query(bad, state: state) do |res, id|
        Pointer(Int64).new(id.to_u64!).value += 1
        res.error?.should be_true
        res.sqlstate.should eq("22012".to_slice)
        res.message.empty?.should be_false
      end
      c.query(syntax, state: state) do |res, id|
        Pointer(Int64).new(id.to_u64!).value += 1
        res.sqlstate.should eq("42601".to_slice)
      end
      c.query(good, 4_i64, state: state) do |res, id|
        Pointer(Int64).new(id.to_u64!).value += 1
        res.first?.not_nil!.i64(0).should eq(4)
      end
      c.drain
      count.should eq(4)
      c.query(good, 5_i64) { |res| res.first?.not_nil!.i64(0).should eq(5) }
      c.drain
    ensure
      c.close
    end
  end

  it "pipelines 10k queries in order with reusable callbacks and state" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    stmt = Rayo::PG::Statement.new("SELECT $1::int8")
    count = 0_i64
    begin
      10_000.times do |i|
        c.query(stmt, i.to_i64, state: pointerof(count).address.to_i64!) do |res, id|
          p = Pointer(Int64).new(id.to_u64!)
          res.error?.should be_false
          res.first?.not_nil!.i64(0).should eq(p.value)
          p.value &+= 1
        end
      end
      c.pending.should eq(10_000)
      c.drain
      count.should eq(10_000)
      c.pending.should eq(0)
    ensure
      c.close
    end
  end

  it "reads fragmented large rows, iterates rows, and ignores notices" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    begin
      PGSpec.execute(c, "DO $$ BEGIN RAISE NOTICE 'hello'; END $$")
      c.query(Rayo::PG::Statement.new("SELECT i, repeat('z', 200000) FROM generate_series(1, 3) i")) do |res|
        res.size.should eq(3)
        n = 0
        res.each do |row|
          n += 1
          row.i32(0).should eq(n)
          row.str(1).size.should eq(200000)
          row.str(1).all? { |b| b == 122 }.should be_true
        end
        n.should eq(3)
      end
      c.drain
    ensure
      c.close
    end
  end

  it "limits depth and distributes pool work" do
    pool = Rayo::PG::Pool.new(PGSpec::DB_URL, size: 2, max_depth: 2)
    stmt = Rayo::PG::Statement.new("SELECT 1")
    begin
      4.times { pool.query(stmt) { |res| res.error?.should be_false } }
      pool.connections.map(&.pending).should eq([2, 2])
      expect_raises(Rayo::PG::DepthError) { pool.query(stmt) { |_| } }
      pool.drain
      pool.connections.map(&.pending).should eq([0, 0])
    ensure
      pool.close
    end
  end
  it "sends a parameter larger than the socket buffers without deadlocking" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    payload = "x" * 2_000_000
    begin
      c.query(Rayo::PG::Statement.new("SELECT length($1::text)"), payload) do |res|
        res.first?.not_nil!.i32(0).should eq(2_000_000)
      end
      c.drain
    ensure
      c.close
    end
  end

  it "batches requests with reusable array parameters and pointer state" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    batch = Rayo::PG::Batch.new
    count = 0_i64
    begin
      batch.add(10_i64)
      batch.add(20_i64)
      stmt = Rayo::PG::Statement.new("SELECT unnest($1::int8[])")
      c.query(stmt, batch.param, state: pointerof(count)) do |res, state|
        res.size.should eq(2)
        res.each { |row| state.as(Int64*).value &+= row.i64(0) }
      end
      batch.clear
      batch.add(30_i64)
      c.drain
      count.should eq(30)
      batch.clear
      batch.add("a,b")
      batch.add("quote\" and slash\\")
      batch.add("bytes".to_slice)
      batch.add(nil)
      c.query(Rayo::PG::Statement.new("SELECT $1::text[]"), batch.param) do |res|
        values = [] of String?
        res.first?.not_nil!.each_array(0, Bytes.new(64)) { |v| values << (v ? String.new(v) : nil) }
        values.should eq(["a,b", "quote\" and slash\\", "bytes", nil])
      end
      c.drain
    ensure
      c.close
      batch.close
    end
  end
  it "retries failed preparation and prepares each statement only once" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    stmt = Rayo::PG::Statement.new("SELECT id FROM prepared_retry")
    begin
      c.query(stmt) { |res| res.sqlstate.should eq("42P01".to_slice) }
      c.drain
      PGSpec.execute(c, "CREATE TABLE prepared_retry(id bigint)")
      PGSpec.execute(c, "INSERT INTO prepared_retry VALUES (7)")
      2.times do
        c.query(stmt) { |res| res.first?.not_nil!.i64(0).should eq(7) }
        c.drain
      end
      c.query(Rayo::PG::Statement.new("SELECT count(*) FROM pg_prepared_statements WHERE name = $1"), stmt.name) do |res|
        res.first?.not_nil!.i64(0).should eq(1)
      end
      c.drain
    ensure
      c.close
    end
  end

  it "keeps resident memory flat across 100k queries after warm-up" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    stmt = Rayo::PG::Statement.new("SELECT $1::int8")
    count = 0_i64
    state = pointerof(count)
    rss_before = 0_i64
    begin
      12.times do |batch|
        10_000.times do |i|
          c.query(stmt, (batch * 10_000 + i).to_i64, state: state) do |res, data|
            p = data.as(Int64*)
            raise "pipeline result mismatch" if res.error? || res.first?.not_nil!.i64(0) != p.value
            p.value &+= 1
          end
        end
        c.drain
        rss_before = File.read("/proc/self/statm").split[1].to_i64 * 4096 if batch == 1
      end
      rss_after = File.read("/proc/self/statm").split[1].to_i64 * 4096
      (rss_after - rss_before).should be < 2_000_000
      count.should eq(120_000)
    ensure
      c.close
    end
  end
  it "continues buffered replies after a callback raises" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    stmt = Rayo::PG::Statement.new("SELECT 1")
    count = 0_i64
    begin
      c.query(stmt) { |_| raise "callback failed" }
      c.query(stmt, state: pointerof(count)) do |res, data|
        res.first?.not_nil!.i32(0).should eq(1)
        data.as(Int64*).value &+= 1
      end
      expect_raises(Exception, "callback failed") { c.drain }
      c.drain
      count.should eq(1)
    ensure
      c.close
    end
  end
end

describe "Postgres affected rows" do
  it "distinguishes inserts, conflicts, updates, deletes and errors" do
    c = Rayo::PG::BlockingTransport.new(PGSpec::DB_URL)
    begin
      PGSpec.execute(c, "CREATE TEMP TABLE affected(id integer PRIMARY KEY)")
      {
        {"INSERT INTO affected VALUES (1), (2)", 2_i64},
        {"INSERT INTO affected VALUES (1) ON CONFLICT DO NOTHING", 0_i64},
        {"UPDATE affected SET id = id + 10", 2_i64},
        {"DELETE FROM affected WHERE id = 11", 1_i64},
        {"DELETE FROM affected WHERE id = 11", 0_i64},
      }.each do |(sql, expected)|
        count = -1_i64
        c.query(Rayo::PG::Statement.new(sql), state: pointerof(count).address.to_i64!) do |res, state|
          res.error?.should be_false
          Pointer(Int64).new(state.to_u64!).value = res.rows_affected
        end
        c.drain
        count.should eq(expected)
      end
      c.query(Rayo::PG::Statement.new("SELECT 1/0")) do |res|
        res.error?.should be_true
        res.rows_affected.should eq(0)
      end
      c.drain
    ensure
      c.close
    end
  end
end
