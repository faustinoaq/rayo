#!/usr/bin/env bash
# Hold the shared benchmark lock across alternating entries. Run from this tree:
# flock /home/user/experiments/crystal-challenges/bench/.lock bash benchmarks/batch/run.sh
set -euo pipefail
root=/home/user/experiments/crystal-challenges
out=${1:-/tmp/rayo-batch-final}
mkdir -p "$out"
# A short probe precedes the recorded rounds so configuration mistakes are visible.
ENVS='-e WORKERS=2 -e PG_CONNS=2 -e BCRYPT_THREADS=2' bash "$root/bench/mcbox.sh" mc2 5502 "$root/bench/batch-mc" 3489 3000 0.1 5s 20s > "$out/probe.log" 2>&1
cp /tmp/lg-mc2.json "$out/probe.json"
echo "probe"
tail -7 "$out/probe.log"
for round in 1 2 3; do
  for entry in epoll rayo; do
    if [ "$entry" = epoll ]; then
      dir=$root/multicore-server-challenge/submissions/crystal-epoll-faustinoaq
      port=3488
      envs='-e WORKERS=2'
    else
      dir=$root/bench/batch-mc
      port=3489
      envs='-e WORKERS=2 -e PG_CONNS=2 -e BCRYPT_THREADS=2'
    fi
    ENVS="$envs" bash "$root/bench/mcbox.sh" mc2 5502 "$dir" "$port" 3000 > "$out/$entry-$round.log" 2>&1
    cp /tmp/lg-mc2.json "$out/$entry-$round.json"
    echo "$entry round $round"
    tail -7 "$out/$entry-$round.log"
  done
done
