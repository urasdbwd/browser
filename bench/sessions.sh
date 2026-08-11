#!/bin/sh
# Steady-state RSS per concurrent CDP session in `serve` mode.
#
#   bench/sessions.sh [binary] [counts]      # counts default "1 2 4 8 16"
#   LP_SERVE_ARGS="--v8-max-heap-mb 64" bench/sessions.sh   # A/B a serve flag
#
# `bench/run.sh` measures one page in one process; this measures what a second,
# third, ... simultaneous session costs the *same* process, which is the number
# that decides how many sessions fit on a small box. Each session is a real CDP
# WebSocket that creates a target, attaches and navigates the same node-dense
# fixture, so every isolate ends up holding a comparable DOM.
#
# Reports fixed overhead (the intercept of the line) and marginal MiB/session
# (its slope) rather than RSS/N, which flatters the number by amortising the
# fixed cost away.
set -eu

BIN=${1:-zig-out/bin/lightpanda}
COUNTS=${2:-"1 2 4 8 16"}

test -x "$BIN" || { echo "no such binary: $BIN" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

exec python3 - "$BIN" "$COUNTS" <<'PY'
import base64, json, os, re, resource, socket, struct, subprocess, sys, tempfile, threading, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BIN, COUNTS = sys.argv[1], [int(c) for c in sys.argv[2].split()]

# Node-dense, not byte-dense: lightpanda's per-page memory tracks node count.
# Same shape as bench/run.sh's fixture so the two numbers stay comparable.
ROWS = 4000
rows = "\n".join(
    '<div class="row r%d"><span>%d</span><a href="#%d">link</a></div>' % (i % 8, i, i)
    for i in range(ROWS)
)
FIXTURE = (
    "<!DOCTYPE html><html><head><title>bench</title></head><body>" + rows +
    '<script>let n=0;for(const el of document.querySelectorAll("div.row span"))'
    'n+=el.textContent.length;document.title="bench "+n;</script></body></html>'
)

work = tempfile.mkdtemp()
with open(os.path.join(work, "index.html"), "w") as f:
    f.write(FIXTURE)


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = ThreadingHTTPServer(("127.0.0.1", 0), lambda *a: Quiet(*a, directory=work))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d/index.html" % httpd.server_address[1]


# --- minimal WebSocket client -------------------------------------------------
# Python has no stdlib WS client. CDP needs exactly this much of RFC 6455:
# an HTTP Upgrade, masked client text frames, and unmasked server text frames.
class WS:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=60)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((
            "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError("handshake failed: %r" % head[:200])
        self.next_id = 0

    def _fill(self):
        chunk = self.s.recv(65536)
        if not chunk:
            raise RuntimeError("peer closed")
        self.buf += chunk

    def _need(self, n):
        while len(self.buf) < n:
            self._fill()

    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        payload = json.dumps(msg).encode()
        mask = os.urandom(4)
        n = len(payload)
        hdr = b"\x81" + (
            bytes([0x80 | n]) if n < 126 else
            b"\xfe" + struct.pack(">H", n) if n < 65536 else
            b"\xff" + struct.pack(">Q", n)) + mask
        self.s.sendall(hdr + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        return self.next_id

    def recv(self):
        while True:
            self._need(2)
            b0, b1 = self.buf[0], self.buf[1]
            n, off = b1 & 0x7F, 2
            if n == 126:
                self._need(4)
                n, off = struct.unpack(">H", self.buf[2:4])[0], 4
            elif n == 127:
                self._need(10)
                n, off = struct.unpack(">Q", self.buf[2:10])[0], 10
            if b1 & 0x80:
                raise RuntimeError("server must not mask frames")
            self._need(off + n)
            frame, self.buf = self.buf[off:off + n], self.buf[off + n:]
            op = b0 & 0x0F
            if op == 8:
                raise RuntimeError("server closed")
            if op == 1:
                return json.loads(frame)
            # ping/pong/binary: ignore

    def wait(self, pred):
        while True:
            m = self.recv()
            got = pred(m)
            if got is not None:
                return got

    def call(self, method, params=None, session=None):
        i = self.send(method, params, session)
        while True:
            m = self.recv()
            if m.get("id") != i:
                continue  # an event, or another command's reply
            if "error" in m:
                raise RuntimeError("%s: %s" % (method, m["error"]))
            return m.get("result", {})


# LP_SESSION_STAGE splits the marginal cost into isolate / page / DOM:
#   connect = WebSocket only (Browser + V8 isolate + inspector + http client)
#   target  = ... plus an attached about:blank page and its JS context
#   load    = ... plus the fixture's DOM (the default, and the real number)
#   release = load, then navigate back to about:blank (does the DOM come back?)
STAGE = os.environ.get("LP_SESSION_STAGE", "load")


def load_page(port):
    """One session: connect, create a target, attach, navigate, wait for load."""
    ws = WS(port)
    if STAGE == "connect":
        return ws
    tid = ws.call("Target.createTarget", {"url": "about:blank"})["targetId"]
    sid = ws.call("Target.attachToTarget", {"targetId": tid, "flatten": True})["sessionId"]
    ws.call("Page.enable", {}, sid)
    if STAGE == "target":
        return ws
    ws.send("Page.navigate", {"url": URL}, sid)
    ws.wait(lambda m: True if m.get("method") == "Page.loadEventFired" else None)
    # An isolate that silently failed to build the DOM would report a flattering
    # number, so make every session prove it is holding the fixture.
    got = ws.call("Runtime.evaluate", {
        "expression": 'document.querySelectorAll("div.row").length',
        "returnByValue": True,
    }, sid)["result"]["value"]
    if got != ROWS:
        raise RuntimeError("page not loaded: %r div.row, expected %d" % (got, ROWS))
    if STAGE == "release":
        # A serve-mode session outlives the pages it loads, so its steady state
        # is only "current page" if navigating away actually hands the DOM back.
        # If this stage matches `load` instead of `target`, it does not, and the
        # real per-session cost is the largest page the session ever held.
        ws.send("Page.navigate", {"url": "about:blank"}, sid)
        ws.wait(lambda m: True if m.get("method") == "Page.loadEventFired" else None)
    return ws


def rss_mib(pid):
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).strip()
    return int(out) / 1024.0


next_port = [9600 + (os.getpid() % 150)]


def measure(n):
    """Peak steady-state RSS of one server hosting n concurrent loaded sessions."""
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_before = usage.ru_utime + usage.ru_stime
    # A fresh port per measurement: the previous server's listener can still be
    # in TIME_WAIT when the next one starts.
    port = next_port[0]
    next_port[0] += 1
    srv = subprocess.Popen(
        [BIN, "serve", "--host", "127.0.0.1", "--port", str(port), "--log-level", "error"]
        + os.environ.get("LP_SERVE_ARGS", "").split(),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):  # wait for the listener
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("server never listened on %d" % port)
        time.sleep(0.3)
        idle = rss_mib(srv.pid)

        sessions, errs = [None] * n, []
        def run(i):
            try:
                sessions[i] = load_page(port)
            except Exception as e:  # noqa: BLE001 - reported, not swallowed
                errs.append(e)
        threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
        load_started = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        load_ms = (time.perf_counter() - load_started) * 1000
        if errs:
            raise errs[0]

        time.sleep(1.0)  # let GC/arenas settle into steady state
        loaded = rss_mib(srv.pid)
        for ws in sessions:
            ws.s.close()
        result = idle, loaded, load_ms
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()

    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_ms = (usage.ru_utime + usage.ru_stime - cpu_before) * 1000
    return result + (cpu_ms,)


print("binary        %s" % BIN)
print("%8s %10s %10s %12s %10s %10s" %
      ("sessions", "idle MiB", "RSS MiB", "delta MiB", "load ms", "CPU ms"))
pts = []
for n in COUNTS:
    idle, loaded, load_ms, cpu_ms = measure(n)
    pts.append((n, loaded))
    print("%8d %10.1f %10.1f %12.1f %10.0f %10.0f" %
          (n, idle, loaded, loaded - idle, load_ms, cpu_ms))

# Least-squares fit over all points: RSS = fixed + marginal * sessions. The
# slope is the number that decides how many sessions fit; the intercept is what
# a bigger box buys you once.
if len(pts) > 1:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    print("\nfixed overhead   %.1f MiB" % (my - slope * mx))
    print("marginal/session %.1f MiB" % slope)
    print("sessions in 1 GB %d" % int((1024 - (my - slope * mx)) / slope))
PY
