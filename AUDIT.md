# apollod audit

Static reasoning over every writable region, pointer step and syscall result
in `src/`. Re-read this when `src/` changes.

## Writable regions

| region | where | capacity | writers | bound |
|---|---|---|---|---|
| `conn_table` | `__DATA,__bss` | 4096 x 64 B | `on_accept`, `read_wait`, `send_response`, `write_more`, `release_fd` | slot = `conn_table + (fd << 6)`. `on_accept` closes any fd at or beyond `CONN_MAX` before forming a slot, and the kqueue only returns fds the loop registered, so every slot index is below 4096. Fields are the `CONN_*` offsets, all below 64 |
| `conn_bufs` | `__DATA,__bss` | 4096 x 8192 B | `read(2)` in `read_more`; `build_metrics` | buffer = `conn_bufs + (fd << 13)`, same fd bound. `read_more` caps each read at `REQ_CAP - len`, and the loop condition keeps `len < REQ_CAP`; the CRLFCRLF scan loads 4 bytes at offsets `[start, len-4]`. The metrics body starts at offset 128 and the headers at 0: 59 + 20 + 23 = 102 fits in 128, and 128 + 122 + 10 x 22 = 470 fits in 8192; the source checks both with `.if`/`.error` |
| `events` | `__DATA,__bss` | 64 x 32 B | `kevent(2)` | `nevents = NEV`; `consumed < returned <= NEV` |
| `kev_chg` | `__DATA,__bss` | 3 x 32 B | `kev_fill` | every call site passes a literal entry index of 0, 1 or 2; six fixed stores at the `KEV_*` offsets |
| `counters` | `__DATA,__data` | 10 x 8 B | `count` / `count_add` (`stadd`) | offsets are `.equ` constants no larger than 72; `metric_table` reuses them |
| `ev_state` | `__DATA,__data` | 2 x 8 B | `wait_events`, `next_event` | returned count, consumed index |
| `kq`, `accept_paused`, `one` | `__DATA,__data` | 4 B each | startup, pause path | |
| stack | 16-byte frames | `parse_request`, `parse_headers`, `build_metrics`, `kev_change`, `timer_fill`, `release_fd` | one `stp`/`ldp` pair each; sp stays 16-aligned; nothing else touches the stack |
| `dbuf`, `actr`, `sa`, `salen`, `optval`, `optlen` (tests) | `__DATA` | 32 / 8 / 16 / 4 / 4 / 4 B | `u64_to_ascii`, `stadd`/`ldadd`, `getsockname`, `getsockopt` | the callers pass lengths |

## Read-only data (`__TEXT,__const`)

`sockaddr` (16 bytes, laid out by hand), three path literals, five static
responses (the assembler checks each `Content-Length` against its body),
`mhdr_a` / `mhdr_b`, `mnames`, `metric_table`, and in `lib.s` the method,
header-name and value literals. The metric table stores offsets from
`mnames`, so `__TEXT` carries no relocations and dyld rebases nothing.

## Connection state machine

    ST_FREE    --accept, fcntl O_NONBLOCK, gen++, one kevent {EV_ADD read, EV_ADD|EV_ONESHOT timer}--> ST_READING
    ST_READING --CRLFCRLF, or buffer full, or EOF with bytes-->                                          ST_WRITING
    ST_READING --EOF with no bytes, read error, or timer-->                                              close
    ST_WRITING --all bytes written, write error, or timer-->                                             close
    close      --EV_DELETE timer, state = ST_FREE, close(2)-->                                           ST_FREE

The loop dispatches socket events by slot state. One `kevent` batch can
hold two events for the same fd. Closing on the first leaves the second
pointing at a free slot, which the loop ignores, or, when `accept` reused
the fd later in the same batch, at a new `ST_READING` connection, where a
stale write event causes one harmless read attempt (`EAGAIN`).

