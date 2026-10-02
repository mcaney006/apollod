#!/bin/bash
# apollod vs apollod-min: source, object and Mach-O sizes, section sizes, imports, instruction counts.
# Development tooling only. Run after `make apollod apollod-min`.
set -u
cd "$(dirname "$0")/.." || exit 2
[ -x apollod ] && [ -x apollod-min ] || { echo "build first: make apollod apollod-min"; exit 2; }

sec()   { size -m "$1" | awk -v s="$2:" '$1=="Section" && $2==s {gsub(/[^0-9]/,"",$3); print $3}'; }
insns() { otool -tv "$1" | grep -cE '^[0-9a-f]{16}'; }
# instructions under the named symbols (local L labels fold into the preceding symbol)
path()  { local bin=$1; shift; otool -tv "$bin" | awk -v want="$*" '
    BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    /^[A-Za-z_][A-Za-z0-9_]*:$/ { f = substr($1, 1, length($1) - 1) }
    /^[0-9a-f]{16}/ { if (f in w) c++ }
    END { print c + 0 }'; }

row() { printf '%-30s %12s %12s\n' "$1" "$2" "$3"; }
row "" apollod apollod-min
row "source bytes"        "$(cat src/apollod.s src/lib.s | wc -c | tr -d ' ')" "$(wc -c < min/apollod-min.s | tr -d ' ')"
row "source lines"        "$(cat src/apollod.s src/lib.s | wc -l | tr -d ' ')" "$(wc -l < min/apollod-min.s | tr -d ' ')"
row "object bytes"        "$(cat build/apollod.o build/lib.o | wc -c | tr -d ' ')" "$(wc -c < build/apollod-min.o | tr -d ' ')"
row "Mach-O bytes"        "$(wc -c < apollod | tr -d ' ')" "$(wc -c < apollod-min | tr -d ' ')"
for s in __text __const __data __bss; do row "$s bytes" "$(sec apollod $s)" "$(sec apollod-min $s)"; done
row "dylibs loaded"       "$(otool -L apollod | tail -n +2 | wc -l | tr -d ' ')" "$(otool -L apollod-min | tail -n +2 | wc -l | tr -d ' ')"
row "undefined symbols"   "$(nm -u apollod | wc -l | tr -d ' ')" "$(nm -u apollod-min | wc -l | tr -d ' ')"
row "instructions, total" "$(insns apollod)" "$(insns apollod-min)"
row "instructions, request path" \
    "$(path apollod next_event on_readable read_more read_scan read_cont request_complete route send_response on_writable close_conn parse_request parse_headers span_eq)" \
    "$(path apollod-min accept_loop)"
echo
echo "request path: static count under next_event..close_conn, parse_request, parse_headers, span_eq; min: accept_loop"
