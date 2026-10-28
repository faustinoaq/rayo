require "../src/rayo"

DATABASE = ENV["DATABASE_URL"]
SCHEMA   = Rayo::PG::Statement.new("CREATE TABLE IF NOT EXISTS users (id bigint PRIMARY KEY, name text NOT NULL)")
SEED     = Rayo::PG::Statement.new("INSERT INTO users (id, name) VALUES (1, 'Ana') ON CONFLICT (id) DO NOTHING")
USERS    = Rayo::PG::Statement.new("SELECT id, name FROM users ORDER BY id LIMIT 20")
USER     = Rayo::PG::Statement.new("SELECT id, name FROM users WHERE id = $1")

# Startup is allowed to block; close it before App forks its worker connections.
startup = Rayo::PG::BlockingTransport.new(DATABASE)
begin
  {SCHEMA, SEED}.each do |statement|
    startup.query(statement) { |res| raise String.new(res.message) if res.error? }
    startup.drain
  end
ensure
  startup.close
end

app = Rayo::App.new
app.get("/db") do |ctx|
  ctx.db.query(USERS) do |res, ctx|
    unless res.error?
      ctx.json_array(res) { |row| {id: row.i64(0), name: row.str(1)} }
    end
  end
end
app.get("/users/:id") do |ctx|
  ctx.db.query(USER, ctx.param_i64("id")) do |res, ctx|
    unless res.error?
      if row = res.first?
        ctx.json(id: row.i64(0), name: row.str(1))
      else
        ctx.status(404)
      end
    end
  end
end
app.run port: (ENV["PORT"]? || "3000").to_i, workers: 1, database: DATABASE, pool: 4
