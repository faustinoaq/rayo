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

## User API

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

- `ctx.param(name) : Bytes` (a slice into the receive buffer), `ctx.param_i64`, `ctx.query(name)`,
  `ctx.header(name)`, `ctx.body : Bytes`, `ctx.json_body` (zero-copy reader).
- `ctx.text`, `ctx.json(**fields)`, `ctx.json { |j| ... }`,
  `ctx.json_array(enumerable) { |item| named_tuple }`, `ctx.status`,
  `ctx.header(name, value)`, `ctx.write(bytes)`.
- JSON constant keys and separators are escaped at compile time into one literal per
  field. Values dispatch through writer overloads: all integer widths, floats, booleans,
  nil, strings/bytes, NamedTuples, tuples, numeric static arrays/slices, and custom
  `to_json(Rayo::JSON::Writer)`. Unsupported values fail compilation.
- `j.array(enumerable) { |item| named_tuple }` also works in streaming writer blocks.
- Strings returned by `row.str` are slices (`Bytes`) unless the user calls `String.new`.
- `ctx.db` is the worker's Postgres pool; queries started by requests handled in the same
  loop turn are pipelined together and flushed once.

## Internal contracts

### Loop and Postgres transport

`Rayo::Uring` owns every socket. Postgres connections are plain fds registered with
`Uring.watch(fd, owner)`; data arrives as `PG::Conn#on_data(ptr, len)`; sends go through
`Uring.send_plain(fd, ptr, len, tag)` and complete with `PG::Conn#on_sent(res)`.
`Rayo::PG` also works without the loop: `PG::BlockingTransport` is used by
its specs and tools/scripts. The worker authenticates blocking connections after
fork, then transfers their sockets into `PG::RingTransport`. No blocking IO runs
on requests. `Uring.add_flusher` registers a worker driver; the loop flushes drivers
once per turn before submitting SQEs, batching all queries queued during completion
dispatch. Only one send per PG socket can be in flight.

`Context#db` is a stack view over the worker pool. Pending query records are allocated
at startup and reused through a free list. Each record stores a deferred handle with
HTTP connection generation and request serial; stale callbacks cannot finish a reused
slot. Multiple queries can share a request; the last callback completes its response.
Capturing callbacks are rejected before queuing at runtime, matching the standalone
PG client. Crystal's ordinary block-taking methods do not expose caller ASTs for
compile-time capture checks. Store per-request state in Context and use the callback's
`ctx` argument. Result/row views expire as the callback returns.

An error result still reaches the callback. If it leaves the default status and an
empty body, the response becomes `500 {"error":"database error"}`. Callback exceptions
also become 500 JSON. No database configuration causes `ctx.db` to raise clearly.
Automatic reconnect and query cancellation are not implemented.

### Response ordering

HTTP pipelining is allowed: responses go out in request order per connection even when a
later request's handler finishes first. The server keeps a pending list per loop turn and
per connection (see `Server.add_pending` in the original code).

### Memory rules for contributors

- No `String` building, interpolation, `to_s`, `Array`, `Hash` or closures on the request path.
- One-time allocation at start-up is fine.
- Every hot-path change is checked with `-Dgc_none` under load: resident memory must stay flat.
