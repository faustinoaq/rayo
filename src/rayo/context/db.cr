require "../context"
require "./json"
require "../pg/worker_pool"

module Rayo::Server
  class_property database : PG::WorkerPool? = nil
end

class Rayo::Context
  property work_pending = 0
  property db_pending = 0
  property db_failed = false

  def reset(request : HTTP::Request) : Nil
    previous_def(request)
    @work_pending = 0
    @db_pending = 0
    @db_failed = false
  end

  def db : Database
    Database.new(self, Server.database || raise PG::Error.new("database is not configured; pass database: to App#run"))
  end

  def database_error : Nil
    @output.clear
    status(500)
    json(error: "database error")
  end

  struct Database
    def initialize(@context : Context, @pool : PG::WorkerPool)
    end

    def query(statement : PG::Statement, *args, &callback : PG::Result, Context -> Nil) : Nil
      raise ArgumentError.new("db.query callback must not capture; use the supplied ctx") if callback.closure?
      @pool.query(@context, statement, *args, callback: callback)
    end
  end
end
