#!/usr/bin/env python3
"""Serve a recorded NMEA 0183 log over TCP, the way a boat's gateway does.

    tools/nmea-replay.py [--port 10110] [--rate 1] [--once] [LOG]

The log defaults to test/annapolis.nmea, the port to 10110, which is what the
nmea0183 plugin dials unless the mariner says otherwise. Point a connection at
127.0.0.1:10110 and the app sees a boat under way, wind, depth and five AIS
targets, one of which closes to a collision alarm about a minute in.

Sentences are grouped the way the log is written, from one RMC to the next,
and a group goes out every second divided by `--rate`. The log restarts when
it runs out, and every client gets it from the top, so what a client sees does
not depend on when it connected.

This serves a RECORDED log and nothing else. It is not a source of live data
and must never be pointed at one: a frame or a fixture built from a real feed
carries other people's vessel names, MMSIs and positions.
"""

import argparse
import pathlib
import socket
import sys
import threading
import time

REPO = pathlib.Path(__file__).resolve().parent.parent


def groups(lines):
    """The log split into one-second groups, each starting at an RMC."""
    out, cur = [], []
    for ln in lines:
        if ln.startswith(b"$") and b"RMC" in ln[:9] and cur:
            out.append(cur)
            cur = []
        cur.append(ln)
    if cur:
        out.append(cur)
    return out


def serve(conn, addr, batches, period, once):
    print(f"client {addr[0]}:{addr[1]} connected", flush=True)
    sent = 0
    try:
        while True:
            for batch in batches:
                conn.sendall(b"\r\n".join(batch) + b"\r\n")
                sent += len(batch)
                time.sleep(period)
            if once:
                break
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        conn.close()
        print(f"client {addr[0]}:{addr[1]} gone after {sent} sentence(s)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", default=str(REPO / "test/annapolis.nmea"))
    ap.add_argument("--port", type=int, default=10110)
    ap.add_argument("--rate", type=float, default=1.0, help="x real time")
    ap.add_argument("--once", action="store_true", help="stop at the end of the log")
    a = ap.parse_args()

    path = pathlib.Path(a.log)
    if not path.exists():
        sys.exit(f"no log at {path} (zig run tools/nmea_gen.zig -- {path})")
    batches = groups(path.read_bytes().splitlines())
    period = 1.0 / a.rate if a.rate > 0 else 0.0

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", a.port))
    except OSError as e:
        sys.exit(f"cannot listen on 127.0.0.1:{a.port}: {e}")
    srv.listen(4)
    print(
        f"serving {path.name}, {len(batches)} group(s) at {a.rate}x "
        f"on 127.0.0.1:{a.port}. Ctrl-C to stop.",
        flush=True,
    )
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(
                target=serve, args=(conn, addr, batches, period, a.once), daemon=True
            ).start()
    except KeyboardInterrupt:
        print("stopped", flush=True)
    finally:
        srv.close()


if __name__ == "__main__":
    main()
