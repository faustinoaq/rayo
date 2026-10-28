require "./spec_helper"
require "../src/rayo/sqlite"

describe Rayo::SQLite do
  it "refreshes column bounds after SQLite automatically reprepares a statement" do
    db = Rayo::SQLite::Database.new(":memory:")
    db.exec("CREATE TABLE shape(a INTEGER); INSERT INTO shape VALUES (1)")
    stmt = db.prepare("SELECT * FROM shape")
    begin
      stmt.step.should be_true
      stmt.i64(0).should eq(1)
      expect_raises(IndexError) { stmt.i64(1) }
      stmt.reset
      db.exec("ALTER TABLE shape ADD COLUMN b TEXT DEFAULT 'new'")
      stmt.step.should be_true
      stmt.str(1).should eq("new".to_slice)
      expect_raises(IndexError) { stmt.i64(2) }
    ensure
      stmt.close
      db.close
    end
  end

  it "clears omitted bindings across resets and changes binding types" do
    db = Rayo::SQLite::Database.new(":memory:")
    stmt = db.prepare("SELECT ?1, ?2, ?3, ?64")
    begin
      stmt.bind(1, 42).bind(2, "borrowed").bind(3, 9).bind(64, 64)
      stmt.step.should be_true
      stmt.reset
      stmt.bind(1, 42).bind(3, "text")
      stmt.step.should be_true
      stmt.i64(0).should eq(42)
      stmt.null?(1).should be_true
      stmt.str(2).should eq("text".to_slice)
      stmt.null?(3).should be_true
      stmt.reset
      stmt.bind(1, nil).bind(2, 123).bind(3, 99).bind(64, "last")
      stmt.step.should be_true
      stmt.null?(0).should be_true
      stmt.i64(1).should eq(123)
      stmt.i64(2).should eq(99)
      stmt.str(3).should eq("last".to_slice)
      stmt.reset
      stmt.step.should be_true
      4.times { |i| stmt.null?(i).should be_true }
    ensure
      stmt.close
      db.close
    end
  end

  it "clears bindings on statements with more than 64 parameters" do
    db = Rayo::SQLite::Database.new(":memory:")
    stmt = db.prepare("SELECT ?65")
    begin
      stmt.bind(65, 123)
      stmt.step.should be_true
      stmt.i64(0).should eq(123)
      stmt.reset
      stmt.step.should be_true
      stmt.null?(0).should be_true
    ensure
      stmt.close
      db.close
    end
  end

  it "reuses prepared bindings and returns borrowed columns, NULL and affected rows" do
    db = Rayo::SQLite::Database.new(":memory:")
    db.exec("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, value INTEGER)")
    insert = db.prepare("INSERT INTO items VALUES (?, ?, ?)")
    query = db.prepare("SELECT id, name, value FROM items ORDER BY id")
    begin
      insert.bind(1, 1).bind(2, "Ana").bind(3, nil)
      insert.step.should be_false
      db.rows_affected.should eq(1)
      insert.step.should be_false # DONE must not implicitly execute the INSERT again.
      insert.reset
      insert.bind(1, 2).bind(2, "雪".to_slice).bind(3, 42)
      insert.step.should be_false
      insert.reset
      query.step.should be_true
      query.i64(0).should eq(1)
      query.str(1).should eq("Ana".to_slice)
      query.null?(2).should be_true
      query.step.should be_true
      query.str(1).should eq("雪".to_slice)
      query.i64(2).should eq(42)
      expect_raises(IndexError) { query.str(3) }
      query.step.should be_false
      query.reset
      GC.stats
      before = GC.stats.total_bytes
      100.times do
        while query.step
          query.i64(0)
          query.str(1)
          query.null?(2)
        end
        query.reset
      end
      assert_no_request_allocations(GC.stats.total_bytes - before)
      insert.bind(1, 2)
      expect_raises(Rayo::SQLite::Error) { insert.step }
      insert.reset
    ensure
      insert.close
      query.close
      db.close
    end
  end
end
