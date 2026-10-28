# Core API

`require "rayo"` loads the Linux worker loop and HTTP framework. See
[examples/hello.cr](examples/hello.cr) for a runnable app.

- `App#get/post/put/patch/delete/options/head(path) { |ctx| ... }` registers routes
  before `run(host: "0.0.0.0", port: 3000, workers: Sys.ncpu,
  database: ENV["DATABASE_URL"]?, pool: 4)`.
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
preallocated owner records. JSON and database Context extensions are loaded by App; see
[ARCHITECTURE.md](ARCHITECTURE.md) for their APIs.

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
peers. There is no chunked response streaming, TLS, automatic HEAD-to-GET
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

## JSON and Postgres integration measurements

The integrated suite passes 55 examples in both GC modes, including real Postgres
queries through two forked workers, ordered pipelines, concurrent peers, errors,
chained callbacks, disconnects, PG row arrays, JSON type checking, and warmed
allocation counters for JSON and request/database callbacks. `rayo/pg` and `rayo/json`
also compile independently without loading the server. `sys.cr` and `buf.cr` are
unchanged.

The JSON and PG examples were built with `--release -Dgc_none -Dwithout_mt` to
avoid the background runtime allocation described above. Servers ran on CPU 6,
the client on CPUs 7–8, using 100 connections, two seconds of concurrent warm-up
and eight seconds of measurement per route. Precise RSS was sampled every 500 ms
from `/proc/<pid>/smaps_rollup`; every sample after warm-up was identical.

| Route | Requests/s | Warmed RSS (KiB) |
| --- | ---: | ---: |
| `/json` | 44,457.7 | 19,968 → 19,968 |
| `/db` (users query, pool 4) | 27,432.7 | 20,204 → 20,204 |

The PG run used its own uniquely named database and dropped it afterward.
These are local measurements on a shared host. Reproduce the traffic with
`CONNECTIONS=100 SECONDS=8 REQUEST_PATH=/json PORT=3000 bin/keepalive`;
use `/db` against the PG example. The benchmark learns the response size once,
so the route must return a stable status, header length and body length.

Known integration gap: database callback captures are rejected before queuing
at runtime, rather than at compile time. The ordinary block-taking API cannot
perform the direct C-callback check; no capturing callback enters the PG queue.


## App-driven additions

The worker API now accepts `ports: Array(Int32)` and
`on_worker_start { |worker_index| ... }`. The hook runs after ring and PG setup and
before serving, in each child (index zero when running one worker). Multiple workers
fail before fork unless built with `-Dwithout_mt`, with or without the GC.

Crystal 1.22.1 starts `Fiber::ExecutionContext::Monitor`'s SYSMON pthread during
runtime startup. Native fork retains only the caller, while Crystal's Thread/Fiber
registries and locks remain copied. In the default GC, `gc/boehm.cr`'s collection
hook walks `Thread.unsafe_each` and uses each `gc_thread_handler` to update native
stack bottoms; Boehm's native fork handling cannot rebuild Crystal's registry.
A local probe confirmed both DEFAULT-0 and SYSMON records remain visible around
raw fork. A single explicit collection in that probe happened to succeed; it does
not make continuing with stale runtime records supported. This explains why the
library must reject that configuration instead of relying on a crash reproducer.
Use `--release -Dwithout_mt`, optionally adding `-Dgc_none`. Start application
threads only from the worker hook.

JSON writers are reusable reference objects. Context creates one with its output
buffer; custom `to_json` methods and nested blocks share its state. Standalone
callers create one writer, clear the buffer and call `reset` for each document.
Postgres results retain CommandComplete counts in `rows_affected` without changing
returned-row `size`.

