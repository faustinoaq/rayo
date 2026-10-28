# Rayo::PG

Require `rayo/pg` independently. This is a PostgreSQL v3 text-protocol client;
no shards are required. Authentication supports trust, cleartext passwords,
MD5, and SCRAM-SHA-256 through libcrypto.

```crystal
require "rayo/pg"

LOOKUP = Rayo::PG::Statement.new("SELECT id, name FROM users WHERE id = $1")

db = Rayo::PG::BlockingTransport.new(ENV["DATABASE_URL"])
begin
  db.query(LOOKUP, 42_i64, state: 123_i64) do |res, request_id|
    if res.error?
      STDERR.write(res.sqlstate)
      STDERR.write(res.message)
    elsif row = res.first?
      STDOUT.write(row.str(1))
    end
  end
  db.drain
ensure
  db.close
end
```

`query` queues work. `flush` sends queued work; it may also receive replies
when the socket is under backpressure. `drain` flushes and receives until all
callbacks finish. Callbacks run in queue order. Each query has its own Sync
boundary, so a SQL error does not discard later queries. Explicit SQL transactions
still obey PostgreSQL's transaction-abort rules.

Create statements once, before serving requests. Each connection sends named
Parse/Describe on first use, then Bind/Execute/Sync thereafter. Parameter types
are inferred by PostgreSQL; use SQL casts when context cannot infer them. A
failed Parse can be retried on a later query. Reusing a statement before that
failed Parse's response arrives can produce SQLSTATE 26000 for those queued uses.

Parameters accept `Int32`, `Int64`, `Bool`, `Nil`, `String`, `Bytes`, and
`Array`/`Slice` of `Int64` or `String`. Bytes are text parameter bytes, not the
binary representation of `bytea`. Text NUL bytes are rejected. Strings in arrays
are quoted and escaped, including the literal string `NULL`.

Callbacks must be non-capturing; capturing callbacks raise `ArgumentError` before
queuing. Pass `state: Int64` for IDs or `state: pointer` for caller-owned state.
The latter callback receives `Void*`, which can be cast to the original type.
State must stay alive until its callback finishes. Queries may be queued in a
callback; recursively driving receives or closing the connection is unsupported.
If a callback raises, its query is consumed; calling `drain` again continues
processing the remaining replies. Connection loss completes all pending callbacks
with SQLSTATE 08006, even if a callback raises, then re-raises the first exception.

`Result#size`, `first?`, and `each` expose rows. `Result#error?`, `sqlstate`, and
`message` expose errors as slices. Rows provide `size`, `null?(col)`, `i64(col)`,
`i32(col)`, `bool(col)`, and `str(col) : Bytes`. Accessing NULL as a value raises;
check `null?` first. Results, rows, and string slices are valid only during the
callback. Rows are collected in a reusable malloc buffer, then accessed without
allocating or copying individual columns. Large result sets grow that buffer;
they are not streamed a row at a time.

`row.each_i64(col) { |value| ... }` parses int8[] with nullable elements.
`row.each_array(col, scratch) { |bytes_or_nil| ... }` parses text[] into
caller-owned scratch, decoding quotes and backslashes. Each element expires at
the next yield. Scratch must fit the largest decoded element. These helpers
support one-dimensional arrays, including explicit lower bounds.

## Loop transport

`Conn.new(url, max_depth: 16384)` owns protocol state, not a socket. Connect to
`conn.host`/`conn.port`, then drive startup and queries with:

- `conn.output : Bytes`: the next send span; empty when no bytes are queued.
- `conn.on_sent(bytes_sent : Int32)`: acknowledge a positive partial/full send;
  zero or negative completions mark the connection lost.
- `conn.on_data(ptr, len)`: arbitrary receive fragments, including partial headers.
- `conn.ready?`, `alive?`, `pending`, `available?`, `max_depth`: scheduling state.
- `conn.lost`: notify EOF or transport failure; `conn.close`: release storage.

There must be at most one send in flight. The output pointer remains stable
until acknowledged, even while queries append to the other output buffer.
After a completion, check `output` again. After receiving startup authentication
messages, check `output` for password responses. The driver must stop driving
and release the socket after `close`. An external driver owns its fd and must
not free Conn while a send still references its output memory.

`BlockingTransport` implements this using raw sockets, nonblocking sends, and
poll for send backpressure. It handles DNS at startup and enables TCP_NODELAY.

## Pools and batching

`Pool.new(url, size: 4, max_depth: 1024)` owns blocking transports.
`Pool.new(connections)` wraps externally driven connections. `pick` chooses the
least queued live, ready connection, rotating ties. `pool.query` forwards to that
connection and raises `DepthError` when all pipelines are full. A single
connection raises `DepthError` before queuing beyond its configured depth.
Blocking pools provide `flush`, `drain`, and `close`; external drivers flush each
connection themselves. `close` releases wrapped connections too.

`Batch.new(capacity: 4096)` builds a reusable text array without allocating an
Array per batch. `add(Int64 | String | Bytes | Nil)`, `size`, `param`, `clear`,
and `close` support aggregation across requests:

```crystal
batch.add(10_i64)
batch.add(20_i64)
conn.query(FIND_MANY, batch.param, state: requests_pointer) do |res, state|
  # Fan results out using the caller's request table at state.
end
batch.clear
```

Use SQL such as `SELECT id FROM users WHERE id = ANY($1::int8[])`. `param` is
copied into the queued Bind message, so `clear` is safe immediately after
`query`. A batch supplies aggregation hooks; request routing and transaction or
group-commit policy belong to the caller.

## Lifetime and limits

Always explicitly close transports, connections, pools, and batches. Their raw
buffers are reused/grown with realloc and explicitly freed; they have no GC
finalizers. Precreate a bounded set of Statements. Statement registration and
connection authentication allocate once; warmed query/result processing does
not allocate managed objects. All state belongs to one worker, with no thread
safety or shared connection state.

URL schemes are `postgres` and `postgresql`, with percent-decoded credentials
and database, DNS/IPv4/IPv6 hosts, and a default port of 5432. Supported query
options are `application_name` and `sslmode=disable`. Connections are plaintext;
other sslmode values raise. TLS, Unix sockets, COPY, cancellation, automatic
reconnect, binary types, timestamp conversion, multidimensional array helpers,
and SCRAM password SASLprep normalization are not implemented. Notices,
notifications, parameter status, and backend key data are ignored.

The integration specs use `RAYO_PG_URL`, defaulting to
`postgres://postgres:postgres@127.0.0.1:5432/postgres`. They create and drop only
a uniquely named `rayo_pg_spec_*` database. Trust uses the server's configured
policy; cleartext/MD5/SCRAM exchanges also have deterministic protocol specs.
The suite includes 10k ordered queries and a warmed 100k-query RSS check.
