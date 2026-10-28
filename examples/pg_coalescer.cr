require "../src/rayo"

module Reads
  FIND = Rayo::PG::Statement.new("SELECT n, id, id * 10 FROM unnest($1::int8[]) WITH ORDINALITY r(id,n) ORDER BY n")

  class Driver
    include Rayo::Uring::Flusher
    getter coordinator : Rayo::PG::Coalescer(Rayo::PG::ReadRequest)
    getter transport : Rayo::PG::RingTransport

    def initialize(url : String)
      @transport = Rayo::PG::RingTransport.new(url, 16)
      @coordinator = Rayo::PG::Coalescer(Rayo::PG::ReadRequest).new do |group|
        group.query(Reads.driver.not_nil!.transport.conn, FIND, group.param(0))
      end
      @coordinator.attach
      Rayo::Uring.add_flusher(self)
    end

    def flush : Nil
      @transport.flush
    end
  end

  class_property driver : Driver? = nil
end

app = Rayo::App.new
app.on_worker_start do |_index|
  Reads.driver = Reads::Driver.new(ENV["DATABASE_URL"])
end
app.get "/values/:id" do |ctx|
  Reads.driver.not_nil!.coordinator.enqueue(ctx, ctx.param_i64("id")) do |res, ctx|
    unless res.error?
      if row = res.first?
        ctx.json(id: row.i64(1), value: row.i64(2))
      else
        ctx.status(404)
      end
    end
  end
end
app.run port: 3000
