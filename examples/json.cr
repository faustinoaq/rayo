require "../src/rayo"

app = Rayo::App.new
app.get("/json") { |ctx| ctx.json(id: 42_i64, name: "Ana") }
app.get("/users/:id") { |ctx| ctx.json(id: ctx.param_i64("id"), name: "Ana") }
app.post("/json") { |ctx| ctx.json(id: ctx.json_body["id"].i64) }
app.get("/items") { |ctx| ctx.json_array(1..3) { |id| {id: id} } }
app.run port: (ENV["PORT"]? || "3000").to_i, workers: 1
