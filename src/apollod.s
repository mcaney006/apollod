// apollod: Darwin arm64, raw syscalls only. kqueue event loop, one thread.

.arch_extension lse

.equ SYS_exit,       1
.equ SYS_read,       3
.equ SYS_write,      4
.equ SYS_close,      6
.equ SYS_accept,     30
.equ SYS_fcntl,      92
.equ SYS_socket,     97
.equ SYS_bind,       104
.equ SYS_setsockopt, 105
.equ SYS_listen,     106
.equ SYS_kqueue,     362
.equ SYS_kevent,     363

.equ AF_INET,        2
.equ SOCK_STREAM,    1
.equ SOL_SOCKET,     0xffff
.equ SO_REUSEADDR,   0x0004
.equ SO_NOSIGPIPE,   0x1022
.equ F_SETFL,        4
.equ O_NONBLOCK,     0x0004
.equ ENOENT,         2
.equ EINTR,          4
.equ ENFILE,         23
.equ EMFILE,         24
.equ EAGAIN,         35
.equ ECONNABORTED,   53
.equ ENOBUFS,        55

.equ EVFILT_READ,    -1
.equ EVFILT_WRITE,   -2
.equ EVFILT_TIMER,   -7
.equ EV_ADD,         0x0001
.equ EV_DELETE,      0x0002
.equ EV_ENABLE,      0x0004
.equ EV_DISABLE,     0x0008
.equ EV_ADD_ONESHOT, 0x0011             // EV_ADD | EV_ONESHOT
.equ EV_ERROR_BIT,   14                 // EV_ERROR 0x4000
// struct kevent, 64-bit
.equ KEV_IDENT,      0
.equ KEV_FILTER,     8
.equ KEV_FLAGS,      10
.equ KEV_FFLAGS,     12
.equ KEV_DATA,       16
.equ KEV_UDATA,      24
.equ KEV_SIZE,       32
.equ KEV_SHIFT,      5
.equ NEV,            64
.equ NCHG,           3

.equ IDLE_TIMEOUT_MS, 10000             // EVFILT_TIMER data, ms
.equ BACKLOG,        128
.equ REQ_CAP,        8192
.equ REQ_SHIFT,      13
.equ METRICS_BODY_OFF, 128              // body scratch offset within the slot buffer

// connection table, indexed by fd
.equ CONN_MAX,       4096
.equ CONN_SHIFT,     6
.equ CONN_SIZE,      64
.equ CONN_STATE,     0
.equ CONN_REQ_LEN,   8
.equ CONN_RESP_PTR,  16
.equ CONN_RESP_OFF,  24
.equ CONN_RESP_LEN,  32
.equ CONN_GEN,       40                 // bumped per accept; timer udata
.equ ST_FREE,        0
.equ ST_READING,     1
.equ ST_WRITING,     2

.equ EX_SOCKET,      1
.equ EX_SETSOCKOPT,  2
.equ EX_BIND,        3
.equ EX_LISTEN,      4
.equ EX_ACCEPT,      5
.equ EX_FCNTL,       6
.equ EX_KQUEUE,      7
.equ EX_KEVENT,      8

.equ C_REQ_TOTAL,     0
.equ C_REQ_GET,       8
.equ C_REQ_HEAD,      16
.equ C_RESP_200,      24
.equ C_RESP_400,      32
.equ C_RESP_404,      40
.equ C_RESP_405,      48
.equ C_BYTES_READ,    56
.equ C_BYTES_WRITTEN, 64
.equ C_TIMEOUTS,      72
.equ C_COUNT,         10

.equ MT_NAME,     0                     // offset from mnames
.equ MT_NAME_LEN, 8
.equ MT_COUNTER,  16                    // offset into counters
.equ MT_SIZE,     24

.if KEV_SIZE != (1 << KEV_SHIFT)
.error "KEV_SHIFT"
.endif
.if CONN_SIZE != (1 << CONN_SHIFT)
.error "CONN_SHIFT"
.endif
.if REQ_CAP != (1 << REQ_SHIFT)
.error "REQ_SHIFT"
.endif

