# Debugging apollod with lldb

The binary keeps its symbol table. Labels that start with `L` are
assembler-local, and labels that start with lowercase `l` are linker-private
on Darwin; the symbol table omits both. Every other label is a symbol:

- loop: `_start`, `wait_events`, `next_event`, `on_error`, `on_timeout`,
  `on_accept`, `accept_drop`, `accept_err`, `accept_pause`, `on_readable`,
  `read_more`, `read_scan`, `read_cont`, `read_err`, `read_wait`, `read_eof`,
  `request_overflow`, `request_complete`, `route`, `bad_request`,
  `method_not_allowed`, `send_response`, `on_writable`, `write_more`,
  `write_err`, `close_conn`
- helpers: `kev_fill`, `kev_submit`, `kev_change`, `timer_fill`,
  `release_fd`, `build_metrics`
- lib: `parse_request`, `parse_headers`, `span_eq`, `span_ieq`,
  `u64_to_ascii`, `copy_span`
- data: `counters`, `ev_state`, `kq`, `accept_paused`, `conn_table`,
  `conn_bufs`, `events`, `kev_chg`, `sockaddr`

For `L` labels (`Lroute_root`, `Lph_line`, ...) break on an address from
`make disasm`.

## Entry

    lldb ./apollod
    (lldb) b _start
    (lldb) r
    (lldb) register read x0 x1 x2 x3 sp lr

dyld reaches `_start` through `LC_MAIN`, so the entry state follows the C
`main` contract: x0 = argc, x1 = argv, x2 = envp, x3 = apple strings, sp
16-byte aligned, lr = return address into dyld. apollod ignores all of it
and never returns.

## Event loop

    (lldb) b on_accept
    (lldb) b on_readable
    (lldb) b on_writable
    (lldb) b on_timeout
    (lldb) c
    # elsewhere: curl -s http://127.0.0.1:8080/
    (lldb) register read x19 x20 x13 x14   # listener, client fd, filter (-1 read, -2 write, -7 timer), udata
    (lldb) image lookup -s ev_state
    (lldb) memory read -s8 -fu -c 2 <address>     # events returned, consumed

## Connection slot

The slot for fd N sits at `conn_table + N * 64`; its request buffer at
`conn_bufs + N * 8192`.

    (lldb) image lookup -s conn_table
    (lldb) memory read -s8 -fu -c 6 <conn_table + N*64>
    # state (0 free, 1 reading, 2 writing), request length, response ptr,
    # response offset, response length, generation

`on_timeout` honors a timer event only when its udata equals the slot's
generation and the slot is live. To watch one, break on `on_timeout` and
compare `x14` with the sixth word above.

## Pending kqueue change

    (lldb) b kev_submit
    (lldb) c
    (lldb) image lookup -s kev_chg
    (lldb) memory read -s8 -fx -c 4 <address>     # ident, filter|flags|fflags, data, udata of entry 0
    (lldb) register read x0                       # number of entries about to go out

## Syscall results

A `b.cs` or `b.cc` follows every `svc #0x80`. Step to the instruction after
the `svc` and read x0 and the carry bit:

    (lldb) dis -n read_more
    (lldb) b <address of the b.cs after the svc>
    (lldb) c
    (lldb) register read x0
    (lldb) p/x $cpsr & (1 << 29)         # nonzero: C set, x0 is errno

## Request bytes and the parsers

    (lldb) b parse_request
    (lldb) c
    (lldb) memory read -s1 -fc -c $x22 $x21      # the bytes read, with no NUL assumed
    (lldb) finish
    (lldb) register read x0 x24 x25 x26 x23      # result, method, route span, cursor
    (lldb) b parse_headers
    (lldb) c
    (lldb) finish
    (lldb) register read x0 x1 x2                # result, Content-Length, HF_* flags

## Response bytes

    (lldb) b write_more
    (lldb) c
    (lldb) memory read -s1 -fc -c $x2 $x1        # after the add/subs: what this write sends

## Counters

    (lldb) image lookup -s counters
    (lldb) memory read -s8 -fu -c 10 <address>
    # order: requests_total requests_get requests_head responses_200 responses_400
    #        responses_404 responses_405 bytes_read bytes_written timeouts

Increments use `stadd`; a watchpoint on a counter fires on the atomic store:

    (lldb) watchpoint set expression -s 8 -- <counters address>

## Disassembly and stack

    (lldb) dis -p -c 16                  # around pc
    (lldb) dis -n on_writable
    (lldb) register read sp fp lr
    (lldb) memory read -s8 -fx -c 4 $sp

`parse_request`, `parse_headers`, `build_metrics`, `kev_change`,
`timer_fill` and `release_fd` push a frame (`stp x29, x30`); the rest is
leaf or straight-line code, so `bt` stays at most three deep.

## Exit codes

| code | where | usual cause |
|---|---|---|
| 1 | socket | out of descriptors |
| 2 | setsockopt on the listener | should not happen |
| 3 | bind | EADDRINUSE: a listener without SO_REUSEADDR already owns 8080 |
| 4 | listen | should not happen |
| 5 | accept | an errno other than EAGAIN, EINTR, ECONNABORTED, EMFILE, ENFILE, ENOBUFS |
| 6 | fcntl on the listener | should not happen |
| 7 | kqueue | out of descriptors |
| 8 | kevent on the listener, the wait itself, or a timer delete failing with something other than ENOENT | kqueue descriptor invalid |

## Without lldb

    make disasm | sed -n '/^on_accept:/,/^on_readable:/p'
    lsof -p $(pgrep -x apollod)          # listener, kqueue, every client fd
    curl -s http://127.0.0.1:8080/metrics
    printf 'GET / HTTP/1.1\r\n\r\n' | nc 127.0.0.1 8080 | xxd
    /bin/bash -c 'S=$SECONDS; exec 3<>/dev/tcp/127.0.0.1/8080; read -t 15 <&3; echo closed after $((SECONDS-S)) s'
