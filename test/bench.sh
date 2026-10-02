#!/bin/bash
# apollod load benchmark. Development tooling only: oha (brew install oha) or ab.
# Usage: test/bench.sh [seconds] [concurrency]
# The server is single-threaded and blocking: concurrency > 1 measures queueing in the accept backlog.
set -u
cd "$(dirname "$0")/.." || exit 2
D=${1:-10}; C=${2:-8}; U=http://127.0.0.1:8080/
[ -x ./apollod ] || { echo "build first: make"; exit 2; }
lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 && { echo "port 8080 already in use"; exit 2; }
./apollod & SP=$!
trap 'kill $SP 2>/dev/null; wait $SP 2>/dev/null' EXIT
for i in $(seq 1 2000); do lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 && break; done

if command -v oha >/dev/null; then
    for c in 1 "$C"; do
        echo "== oha -z ${D}s -c $c $U"
        oha -z "${D}s" -c "$c" --no-tui "$U" | grep -E 'Success rate|Requests/sec|Slowest|Fastest|Average|50\.00%|95\.00%|99\.00%'
    done
elif command -v ab >/dev/null; then
    echo "== ab -t $D -c $C $U"
    ab -q -t "$D" -c "$C" "$U" | grep -E 'Requests per second|Failed requests|  50%|  95%|  99%'
else
    echo "no load generator found: brew install oha"; exit 2
fi
echo "== /metrics after load"
curl -s http://127.0.0.1:8080/metrics
echo "== TIME_WAIT: $(netstat -an -p tcp | grep -c TIME_WAIT) of $(( $(sysctl -n net.inet.ip.portrange.last) - $(sysctl -n net.inet.ip.portrange.first) + 1 )) ephemeral ports; wait 30 s before make test"
