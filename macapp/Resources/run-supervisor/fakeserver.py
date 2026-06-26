#!/usr/bin/env python3
"""A tiny rails-like dev server for the supervisor integration test (test_supervisor.py).

Mimics the behaviour that matters for teardown/orphan testing:
- binds a TCP port (so "is it still up?" is observable from outside),
- writes its pid to a pidfile and refuses to start if that pidfile holds a LIVE pid
  ("A server is already running (pid: N)") — exactly Rails' guard,
- clears a STALE (dead-pid) pidfile and starts (like Rails),
- on SIGINT, drains for FAKE_DRAIN seconds, removes its pidfile, then exits (graceful Ctrl-C).

Env: FAKE_PIDFILE (required), FAKE_PORT (default 3111), FAKE_DRAIN (default 0.3).
"""
import os
import sys
import time
import signal
import socket

PIDFILE = os.environ["FAKE_PIDFILE"]
PORT = int(os.environ.get("FAKE_PORT", "3111"))
DRAIN = float(os.environ.get("FAKE_DRAIN", "0.3"))

# Rails-style "already running" guard.
if os.path.exists(PIDFILE):
    try:
        pid = int(open(PIDFILE).read().strip() or "0")
    except ValueError:
        pid = 0
    alive = pid > 1
    if alive:
        try:
            os.kill(pid, 0)
        except OSError:
            alive = False
    if alive:
        sys.stderr.write("A server is already running (pid: %d).\n" % pid)
        sys.stderr.flush()
        sys.exit(1)
    try:
        os.remove(PIDFILE)  # stale (dead pid) -> clear and continue, like Rails
    except OSError:
        pass

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", PORT))
sock.listen(16)
with open(PIDFILE, "w") as f:
    f.write(str(os.getpid()))

draining_at = [None]


def on_int(_sig, _frame):
    if draining_at[0] is None:
        draining_at[0] = time.time()


signal.signal(signal.SIGINT, on_int)
# Puma IGNORES SIGHUP — so a bare PTY hangup (surface freed without a graceful stop) does NOT kill
# it; only the supervisor catching SIGHUP and SIGINTing it does. Mimic that, or the test can't catch
# the orphan bug.
signal.signal(signal.SIGHUP, signal.SIG_IGN)
sys.stdout.write("FAKE up pid=%d port=%d\n" % (os.getpid(), PORT))
sys.stdout.flush()

while True:
    if draining_at[0] is not None and time.time() - draining_at[0] >= DRAIN:
        try:
            sock.close()
        except OSError:
            pass
        try:
            os.remove(PIDFILE)
        except OSError:
            pass
        sys.exit(0)
    time.sleep(0.05)
