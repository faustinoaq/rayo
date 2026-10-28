# Conduit read batching comparison

`conduit.patch` applies to the read-only rw-mc Rayo submission at framework
commit c5358eda5b209dec85eda8dc4ca703e727065b6f. Apply it in a copy of that
submission, update the Rayo dependency to this branch's commit, and rebuild.
For the local experiment only, `shard.yml` uses
`path: /home/user/experiments/rayo-batch`; run `shards install` without `--frozen`
when changing sources. The original submission stays untouched.

The patch replaces the application's Deque/round scheduling policy with
`PG::Coalescer(Request)`. It retains application-specific page selection, shared
article enrichment, viewer flags and response serialization. User and profile
reads gain ordinal array queries matching the reference entry. Nothing is cached
across requests.

Eight reusable round slots share the existing two read transports per worker.
Groups have up to 1,024 requests, a bounded 32-group queue and depth eight. The
collection window is 12.5 ms per observed in-flight group, capped at 25 ms; idle
arrivals dispatch in the same loop turn. Each group calls `done` after its last
query/fan-out. Dedicated read sessions keep the reference's planner settings.

Both entries use two workers. Rayo uses two ordinary plus two read connections
per worker; the reference uses four connections per worker. Both use two bcrypt
helpers per worker. The application retains its GC-enabled collections; the
coordinator itself is checked with both GC modes and allocation measurements.
Write group commit and the rest of the application remain unchanged.

Run on the shared eight-core mc2 box after building the patched copy:

```sh
flock /home/user/experiments/crystal-challenges/bench/.lock \
  bash benchmarks/batch/run.sh
```

The script holds the benchmark lock across a short probe followed by three
alternating reference/Rayo pairs. Each recorded run calls the requested
`mcbox.sh mc2 5502 <dir> <port> 3000` with its default 30-second ramp,
60-second measurement, 5-second tail and think scale 0.1. It preserves both the
load-generator JSON and the CPU split output under `/tmp/rayo-batch-final`.
Ports 3488/3489 belong to this experiment. The existing mcbox harness owns startup,
its isolated box seed reset, and shutdown for those ports.

CPU-seconds from mcbox include ramp and tail, whereas request counts/req/s cover
the measurement interval. Dividing those CPU totals by measured requests gives a
consistent comparison proxy, rather than an isolated steady-state CPU cost.
