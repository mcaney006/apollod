# apollod

An HTTP/1.x daemon for Apple Silicon macOS, written in ARM64 assembly. It
reaches the XNU kernel through `svc #0x80` and imports no symbols. One thread
runs a kqueue event loop over a fixed table of 4096 connections, each with
its own idle deadline, and updates its counters with LSE atomics. The 1,220
lines of source assemble to 837 instructions.

    curl -i http://127.0.0.1:8080/

`apollod-min`, a second configuration, answers every connection with `OK` in
66 instructions. The last section measures the two side by side.

## build

    make                 # as + ld; the Makefile shows the exact commands
    make run
    make test            # assembly unit harness, end-to-end (curl, nc), import check
    make bench           # oha or ab against a fresh server
    make apollod-min
    make compare         # apollod vs apollod-min: sizes, imports, instruction counts
    make disasm          # otool -tv
    make inspect         # otool -hv / -l / -L, nm -m, size -m
    make verify-imports  # fails if nm -u is not empty
    make clean

The toolchain is Xcode Command Line Tools `as` and `ld`, with no clang driver
and no crt objects. The link line is `-e _start -lSystem -syslibroot $(SDK)`.
`ld` needs `-lSystem` to emit `LC_LOAD_DYLINKER` for a dynamic executable;
the binary imports nothing from it. `.arch_extension lse` in the source lets
the assembler accept the ARMv8.1 atomics. The build targets current macOS on
Apple Silicon, where every core has them, so no runtime detection exists.

`ld -static` links an `LC_UNIXTHREAD` executable, and the kernel kills that
at `exec` with SIGKILL (exit status 137), so a dynamic executable with zero
imports is the lowest layer the platform allows.

## run

    ulimit -n 8192       # the default 256 caps the server near 250 clients
    ./apollod            # 127.0.0.1:8080, backlog 128, runs until killed

A fatal error during startup exits with a code: 1 socket, 2 setsockopt,
3 bind, 4 listen, 5 accept, 6 fcntl, 7 kqueue, 8 kevent. An error on a
client connection closes that connection and the listener keeps running.

## architecture

    _start
      socket, setsockopt(SO_REUSEADDR), setsockopt(SO_NOSIGPIPE)   accepted sockets inherit NOSIGPIPE
      bind(127.0.0.1:8080), listen(128), fcntl(O_NONBLOCK)
      kqueue(), kevent(listener, EVFILT_READ, EV_ADD)
    wait_events
      kevent(kq, NULL, 0, events, 64, NULL)
    next_event                            timer events dispatch by generation, socket events by slot state
      listener  -> on_accept              accept until EAGAIN; fcntl O_NONBLOCK; slot = READING, gen++;
                                          one kevent: EV_ADD read + EV_ADD|EV_ONESHOT 10 s timer, udata = gen
      timer     -> on_timeout             gen matches and the slot is live: count, close
      READING   -> on_readable            read until CRLFCRLF, buffer full, EAGAIN, EOF, or error
                                          EAGAIN after new bytes: re-arm the timer
                   parse_request          METHOD SP target SP HTTP/1.x CRLF
                   parse_headers          name ":" OWS value CRLF ... CRLF
                   route                  span compare against /, /health, /metrics
                   send_response          slot = WRITING, response pointer and length recorded
      WRITING   -> on_writable            write what remains; EAGAIN: EV_DISABLE read, EV_ADD|EV_ONESHOT write,
                                          re-arm the timer if bytes went out
      done      -> close_conn             EV_DELETE the timer (ENOENT if it fired), slot = FREE, close(2)

A connection costs seven syscalls on the happy path (accept, fcntl, kevent,
read, write, kevent, close) plus a share of one kevent wait per batch.

The connection table uses the fd as the slot index. A slot holds 64 bytes
(`CONN_STATE`, `CONN_REQ_LEN`, `CONN_RESP_PTR`, `CONN_RESP_OFF`,
`CONN_RESP_LEN`, `CONN_GEN`) and owns an 8 KiB request buffer in
`conn_bufs`. `on_accept` closes any fd at or beyond 4096. When `accept`
returns `EMFILE`, `ENFILE` or `ENOBUFS`, the loop disables the listener's
filter until a connection closes; a full descriptor table parks new
connections in the backlog and the loop does not spin.