Opt-in gzip (`app.gzip`, `app.gzip_min_size`, `ctx.compress = false`) uses one
compressor per worker. Optional `rayo/bcrypt` provides bounded asynchronous helper
jobs and composes with deferred database callbacks. Optional `rayo/sqlite` exposes
prepared statements and borrowed columns; `rayo/sqlite/group_commit` delays
responses until commit and rolls back failed batches. `JSON::Timestamp` supports
Postgres ISO timestamptz text and binary microseconds. See README for signatures,
view lifetimes and limits. `sys.cr` and `buf.cr` remain unchanged.

The expanded suite covers custom JSON separators/fields, fragmented affected-row
counts and real Postgres writes, multiworker hook indices, multiple listening ports,
gzip decompression/negotiation/opt-out and warmed allocations, bcrypt vectors and
helper completion, chained database/password callbacks, timestamp offsets/epochs,
SQLite bindings and commit/rollback during pipelined requests. CI runs both GC
modes with the default runtime and `-Dwithout_mt` on every kernel in the matrix.

All 69 examples pass in each of the four build combinations (default runtime or
`-Dwithout_mt`, with or without `-Dgc_none`), about 9–15 seconds per suite on the
shared host. Server fixtures exec the current spec executable to start a fresh
runtime. A raw-fork version of the default-runtime core fixture intermittently
crashed while dispatching accepts. Fresh-exec kernel runs later exposed the
independent ring rooting bug described below; the accept crash alone does not
establish a fork/GC failure. Raw fork still bypasses App's guard and continues
with inherited runtime threads. The exec fixtures preserve singleworker default
runtime coverage and retain actual multiworker coverage in the `-Dwithout_mt`
builds. The small raw-fork socket helpers perform only native syscalls in children.

Local native development symlinks under ignored `lib/` supplied the linker names
for the host's installed libdeflate/SQLite runtime libraries; CI installs the
corresponding development packages. No machine settings changed. Optional-driver memory checks run under the shared
benchmark lock.


Kernel testing with fresh runtimes exposed a concrete GC lifetime bug: the ring
table held managed `Ring` references in `LibC.malloc` storage, which the collector
does not scan. Bcrypt startup allocations could trigger collection and reclaim a
live ring before attaching its completion socket. The table now uses GC-scanned
`Pointer(Ring).malloc` storage. Forced collections during startup and between
requests cover ring lifetime in GC builds; no request-path allocation was added.
This is independent of the unsupported runtime fork configuration. Default-runtime
database allocation samples allow monitor noise; `-Dwithout_mt` samples still
require exactly zero. SQLite row iteration and bcrypt submissions also have warmed
managed-allocation checks.

### Optional-driver memory check

The release fixture built with `-Dgc_none -Dwithout_mt` stayed flat in every warmed
`smaps_rollup` RSS sample on 32 persistent connections. Each route warmed for two
seconds, then drove a three-second target window (finishing each in-flight batch).
The bcrypt route hashes and verifies through the loop at cost 10, exercising the
interleaved engine. SQLite reads reuse a statement prepared in the worker hook.
These are memory checks on a shared host, not throughput comparisons.

| Route | Requests in measurement | Warmed RSS (KiB) |
| --- | ---: | ---: |
| gzip | 54,144 | 19,204 → 19,204 |
| plain opt-out | 54,368 | 20,228 → 20,228 |
| bcrypt hash → verify | 64 | 20,372 → 20,372 |
| SQLite prepared read | 96,224 | 20,372 → 20,372 |

[Captured samples](benchmarks/wave2-memory.txt). Reproduce after installing the
native development packages (this host also used `LIBRARY_PATH=$PWD/lib/native`):

```sh
mkdir -p bin
crystal build spec/wave2_integration_spec.cr --release -Dgc_none -Dwithout_mt -o bin/wave2-load
flock /home/user/experiments/crystal-challenges/bench/.lock python3 benchmarks/wave2_memory.py bin/wave2-load
```

The script starts and stops only its recorded fixture PID, chooses two free ports,
and uses an in-memory SQLite database. It does not open Postgres or alter settings.
A compile spec also checks that `rayo/sqlite/group_commit` can be required directly;
its loop dependencies load without requiring the umbrella entry point first.
