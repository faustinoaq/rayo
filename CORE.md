# Core API

`require "rayo"` loads the Linux worker loop and HTTP framework. See
[examples/hello.cr](examples/hello.cr) for a runnable app.

- `App#get/post/put/patch/delete/options/head(path) { |ctx| ... }` registers routes
  before `run(host: "0.0.0.0", port: 3000, workers: Sys.ncpu)`.
- Routes form a segment tree. Static segments take precedence over `:name`, then a
  trailing `*` or `*name`. Captures are receive-buffer slices. Missing paths return
  404; a matching path without that method returns 405 with `Allow`.
- `ctx.method`, `ctx.path`, `ctx.query`, `ctx.query(name)`, `ctx.header(name)` and
  `ctx.body` expose the request. Paths, query values, headers and bodies are `Bytes`.
  Missing fields return an empty slice. Query values and captures retain their raw
  URL encoding; the framework does not allocate decoded strings.
- `ctx.param(name)` returns `Bytes`; `ctx.param_i64(name)` parses a signed integer
  and raises on missing, invalid or overflowing values.
- `ctx.text(string)` and `ctx.write(bytes)` append a response body. `ctx.status(code)`
  sets the status; `ctx.status` reads it. `ctx.header(name, value)` replaces a response
  field, accepting `String` or `Bytes`. `Content-Type` can also be set with
  `ctx.content_type(value)`. The server owns Date, Content-Length and Connection.
- `app.before { |ctx| ... }` runs before routing; `app.after { |ctx| ... }` runs when
  the response finishes, including deferred responses. Handler/hook exceptions become
  500 responses. Exceptions and application string building allocate; handlers used
  with `-Dgc_none` should keep their normal request paths free of both.

## Deferred responses

`handle = ctx.defer` pauses this connection's pipeline. Store the value handle in
caller-owned state and return from the handler. A later loop callback can call
`handle.context` to access the still-live context, then `handle.finish`, or use
`handle.finish { |ctx| ctx.text("done") }`. `finish` returns false for a disconnected,
already-finished or reused request. Its block is yielded inline.

The request's input stays stable until completion. Later bytes have a separate
buffer; later requests on that connection run after completion. This preserves wire
order while allowing other connections to progress. Views expire when the response
finishes. Application callback procs must be non-capturing; store request state in
preallocated owner records. JSON and database Context extensions remain TODO hooks
for their respective components.

## Plain fd transport and timers

After the worker loop is initialized, an fd owner implements
`Rayo::Uring::Handler`:

```crystal
def on_data(ptr : UInt8*, len : Int32) : Nil
end

def on_sent(result : Int32) : Nil
end

def on_closed : Nil
end
```

`tag = Uring.watch(fd, owner)` transfers ownership of an ordinary socket fd to the
loop. `Uring.send_plain(fd, ptr, len, tag)` reports the actual send result through
`on_sent`; the owner handles short sends and keeps memory stable until completion.
The `on_data` view lasts only for that callback. `Uring.unwatch(tag)` shuts down the
socket and closes it after outstanding operations finish, then calls `on_closed`.
There are 1,024 reusable owner slots per worker. An owner must serialize its sends
when protocol order matters.

`token = Uring.arm_timeout(milliseconds, callback, tag: 0_u64)` installs a one-shot
monotonic timer. `callback` has type `Proc(UInt64, Nil)` and receives the tag; capturing
procs are rejected. `Uring.cancel_timeout(token)` returns whether the token was live.
There are 4,096 reusable timer slots. The loop caches the earliest deadline and uses
it as epoll's wait timeout; idle timer tables require no scan on request turns.

## Implementation and limits

Each process owns its rings, listeners, connection records and buffers. Workers use
SO_REUSEPORT and parent-death signals. One worker runs in process; with several
workers, the parent waits and stops/reaps the rest when one exits. Listening accepts
IPv4 address literals. SIGTERM and SIGINT have their default disposition in the loop.

