#!/bin/bash
# apollod end-to-end tests. Development tooling only: bash, curl, nc, xxd, lsof, md5, nm.
# Starts ./apollod on 127.0.0.1:8080, drives it, exits non-zero if any check fails.
set -u
cd "$(dirname "$0")/.." || exit 2
H=127.0.0.1; P=8080; U=http://$H:$P
pass=0; fail=0
ok()    { pass=$((pass+1)); echo "ok   $1"; }
flunk() { fail=$((fail+1)); echo "FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else flunk "$1: got '$2' want '$3'"; fi; }

[ -x ./apollod ] || { echo "build first: make"; exit 2; }
lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $P already in use"; exit 2; }
ulimit -n 8192 2>/dev/null || echo "note: could not raise ulimit -n (now $(ulimit -n)); the 2000-connection test needs >= 4200"
./apollod & SP=$!
T=$(mktemp -d)
trap 'kill $SP 2>/dev/null; wait $SP 2>/dev/null; rm -rf "$T"' EXIT
for i in $(seq 1 2000); do lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1 && break; done

alive() { kill -0 $SP 2>/dev/null && echo yes || echo no; }
code()  { curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$@"; }
body()  { curl -s --max-time 3 "$@"; }
hdr()   { local k=$1; shift; curl -s --max-time 3 -D - -o /dev/null "$@" | tr -d '\r' | awk -v k="$k:" 'tolower($1)==tolower(k){$1=""; sub(/^ /,""); print}'; }
raw()   { printf "$1" | nc $H $P; }                                  # complete requests only: nc waits for the server to close
tcp()   { /bin/bash -c "exec 3<>/dev/tcp/$H/$P; $1; exec 3>&-"; }   # send, then close without reading
mval()  { echo "$1" | awk -v k="$2" '$1==k{print $2}'; }

# --- status lines, headers, bodies
check "GET / status"                "$(code $U/)" 200
check "GET / body"                  "$(body $U/)" "apollo says hello"
check "GET / Content-Length"        "$(hdr Content-Length $U/)" 17
check "GET / Content-Type"          "$(hdr Content-Type $U/)" text/plain
check "GET / Connection"            "$(hdr Connection $U/)" close
check "GET /health status"          "$(code $U/health)" 200
check "GET /health body"            "$(body $U/health)" ok
check "GET /health?x=1 routes"      "$(body "$U/health?x=1")" ok
check "GET /nope status"            "$(code $U/nope)" 404
check "GET /nope Content-Length"    "$(hdr Content-Length $U/nope)" 9
check "GET /healthx status"         "$(code $U/healthx)" 404
check "POST / status"               "$(code -X POST $U/)" 405
check "POST / Allow"                "$(hdr Allow -X POST $U/)" "GET, HEAD"
check "PUT /nope status"            "$(code -X PUT $U/nope)" 405
check "HTTP/1.0 accepted"           "$(raw 'GET / HTTP/1.0\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 200 OK"

# --- HEAD: identical headers, no body
gh=$(raw 'GET / HTTP/1.1\r\n\r\n' | sed -n '1,/^\r$/p' | md5)
hh=$(raw 'HEAD / HTTP/1.1\r\n\r\n' | md5)
check "HEAD / == GET / headers, no body" "$hh" "$gh"
check "curl -I / status"            "$(curl -sI --max-time 3 -o /dev/null -w '%{http_code}' $U/)" 200

# --- byte-exact framing
check "CRLF CRLF then body"         "$(raw 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' | xxd -p | tr -d '\n' | grep -c '0d0a0d0a61706f6c6c6f')" 1
check "request split across reads"  "$(/bin/bash -c "exec 3<>/dev/tcp/$H/$P; printf 'GET /health HTTP/1.1\r\nHost: x' >&3; for i in \$(seq 1 20000); do :; done; printf '\r\n\r\n' >&3; cat <&3" | tail -c 2)" ok

# --- sequential load
n=0; for i in $(seq 1 100); do [ "$(code $U/)" = 200 ] && n=$((n+1)); done
check "100 sequential requests"     "$n" 100

# --- metrics
M0=$(body $U/metrics)
code $U/ >/dev/null; code $U/nope >/dev/null; code -X POST $U/ >/dev/null
curl -sI --max-time 3 -o /dev/null $U/health; raw '123 / HTTP/1.1\r\n\r\n' >/dev/null
M1=$(body $U/metrics)
d() { echo $(( $(mval "$M1" $1) - $(mval "$M0" $1) )); }
check "metrics requests_total +6"   "$(d requests_total)" 6
check "metrics requests_get +3"     "$(d requests_get)" 3       # / + /nope (404 is still a GET) + this scrape
check "metrics requests_head +1"    "$(d requests_head)" 1
check "metrics responses_200 +3"    "$(d responses_200)" 3
check "metrics responses_400 +1"    "$(d responses_400)" 1
check "metrics responses_404 +1"    "$(d responses_404)" 1
check "metrics responses_405 +1"    "$(d responses_405)" 1
check "metrics bytes_read grows"    "$([ "$(d bytes_read)" -gt 0 ] && echo yes)" yes
check "metrics bytes_written grows" "$([ "$(d bytes_written)" -gt 0 ] && echo yes)" yes
curl -s --max-time 3 -D "$T/h" -o "$T/b" $U/metrics
check "metrics Content-Length == body" "$(tr -d '\r' < "$T/h" | awk '/^Content-Length:/{print $2}')" "$(wc -c < "$T/b" | tr -d ' ')"
check "HEAD /metrics has no body"   "$(raw 'HEAD /metrics HTTP/1.1\r\n\r\n' | grep -c '^requests_total')" 0

# --- malformed input
check "empty method"                "$(raw ' / HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "invalid method"              "$(raw '123 / HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "lowercase method"            "$(raw 'get / HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "missing version"             "$(raw 'GET /\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "HTTP/2.0"                    "$(raw 'GET / HTTP/2.0\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "target without leading /"    "$(raw 'GET health HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "NUL bytes"                   "$(raw '\0\0\0 / HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "control byte in target"      "$(raw 'GET /\001 HTTP/1.1\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "8192 x A"                    "$(/bin/bash -c "exec 3<>/dev/tcp/$H/$P; head -c 8192 /dev/zero | tr '\0' A >&3; cat <&3" | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
tcp 'printf "GET / HTTP/1.1\r\nX-Big: " >&3; head -c 20000 /dev/zero | tr "\0" A >&3'
check "header larger than buffer: alive"   "$(alive)" yes
tcp 'head -c 65536 /dev/zero | tr "\0" A >&3'
check "64 KiB of A: alive"          "$(alive)" yes
tcp ':'
check "empty request: alive"        "$(alive)" yes
tcp 'printf "GET / HTTP/1.1\r\n" >&3'
check "incomplete CRLF, EOF: alive" "$(alive)" yes
tcp 'printf "GET / HTTP/1.1\n\n" >&3'
check "LF-only, EOF: alive"         "$(alive)" yes
tcp 'printf "GET / HTTP/1.1\r\n\r\n" >&3'
check "peer closes before reply: alive" "$(alive)" yes
check "still serving after abuse"   "$(body $U/)" "apollo says hello"

# --- headers
check "Host and Connection accepted" "$(raw 'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' | tail -c 2)" ok
check "lowercase header names"      "$(raw 'GET /health HTTP/1.1\r\nhost: x\r\nconnection: keep-alive\r\ncontent-length: 0\r\n\r\n' | tail -c 2)" ok
check "unknown headers ignored"     "$(raw 'GET /health HTTP/1.1\r\nX-A: 1\r\nUser-Agent: nc\r\nAccept: */*\r\n\r\n' | tail -c 2)" ok
check "50 headers"                  "$(raw "GET /health HTTP/1.1\r\n$(for i in $(seq 1 50); do printf 'X-H%d: v\\r\\n' $i; done)\r\n" | tail -c 2)" ok
check "Content-Length not numeric"  "$(raw 'GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "header without colon"        "$(raw 'GET / HTTP/1.1\r\nHost localhost\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "obs-fold continuation"       "$(raw 'GET / HTTP/1.1\r\nHost: a\r\n b\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"
check "control byte in header"      "$(raw 'GET / HTTP/1.1\r\nHost: a\001\r\n\r\n' | head -1 | tr -d '\r')" "HTTP/1.1 400 Bad Request"

# --- concurrency
/bin/bash -c "exec 3<>/dev/tcp/$H/$P; printf 'GET / HTTP/1.1\r\nHost: x' >&3; read -t 30 <&3" & HOLD=$!
check "partial request held open: others served" "$(code $U/health)" 200
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
pids=""
for i in $(seq 1 100); do /bin/bash -c "exec 3<>/dev/tcp/$H/$P; read -t 60 <&3" & pids="$pids $!"; done
for i in $(seq 1 100); do [ "$(lsof -p $SP 2>/dev/null | grep -c TCP)" -ge 101 ] && break; done
check "100 idle connections held: served"    "$(code $U/)" 200
check "100 idle connections held: alive"     "$(alive)" yes
kill $pids 2>/dev/null; wait $pids 2>/dev/null
check "after idle connections close: served" "$(code $U/)" 200
if command -v oha >/dev/null; then
    # a drained port pool (TIME_WAIT) fails the client, not the server
    if [ "$(netstat -an -p tcp | grep -c TIME_WAIT)" -gt 8000 ]; then
        echo "skip oha: ephemeral ports still in TIME_WAIT from an earlier run"
    else
        check "oha -c 64 -n 5000 success rate"  "$(oha -n 5000 -c 64 --no-tui $U/ | awk '/Success rate/{print $3}')" "100.00%"
    fi
fi

# --- idle timeout (10 s). bash 3.2 read -t returns 1 for both timeout and EOF, so measure elapsed seconds
M0=$(body $U/metrics)
r=$(/bin/bash -c "S=\$SECONDS; exec 3<>/dev/tcp/$H/$P; read -t 3 <&3; echo \$((SECONDS - S))")
check "idle 3 s: still open (client read ran its full 3 s)" "$([ "$r" -ge 3 ] && echo yes)" yes
r=$(/bin/bash -c "S=\$SECONDS; exec 3<>/dev/tcp/$H/$P; printf 'GET / HTTP/1.1\r\nHost: x' >&3; read -t 15 <&3; echo \$((SECONDS - S))")
check "idle with a partial request: server closed it at ~10 s" "$([ "$r" -ge 9 ] && [ "$r" -le 12 ] && echo yes)" yes
r=$(/bin/bash -c "exec 3<>/dev/tcp/$H/$P; printf 'GET / HTTP/1.1\r\nHost: x' >&3; read -t 6 <&3; printf '\r\nX-A: y' >&3; read -t 6 <&3; printf '\r\n\r\n' >&3; read -t 5 <&3; echo \$?")
check "bytes at 6 s reset the deadline: answered at 12 s" "$r" 0
M1=$(body $U/metrics)
check "metrics timeouts +1"                 "$(d timeouts)" 1

# --- 2000 connections from one process
if [ "$(ulimit -n)" -ge 4200 ]; then
    /bin/bash -c "for i in \$(seq 10 2009); do eval \"exec \$i<>/dev/tcp/$H/$P\" || exit 9; done; : > '$T/big-ready'; read -t 60 <&10" & BIG=$!
    for i in $(seq 1 100); do
        [ -f "$T/big-ready" ] && break
        kill -0 "$BIG" 2>/dev/null || break
        sleep 0.1
    done
    check "2000 connections held: client connected" "$([ -f "$T/big-ready" ] && echo yes || echo no)" yes
    for i in $(seq 1 100); do
        n=$(lsof -p $SP 2>/dev/null | grep -c TCP)
        [ "$n" -ge 2001 ] && break
        sleep 0.1
    done
    check "2000 connections held: all accepted" "$n" 2001
    check "2000 connections held: served"       "$(code $U/)" 200
    kill $BIG 2>/dev/null; wait $BIG 2>/dev/null
    for i in $(seq 1 100); do [ "$(lsof -p $SP 2>/dev/null | grep -c TCP)" -le 2 ] && break; done
    check "after 2000 close: served"            "$(code $U/)" 200
else
    echo "skip 2000-connection test: ulimit -n is $(ulimit -n)"
fi

# --- EMFILE: fd limit 40, 60 clients; some are accepted, never all
kill $SP 2>/dev/null; wait $SP 2>/dev/null
(ulimit -n 40; exec ./apollod) & SP=$!
for i in $(seq 1 2000); do lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1 && break; done
pids=""
for i in $(seq 1 60); do /bin/bash -c "exec 3<>/dev/tcp/$H/$P; read -t 60 <&3" & pids="$pids $!"; done
prev=-1; n=0
for i in $(seq 1 100); do n=$(lsof -p $SP 2>/dev/null | grep -c TCP); [ "$n" -ge 2 ] && [ "$n" = "$prev" ] && break; prev=$n; done
check "fd limit 40: some clients accepted, not all" "$([ "$n" -ge 2 ] && [ "$n" -lt 61 ] && echo yes)" yes
check "exhausted: alive"                     "$(alive)" yes
check "exhausted: new request waits"         "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' $U/)" 000
kill $pids 2>/dev/null; wait $pids 2>/dev/null
for i in $(seq 1 100); do [ "$(lsof -p $SP 2>/dev/null | grep -c TCP)" -le 2 ] && break; done
check "released: accepting again"            "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' $U/)" 200
check "released: alive"                      "$(alive)" yes

# --- binary: nothing imported
check "no undefined symbols"        "$(nm -u ./apollod | wc -l | tr -d ' ')" 0
check "no libc I/O or network symbols" "$(nm ./apollod | grep -cE ' _(socket|bind|listen|accept|read|write|close|malloc|printf|main)$')" 0

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
