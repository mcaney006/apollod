// apollod unit tests: exit status = index of first failing check, 0 = all pass
// x19 = current check number
// constants precede code: `. - label` must be absolute where it is used as an immediate

.equ SYS_exit,        1
.equ SYS_write,       4
.equ SYS_close,       6
.equ SYS_accept,      30
.equ SYS_getsockname, 32
.equ SYS_socket,      97
.equ SYS_connect,     98
.equ SYS_bind,        104
.equ SYS_setsockopt,  105
.equ SYS_listen,      106
.equ SYS_getsockopt,  118
.equ EBADF,           9
.equ AF_INET,         2
.equ SOCK_STREAM,     1
.equ SOL_SOCKET,      0xffff
.equ SO_NOSIGPIPE,    0x1022

.arch_extension lse

.macro sys nr
    mov     x16, #\nr
    svc     #0x80
.endm

.data
.p2align 3
actr:       .quad   0
.p2align 2
one:        .long   1
sa:         .byte   16, AF_INET, 0, 0, 127, 0, 0, 1     // port 0: kernel assigns; getsockname fills it in
            .byte   0, 0, 0, 0, 0, 0, 0, 0
salen:      .long   16
optval:     .long   0
optlen:     .long   4

.section __TEXT,__const
ok_msg:     .ascii  "unit: ok\n"
.equ ok_len, . - ok_msg

r_get:      .ascii  "GET / HTTP/1.1\r\n\r\n"
.equ r_get_len, . - r_get
r_head:     .ascii  "HEAD /health?x=1 HTTP/1.0\r\nHost: a\r\n\r\n"
.equ r_head_len, . - r_head
r_post:     .ascii  "POST / HTTP/1.1\r\n\r\n"
.equ r_post_len, . - r_post
r_lower:    .ascii  "get / HTTP/1.1\r\n\r\n"
.equ r_lower_len, . - r_lower
r_dblsp:    .ascii  "GET  / HTTP/1.1\r\n\r\n"
.equ r_dblsp_len, . - r_dblsp
r_http2:    .ascii  "GET / HTTP/2.0\r\n\r\n"
.equ r_http2_len, . - r_http2
r_lf:       .ascii  "GET / HTTP/1.1\n\n"
.equ r_lf_len, . - r_lf
r_ctl:      .ascii  "GET /\001 HTTP/1.1\r\n\r\n"
.equ r_ctl_len, . - r_ctl
r_longm:    .ascii  "AAAAAAAAAAAAAAAAA / HTTP/1.1\r\n\r\n"    // 17-byte method
.equ r_longm_len, . - r_longm
r_trunc:    .ascii  "GET / HTTP/1.1"
.equ r_trunc_len, . - r_trunc
r_query:    .ascii  "GET /?q=1 HTTP/1.1\r\n\r\n"
.equ r_query_len, . - r_query
r_tmax:     .ascii  "GET /"
            .fill   1023, 1, 'a'                    // 1024-byte target: allowed
            .ascii  " HTTP/1.1\r\n\r\n"
.equ r_tmax_len, . - r_tmax
r_tover:    .ascii  "GET /"
            .fill   1024, 1, 'a'                    // 1025-byte target: rejected
            .ascii  " HTTP/1.1\r\n\r\n"
.equ r_tover_len, . - r_tover
r_norel:    .ascii  "GET health HTTP/1.1\r\n\r\n"
.equ r_norel_len, . - r_norel
r_nometh:   .ascii  " / HTTP/1.1\r\n\r\n"
.equ r_nometh_len, . - r_nometh

s_a:        .ascii  "/health"
.equ s_a_len, . - s_a
s_b:        .ascii  "/healtx"
.equ s_b_len, . - s_b
s_up:       .ascii  "Content-LENGTH"
.equ s_up_len, . - s_up
s_lo:       .ascii  "content-length"
.equ s_lo_len, . - s_lo

d_0:        .ascii  "0"
.equ d_0_len, . - d_0
d_1:        .ascii  "1"
.equ d_1_len, . - d_1
d_9:        .ascii  "9"
.equ d_9_len, . - d_9
d_10:       .ascii  "10"
.equ d_10_len, . - d_10
d_99:       .ascii  "99"
.equ d_99_len, . - d_99
d_100:      .ascii  "100"
.equ d_100_len, . - d_100
d_999:      .ascii  "999"
.equ d_999_len, . - d_999
d_1000:     .ascii  "1000"
.equ d_1000_len, . - d_1000
d_u32:      .ascii  "4294967295"
.equ d_u32_len, . - d_u32
d_u64:      .ascii  "18446744073709551615"
.equ d_u64_len, . - d_u64