The loop dispatches timer events by generation. A timer's ident is the fd
and its udata is the slot's `CONN_GEN` at arming time; `on_accept`
increments `CONN_GEN` before arming. A timer event whose udata differs from
the current generation belonged to an earlier connection on that fd, and
`on_timeout` ignores it, as it ignores one for a free slot. `close(2)`
removes an fd's read and write filters and leaves a timer keyed by the same
number in place, so `release_fd` deletes the timer itself; a one-shot timer
that fired before the delete reports `ENOENT` there, and `release_fd`
accepts that.

`read_wait` re-arms the timer only when the parked length grew during the
event, and `write_err` re-arms it only when bytes went out during the event
(`x13`). Re-adding an existing `EVFILT_TIMER` restarts it (kqueue(2)), so
progress alone extends a deadline. A timer that fires closes the connection
with no reply and increments `timeouts`.

On a short write, `write_err` submits `EV_DISABLE` on the read filter
(idempotent, so a second short write is fine) and `EV_ADD | EV_ONESHOT` on
the write filter in one `kevent`, with the timer re-arm as an optional
third entry.

When `accept` returns `EMFILE`, `ENFILE` or `ENOBUFS`, the loop disables
the listener's read filter and sets `accept_paused`; the next `close_conn`
re-enables it. Connections wait in the backlog (128) meanwhile. Without the
pause, a level-triggered listener would spin the loop.

`on_accept` submits two changes in one call. If the call fails after
applying the first, `release_fd` runs, deletes the timer (or gets `ENOENT`)
and closes the fd, which drops the read filter, so no registration outlives
a failed accept.

## Counters

`count` and `count_add` each execute a single `stadd`. The add happens as
one atomic read-modify-write at the memory system, so two concurrent
increments of the same word both land, where `ldr`/`add`/`str` could lose
one. Relaxed ordering is correct because nothing sequences against a
counter; the only reader is `build_metrics`, whose aligned 8-byte `ldr` is
single-copy atomic on ARMv8 and sees a whole old or new value. Both source
files carry `.arch_extension lse`; FEAT_LSE is present on every Apple
Silicon core, and `test/unit.s` checks 51 and 52 execute both instructions.

## Bounds by routine

`on_readable` / `read_more`: `x1 = buf + len`, `x2 = REQ_CAP - len`, and
the loop condition keeps `len < REQ_CAP`. The scan starts at
`max(len_old - 3, 0)` so it finds a terminator split across reads, and it
compares `x12 = len - 4` signed (`b.gt`) so `len < 4` ends the loop instead
of wrapping.

`parse_request`: a `cursor < end` check precedes every byte load. The
method is 1 to 16 bytes of `A` to `Z`. The target starts with `/` and runs
1 to 1024 bytes of `0x21` to `0x7e`. The version check requires
`cursor + 10 <= end` before the four loads covering `HTTP/1.x\r\n`. The
routine leaves `x23` one past that CRLF. The query strip walks
`[x25, x25 + x26)` and nothing beyond.

`parse_headers`: each line requires `cursor + 2 <= end` before the CRLF
probe; the name is 1 to 64 bytes of `0x21` to `0x7e` except `:`; the
routine skips OWS; value bytes are `0x20` to `0x7e` or HTAB until CR; it
requires `cursor + 2 <= end` before reading the LF; trailing OWS trimming
walks back no further than the value start. `Content-Length` must be 1 to
19 digits, so the accumulator cannot wrap. The routine examines each byte
once, the cursor only advances, and the loop ends at the empty line or at
`end`.

`u64_to_ascii`: writes `ndigits` bytes (1 to 20) backward from
`dst + ndigits`; callers provide at least 20 bytes.

`copy_span`: forward byte copy. The one overlapping use is the metrics body
move, where `dst < src` (`dst <= buf + 102`, `src = buf + 128`).

`write_more`: `ptr = resp + off` and `rem = len - off`, with `off <= len`
because it adds only what `write` returned; `rem == 0` closes.

`span_eq` / `span_ieq`: compare lengths first, then at most `len` bytes of
each. `span_ieq` folds `A` to `Z` of its first operand and the literals are
lowercase.

`kev_fill` / `kev_submit`: every call site passes a literal entry index and
`nchanges` equals the number of entries filled in that sequence; `nevents`
is 0, so a failed change surfaces as the syscall's errno and never as an
`EV_ERROR` event.

