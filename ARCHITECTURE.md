# Rayo architecture

Rayo grew out of servers written for public benchmark challenges (a 1 vCPU SQLite API, an
8-core Conduit API on Postgres, a 16-core feed API). This document is the contract between
its parts. Everything lives under `module Rayo`; each part can be required on its own.

## Principles

1. **Linux only, io_uring only.** Linux 6.1+. There is no epoll fallback, by design: newer
   kernel features are probed at start-up and used when present, never traded for portability. One io_uring per worker process (several when
   the fixed-file table needs more room). Multishot accept and recv, provided buffers,
   direct (fixed) descriptors. The stdlib event loop, `IO` and `Socket` are not used on the
   request path.
2. **Share nothing.** `App#run` forks one worker per CPU. Each worker has its own listeners
   (`SO_REUSEPORT`), ring, connection table and Postgres connections. No locks, no threads
   on the request path.
3. **No allocation per request.** Buffers are allocated at start-up and reused or grown with
   `realloc`. Handlers write straight into the connection's output buffer. A program that
   follows the rules can be built with `-Dgc_none`; a program that doesn't still works with
   the GC on. Every part is tested both ways (`crystal spec` and `crystal spec -Dgc_none`).
4. **No blocking.** A handler that needs the database starts a query and returns; the query's
   callback finishes the response. Callbacks are non-capturing procs (no closure
   allocation); per-request state goes in the context.
5. **Batching is a feature.** Requests that arrive together can share one round trip to
   Postgres (pipelining) and, opt-in, one query (`Rayo::PG::Batch`).

## Layout

| File | Module | Role |
|---|---|---|
| `src/rayo/sys.cr` | `Rayo::Sys`, `Rayo::LibSys` | syscalls, sockets, rlimits, clocks |
| `src/rayo/buf.cr` | `Rayo::Buf` | growable malloc buffer, integer and JSON-string writers |
| `src/rayo/uring.cr` | `Rayo::Uring` | rings, SQE/CQE plumbing, buffer rings, fixed files, memlock sizing |
| `src/rayo/http.cr` | `Rayo::HTTP` | zero-copy HTTP/1.1 request parser, response writer (gzip with libdeflate on the roadmap) |
| `src/rayo/server.cr` | `Rayo::Server` | connection table, generations, ordered pipelined responses, send queue |
| `src/rayo/router.cr` | `Rayo::Router` | compile-time-registered routes, path params as slices |
| `src/rayo/context.cr` | `Rayo::Context` | per-request view: method, path, params, headers, body, output |
| `src/rayo/app.cr` | `Rayo::App` | user API: routes, middleware hooks, `run(port, workers)` |
| `src/rayo/pg.cr` + `src/rayo/pg/*` | `Rayo::PG` | Postgres v3 wire protocol, pipelining, prepared statements |
| `src/rayo/json.cr` | `Rayo::JSON` | streaming writer into a `Buf`; zero-copy reader for request bodies |
| `src/rayo/jwt.cr` | `Rayo::JWT` | HS256 sign/verify without allocation (libcrypto) |

## User API (target for 0.1)

```crystal
require "rayo"

app = Rayo::App.new

app.get "/" { |ctx| ctx.text "¡hola!" }

app.get "/users/:id" do |ctx|
  ctx.json do |j|
    j.object do
      j.field "id", ctx.param_i64("id")
      j.field "name", "Ana"
    end
  end
end

USER = Rayo::PG::Statement.new("SELECT id, name FROM users WHERE id = $1")

app.get "/db/users/:id" do |ctx|
  ctx.db.query(USER, ctx.param_i64("id")) do |res, ctx|
    if row = res.first?
      ctx.json { |j| j.object { j.field "id", row.i64(0); j.field "name", row.str(1) } }
    else
      ctx.status 404
    end
  end
end

app.run port: 3000 # workers: Rayo::Sys.ncpu, database: ENV["DATABASE_URL"]
```

- `ctx.param(name) : Bytes` (a slice into the receive buffer), `ctx.param_i64`, `ctx.query(name)`,
  `ctx.header(name)`, `ctx.body : Bytes`, `ctx.json_body` (zero-copy reader).
- `ctx.text`, `ctx.json { }`, `ctx.status`, `ctx.header(name, value)`, `ctx.write(bytes)`.
- Strings returned by `row.str` are slices (`Bytes`) unless the user calls `String.new`.
- `ctx.db` is the worker's Postgres pool; queries started by requests handled in the same
  loop turn are pipelined together and flushed once.

## Internal contracts

### Loop and Postgres transport

`Rayo::Uring` owns every socket. Postgres connections are plain fds registered with
`Uring.watch(fd, owner_tag)`; data arrives as `PG::Conn#on_data(ptr, len)`; sends go through
`Uring.send_plain(fd, ptr, len, tag)` and complete with `PG::Conn#on_sent(res)`.
`Rayo::PG` must also work without the loop: `PG::BlockingTransport` (plain blocking socket)
is used by its specs and by tools/scripts.

### Response ordering

HTTP pipelining is allowed: responses go out in request order per connection even when a
later request's handler finishes first. The server keeps a pending list per loop turn and
per connection (see `Server.add_pending` in the original code).

### Memory rules for contributors

- No `String` building, interpolation, `to_s`, `Array`, `Hash` or closures on the request path.
- One-time allocation at start-up is fine.
- Every hot-path change is checked with `-Dgc_none` under load: resident memory must stay flat.