Every connection gets a one-shot `EVFILT_TIMER` with ident = fd,
data = 10000 ms and udata = the slot's generation. The `kevent` call that
registers the read filter arms it, progress in either direction re-arms it,
and `release_fd` deletes it at close. The kernel keys a timer by its number,
so it survives `close(2)`, and a fired one-shot can still sit in a batch after its
connection closed and the fd went to a new client. `on_timeout` therefore
compares the event's udata with the slot's current generation and ignores a
mismatch. Ten seconds without progress close the connection with no reply
and add one to `timeouts`. A client that keeps sending stays connected until
the 8 KiB buffer fills.

| file | contents |
|---|---|
| `src/apollod.s` | syscall layer, socket setup, event loop, connection table, timers, reader, writer, routing, responses, counters, metrics builder |
| `src/lib.s` | routines with no syscalls: `parse_request`, `parse_headers`, `span_eq`, `span_ieq`, `u64_to_ascii`, `copy_span` |
| `min/apollod-min.s` | the minimal configuration |
| `test/unit.s` | assembly harness linked against `lib.o`; 52 checks; exit status = first failing check |
| `test/e2e.sh` | 74 checks over the wire with curl, nc, and bash `/dev/tcp` |
| `test/bench.sh`, `test/compare.sh` | load benchmark; apollod vs apollod-min table |
| `AUDIT.md` | buffers, bounds, state machine, syscall results, register ownership |
| `DEBUG.md` | lldb recipes |

## counters

The counters update with `stadd` (`ldadd` with the result discarded), one
ARMv8.1 LSE instruction:

    adrp    x9, counters@PAGE
    add     x9, x9, counters@PAGEOFF
    add     x9, x9, #C_REQ_TOTAL
    mov     x10, #1
    stadd   x10, [x9]

A `ldr` / `add` / `str` sequence leaves a window between the load and the
store. A second thread or process sharing the page can read the same old
value inside that window, and one increment disappears. `stadd` performs the
read-modify-write as one atomic operation at the memory system (the core can
hand it to the L2 or the interconnect as a far atomic), so concurrent
increments to the same word serialize. The operation is "add to a word", so
a compare-and-swap loop with `ldxr`/`stxr` retries has no role. The counters
carry no ordering obligation toward other data, which makes the relaxed form
without acquire or release semantics both correct and the cheapest.
`build_metrics` reads each counter with an aligned 8-byte `ldr`, which ARMv8
guarantees single-copy atomic, so a reader sees a whole old or new value.
Every Apple Silicon core implements FEAT_LSE (`sysctl
hw.optional.arm.FEAT_LSE` reports 1), the build targets nothing else, and
`test/unit.s` checks 51 and 52 execute `stadd` and `ldadd` on the running
machine. apollod runs one thread; the macros do not depend on that.

## syscall ABI

Darwin arm64 puts the syscall number in `x16` and the arguments in `x0` to
`x5`, then executes `svc #0x80`. On return either the carry flag is clear
and `x0` holds the result, or the carry flag is set and `x0` holds errno.
Darwin never returns a negative errno in `x0`. `test/unit.s` check 1
verifies the convention on the running machine (`write` to fd -1 must set C
and return `EBADF` = 9), and the server branches on `b.cs` or `b.cc` after
every `svc`. The kernel writes back both `x0` and `x1` on return, so every
call reloads all of its arguments.

Numbers, from `$(SDK)/usr/include/sys/syscall.h`:

| syscall | x16 | | syscall | x16 |
|---|---|---|---|---|
| exit | 1 | | socket | 97 |
| read | 3 | | bind | 104 |
| write | 4 | | setsockopt | 105 |
| close | 6 | | listen | 106 |
| accept | 30 | | kqueue | 362 |
| fcntl | 92 | | kevent | 363 |

Constants from `sys/socket.h`, `netinet/in.h`, `sys/fcntl.h`, `sys/event.h`
and `sys/errno.h`: `AF_INET` 2, `SOCK_STREAM` 1, `SOL_SOCKET` 0xffff,
`SO_REUSEADDR` 0x0004, `SO_NOSIGPIPE` 0x1022, `F_SETFL` 4, `O_NONBLOCK` 0x4,
`EVFILT_READ` -1, `EVFILT_WRITE` -2, `EVFILT_TIMER` -7, `EV_ADD` 0x1,
`EV_DELETE` 0x2, `EV_ENABLE` 0x4, `EV_DISABLE` 0x8, `EV_ONESHOT` 0x10,
`EV_ERROR` 0x4000, `ENOENT` 2, `EINTR` 4, `ENFILE` 23, `EMFILE` 24,
`EAGAIN` 35, `ECONNABORTED` 53, `ENOBUFS` 55. `EVFILT_TIMER` interprets
`data` as milliseconds when `fflags` is 0 (kqueue(2)).