## Syscall results

| call | on C set (x0 = errno) |
|---|---|
| `socket` | exit 1 |
| `setsockopt` x2 on the listener | exit 2 |
| `bind` | exit 3 |
| `listen` | exit 4 |
| `fcntl` on the listener | exit 6 |
| `kqueue` | exit 7 |
| `kevent`: register listener, wait (other than `EINTR`), disable or enable listener | exit 8 |
| `accept` | `EAGAIN`: backlog drained; `EINTR`, `ECONNABORTED`: retry; `EMFILE`, `ENFILE`, `ENOBUFS`: pause; anything else: exit 5 |
| `fcntl` on a client | close that fd, keep accepting |
| `kevent`: add a client's read filter and timer | `release_fd` that fd, keep accepting |
| `read` | `EAGAIN`: park the length, re-arm if bytes arrived, wait; `EINTR`: retry; anything else: close |
| `write` | `EAGAIN`: wait for writability, re-arm if bytes went out; `EINTR`: retry; anything else: close |
| `kevent`: disable read / add write / re-arm timer on a client | close |
| `kevent`: re-arm timer after a partial read | close |
| `kevent`: delete timer in `release_fd` | `ENOENT`: it fired, fine; anything else: exit 8 |
| `close` (client) | result not read: the descriptor is gone either way and no retry helps |
| `EV_ERROR` flag in a returned event | listener: exit 8; client: close |

`SO_NOSIGPIPE` on the listener keeps an early-closing peer from killing the
process; without it the first write to a reset socket raises `SIGPIPE`.
`test/unit.s` check 50 confirms the option reaches accepted sockets.

## Registers

`x19` to `x28` follow the block comment in `src/apollod.s`. `x9`/`x10` are
counter scratch and never live across a `count`. `x11` is the slot pointer;
the `slot` macro recomputes it after every `bl` because the callees clobber
it. `x12` to `x14` are scratch within one straight-line stretch; `x13` also
serves as the "bytes went out" flag across the write loop, where nothing
else uses it, and `x14` carries the event's udata from `next_event` to
`on_timeout`. `x0` to `x6` carry arguments and results for the routines.
`x16` holds the syscall number and nothing else.

`parse_request`, `parse_headers`, `build_metrics`, `kev_change`,
`timer_fill` and `release_fd` save `lr` because they call other routines;
`kev_fill` and `kev_submit` are leaves; the event loop is not a function and
needs no frame for its `bl` calls. `release_fd` may branch to `fail_kevent` with a
frame pushed, and the process exits there.

The kernel writes back `x0` and `x1` on return from `svc`; every syscall
reloads all of its arguments, and nothing relies on a register surviving a
trap except callee-saved ones.

`on_readable` resets `x24` (method) to GET at the start of every readable
event, so a 400 sent before the parser saw a method carries a body.

## Signed / unsigned

All lengths and offsets are unsigned 64-bit; compares use `hs`/`lo`/`hi`/`ls`.
The single signed compare (`b.gt` in the scan) is deliberate, see above. The
loop loads the filter with `ldrsh` and tests it with `cmn w13, #7`, the one
place that compares a negative constant. `ccmp` appears only with immediates
below 32 (its 5-bit field); errno sets above that use plain `cmp`/`b.eq`
chains.

## Known gaps

- The short-write path (`EAGAIN` on `write`) rests on reasoning alone: a
  write of 8 KB or less into an empty loopback send buffer never returns
  short.
- The deadline measures idleness. A peer that sends a byte every 9 s keeps
  its slot until the 8 KiB buffer fills (then 400 and close).
- The server ignores bytes after `CRLFCRLF` (a request body) and closes the
  connection after the reply, so nothing gets misread as a second request.
  If unread bytes remain at close, the kernel sends RST.
- Nobody reads `close(2)` errors.
- `SO_REUSEADDR` on BSD lets a second `SO_REUSEADDR` listener bind the same
  port; two apollods start without error and one of them starves.