Multishot accept yields ordinary fds which are immediately installed in the first
fixed-file table with space. This avoids a peer reset when direct multishot accept
runs out of file slots. The connection pays one registration syscall; subsequent
multishot receives and sends use fixed descriptors. Each ring has provided buffers,
and eventfd/epoll drives all rings. Ring counts and queue sizes use the memlock budget.
`URING_SLOTS` can lower the per-ring table size for spill-over testing.

Connection records and malloc buffers are created on first use of a slot and retained
for reuse. Buffers grow only when a new high-water mark requires it. Output under a
send is immutable; a second buffer queues subsequent responses. Shutdown completes
before the fixed slot closes, and send memory survives until its completion.

Request headers are limited to 16 KiB and bodies to 1 MiB. Malformed or chunked request
framing gets 400 and a close. Deferred input is bounded to the same size; a response
queue over 4 MiB closes a slow connection. Total fixed-slot exhaustion refuses new
peers. There is no gzip, chunked response streaming, TLS, automatic HEAD-to-GET
fallback, HTTP upgrade, 100-continue handshake, or idle-client timeout in this core.
`sys.cr` and `buf.cr` are unchanged.

## Validation and load measurement

On the supplied Crystal 1.22.1 Linux host, both `crystal spec` and
`crystal spec -Dgc_none` passed **12 examples**, taking about **0.3–0.55 seconds**
per suite. Formatting checks passed and `examples/hello.cr` built with
`--release -Dgc_none`. Integration coverage includes 200 simultaneous sockets,
32-slot ring spill-over, pipelines, deferred input stability, half-closed pipelines,
large bodies, queued/short sends, disconnects, plain-fd callbacks, timer cancellation,
header replacement and worker supervision.

`wrk` was unavailable. [benchmarks/keepalive.cr](benchmarks/keepalive.cr) warms 200
persistent connections, then drives them for 20 seconds against the hello example.
The client uses ordinary Crystal sockets and runs separately from the server.
These are local client-loop measurements on a shared host, not a throughput ceiling.

| Server build flags | Duration | Requests | Requests/s | Warmed precise RSS |
| --- | ---: | ---: | ---: | ---: |
| `--release -Dgc_none` | 20.008 s | 892,756 | 44,619.7 | 17,224 → 17,312 KiB |
| `--release -Dgc_none -Dwithout_mt` | 20.008 s | 916,007 | 45,781.9 | 17,224 → 17,224 KiB |

RSS was sampled once per second from `/proc/<pid>/smaps_rollup` after warm-up.
`VmRSS` counters alone hide small changes: the exact build's warmed `VmRSS` ranged
from 16,640 to 16,768 KiB, while the single-thread build stayed at 16,768 KiB.

**Known runtime limitation:** the exact requested build has a small background
allocation in Crystal 1.22.1's SYSMON thread, independent of requests. A temporary
malloc trace located repeated 40-byte allocations in
`Fiber::ExecutionContext::Monitor#run_loop` (stdlib
`fiber/execution_context/monitor.cr`), approximately 100 times per second. That
accounts for the 88 KiB rise in precise RSS; it is not flat in this configuration.
Adding `-Dwithout_mt` selects Crystal's single-thread runtime and removes that
background source. Its warmed RSS stayed exactly flat in every sampled second.
The library does not replace or patch stdlib scheduler internals.

To repeat the single-thread measurement from the repository root:

```sh
mkdir -p bin
crystal build examples/hello.cr --release -Dgc_none -Dwithout_mt -o bin/hello
crystal build benchmarks/keepalive.cr --release -o bin/keepalive
PORT=3000 bin/hello &
rayo_pid=$!
PORT=3000 bin/keepalive
kill "$rayo_pid"
wait "$rayo_pid"
```

Omit `-Dwithout_mt` to repeat the exact requested build. Stop only the recorded
server PID. The benchmark requires no database or system configuration changes.