`struct kevent` in a 64-bit process occupies 32 bytes: `ident` u64 at 0,
`filter` i16 at 8, `flags` u16 at 10, `fflags` u32 at 12, `data` i64 at 16,
`udata` at 24. `sockaddr_in` follows the BSD layout with `sin_len` first,
written by hand in network byte order:

    .byte 16, 2             sin_len, sin_family
    .byte 0x1f, 0x90        sin_port = 8080
    .byte 127, 0, 0, 1      sin_addr
    .byte 0 (x8)            sin_zero

`otool -s __TEXT __const apollod` shows the bytes as linked.

The code relies on three kernel behaviors, and a check covers each:

- `SO_NOSIGPIPE` set on the listener reaches accepted sockets (`sonewconn`
  copies it). Unit check 50 verifies this in-process with connect, accept
  and getsockopt.
- `close(2)` removes an fd's read and write filters and leaves a timer keyed
  by the same number in place. The e2e suite would misfire on reused fds if
  the code assumed otherwise.
- `EV_DELETE` on a one-shot timer that has fired returns `ENOENT`.

## register convention

Callee-saved registers hold the state of the connection in hand:

| register | owner |
|---|---|
| x19 | listening socket |
| x20 | client socket of the current event |
| x21 | that connection's request buffer |
| x22 | request length: bytes read, the only length the code trusts |
| x23 | parser cursor |
| x24 | method: 0 GET, 1 HEAD; reset per readable event |
| x25, x26 | route span: pointer, length, query stripped |
| x27, x28 | response pointer, response header length |
| x9, x10 | counter scratch (`count` macros) |
| x11 | slot pointer, recomputed after every call |
| x12 to x14 | scratch |
| x16 | syscall number and nothing else |

Internal routines take arguments in `x0` to `x6` and return in `x0`; the
source lists each routine's clobbers next to it. `parse_request`,
`parse_headers`, `build_metrics`, `kev_change`, `timer_fill` and
`release_fd` save `lr` because they call other routines, and `kev_fill` and
`kev_submit` are leaves. Each of the six uses one 16-byte stack frame and
nothing else touches the stack.

## memory layout

Everything is static. There is no heap, no allocation and no runtime.

| region | size | purpose |
|---|---|---|
| `__TEXT,__text` | 3348 B, 837 instructions | code |
| `__TEXT,__const` | 1058 B | sockaddr, path and header literals, five static responses, metrics header pieces, metric name table |
| `__DATA,__data` | 108 B | ten 8-byte counters, event cursor, `kq`, `accept_paused`, the `int one` |
| `__DATA,__bss` | 33,818,720 B | `conn_bufs` 4096 x 8192, `conn_table` 4096 x 64, `events` 64 x 32, `kev_chg` 3 x 32 |

Every load and store addresses a structure through an `.equ` offset
(`CONN_*`, `KEV_*`, `C_*`, `MT_*`); no bare numeric offset appears in the
code. The assembler checks the shifts (`CONN_SHIFT`, `REQ_SHIFT`,
`KEV_SHIFT`) against the sizes. The metric table stores name offsets
relative to `mnames`, so `__TEXT` needs no relocations and `dyld_info
-fixups` prints nothing.

A static response is a header followed by its body in one contiguous block,
and the assembler checks every `Content-Length` against the body bytes
(`.if ... .error`). `build_metrics` writes `/metrics` into the connection's
own buffer once the parser has consumed the request: the body first at offset 128,
then the headers carrying the measured length, then the body moved down to
follow them, so it too goes out as one contiguous write.

## HTTP support

- Methods: `GET`, and `HEAD`, which returns the same headers as GET with no
  body. Any other token of `A` to `Z` gets 405 with `Allow: GET, HEAD`.
- Versions: `HTTP/1.0` and `HTTP/1.1`. Every response says `HTTP/1.1` with
  `Connection: close`, and the server closes the connection after it.