.macro sys nr
    mov     x16, #\nr
    svc     #0x80
.endm

// counters[off] += 1, atomic
.macro count off
    adrp    x9, counters@PAGE
    add     x9, x9, counters@PAGEOFF
    add     x9, x9, #\off
    mov     x10, #1
    stadd   x10, [x9]
.endm

// counters[off] += x0, atomic
.macro count_add off
    adrp    x9, counters@PAGE
    add     x9, x9, counters@PAGEOFF
    add     x9, x9, #\off
    stadd   x0, [x9]
.endm

// x11 = &conn_table[x20]
.macro slot
    adrp    x11, conn_table@PAGE
    add     x11, x11, conn_table@PAGEOFF
    add     x11, x11, x20, lsl #CONN_SHIFT
.endm

// branch to target if route x25/x26 == path
.macro match path, target
    mov     x0, x25
    mov     x1, x26
    adrp    x2, \path@PAGE
    add     x2, x2, \path@PAGEOFF
    mov     x3, #\path\()_len
    bl      span_eq
    cbnz    x0, \target
.endm

// x27/x28/x0 = response ptr, header len, body len
.macro respond name
    adrp    x27, \name@PAGE
    add     x27, x27, \name@PAGEOFF
    mov     x28, #\name\()_hdr_len
    mov     x0, #\name\()_body_len
    b       send_response
.endm

.macro metric name, off
    .quad   \name - mnames, \name\()_len, \off
.endm

.section __TEXT,__const
// sockaddr_in: sin_len, sin_family, sin_port, sin_addr, sin_zero[8]
sockaddr:   .byte   16, AF_INET
            .byte   0x1f, 0x90              // 8080
            .byte   127, 0, 0, 1
            .byte   0, 0, 0, 0, 0, 0, 0, 0
.equ sockaddr_len, . - sockaddr

path_root:      .ascii  "/"
.equ path_root_len, . - path_root
path_health:    .ascii  "/health"
.equ path_health_len, . - path_health
path_metrics:   .ascii  "/metrics"
.equ path_metrics_len, . - path_metrics

// header then body, contiguous; body length asserted
.equ resp_root_body_len, 17
resp_root:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: 17\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ resp_root_hdr_len, . - resp_root
resp_root_body:
    .ascii  "apollo says hello"
.if . - resp_root_body != resp_root_body_len
.error "resp_root: Content-Length"
.endif

.equ resp_health_body_len, 2
resp_health:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: 2\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ resp_health_hdr_len, . - resp_health
resp_health_body:
    .ascii  "ok"
.if . - resp_health_body != resp_health_body_len
.error "resp_health: Content-Length"
.endif

.equ resp_400_body_len, 11
resp_400:
    .ascii  "HTTP/1.1 400 Bad Request\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: 11\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ resp_400_hdr_len, . - resp_400
resp_400_body:
    .ascii  "bad request"
.if . - resp_400_body != resp_400_body_len
.error "resp_400: Content-Length"
.endif

.equ resp_404_body_len, 9
resp_404:
    .ascii  "HTTP/1.1 404 Not Found\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: 9\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ resp_404_hdr_len, . - resp_404
resp_404_body:
    .ascii  "not found"
.if . - resp_404_body != resp_404_body_len
.error "resp_404: Content-Length"
.endif

.equ resp_405_body_len, 18
resp_405:
    .ascii  "HTTP/1.1 405 Method Not Allowed\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: 18\r\n"
    .ascii  "Allow: GET, HEAD\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ resp_405_hdr_len, . - resp_405
resp_405_body:
    .ascii  "method not allowed"
.if . - resp_405_body != resp_405_body_len
.error "resp_405: Content-Length"
.endif

// metrics: mhdr_a, decimal body length, mhdr_b, body
mhdr_a:
    .ascii  "HTTP/1.1 200 OK\r\n"
    .ascii  "Content-Type: text/plain\r\n"
    .ascii  "Content-Length: "
.equ mhdr_a_len, . - mhdr_a
mhdr_b:
    .ascii  "\r\n"
    .ascii  "Connection: close\r\n"
    .ascii  "\r\n"
