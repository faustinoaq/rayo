"""Warmed RSS check for the optional-driver integration fixture (run under flock)."""
import os
import socket
import subprocess
import sys
import time


def response(reader):
    status = reader.readline()
    if not status.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {status!r}")
    length = 0
    while True:
        line = reader.readline()
        if line == b"\r\n":
            break
        if not line:
            raise RuntimeError("server closed while reading headers")
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    if len(reader.read(length)) != length:
        raise RuntimeError("short response body")


def rss(pid):
    with open(f"/proc/{pid}/smaps_rollup") as source:
        for line in source:
            if line.startswith("Rss:"):
                return int(line.split()[1])
    raise RuntimeError("RSS unavailable")


reserved = [socket.socket() for _ in range(2)]
for listener in reserved:
    listener.bind(("127.0.0.1", 0))
ports = [listener.getsockname()[1] for listener in reserved]
for listener in reserved:
    listener.close()
env = dict(os.environ, RAYO_SPEC_FIXTURE="features", RAYO_SPEC_PORTS=",".join(map(str, ports)),
           RAYO_SPEC_BCRYPT_COST=os.environ.get("RAYO_SPEC_BCRYPT_COST", "10"))
print(f"bcrypt_cost={env['RAYO_SPEC_BCRYPT_COST']} warmup_seconds=2 measure_seconds=3", flush=True)
server = subprocess.Popen([sys.argv[1]], env=env)
try:
    deadline = time.monotonic() + 5
    while True:
        try:
            probe = socket.create_connection(("127.0.0.1", ports[0]), timeout=2)
            probe.close()
            break
        except ConnectionRefusedError:
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("fixture failed to start")
            time.sleep(0.01)
    for path in ("/gzip", "/plain", "/hash", "/count"):
        peers = [socket.create_connection(("127.0.0.1", ports[0]), timeout=5) for _ in range(32)]
        readers = [peer.makefile("rb") for peer in peers]
        request = f"GET {path} HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n".encode()

        def turn():
            for peer in peers:
                peer.sendall(request)
            for reader in readers:
                response(reader)

        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                turn()
            samples = [rss(server.pid)]
            deadline = time.monotonic() + 3
            next_sample = time.monotonic() + 0.5
            count = 0
            while time.monotonic() < deadline:
                turn()
                count += len(peers)
                if time.monotonic() >= next_sample:
                    samples.append(rss(server.pid))
                    next_sample += 0.5
            print(f"{path}: connections=32 requests={count} warmed_RSS_KiB={samples}", flush=True)
            if len(set(samples)) != 1:
                raise RuntimeError(f"warmed RSS changed for {path}")
        finally:
            for reader in readers:
                reader.close()
            for peer in peers:
                peer.close()
finally:
    if server.poll() is None:
        server.terminate()
    server.wait(timeout=5)