hd_host:    .ascii  "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
.equ hd_host_len, . - hd_host
hd_none:    .ascii  "GET / HTTP/1.1\r\n\r\n"
.equ hd_none_len, . - hd_none
hd_mixed:   .ascii  "GET / HTTP/1.1\r\nhost: a\r\nCONNECTION: Close\r\nContent-length:  12 \r\nX-Other: y\r\n\r\n"
.equ hd_mixed_len, . - hd_mixed
hd_keep:    .ascii  "GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n"
.equ hd_keep_len, . - hd_keep
hd_clbad:   .ascii  "GET / HTTP/1.1\r\nContent-Length: 12a\r\n\r\n"
.equ hd_clbad_len, . - hd_clbad
hd_cl20:    .ascii  "GET / HTTP/1.1\r\nContent-Length: 12345678901234567890\r\n\r\n"
.equ hd_cl20_len, . - hd_cl20
hd_cl19:    .ascii  "GET / HTTP/1.1\r\nContent-Length: 1234567890123456789\r\n\r\n"
.equ hd_cl19_len, . - hd_cl19
hd_clempty: .ascii  "GET / HTTP/1.1\r\nContent-Length: \r\n\r\n"
.equ hd_clempty_len, . - hd_clempty
hd_nocolon: .ascii  "GET / HTTP/1.1\r\nNoColon\r\n\r\n"
.equ hd_nocolon_len, . - hd_nocolon
hd_lf:      .ascii  "GET / HTTP/1.1\r\nHost: a\n\n"
.equ hd_lf_len, . - hd_lf
hd_fold:    .ascii  "GET / HTTP/1.1\r\nHost: a\r\n b\r\n\r\n"
.equ hd_fold_len, . - hd_fold
hd_noname:  .ascii  "GET / HTTP/1.1\r\n: x\r\n\r\n"
.equ hd_noname_len, . - hd_noname
hd_name64:  .ascii  "GET / HTTP/1.1\r\n"
            .fill   64, 1, 'a'
            .ascii  ": v\r\n\r\n"
.equ hd_name64_len, . - hd_name64
hd_name65:  .ascii  "GET / HTTP/1.1\r\n"
            .fill   65, 1, 'a'
            .ascii  ": v\r\n\r\n"
.equ hd_name65_len, . - hd_name65
hd_cl0:     .ascii  "GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
.equ hd_cl0_len, . - hd_cl0
hd_trim:    .ascii  "GET / HTTP/1.1\r\nConnection: close \t\r\n\r\n"
.equ hd_trim_len, . - hd_trim
hd_ctl:     .ascii  "GET / HTTP/1.1\r\nHost: a\001b\r\n\r\n"
.equ hd_ctl_len, . - hd_ctl
hd_colon2:  .ascii  "GET / HTTP/1.1\r\nHost: a:b\r\n\r\n"
.equ hd_colon2_len, . - hd_colon2

.zerofill __DATA,__bss,dbuf,32,3

// parse: run parse_request on \buf, require result \want
.macro parse num, buf, want
    mov     x19, #\num
    adrp    x21, \buf@PAGE
    add     x21, x21, \buf@PAGEOFF
    mov     x22, #\buf\()_len
    bl      parse_request
    cmp     x0, #\want
    b.ne    fail
.endm

// hdrs: parse_request must succeed, then parse_headers must return \want
.macro hdrs num, buf, want
    mov     x19, #\num
    adrp    x21, \buf@PAGE
    add     x21, x21, \buf@PAGEOFF
    mov     x22, #\buf\()_len
    bl      parse_request
    cbnz    x0, fail
    bl      parse_headers
    cmp     x0, #\want
    b.ne    fail
.endm

// u64: format \val into dbuf, compare the digits against literal \want
.macro u64 num, val, want
    mov     x19, #\num
    ldr     x0, =\val
    adrp    x1, dbuf@PAGE
    add     x1, x1, dbuf@PAGEOFF
    bl      u64_to_ascii
    mov     x2, x1
    mov     x1, x0
    mov     x0, x2
    adrp    x2, \want@PAGE
    add     x2, x2, \want@PAGEOFF
    mov     x3, #\want\()_len
    bl      span_eq
    cbz     x0, fail
.endm

