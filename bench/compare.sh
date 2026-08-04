#!/usr/bin/env bash
# A/B two lightpanda binaries on the same fixture, same machine, interleaved.
#
#   bench/compare.sh <baseline-binary> <candidate-binary> [iters]
#
# Reports wall time, CPU time (user+sys) and peak RSS. Runs are interleaved
# rather than batched so a thermal or load drift hits both sides equally --
# batching A then B is how you accidentally measure the machine warming up.
set -euo pipefail

A="${1:?usage: compare.sh <baseline> <candidate> [iters]}"
B="${2:?usage: compare.sh <baseline> <candidate> [iters]}"
ITERS="${3:-7}"

for bin in "$A" "$B"; do
  [ -x "$bin" ] || { echo "not executable: $bin" >&2; exit 2; }
done

WORK=$(mktemp -d)
trap 'kill "${SRV:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Node-dense, not byte-dense: per-page memory tracks node count, not file size.
#
# Sized so total CPU lands in seconds, not milliseconds. /usr/bin/time resolves
# to 10ms on macOS, so a workload that costs 80ms of CPU cannot show a
# difference smaller than ~12% no matter how many iterations you average --
# the samples quantise to the same two or three values and every delta reads
# as exactly 0.0%. Heavier fixture, real resolution.
NODES="${NODES:-40000}"
{
  echo '<!DOCTYPE html><html><head><title>bench</title></head><body>'
  awk -v n="$NODES" 'BEGIN { for (i = 0; i < n; i++)
    printf "<div class=\"row r%d\" data-i=\"%d\"><span>%d</span><a href=\"#%d\">link</a></div>\n", i%8, i, i, i }'
  echo '<script>
  // Parse-bound, selector-bound and JS-bound work in one page, so a win in any
  // one of the three shows up.
  let n = 0;
  for (let pass = 0; pass < 8; pass++) {
    for (const el of document.querySelectorAll("div.row span")) n += el.textContent.length;
    n += document.querySelectorAll("div.r3 a").length;
    n += document.getElementsByClassName("row").length;
  }
  const rows = document.querySelectorAll("div.row");
  for (let pass = 0; pass < 4; pass++) {
    for (const el of rows) { el.setAttribute("data-x", el.getAttribute("data-i")); n += el.children.length; }
  }
  document.title = "bench " + n;
  </script></body></html>'
} > "$WORK/index.html"

python3 -u -m http.server --directory "$WORK" --bind 127.0.0.1 0 >"$WORK/srv.log" 2>&1 &
SRV=$!
PORT=""
for _ in $(seq 100); do
  PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$WORK/srv.log")
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { echo "fixture server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/index.html"

# Normalise macOS (-l, bytes) and GNU (-f %M, KiB) to "<wall s> <user s> <sys s> <rss MiB>".
case $(uname -s) in
Darwin) measure() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '
  / real /{w=$1; u=$3; s=$5} /maximum resident set size/{r=$1}
  END{print w, u, s, r/1048576}'; } ;;
*) measure() { /usr/bin/time -f '%e %U %S %M' "$@" 2>&1 >/dev/null | tail -1 |
  awk '{print $1, $2, $3, $4/1024}'; } ;;
esac

# Warm the page cache for both so neither pays the first-read cost.
"$A" fetch --dump html "$URL" >/dev/null 2>&1 || { echo "baseline warmup failed" >&2; exit 1; }
"$B" fetch --dump html "$URL" >/dev/null 2>&1 || { echo "candidate warmup failed" >&2; exit 1; }

: > "$WORK/a"; : > "$WORK/b"
for _ in $(seq "$ITERS"); do
  measure "$A" fetch --dump html "$URL" >> "$WORK/a"
  measure "$B" fetch --dump html "$URL" >> "$WORK/b"
done

med() { sort -n -k "$2","$2" "$WORK/$1" | awk -v c="$2" '{v[NR]=$c} END{print v[int((NR+1)/2)]}'; }

row() { # label unit scale
  local la lb d
  la=$(med a "$4"); lb=$(med b "$4")
  d=$(awk -v a="$la" -v b="$lb" 'BEGIN{ if (a==0) print "n/a"; else printf "%+.1f%%", (b-a)/a*100 }')
  awk -v n="$1" -v u="$2" -v s="$3" -v a="$la" -v b="$lb" -v d="$d" \
    'BEGIN{ printf "%-16s %10.1f %10.1f %10s   %s\n", n, a*s, b*s, d, u }'
}

echo "fixture       ${NODES}-row DOM, 8 selector passes + 4 attribute passes, median of $ITERS interleaved runs"
printf '%-16s %10s %10s %10s\n' "" "baseline" "candidate" "delta"
row "wall time"  ms   1000 1
row "cpu user"   ms   1000 2
row "cpu sys"    ms   1000 3
row "peak rss"   MiB  1    4
printf '%-16s %10d %10d %10s   %s\n' "binary size" \
  "$(wc -c < "$A")" "$(wc -c < "$B")" \
  "$(awk -v a="$(wc -c < "$A")" -v b="$(wc -c < "$B")" 'BEGIN{printf "%+.1f%%", (b-a)/a*100}')" bytes
echo
echo "baseline  $A"
echo "candidate $B"
