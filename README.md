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

Runnable examples: [JSON](examples/json.cr) and [Postgres](examples/pg.cr).
The Postgres example creates its users table and seed row during startup.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the parts fit together.

## Parts

Each part can be required on its own:

| Require | What |
|---|---|
| `rayo` | everything |
| `rayo/pg` | Postgres v3 client with pipelining (works with or without the Rayo loop) |
| `rayo/json` | streaming JSON writer and zero-copy reader |
| `rayo/jwt` | HS256 tokens without allocation |
| `rayo/buf` | growable byte buffer with fast integer and JSON-string writers |

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

- Linux 6.1 or newer. The loop uses `IORING_SETUP_COOP_TASKRUN` to batch completions
  and waits on ring fds with epoll, including when several rings are active.
  Newer kernels unlock the features marked in the roadmap.
- x86-64 or arm64
- Crystal 1.22+
- libcrypto (OpenSSL 3) and libdeflate
- io_uring allowed: some container runtimes block it by default (Docker's default seccomp
  profile, gVisor, some managed Kubernetes). Run with a seccomp profile that allows the
  `io_uring_*` syscalls; Rayo exits with a clear message when io_uring is not available.

## Roadmap

These come from the benchmark servers Rayo grew out of, or from recent kernels. Each one
goes in only after it shows a measured gain.

**From the benchmark servers**

| Feature | What it gives |
|---|---|
| gzip with libdeflate, cached per response | less bandwidth and send time on large JSON |
| Cross-request query batching (`Rayo::PG::Batch`) | requests in the same loop turn share one query, not just one round trip |
| Group commit for writes (opt-in) | fewer commits under write-heavy load; trades latency for CPU |
| Chunked request bodies | streaming uploads |
| Multi-lane bcrypt | password hashing several at a time with SIMD |

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