.equ mhdr_b_len, . - mhdr_b
.if mhdr_a_len + 20 + mhdr_b_len > METRICS_BODY_OFF
.error "metrics headers overrun the body region"
.endif

mnames:
mn_requests_total:  .ascii "requests_total"
.equ mn_requests_total_len, . - mn_requests_total
mn_requests_get:    .ascii "requests_get"
.equ mn_requests_get_len, . - mn_requests_get
mn_requests_head:   .ascii "requests_head"
.equ mn_requests_head_len, . - mn_requests_head
mn_responses_200:   .ascii "responses_200"
.equ mn_responses_200_len, . - mn_responses_200
mn_responses_400:   .ascii "responses_400"
.equ mn_responses_400_len, . - mn_responses_400
mn_responses_404:   .ascii "responses_404"
.equ mn_responses_404_len, . - mn_responses_404
mn_responses_405:   .ascii "responses_405"
.equ mn_responses_405_len, . - mn_responses_405
mn_bytes_read:      .ascii "bytes_read"
.equ mn_bytes_read_len, . - mn_bytes_read
mn_bytes_written:   .ascii "bytes_written"
.equ mn_bytes_written_len, . - mn_bytes_written
mn_timeouts:        .ascii "timeouts"
.equ mn_timeouts_len, . - mn_timeouts
.equ mnames_len, . - mnames
// worst case: name SP 20 digits LF per entry
.if METRICS_BODY_OFF + mnames_len + C_COUNT * 22 > REQ_CAP
.error "metrics body overruns the slot buffer"
.endif

.p2align 3
metric_table:
    metric  mn_requests_total, C_REQ_TOTAL
    metric  mn_requests_get,   C_REQ_GET
    metric  mn_requests_head,  C_REQ_HEAD
    metric  mn_responses_200,  C_RESP_200
    metric  mn_responses_400,  C_RESP_400
    metric  mn_responses_404,  C_RESP_404
    metric  mn_responses_405,  C_RESP_405
    metric  mn_bytes_read,     C_BYTES_READ
    metric  mn_bytes_written,  C_BYTES_WRITTEN
    metric  mn_timeouts,       C_TIMEOUTS
metric_table_end:

.data
.p2align 3
counters:       .fill   C_COUNT, 8, 0
ev_state:       .quad   0, 0            // returned, consumed
.p2align 2
one:            .long   1
kq:             .long   0
accept_paused:  .long   0               // listener read filter disabled

.zerofill __DATA,__bss,conn_table,CONN_MAX*CONN_SIZE,CONN_SHIFT
.zerofill __DATA,__bss,conn_bufs,CONN_MAX*REQ_CAP,REQ_SHIFT
.zerofill __DATA,__bss,events,NEV*KEV_SIZE,3
.zerofill __DATA,__bss,kev_chg,NCHG*KEV_SIZE,3

// x19 = listen fd
// x20 = client fd
// x21 = request buffer
// x22 = request length
// x23 = parser cursor
// x24 = method (0 GET, 1 HEAD)
// x25 = route ptr
// x26 = route len
// x27 = response ptr
// x28 = response header len
// x9, x10 = counter scratch; x11 = slot; x12-x14 = scratch
.text
.globl _start
.p2align 2
_start:
    mov     x0, #AF_INET
    mov     x1, #SOCK_STREAM
    mov     x2, #0
    sys     SYS_socket
    b.cs    fail_socket
    mov     x19, x0

    mov     x0, x19
    mov     x1, #SOL_SOCKET
    mov     x2, #SO_REUSEADDR
    adrp    x3, one@PAGE
    add     x3, x3, one@PAGEOFF
    mov     x4, #4
    sys     SYS_setsockopt
    b.cs    fail_setsockopt

    mov     x0, x19                     // inherited through accept
    mov     x1, #SOL_SOCKET
    mov     x2, #SO_NOSIGPIPE
    adrp    x3, one@PAGE
    add     x3, x3, one@PAGEOFF
    mov     x4, #4
    sys     SYS_setsockopt
    b.cs    fail_setsockopt

    mov     x0, x19
    adrp    x1, sockaddr@PAGE
    add     x1, x1, sockaddr@PAGEOFF
    mov     x2, #sockaddr_len
    sys     SYS_bind
    b.cs    fail_bind

    mov     x0, x19
    mov     x1, #BACKLOG
    sys     SYS_listen
    b.cs    fail_listen

    mov     x0, x19
    mov     x1, #F_SETFL
    mov     x2, #O_NONBLOCK
    sys     SYS_fcntl
    b.cs    fail_fcntl

    sys     SYS_kqueue
    b.cs    fail_kqueue
    adrp    x9, kq@PAGE
    add     x9, x9, kq@PAGEOFF
    str     w0, [x9]

    mov     x0, x19
    mov     x1, #EVFILT_READ
    mov     x2, #EV_ADD
    bl      kev_change
    cbnz    x0, fail_kevent

