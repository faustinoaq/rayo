`request_path.cr` measures HTTP parsing, context reset, routing, JSON serialization,
response framing and buffer reuse without SQL or network latency. `/hello` writes
text, `/json` writes scalar fields, `/posts/123` captures a parameter and serializes
borrowed bytes, and `/feed` serializes twenty objects. Requests include ordinary
wrk headers. Each case warms its buffers before measurement and reports elapsed
nanoseconds per request, managed bytes allocated and response size.

Build with the same compiler and CPU target for both revisions:

```sh
crystal build benchmarks/request_path.cr --release --mcpu x86-64-v3 \
  -Dwithout_mt -Dgc_none -o bin/request-path
```

Run every benchmark under the shared lock. Compare saved baseline and candidate
binaries in at least three alternating rounds; smaller ns/request is better.
The single-thread build should report zero managed bytes allocated. `ITERATIONS`
defaults to one million iterations per route.

```sh
flock /home/user/experiments/crystal-challenges/bench/.lock \
  taskset -c 6 bin/request-path
```

`SERVE=1` runs the same four routes through the complete io_uring server. `PORT`
defaults to 3000. This example holds the lock across startup, load and shutdown;
it records only the PID it starts. Repeat with alternating binaries to compare
networking and loop overhead too.

```sh
flock /home/user/experiments/crystal-challenges/bench/.lock bash -c '
  SERVE=1 PORT=18998 taskset -c 6 bin/request-path > /tmp/request-path.log 2>&1 &
  pid=$!
  trap '\''kill "$pid"; wait "$pid" 2>/dev/null || true'\'' EXIT
  until curl -sf http://127.0.0.1:18998/hello >/dev/null; do sleep 0.1; done
  for route in hello json posts/123 feed; do
    docker exec crdev taskset -c 10-11 wrk -t2 -c256 -d3s \
      http://127.0.0.1:18998/$route >/dev/null
    docker exec crdev taskset -c 10-11 wrk --latency -t2 -c256 -d15s \
      http://127.0.0.1:18998/$route
  done
'
```

Measure profiles separately from throughput runs: sampling changes scheduling
and can distort latency. The SQLite challenge additionally needs fresh database
copies, its shared feed/mix Lua workloads and the identical SQLite archive for
both servers. This microbenchmark deliberately removes those application costs.
