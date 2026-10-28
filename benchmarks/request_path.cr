require "../src/rayo"

# Build with --release --mcpu x86-64-v3 -Dwithout_mt -Dgc_none.
# SERVE=1 exposes the same routes to wrk; otherwise measure without network/SQL.
app = Rayo::App.new
app.get("/hello") { |ctx| ctx.text "Hello, world!" }
app.get("/json") { |ctx| ctx.json message: "Hello, world!", id: 123_i64, ok: true }
app.get("/posts/:id") do |ctx|
  ctx.json id: ctx.param_i64("id"), body: "A borrowed database value".to_slice, likes: 42_i64
end
app.get("/feed") do |ctx|
  ctx.json do |j|
    j.array(1..20) do |id|
      {id: id, body: "A borrowed database value".to_slice, username: "alice".to_slice, likes: 42_i64}
    end
  end
end

if ENV["SERVE"]? == "1"
  app.run host: "127.0.0.1", port: (ENV["PORT"]? || "3000").to_i, workers: 1, database: nil
end

iterations = (ENV["ITERATIONS"]? || "1000000").to_i
raise "ITERATIONS must be positive" if iterations < 1
ctx = Rayo::Context.new(0)
wire = Rayo::Buf.new(8192)
%w(/hello /json /posts/123 /feed).each do |path|
  input = "GET #{path} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: wrk\r\nAccept: */*\r\n\r\n"
  req = Rayo::HTTP::Request.new
  # Warm buffers and the cached date before timing reusable request state.
  2.times do |pass|
    count = pass == 0 ? 1000 : iterations
    allocated = GC.stats.total_bytes
    started = Time.instant
    count.times do
      consumed = Rayo::HTTP.parse(input.to_unsafe, input.bytesize, pointerof(req))
      raise "incomplete request" unless consumed == input.bytesize
      ctx.reset(req)
      app.dispatch(ctx)
      app.after_response(ctx)
      wire.clear
      Rayo::HTTP.response(wire, ctx.code, ctx.output, ctx.headers, ctx.content_type, false, false)
    end
    elapsed = Time.instant - started
    bytes = GC.stats.total_bytes - allocated
    if pass == 1
      puts "#{path} ns/request=#{(elapsed.total_nanoseconds / count).round(1)} allocated=#{bytes} response_bytes=#{wire.len}"
    end
  end
end
