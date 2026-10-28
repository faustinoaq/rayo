# Rayo ⚡

*Rayo* means lightning in Spanish. It is a web framework for [Crystal](https://crystal-lang.org)
on Linux, built for throughput and tail latency:

- **io_uring** networking: multishot accept and receive, provided buffers, direct descriptors.
- **One worker per CPU**, nothing shared, no locks on the request path.
- **A pipelined Postgres client** written for the loop: requests that arrive together share a
  round trip.
- **No allocation per request**: buffers are reused, responses are written in place. Programs
  that follow the rules can be built with `-Dgc_none` and run without a garbage collector.

> **Status: under construction (0.1 in progress).** The design comes from servers that run in
> public benchmark challenges; this repository turns that code into a reusable framework.
> APIs will change until 0.1 is tagged.

## Usage

```crystal
require "rayo"

app = Rayo::App.new

app.get "/" { |ctx| ctx.text "¡hola!" }

app.get "/users/:id" do |ctx|
  ctx.json id: ctx.param_i64("id"), name: "Ana"
end

app.get "/items" do |ctx|
  ctx.json_array(1..3) { |id| {id: id} }
end

USER = Rayo::PG::Statement.new("SELECT id, name FROM users WHERE id = $1")
app.get "/db/users/:id" do |ctx|
  ctx.db.query(USER, ctx.param_i64("id")) do |res, ctx|
    unless res.error?
      if row = res.first?
        ctx.json id: row.i64(0), name: row.str(1)
      else
        ctx.status 404
      end
    end
  end
end

app.run port: 3000, database: ENV["DATABASE_URL"]?, pool: 4
```

JSON fields are stack NamedTuples. Strings and byte slices are escaped; nested
NamedTuples become objects, tuples and numeric slices/static arrays become arrays.
`ctx.json { |j| ... }` keeps the streaming writer API, including
`j.array(rows) { |row| {id: row.i64(0)} }`. `ctx.json_body` borrows the request body.

Database sockets open in each worker after fork. Queries defer the response;
callbacks receive the still-live context, and requests retain their wire order.
Use constants for statements and the callback's `ctx` argument for request state.
Capturing callbacks raise before queuing. An unhandled PG error returns 500 JSON;
a callback can handle it with `res.error?`, a status or a response body.
Calling `ctx.db` without a configured database raises a clear error.

Build forked apps with Crystal's single-thread runtime:

```sh
crystal build app.cr --release -Dwithout_mt -o app
# Add -Dgc_none once your handlers reuse their memory.
```

`workers > 1` fails before forking without `-Dwithout_mt`, with either GC mode.
Crystal 1.22 starts a runtime monitor thread before application code; raw fork
preserves runtime thread/GC records for threads that no longer exist in the child.
One worker can use the default runtime. Start application helper threads and open
SQLite handles in the worker hook, after fork.

```crystal
app.gzip = true
app.gzip_min_size = 1024
app.on_worker_start do |worker_index|
  # Open worker-owned resources here. Rings and the PG pool are ready.
end
app.get("/download") do |ctx|
  ctx.compress = false # route opt-out
  ctx.text("already compact")
end
app.run ports: [3000, 3001], workers: 2, database: nil
```

Gzip uses one libdeflate compressor and scratch buffer per worker, respects
`Accept-Encoding` quality values and wildcard negotiation, preserves `Vary`, and
keeps the original body when compression does not shrink it. It skips bodyless,
partial, and already encoded responses. `ctx.response_header(name)` borrows a
response header until the next header update.

`res.rows_affected : Int64` exposes PostgreSQL's command count, including zero for
`ON CONFLICT DO NOTHING`; `res.size` continues to count returned rows. Commands
without a count and errors report zero. JSON timestamp values normalize PostgreSQL
ISO timestamptz text or its eight-byte binary representation to UTC RFC 3339 with
six fractional digits:

```crystal
ctx.json(created_at: Rayo::JSON::Timestamp.new(row.str(2)))
# Or JSON::Timestamp.binary(bytes), / binary(microseconds_since_2000).
```

The timestamp helper rejects infinity and years outside 0001–9999. Text input
must carry a timezone (`Z`, `+HH`, `+HH:MM`, or `+HH:MM:SS`); the PG client configures
ISO dates. Standalone users can require `rayo/json/timestamp`.

Runnable examples: [JSON](examples/json.cr) and [Postgres](examples/pg.cr).
The Postgres example creates its users table and seed row during startup.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the parts fit together.

## Parts

Each part can be required on its own:

| Require | What |
|---|---|
| `rayo` | HTTP framework, Postgres, JSON/timestamps, JWT and gzip |
| `rayo/pg` | Postgres v3 client with pipelining (works with or without the Rayo loop) |
| `rayo/json` | streaming JSON writer and zero-copy reader |
| `rayo/bcrypt` | bounded asynchronous password jobs with interleaved cost-10 lanes and libcrypt fallback |
| `rayo/sqlite` | optional synchronous SQLite C adapter and borrowed columns |
| `rayo/sqlite/group_commit` | opt-in SQLite commit-before-response batching through the loop |
| `rayo/json/timestamp` | PostgreSQL timestamptz to RFC 3339 JSON values |
| `rayo/jwt` | HS256 tokens without allocation |
| `rayo/buf` | growable byte buffer with fast integer and JSON-string writers |

## Optional password hashing and SQLite

```crystal
require "rayo/bcrypt"

module Passwords
  class_property pool : Rayo::Bcrypt::Pool? = nil
end
app.on_worker_start do |_index|
  pool = Rayo::Bcrypt::Pool.new(threads: 1, capacity: 128, cost: 10, window_ms: 1)
  pool.attach
  Passwords.pool = pool
end
app.post("/hash") do |ctx|
  Passwords.pool.not_nil!.hash(ctx, ctx.body) do |result, ctx|
    ctx.json(hash: result.hash, ok: result.ok?)
  end
end
```

`pool.verify(ctx, password_bytes, stored_hash) { |result, ctx| ... }` checks a
password. Callbacks cannot capture; use `ctx` for request state. Results borrow
job storage only until the callback returns. Passwords are limited to 72 bytes
without NUL; cost is 4–16. Cost-10 `$2b$` and ASCII `$2a$` jobs use up to six
interleaved lanes; other supported hashes use libcrypt. Queue exhaustion raises
before deferring the request. Helpers never call application code: completion
wakes the ring, which dispatches callbacks. Database and password callbacks may
chain either direction. A configured pool lives until worker exit.

For tools, `hash(password, state: UInt64)` and `verify(password, hash, state: UInt64)`
use non-capturing `|result, state|` callbacks. `fd` and `on_data(ptr, len)` expose
the completion transport; call `attach` once to let the Rayo loop own it. An
unattached pool can be closed explicitly after draining all jobs.

`require "rayo/sqlite"` loads only the synchronous C adapter:
`SQLite::Database.new(path)`, `db.exec(sql)`, `db.prepare(sql)`,
`stmt.bind(index, value)` (one-based, integers/text/bytes/nil), `stmt.step`
(true for a row, false for done), `stmt.i64(index)`, `stmt.str(index)` and
`stmt.null?(index)` (zero-based columns), `stmt.reset`, `stmt.close`,
`db.rows_affected`, `db.close`. Prepare once after fork. Bindings borrow input
until reset/rebind; column slices expire on step/reset/close. Reset clears bindings.
SQLite may allocate internally; no managed objects are created for binding or rows.
Close statements before their database. SQLite calls run on the worker and can
block it; choose busy timeouts and storage settings for the application.

`require "rayo/sqlite/group_commit"` adds `SQLite::GroupCommit.new(db, capacity: 1024)`.
Create and `attach` it in `on_worker_start`, then call
`group.transaction(ctx) { |db| ... }` from a handler. Responses stay deferred until
that loop turn's transaction commits. An exception or failed commit rolls back
the batch and returns 500 to all its live requests. Batching is opt-in: requests
share a transaction and can see earlier uncommitted changes in that batch. It is
intended for synchronous SQLite work; finish that work inside the block. A group
and its database live until worker exit.

## Why Rayo is different

Rayo does not try to run everywhere. It picks the fastest way Linux offers today and builds
only on that:

- **io_uring only. There is no epoll or kqueue fallback**, and no macOS or Windows support.
  A fallback would mean a second, slower code path to keep and a design limited to what
  both paths can do.
- **No garbage collector needed.** The request path does not allocate, so apps can be built
  with `-Dgc_none`: no pauses, flat memory under load.
- **No stdlib event loop, fibers or `IO` on the request path.** One loop per worker, written
  for io_uring.
- **Postgres in the loop.** The database client is part of the framework and shares the
  ring with the HTTP sockets, so requests that arrive together share a round trip.
- **Newer kernels make it faster.** Rayo probes the kernel at start-up and turns on newer
  io_uring features when they are there (see the roadmap). It never switches to a
  slower design to support an older system.

If you need portability, a stdlib-based framework is the better choice. Rayo is for Linux
servers where every core and every millisecond counts.

## Requirements

- Linux 6.1 or newer. The loop uses `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN`
  and waits directly in ring zero while it is the only active ring. Timer deadlines bound
  that wait with `IORING_ENTER_EXT_ARG`. With several active rings, epoll watches their
  eventfds with a 1 ms maximum wait to tolerate lost notifications on Linux 6.12/6.18.
  Newer kernels unlock the features marked in the roadmap.
- x86-64 or arm64
- Crystal 1.22+
- libcrypto (OpenSSL 3) and libdeflate; libcrypt for optional bcrypt, SQLite3 for optional SQLite
  (Debian/Ubuntu: `libssl-dev libdeflate-dev libcrypt-dev libsqlite3-dev`)
- io_uring allowed: some container runtimes block it by default (Docker's default seccomp
  profile, gVisor, some managed Kubernetes). Run with a seccomp profile that allows the
  `io_uring_*` syscalls; Rayo exits with a clear message when io_uring is not available.

## Roadmap

These come from the benchmark servers Rayo grew out of, or from recent kernels. Each one
goes in only after it shows a measured gain.

**From the benchmark servers**

| Feature | What it gives |
|---|---|
| Cross-request query batching (`Rayo::PG::Batch`) | requests in the same loop turn share one query, not just one round trip |
| Chunked request bodies | streaming uploads |

**From newer kernels** (used when present, detected at start-up)

| Feature | Kernel | What it gives |
|---|---|---|
| Zero-copy send (`SEND_ZC`) | 6.0 | no copy of large responses into the kernel |
| NAPI busy polling | 6.9 | lower latency when the NIC supports it |
| Receive bundles | 6.10 | several buffers in one completion: fewer completions under load |
| Incremental buffer consumption | 6.12 | small reads stop wasting whole buffers: less memory per connection |
| Registered wait regions, ring resizing | 6.13 | cheaper waits; rings that grow with the load |
| Zero-copy receive (`zcrx`) | 6.15 | data goes from the NIC to user memory with no copy (needs NIC support) |

## Development

```sh
crystal spec            # with the GC
crystal spec -Dgc_none  # without it: the request path must not allocate
```

CI runs the specs on the GitHub runner's kernel and, in KVM guests booted with
[virtme-ng](https://github.com/arighi/virtme-ng), on Linux 6.1, 6.6, 6.12, 6.18 and 7.2
(`.github/workflows/kernels.yml`), so features of newer kernels are tested on those kernels.

Postgres specs use `RAYO_PG_URL` (default `postgres://postgres:postgres@127.0.0.1:5432/postgres`).

## License

MIT, see [LICENSE](LICENSE).
