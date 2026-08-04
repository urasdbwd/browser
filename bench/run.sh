#!/bin/sh
# Cold-start wall time, peak RSS and binary size for `lightpanda fetch`.
#
#   bench/run.sh [binary] [iterations]
#
# Serves a node-dense fixture over loopback (lightpanda has no file:// support
# because curl is built with CURL_DISABLE_FILE) and fetches it repeatedly,
# reporting the median so a single slow run does not move the number.
set -eu

BIN=${1:-zig-out/bin/lightpanda}
ITERS=${2:-5}

test -x "$BIN" || { echo "no such binary: $BIN" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required to serve the fixture" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'kill "${SRV:-}" 2>/dev/null; wait "${SRV:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

# Node-dense, not byte-dense: lightpanda's per-page memory tracks node count.
{
	echo '<!DOCTYPE html><html><head><title>bench</title></head><body>'
	awk 'BEGIN { for (i = 0; i < 4000; i++)
		printf "<div class=\"row r%d\"><span>%d</span><a href=\"#%d\">link</a></div>\n", i%8, i, i }'
	echo '<script>
	let n = 0;
	for (const el of document.querySelectorAll("div.row span")) n += el.textContent.length;
	document.title = "bench " + n;
	</script></body></html>'
} > "$WORK/index.html"

# -u so the "Serving HTTP on ... port N" banner reaches the log immediately;
# port 0 lets the OS pick, which keeps concurrent benchmark runs from colliding.
python3 -u -m http.server --directory "$WORK" --bind 127.0.0.1 0 >"$WORK/srv.log" 2>&1 &
SRV=$!

PORT=""
i=0
while [ $i -lt 100 ]; do
	PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$WORK/srv.log")
	[ -n "$PORT" ] && break
	i=$((i + 1))
	sleep 0.1
done
[ -n "$PORT" ] || { echo "fixture server did not start" >&2; cat "$WORK/srv.log" >&2; exit 1; }

# macOS /usr/bin/time has no -f; GNU time has no -l. Normalise both to
# "<wall seconds> <peak rss kbytes>".
case $(uname -s) in
Darwin) measure() { /usr/bin/time -l "$@" 2>&1 >/dev/null |
	awk '/ real /{t=$1} /maximum resident set size/{r=$1} END{print t, r/1024}'; } ;;
*) measure() { /usr/bin/time -f '%e %M' "$@" 2>&1 >/dev/null | tail -1; } ;;
esac

URL="http://127.0.0.1:$PORT/index.html"
"$BIN" fetch --dump html "$URL" >/dev/null 2>&1 || { echo "warmup fetch failed" >&2; exit 1; }

i=0
while [ $i -lt "$ITERS" ]; do
	measure "$BIN" fetch --dump html "$URL"
	i=$((i + 1))
done > "$WORK/samples"

# Median each column independently; a slow run and a fat run need not be the
# same run.
median() { sort -n -k "$1","$1" "$WORK/samples" | awk -v c="$1" '{v[NR]=$c} END{print v[int((NR+1)/2)]}'; }

printf 'binary        %s\n' "$BIN"
printf 'binary bytes  %s\n' "$(wc -c < "$BIN" | tr -d ' ')"
printf 'cold start ms %.0f  (median of %s)\n' "$(median 1 | awk '{print $1*1000}')" "$ITERS"
printf 'peak rss MiB  %.1f  (median of %s)\n' "$(median 2 | awk '{print $1/1024}')" "$ITERS"
