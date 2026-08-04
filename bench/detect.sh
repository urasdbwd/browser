#!/usr/bin/env bash
# Runs the bot-detection probe against a built binary and prints one line per
# check. Exits non-zero if any check FAILs, so it works as a CI gate.
#
#   bench/detect.sh [path-to-lightpanda] [port]
set -euo pipefail

BIN="${1:-zig-out/bin/lightpanda}"
PORT="${2:-8731}"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -x "$BIN" ] || { echo "no binary at $BIN — run 'make build' first" >&2; exit 2; }

python3 -m http.server "$PORT" --directory "$DIR" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

OUT=$("$BIN" fetch --stealth --log-level info \
        --inject-script-file "$DIR/detection_probe.js" \
        "http://127.0.0.1:$PORT/detection_probe.html" 2>&1 \
      | grep 'console.log' | sed 's/.*param\.0=//; s/param\.[0-9]*=//g')

echo "$OUT"
FAILED=$(echo "$OUT" | grep -c '^FAIL' || true)
[ "$FAILED" -eq 0 ] || { echo "$FAILED detection tell(s)" >&2; exit 1; }
