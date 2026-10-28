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

## Planned API

```crystal
require "rayo"

app = Rayo::App.new

app.get "/" { |ctx| ctx.text "¡hola!" }

app.get "/users/:id" do |ctx|
  ctx.json { |j| j.object { j.field "id", ctx.param_i64("id") } }
end

app.run port: 3000
```

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

## Requirements

- Linux 6.1 or newer (io_uring features), x86-64 or arm64
- Crystal 1.22+
- libcrypto (OpenSSL 3) and libdeflate

## Development

```sh
crystal spec            # with the GC
crystal spec -Dgc_none  # without it: the request path must not allocate
```

Postgres specs use `RAYO_PG_URL` (default `postgres://postgres:postgres@127.0.0.1:5432/postgres`).

## License

MIT, see [LICENSE](LICENSE).