- Routes: `/` returns `apollo says hello`, `/health` returns `ok`,
  `/metrics` returns the counters, and anything else gets 404. Routing
  ignores the query string: `/health?x=1` is `/health`. There is no URL
  decoding, so `/health/` is a different route from `/health`.
- The parser reads headers up to the empty line. Each line must be `name ":"
  OWS value OWS CRLF` with a name of 1 to 64 bytes of visible ASCII and a
  value of printable ASCII or HTAB. It matches `Host`, `Connection` (`close`
  or `keep-alive`) and `Content-Length` (1 to 19 digits) ignoring case and
  validates them, tolerates a missing `Host`, and ignores every other
  header. GET and HEAD use none of it, so the server ignores any body.
- 400 for an empty or non-token method, a method longer than 16 bytes, a
  target that does not start with `/`, a target longer than 1024 bytes, a
  byte outside `0x21` to `0x7e` in the target, any version other than the
  two above, LF without CR, a header line without a colon, with an empty
  name, with a control byte, or starting with whitespace (obs-fold), a
  non-numeric or over-long `Content-Length`, EOF before `CRLFCRLF`, and no
  `CRLFCRLF` within 8192 bytes.
- The server closes a connection that sends nothing without a reply, and
  closes one that stalls for 10 s without a reply while counting it in
  `timeouts`.

`/metrics` body:

    requests_total 7
    requests_get 4
    requests_head 1
    responses_200 4
    responses_400 1
    responses_404 1
    responses_405 1
    bytes_read 512
    bytes_written 750
    timeouts 0

Every counter includes the current request except `bytes_written`; the
response carrying that line has not gone out when `build_metrics` runs.

## binary inspection

    $ otool -hv apollod
    MH_MAGIC_64  ARM64  ALL  0x00  EXECUTE  17  976  NOUNDEFS DYLDLINK TWOLEVEL PIE
    $ nm -u apollod
    $ dyld_info -fixups apollod
    (no rebases, no binds)
    $ otool -L apollod
        /usr/lib/libSystem.B.dylib
    $ wc -c < apollod
    39608

The binary is a userspace Mach-O executable. The kernel maps it and starts
dyld (`LC_LOAD_DYLINKER`). dyld loads libSystem because the load command is
there, runs libSystem's own initializers, then jumps to `_start` through
`LC_MAIN` with the C `main` register contract (argc, argv, envp, apple),
all of which apollod ignores. From that instruction until `exit`, no code
outside `__TEXT,__text` runs in this process. `NOUNDEFS` and the empty
`nm -u` are the evidence: no `_socket`, `_bind`, `_listen`, `_accept`,
`_read`, `_write`, `_close`, `_kqueue`, `_kevent`, `_malloc`, `_printf`,
and no `dyld_stub_binder`. `make verify-imports` fails if that changes, and
`test/e2e.sh` checks the symbol table for the same names.

The symbol table is present. Every label is a symbol except those starting
with `L` (assembler-local) or lowercase `l` (linker-private on Darwin), and
the `.equ` constants show up as absolute symbols in `nm -m`. `ld` applies an
ad-hoc code signature. Two 16 KiB pages (`__TEXT`, `__DATA`) plus a
6,840-byte `__LINKEDIT` make up the 39,608 bytes; the 32 MiB of `__bss` is
zero-fill and costs nothing on disk.

## testing

    make test

`test/unit` runs 52 checks in assembly: the errno convention;
`parse_request` over 15 request lines, including both size bounds and one
past each; `parse_headers` over 18 header blocks (case folding, OWS, 19
against 20 digits, missing colon, obs-fold, control bytes, 64 against 65
byte names, values with colons); `span_eq` and `span_ieq`; `u64_to_ascii`
for 0, 1, 9, 10, 99, 100, 999, 1000, 2^32-1, 2^64-1; `SO_NOSIGPIPE`
inheritance through `accept`; `stadd` and `ldadd` executing with the
expected results.

