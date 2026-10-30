require "../../src/rayo"

app = Rayo::App.new
app.get("/") { |ctx| ctx.text("ok") }
app.on_worker_start { |_| STDERR.puts Rayo::Uring.describe }
app.run(host: "127.0.0.1", port: ENV["SPILL_PORT"].to_i, workers: 1, database: nil)