wait_events:
    adrp    x0, kq@PAGE
    add     x0, x0, kq@PAGEOFF
    ldr     w0, [x0]
    mov     x1, #0
    mov     x2, #0
    adrp    x3, events@PAGE
    add     x3, x3, events@PAGEOFF
    mov     x4, #NEV
    mov     x5, #0
    sys     SYS_kevent
    b.cc    1f
    cmp     x0, #EINTR
    b.eq    wait_events
    b       fail_kevent
1:  adrp    x9, ev_state@PAGE
    add     x9, x9, ev_state@PAGEOFF
    stp     x0, xzr, [x9]

next_event:
    adrp    x9, ev_state@PAGE
    add     x9, x9, ev_state@PAGEOFF
    ldp     x12, x13, [x9]
    cmp     x13, x12
    b.hs    wait_events
    add     x14, x13, #1
    str     x14, [x9, #8]
    adrp    x11, events@PAGE
    add     x11, x11, events@PAGEOFF
    add     x11, x11, x13, lsl #KEV_SHIFT
    ldr     x20, [x11, #KEV_IDENT]
    ldrh    w12, [x11, #KEV_FLAGS]
    ldrsh   w13, [x11, #KEV_FILTER]
    ldr     x14, [x11, #KEV_UDATA]
    tbnz    w12, #EV_ERROR_BIT, on_error
    cmp     x20, x19
    b.eq    on_accept
    cmn     w13, #7                     // EVFILT_TIMER
    b.eq    on_timeout
    slot
    ldr     x12, [x11, #CONN_STATE]
    cmp     x12, #ST_READING
    b.eq    on_readable
    cmp     x12, #ST_WRITING
    b.eq    on_writable
    b       next_event                  // stale: closed earlier in this batch

on_error:
    cmp     x20, x19
    b.eq    fail_kevent
    b       close_conn

on_timeout:
    slot
    ldr     x12, [x11, #CONN_STATE]
    cbz     x12, next_event
    ldr     x12, [x11, #CONN_GEN]
    cmp     x12, x14
    b.ne    next_event                  // stale timer, fd reused
    count   C_TIMEOUTS
    b       close_conn

on_accept:
    mov     x0, x19
    mov     x1, #0
    mov     x2, #0
    sys     SYS_accept
    b.cs    accept_err
    mov     x20, x0
    cmp     x20, #CONN_MAX
    b.hs    accept_drop
    mov     x0, x20
    mov     x1, #F_SETFL
    mov     x2, #O_NONBLOCK
    sys     SYS_fcntl
    b.cs    accept_drop
    slot
    ldr     x12, [x11, #CONN_GEN]
    add     x12, x12, #1
    str     x12, [x11, #CONN_GEN]
    mov     x12, #ST_READING
    str     x12, [x11, #CONN_STATE]
    str     xzr, [x11, #CONN_REQ_LEN]
    mov     x0, #0                      // read filter + idle timer
    mov     x1, x20
    mov     x2, #EVFILT_READ
    mov     x3, #EV_ADD
    mov     x4, #0
    mov     x5, #0
    bl      kev_fill
    mov     x0, #1
    bl      timer_fill
    mov     x0, #2
    bl      kev_submit
    cbz     x0, on_accept
    bl      release_fd                  // part of the submission may have applied
    b       on_accept
accept_drop:
    mov     x0, x20
    sys     SYS_close
    b       on_accept
accept_err:
    cmp     x0, #EAGAIN
    b.eq    next_event
    cmp     x0, #EINTR
    b.eq    on_accept
    cmp     x0, #ECONNABORTED
    b.eq    on_accept
    cmp     x0, #EMFILE
    b.eq    accept_pause
    cmp     x0, #ENFILE
    b.eq    accept_pause
    cmp     x0, #ENOBUFS
    b.ne    fail_accept
accept_pause:                           // out of descriptors: stop watching the listener until a close
    mov     x0, x19
    mov     x1, #EVFILT_READ
    mov     x2, #EV_DISABLE
    bl      kev_change
    cbnz    x0, fail_kevent
    adrp    x9, accept_paused@PAGE
    add     x9, x9, accept_paused@PAGEOFF
    mov     w10, #1
    str     w10, [x9]
    b       next_event

on_readable:
    mov     x24, #0                     // GET until a method is parsed
    adrp    x21, conn_bufs@PAGE
    add     x21, x21, conn_bufs@PAGEOFF
    add     x21, x21, x20, lsl #REQ_SHIFT
    slot
    ldr     x22, [x11, #CONN_REQ_LEN]
read_more:
    mov     x0, x20
    add     x1, x21, x22
    mov     x2, #REQ_CAP
    sub     x2, x2, x22
    sys     SYS_read
    b.cs    read_err
    cbz     x0, read_eof
    count_add C_BYTES_READ
    subs    x11, x22, #3                // terminator may straddle reads
    csel    x11, x11, xzr, hs
    add     x22, x22, x0
    sub     x12, x22, #4                // last candidate; negative when len < 4
    mov     w13, #0x0a0d
    movk    w13, #0x0a0d, lsl #16       // CRLFCRLF
read_scan:
    cmp     x11, x12
    b.gt    read_cont
    ldr     w14, [x21, x11]
    cmp     w14, w13
    b.eq    request_complete
    add     x11, x11, #1
    b       read_scan
read_cont:
    cmp     x22, #REQ_CAP
    b.lo    read_more
    b       request_overflow
read_err:
    cmp     x0, #EAGAIN
    b.eq    read_wait
    cmp     x0, #EINTR
    b.eq    read_more
    b       close_conn
read_wait:                              // park; re-arm the timer only on new bytes
    slot
    ldr     x12, [x11, #CONN_REQ_LEN]
    str     x22, [x11, #CONN_REQ_LEN]
    cmp     x22, x12
    b.eq    next_event
    mov     x0, #0
    bl      timer_fill
    mov     x0, #1
    bl      kev_submit
    cbnz    x0, close_conn
    b       next_event
read_eof:
    cbz     x22, close_conn             // nothing received
request_overflow:                       // bytes but no CRLFCRLF
    count   C_REQ_TOTAL
    b       bad_request
request_complete:
    count   C_REQ_TOTAL
    bl      parse_request
    cbnz    x0, Lreq_invalid
    bl      parse_headers               // x1/x2 unused for GET/HEAD
    cbnz    x0, bad_request

route:
    cbnz    x24, 1f
    count   C_REQ_GET
    b       2f
1:  count   C_REQ_HEAD
2:  match   path_root, Lroute_root
    match   path_health, Lroute_health
    match   path_metrics, Lroute_metrics
    count   C_RESP_404
    respond resp_404
Lroute_root:
    count   C_RESP_200
    respond resp_root
Lroute_health:
    count   C_RESP_200
    respond resp_health
Lroute_metrics:
    count   C_RESP_200
    bl      build_metrics
    b       send_response

Lreq_invalid:
    cmp     x0, #2
    b.eq    method_not_allowed
bad_request:
    count   C_RESP_400
    respond resp_400
method_not_allowed:
    count   C_RESP_405
    respond resp_405

// x27 ptr, x28 header len, x0 body len; HEAD sends headers only
send_response:
    mov     x2, x28
    cbnz    x24, 1f
    add     x2, x2, x0
1:  slot
    str     x27, [x11, #CONN_RESP_PTR]
    str     xzr, [x11, #CONN_RESP_OFF]
    str     x2, [x11, #CONN_RESP_LEN]
    mov     x12, #ST_WRITING
    str     x12, [x11, #CONN_STATE]

// x13 = 1 once bytes went out this event
on_writable:
    mov     x13, #0
write_more:
    slot
    ldr     x1, [x11, #CONN_RESP_PTR]
    ldr     x12, [x11, #CONN_RESP_OFF]
    ldr     x2, [x11, #CONN_RESP_LEN]
    add     x1, x1, x12
    subs    x2, x2, x12
    b.ls    close_conn
    mov     x0, x20
    sys     SYS_write
    b.cs    write_err
    count_add C_BYTES_WRITTEN
    slot
    ldr     x12, [x11, #CONN_RESP_OFF]
    add     x12, x12, x0
    str     x12, [x11, #CONN_RESP_OFF]
    mov     x13, #1
    b       write_more
write_err:
    cmp     x0, #EINTR
    b.eq    write_more
    cmp     x0, #EAGAIN
    b.ne    close_conn
    mov     x0, #0                      // EV_DISABLE is idempotent
    mov     x1, x20
    mov     x2, #EVFILT_READ
    mov     x3, #EV_DISABLE
    mov     x4, #0
    mov     x5, #0
    bl      kev_fill
    mov     x0, #1
    mov     x1, x20
    mov     x2, #EVFILT_WRITE
    mov     x3, #EV_ADD_ONESHOT
    mov     x4, #0
    mov     x5, #0
    bl      kev_fill
    mov     x14, #2
    cbz     x13, 1f
    mov     x0, #2
    bl      timer_fill
    mov     x14, #3
1:  mov     x0, x14
    bl      kev_submit
    cbnz    x0, close_conn
    b       next_event

close_conn:
    bl      release_fd
    adrp    x9, accept_paused@PAGE
    add     x9, x9, accept_paused@PAGEOFF
    ldr     w10, [x9]
    cbz     w10, next_event
    str     wzr, [x9]
    mov     x0, x19
    mov     x1, #EVFILT_READ
    mov     x2, #EV_ENABLE
    bl      kev_change
    cbnz    x0, fail_kevent
    b       next_event

fail_socket:
    mov     x0, #EX_SOCKET
    b       exit
fail_setsockopt:
    mov     x0, #EX_SETSOCKOPT
    b       exit
fail_bind:
    mov     x0, #EX_BIND
    b       exit
fail_listen:
    mov     x0, #EX_LISTEN
    b       exit
fail_accept:
    mov     x0, #EX_ACCEPT
    b       exit
fail_fcntl:
    mov     x0, #EX_FCNTL
    b       exit
fail_kqueue:
    mov     x0, #EX_KQUEUE
    b       exit
fail_kevent:
    mov     x0, #EX_KEVENT
exit:
    sys     SYS_exit

// kev_fill: x0 entry, x1 ident, x2 filter, x3 flags, x4 data, x5 udata. clobbers x9
kev_fill:
    adrp    x9, kev_chg@PAGE
    add     x9, x9, kev_chg@PAGEOFF
    add     x9, x9, x0, lsl #KEV_SHIFT
    str     x1, [x9, #KEV_IDENT]
    strh    w2, [x9, #KEV_FILTER]
    strh    w3, [x9, #KEV_FLAGS]
    str     wzr, [x9, #KEV_FFLAGS]
    str     x4, [x9, #KEV_DATA]
    str     x5, [x9, #KEV_UDATA]
    ret

// kev_submit: x0 entries -> x0 = 0 or errno. clobbers x0-x5
kev_submit:
    mov     x2, x0
    adrp    x0, kq@PAGE
    add     x0, x0, kq@PAGEOFF
    ldr     w0, [x0]
    adrp    x1, kev_chg@PAGE
    add     x1, x1, kev_chg@PAGEOFF
    mov     x3, #0
    mov     x4, #0
    mov     x5, #0
    sys     SYS_kevent
    b.cs    1f
    mov     x0, #0
1:  ret

// kev_change: x0 ident, x1 filter, x2 flags -> x0 = 0 or errno. clobbers x0-x5, x9
kev_change:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x3, x2
    mov     x2, x1
    mov     x1, x0
    mov     x0, #0
    mov     x4, #0
    mov     x5, #0
    bl      kev_fill
    mov     x0, #1
    bl      kev_submit
    ldp     x29, x30, [sp], #16
    ret

// timer_fill: x0 entry -> one-shot idle timer for x20, udata = slot generation. clobbers x0-x5, x9, x11
timer_fill:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    slot
    ldr     x5, [x11, #CONN_GEN]
    mov     x1, x20
    mov     x2, #EVFILT_TIMER
    mov     x3, #EV_ADD_ONESHOT
    mov     x4, #IDLE_TIMEOUT_MS
    bl      kev_fill
    ldp     x29, x30, [sp], #16
    ret

// release_fd: delete x20's timer (ENOENT if it fired), free the slot, close. clobbers x0-x5, x9, x11
release_fd:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x0, #0
    mov     x1, x20
    mov     x2, #EVFILT_TIMER
    mov     x3, #EV_DELETE
    mov     x4, #0
    mov     x5, #0
    bl      kev_fill
    mov     x0, #1
    bl      kev_submit
    cbz     x0, 1f
    cmp     x0, #ENOENT
    b.ne    fail_kevent
1:  slot
    str     xzr, [x11, #CONN_STATE]
    mov     x0, x20
    sys     SYS_close
    ldp     x29, x30, [sp], #16
    ret

// build_metrics: body at x21+METRICS_BODY_OFF, headers at x21, body moved down after them.
//                -> x27 ptr, x28 header len, x0 body len. clobbers x0-x5, x9-x14
build_metrics:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x27, x21
    add     x9, x27, #METRICS_BODY_OFF
    adrp    x10, metric_table@PAGE
    add     x10, x10, metric_table@PAGEOFF
    adrp    x11, metric_table_end@PAGE
    add     x11, x11, metric_table_end@PAGEOFF
    adrp    x12, counters@PAGE
    add     x12, x12, counters@PAGEOFF
    adrp    x13, mnames@PAGE
    add     x13, x13, mnames@PAGEOFF
Lbm_entry:
    cmp     x10, x11
    b.hs    Lbm_headers
    ldr     x0, [x10, #MT_NAME]
    add     x0, x13, x0
    ldr     x1, [x10, #MT_NAME_LEN]
    mov     x2, x9
    bl      copy_span
    mov     w3, #' '
    strb    w3, [x2], #1
    ldr     x0, [x10, #MT_COUNTER]
    ldr     x0, [x12, x0]
    mov     x1, x2
    bl      u64_to_ascii
    add     x9, x1, x0
    mov     w3, #'\n'
    strb    w3, [x9], #1
    add     x10, x10, #MT_SIZE
    b       Lbm_entry
Lbm_headers:
    add     x14, x27, #METRICS_BODY_OFF
    sub     x14, x9, x14                    // body len
    adrp    x0, mhdr_a@PAGE
    add     x0, x0, mhdr_a@PAGEOFF
    mov     x1, #mhdr_a_len
    mov     x2, x27
    bl      copy_span
    mov     x0, x14
    mov     x1, x2
    bl      u64_to_ascii
    add     x2, x1, x0
    adrp    x0, mhdr_b@PAGE
    add     x0, x0, mhdr_b@PAGEOFF
    mov     x1, #mhdr_b_len
    bl      copy_span
    sub     x28, x2, x27                    // header len
    add     x0, x27, #METRICS_BODY_OFF
    mov     x1, x14
    bl      copy_span                       // dst < src
    mov     x0, x14
    ldp     x29, x30, [sp], #16
    ret
