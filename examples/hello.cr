require "../src/rayo"

app = Rayo::App.new
app.get "/" { |ctx| ctx.text "Hello, world!" }
app.get "/users/:id" do |ctx|
  ctx.write(ctx.param("id"))
end
app.run port: (ENV["PORT"]? || "3000").to_i, workers: 1
