require "./buf"

@[Link("sqlite3")]
lib Rayo::SQLite::LibSQLite
  fun open = sqlite3_open_v2(path : UInt8*, db : Void**, flags : Int32, vfs : UInt8*) : Int32
  fun close = sqlite3_close(db : Void*) : Int32
  fun exec = sqlite3_exec(db : Void*, sql : UInt8*, callback : Void*, arg : Void*, error : UInt8**) : Int32
  fun prepare = sqlite3_prepare_v3(db : Void*, sql : UInt8*, length : Int32, flags : UInt32, statement : Void**, tail : UInt8**) : Int32
  fun finalize = sqlite3_finalize(statement : Void*) : Int32
  fun reset = sqlite3_reset(statement : Void*) : Int32
  fun clear = sqlite3_clear_bindings(statement : Void*) : Int32
  fun step = sqlite3_step(statement : Void*) : Int32
  fun bind_int64 = sqlite3_bind_int64(statement : Void*, index : Int32, value : Int64) : Int32
  fun bind_null = sqlite3_bind_null(statement : Void*, index : Int32) : Int32
  fun bind_text = sqlite3_bind_text(statement : Void*, index : Int32, value : UInt8*, length : Int32, destructor : Void*) : Int32
  fun column_int64 = sqlite3_column_int64(statement : Void*, index : Int32) : Int64
  fun column_text = sqlite3_column_text(statement : Void*, index : Int32) : UInt8*
  fun column_bytes = sqlite3_column_bytes(statement : Void*, index : Int32) : Int32
  fun column_type = sqlite3_column_type(statement : Void*, index : Int32) : Int32
  fun column_count = sqlite3_column_count(statement : Void*) : Int32
  fun changes = sqlite3_changes64(db : Void*) : Int64
  fun extended_result_codes = sqlite3_extended_result_codes(db : Void*, enabled : Int32) : Int32
end

module Rayo::SQLite
  class Error < Exception
    getter code : Int32

    def initialize(@code)
      super("SQLite error #{@code}")
    end
  end

  # Open after fork. SQLite runs synchronously on the owning worker.
  class Database
    getter ptr = Pointer(Void).null

    def initialize(path : String)
      rc = LibSQLite.open(path.to_unsafe, pointerof(@ptr), 0x2 | 0x4 | 0x8000, Pointer(UInt8).null)
      if rc != 0
        LibSQLite.close(@ptr) unless @ptr.null?
        @ptr = Pointer(Void).null
        raise Error.new(rc)
      end
      LibSQLite.extended_result_codes(@ptr, 1)
    end

    def exec(sql : String) : Nil
      check_open
      rc = LibSQLite.exec(@ptr, sql.to_unsafe, Pointer(Void).null, Pointer(Void).null, Pointer(UInt8*).null)
      raise Error.new(rc) unless rc == 0
    end

    def prepare(sql : String) : Statement
      check_open
      Statement.new(self, sql)
    end

    def rows_affected : Int64
      check_open
      LibSQLite.changes(@ptr)
    end

    def check_open : Nil
      raise "SQLite database closed" if @ptr.null?
    end

    def close : Nil
      return if @ptr.null?
      rc = LibSQLite.close(@ptr)
      raise Error.new(rc) unless rc == 0
      @ptr = Pointer(Void).null
    end
  end

  class Statement
    @ptr = Pointer(Void).null
    @row = false
    @done = false

    def initialize(@database : Database, sql : String)
      rc = LibSQLite.prepare(@database.ptr, sql.to_unsafe, sql.bytesize, 1_u32, pointerof(@ptr), Pointer(UInt8*).null)
      raise Error.new(rc) unless rc == 0
      raise ArgumentError.new("empty SQLite statement") if @ptr.null?
    end

    private def check_open : Nil
      @database.check_open
      raise "SQLite statement closed" if @ptr.null?
    end

    def bind(index : Int32, value : Int) : self
      check_open
      rc = LibSQLite.bind_int64(@ptr, index, value.to_i64)
      raise Error.new(rc) unless rc == 0
      self
    end

    def bind(index : Int32, value : Nil) : self
      check_open
      rc = LibSQLite.bind_null(@ptr, index)
      raise Error.new(rc) unless rc == 0
      self
    end

    # SQLITE_STATIC: caller keeps bytes alive and unchanged until reset/rebind.
    def bind(index : Int32, value : String | Bytes) : self
      check_open
      bytes = value.is_a?(String) ? value.to_slice : value
      ptr = bytes.empty? ? "".to_unsafe : bytes.to_unsafe
      rc = LibSQLite.bind_text(@ptr, index, ptr, bytes.size, Pointer(Void).null)
      raise Error.new(rc) unless rc == 0
      self
    end

    # true = row available, false = done. Views expire on step/reset/close.
    def step : Bool
      check_open
      return false if @done
      @row = false
      rc = LibSQLite.step(@ptr)
      return @row = true if rc == 100
      @done = true
      raise Error.new(rc) unless rc == 101
      false
    end

    private def column(index : Int32) : Nil
      check_open
      raise IndexError.new unless @row && 0 <= index < LibSQLite.column_count(@ptr)
    end

    def null?(index : Int32) : Bool
      column(index)
      LibSQLite.column_type(@ptr, index) == 5
    end

    def i64(index : Int32) : Int64
      column(index)
      LibSQLite.column_int64(@ptr, index)
    end

    def str(index : Int32) : Bytes
      raise "NULL SQLite column" if null?(index)
      ptr = LibSQLite.column_text(@ptr, index)
      Bytes.new(ptr, LibSQLite.column_bytes(@ptr, index))
    end

    def reset : Nil
      check_open
      @row = false
      @done = false
      # reset reports the previous step's error, already delivered by step.
      LibSQLite.reset(@ptr)
      LibSQLite.clear(@ptr)
    end

    def close : Nil
      return if @ptr.null?
      LibSQLite.finalize(@ptr)
      @ptr = Pointer(Void).null
      @row = false
    end
  end
end