`test/e2e.sh` runs 74 checks over the wire: status, headers, body and
`Content-Length` for every route; HEAD byte-identical to GET's headers;
CRLF framing via `xxd`; a request split across two reads; 100 sequential
requests; metrics deltas over a known burst and `Content-Length` against the
body of a single response; header handling (mixed case, 50 headers, unknown
headers, four malformed forms); malformed requests (empty method, `123`,
lowercase, missing version, `HTTP/2.0`, NUL bytes, control bytes, unrooted
target, 8192 x `A`, a 20000-byte header, 64 KiB of garbage, an empty
connection, a truncated request then EOF, LF-only then EOF, a peer closing
before the reply), with a liveness check after each; concurrency (a
half-sent request held open while others get served, 100 idle connections
held open, `oha -c 64`); the idle deadline (a silent connection still open
at 3 s and closed near 10 s, a byte at 6 s extending it past 12 s,
`timeouts` +1); 2000 connections held by one process while a request gets
served; descriptor exhaustion under `ulimit -n 40` (the server accepts what
fits, stays alive, parks the next request, and resumes when a connection
closes); `nm` for undefined and libc symbols.

Raw bytes by hand:

    printf 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' | nc 127.0.0.1 8080 | xxd

## benchmarks

`make bench` runs oha for 5 s per setting over loopback on this machine
(Apple M5, macOS 26.2) with an empty TIME_WAIT table. Every request opens a
new TCP connection because every response closes, so the figures count
connections per second as much as requests per second.

| concurrency | req/s | p50 | p95 | p99 | success |
|---|---|---|---|---|---|
| 1 | 10,955 | 0.089 ms | 0.098 ms | 0.114 ms | 100% |
| 8 | 25,015 | 0.236 ms | 0.319 ms | 0.402 ms | 95.6% |

The failures at concurrency 8 (and near 10% at 64) all report
`EADDRNOTAVAIL` (os error 49) on the client. macOS offers 16,384 ephemeral
ports (49152 to 65535) and holds a closed connection in TIME_WAIT for 30 s
(`net.inet.tcp.msl` = 15000), so a connection-per-request load drains the
pool during the run, and the share that fails varies between runs. The
server's counters agree with the client's successes every time
(`requests_total` equals `responses_200`): it answered every connection
that reached it. Benchmarking past that limit needs keep-alive, which
apollod lacks. `make bench` prints the TIME_WAIT count; wait 30 s before
`make test` after it.

Between syscalls the server executes at most the 408-instruction request
path, so the time goes to the kernel and to connection setup. The two timer
registrations cost about 2% against the version without deadlines (11,182
req/s at concurrency 1).

## apollod-min

`min/apollod-min.s` runs socket, `SO_REUSEADDR`, `SO_NOSIGPIPE`, bind and
listen, then loops over accept, one read, one write of
`HTTP/1.1 200 OK` / `Content-Length: 2` / `Connection: close` / `OK`, and
close. It has no parser, no routing, no counters and no deadlines. A fatal
init error exits 1; `EINTR` and `ECONNABORTED` on accept retry and any other
accept error exits. It survives peers that close early for the same reason
apollod does.

`make compare`:

| | apollod | apollod-min |
|---|---|---|
| source bytes / lines | 31,946 / 1,220 | 2,525 / 108 |
| object bytes | 12,848 | 1,776 |
| Mach-O bytes | 39,608 | 34,040 |
| `__text` | 3,348 | 264 |
| `__const` | 1,058 | 75 |
| `__data` | 108 | 4 |
| `__bss` | 33,818,720 | 8,192 |
| dylibs loaded | 1 | 1 |
| undefined symbols | 0 | 0 |
| instructions, total | 837 | 66 |
| instructions, request path | 408 | 22 |

The Mach-O sizes differ by 5.5 KB because both consist of two 16 KiB pages
plus `__LINKEDIT` (6,840 and 1,272 bytes); the 264 bytes of text occupy a
16 KiB page either way. "Request path" is a static count of the
instructions under the symbols a `GET /` can execute.

## limitations

- 4096 slots; the server closes further connections on accept. The idle
  deadline resets on any progress, so a client trickling a byte every 9 s
  holds a slot until it fills the 8 KiB buffer.
- No keep-alive, request bodies, chunked encoding or URL decoding.
- The bind address is 127.0.0.1:8080, hard-coded.
- The short-write path exists and `AUDIT.md` reasons through it, but a write
  of 8 KB or less into an empty loopback send buffer never exercises it.
- `SO_REUSEADDR` on BSD lets a second `SO_REUSEADDR` listener bind the same
  port, so two apollods start without error and one of them starves.
- The platform rules out a static executable (see build).