.text
.globl _start
.p2align 2
_start:
    // 1: write(-1, ...) -> C set, x0 = EBADF
    mov     x19, #1
    mov     x0, #-1
    adrp    x1, ok_msg@PAGE
    add     x1, x1, ok_msg@PAGEOFF
    mov     x2, #ok_len
    mov     x16, #SYS_write
    svc     #0x80
    b.cc    fail
    cmp     x0, #EBADF
    b.ne    fail

    // 2: write(1, ...) -> C clear, x0 = len
    mov     x19, #2
    mov     x0, #1
    adrp    x1, ok_msg@PAGE
    add     x1, x1, ok_msg@PAGEOFF
    mov     x2, #ok_len
    mov     x16, #SYS_write
    svc     #0x80
    b.cs    fail
    mov     x9, #ok_len
    cmp     x0, x9
    b.ne    fail

    // 3: GET / -> ok, GET, route "/" at offset 4, cursor one past the request line
    parse   3, r_get, 0
    cbnz    x24, fail
    cmp     x26, #1
    b.ne    fail
    sub     x9, x25, x21
    cmp     x9, #4
    b.ne    fail
    sub     x9, x23, x21
    cmp     x9, #16
    b.ne    fail

    // 4: HEAD /health?x=1 HTTP/1.0 -> ok, HEAD, route "/health" at offset 5
    parse   4, r_head, 0
    cmp     x24, #1
    b.ne    fail
    cmp     x26, #7
    b.ne    fail
    sub     x9, x25, x21
    cmp     x9, #5
    b.ne    fail

    // 5: POST -> method not allowed
    parse   5, r_post, 2

    // 6-12: malformed
    parse   6, r_lower, 1
    parse   7, r_dblsp, 1
    parse   8, r_http2, 1
    parse   9, r_lf, 1
    parse   10, r_ctl, 1
    parse   11, r_longm, 1
    parse   12, r_trunc, 1

    // 13: query stripped from route
    parse   13, r_query, 0
    cmp     x26, #1
    b.ne    fail

    // 14: target at the bound
    parse   14, r_tmax, 0
    cmp     x26, #1024
    b.ne    fail

    // 15-17: over the bound, non-rooted target, empty method
    parse   15, r_tover, 1
    parse   16, r_norel, 1
    parse   17, r_nometh, 1

    // 18: span_eq equal
    mov     x19, #18
    adrp    x0, s_a@PAGE
    add     x0, x0, s_a@PAGEOFF
    mov     x1, #s_a_len
    adrp    x2, s_a@PAGE
    add     x2, x2, s_a@PAGEOFF
    mov     x3, #s_a_len
    bl      span_eq
    cmp     x0, #1
    b.ne    fail

    // 19: same length, last byte differs
    mov     x19, #19
    adrp    x0, s_a@PAGE
    add     x0, x0, s_a@PAGEOFF
    mov     x1, #s_a_len
    adrp    x2, s_b@PAGE
    add     x2, x2, s_b@PAGEOFF
    mov     x3, #s_b_len
    bl      span_eq
    cbnz    x0, fail

    // 20: same bytes, different length
    mov     x19, #20
    adrp    x0, s_a@PAGE
    add     x0, x0, s_a@PAGEOFF
    mov     x1, #s_a_len
    adrp    x2, s_a@PAGE
    add     x2, x2, s_a@PAGEOFF
    mov     x3, #6
    bl      span_eq
    cbnz    x0, fail

    // 21-30: u64_to_ascii
    u64     21, 0, d_0
    u64     22, 1, d_1
    u64     23, 9, d_9
    u64     24, 10, d_10
    u64     25, 99, d_99
    u64     26, 100, d_100
    u64     27, 999, d_999
    u64     28, 1000, d_1000
    u64     29, 0xffffffff, d_u32
    u64     30, 0xffffffffffffffff, d_u64

    // 31: span_ieq folds A-Z on the first operand
    mov     x19, #31
    adrp    x0, s_up@PAGE
    add     x0, x0, s_up@PAGEOFF
    mov     x1, #s_up_len
    adrp    x2, s_lo@PAGE
    add     x2, x2, s_lo@PAGEOFF
    mov     x3, #s_lo_len
    bl      span_ieq
    cmp     x0, #1
    b.ne    fail

    // 32: Host only -> HF_HOST, Content-Length 0, cursor at end
    hdrs    32, hd_host, 0
    cmp     x2, #1
    b.ne    fail
    cbnz    x1, fail
    add     x9, x21, x22
    cmp     x23, x9
    b.ne    fail

    // 33: no headers -> no flags
    hdrs    33, hd_none, 0
    cbnz    x2, fail
    cbnz    x1, fail

    // 34: mixed case, OWS both sides, unknown header ignored
    hdrs    34, hd_mixed, 0
    cmp     x2, #3
    b.ne    fail
    cmp     x1, #12
    b.ne    fail

    // 35: keep-alive
    hdrs    35, hd_keep, 0
    cmp     x2, #4
    b.ne    fail

    // 36-38: Content-Length not digits, 20 digits, empty
    hdrs    36, hd_clbad, 1
    hdrs    37, hd_cl20, 1
    hdrs    38, hd_clempty, 1

    // 39: 19 digits parse exactly
    hdrs    39, hd_cl19, 0
    ldr     x9, =1234567890123456789
    cmp     x1, x9
    b.ne    fail

    // 40-44: no colon, LF only, obs-fold, empty name, control byte in value
    hdrs    40, hd_nocolon, 1
    hdrs    41, hd_lf, 1
    hdrs    42, hd_fold, 1
    hdrs    43, hd_noname, 1
    hdrs    44, hd_ctl, 1

    // 45-46: name length at the bound and one past
    hdrs    45, hd_name64, 0
    hdrs    46, hd_name65, 1

    // 47: Content-Length: 0
    hdrs    47, hd_cl0, 0
    cbnz    x1, fail

    // 48: trailing OWS trimmed before matching the value
    hdrs    48, hd_trim, 0
    cmp     x2, #2
    b.ne    fail

    // 49: colon inside a value is just a byte
    hdrs    49, hd_colon2, 0
    cmp     x2, #1
    b.ne    fail

    // 50: SO_NOSIGPIPE set on a listener is inherited by accept()ed sockets.
    //     listener on 127.0.0.1:0, connect to it from the same process, accept, getsockopt.
    mov     x19, #50
    mov     x0, #AF_INET
    mov     x1, #SOCK_STREAM
    mov     x2, #0
    sys     SYS_socket
    b.cs    fail
    mov     x20, x0                     // listener
    mov     x0, x20
    mov     x1, #SOL_SOCKET
    mov     x2, #SO_NOSIGPIPE
    adrp    x3, one@PAGE
    add     x3, x3, one@PAGEOFF
    mov     x4, #4
    sys     SYS_setsockopt
    b.cs    fail
    mov     x0, x20
    adrp    x1, sa@PAGE
    add     x1, x1, sa@PAGEOFF
    mov     x2, #16
    sys     SYS_bind
    b.cs    fail
    mov     x0, x20
    mov     x1, #1
    sys     SYS_listen
    b.cs    fail
    mov     x0, x20
    adrp    x1, sa@PAGE
    add     x1, x1, sa@PAGEOFF
    adrp    x2, salen@PAGE
    add     x2, x2, salen@PAGEOFF
    sys     SYS_getsockname             // sa.sin_port now holds the assigned port
    b.cs    fail
    mov     x0, #AF_INET
    mov     x1, #SOCK_STREAM
    mov     x2, #0
    sys     SYS_socket
    b.cs    fail
    mov     x21, x0                     // client
    mov     x0, x21
    adrp    x1, sa@PAGE
    add     x1, x1, sa@PAGEOFF
    mov     x2, #16
    sys     SYS_connect                 // loopback handshake completes in-kernel before accept
    b.cs    fail
    mov     x0, x20
    mov     x1, #0
    mov     x2, #0
    sys     SYS_accept
    b.cs    fail
    mov     x22, x0                     // accepted
    mov     x0, x22
    mov     x1, #SOL_SOCKET
    mov     x2, #SO_NOSIGPIPE
    adrp    x3, optval@PAGE
    add     x3, x3, optval@PAGEOFF
    adrp    x4, optlen@PAGE
    add     x4, x4, optlen@PAGEOFF
    sys     SYS_getsockopt
    b.cs    fail
    adrp    x9, optval@PAGE
    add     x9, x9, optval@PAGEOFF
    ldr     w9, [x9]
    cbz     w9, fail                    // not inherited
    mov     x0, x22
    sys     SYS_close
    mov     x0, x21
    sys     SYS_close
    mov     x0, x20
    sys     SYS_close

    // 51-52: stadd, ldadd
    mov     x19, #51
    adrp    x9, actr@PAGE
    add     x9, x9, actr@PAGEOFF
    mov     x10, #1
    stadd   x10, [x9]
    ldr     x10, [x9]
    cmp     x10, #1
    b.ne    fail
    mov     x19, #52
    mov     x0, #41
    ldadd   x0, x1, [x9]
    cmp     x1, #1
    b.ne    fail
    ldr     x10, [x9]
    cmp     x10, #42
    b.ne    fail

    mov     x0, #0
    b       exit
fail:
    mov     x0, x19
exit:
    mov     x16, #SYS_exit
    svc     #0x80
