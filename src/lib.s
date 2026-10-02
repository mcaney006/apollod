// apollod lib: pure routines, no syscalls, no writes to globals

.equ METHOD_MAX,      16
.equ TARGET_MAX,      1024
.equ HEADER_NAME_MAX, 64
.equ CLEN_DIGITS_MAX, 19            // fits in 64 bits

// parse_headers flag bits (x2)
.equ HF_HOST,       1
.equ HF_CLOSE,      2
.equ HF_KEEPALIVE,  4

.section __TEXT,__const
m_get:          .ascii  "GET"
.equ m_get_len, . - m_get
m_head:         .ascii  "HEAD"
.equ m_head_len, . - m_head
h_host:         .ascii  "host"
.equ h_host_len, . - h_host
h_connection:   .ascii  "connection"
.equ h_connection_len, . - h_connection
h_clen:         .ascii  "content-length"
.equ h_clen_len, . - h_clen
v_close:        .ascii  "close"
.equ v_close_len, . - v_close
v_keepalive:    .ascii  "keep-alive"
.equ v_keepalive_len, . - v_keepalive

.text
.p2align 2

// span_eq: x0/x1 = a ptr/len, x2/x3 = b ptr/len -> x0 = 1 equal, 0 otherwise. clobbers x0-x5
.globl span_eq
span_eq:
    cmp     x1, x3
    b.ne    Lse_no
Lse_loop:
    cbz     x1, Lse_yes
    ldrb    w4, [x0], #1
    ldrb    w5, [x2], #1
    sub     x1, x1, #1
    cmp     w4, w5
    b.eq    Lse_loop
Lse_no:
    mov     x0, #0
    ret
Lse_yes:
    mov     x0, #1
    ret

// span_ieq: as span_eq, with A-Z in a folded to a-z; b must already be lowercase. clobbers x0-x6
.globl span_ieq
span_ieq:
    cmp     x1, x3
    b.ne    Lsi_no
Lsi_loop:
    cbz     x1, Lsi_yes
    ldrb    w4, [x0], #1
    ldrb    w5, [x2], #1
    sub     x1, x1, #1
    sub     w6, w4, #'A'
    cmp     w6, #25
    b.hi    1f
    add     w4, w4, #32
1:  cmp     w4, w5
    b.eq    Lsi_loop
Lsi_no:
    mov     x0, #0
    ret
Lsi_yes:
    mov     x0, #1
    ret

// parse_request: x21 buf, x22 len -> x0: 0 ok, 1 malformed, 2 method not allowed
//   x24 = method (0 GET, 1 HEAD); x25/x26 = route ptr/len (target with query stripped)
//   x23 = one past the request line CRLF (first header line). clobbers x0-x5, x9-x14
.globl parse_request
parse_request:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x23, x21
    add     x9, x21, x22                // end
    mov     x10, x23                    // method start
Lpr_method:
    cmp     x23, x9
    b.hs    Lpr_bad
    ldrb    w11, [x23]
    cmp     w11, #' '
    b.eq    Lpr_method_end
    sub     w12, w11, #'A'
    cmp     w12, #25
    b.hi    Lpr_bad                     // token: A-Z only
    add     x23, x23, #1
    sub     x13, x23, x10
    cmp     x13, #METHOD_MAX
    b.hi    Lpr_bad
    b       Lpr_method
Lpr_method_end:
    sub     x13, x23, x10               // method len
    cbz     x13, Lpr_bad
    add     x23, x23, #1                // SP
    mov     x0, x10
    mov     x1, x13
    adrp    x2, m_get@PAGE
    add     x2, x2, m_get@PAGEOFF
    mov     x3, #m_get_len
    bl      span_eq
    cbnz    x0, Lpr_get
    mov     x0, x10
    mov     x1, x13
    adrp    x2, m_head@PAGE
    add     x2, x2, m_head@PAGEOFF
    mov     x3, #m_head_len
    bl      span_eq
    cbz     x0, Lpr_405
    mov     x24, #1
    b       Lpr_target
Lpr_get:
    mov     x24, #0
Lpr_target:
    mov     x25, x23
    cmp     x23, x9
    b.hs    Lpr_bad
    ldrb    w11, [x23]
    cmp     w11, #'/'
    b.ne    Lpr_bad
Lpr_target_loop:
    cmp     x23, x9
    b.hs    Lpr_bad
    ldrb    w11, [x23]
    cmp     w11, #' '
    b.eq    Lpr_target_end
    sub     w12, w11, #0x21
    cmp     w12, #0x5d
    b.hi    Lpr_bad                     // visible ASCII 0x21..0x7e only
    add     x23, x23, #1
    sub     x13, x23, x25
    cmp     x13, #TARGET_MAX
    b.hi    Lpr_bad
    b       Lpr_target_loop
Lpr_target_end:
    sub     x26, x23, x25               // target len, >= 1
    add     x23, x23, #1                // SP
    add     x13, x23, #10               // "HTTP/1.x" CR LF
    cmp     x13, x9
    b.hi    Lpr_bad
    ldr     w14, [x23]
    mov     w12, #0x5448
    movk    w12, #0x5054, lsl #16       // "HTTP"
    cmp     w14, w12
    b.ne    Lpr_bad
    ldr     w14, [x23, #3]
    mov     w12, #0x2f50
    movk    w12, #0x2e31, lsl #16       // "P/1."
    cmp     w14, w12
    b.ne    Lpr_bad
    ldrb    w11, [x23, #7]
    sub     w11, w11, #'0'
    cmp     w11, #1
    b.hi    Lpr_bad                     // 1.0 or 1.1
    ldrh    w11, [x23, #8]
    cmp     w11, #0x0a0d
    b.ne    Lpr_bad
    add     x23, x23, #10               // past CRLF
    mov     x0, x25                     // route = target up to '?'
    mov     x1, x26
Lpr_query:
    cbz     x1, Lpr_ok
    ldrb    w11, [x0]
    cmp     w11, #'?'
    b.eq    Lpr_strip
    add     x0, x0, #1
    sub     x1, x1, #1
    b       Lpr_query
Lpr_strip:
    sub     x26, x0, x25
Lpr_ok:
    mov     x0, #0
    b       Lpr_ret
Lpr_bad:
    mov     x0, #1
    b       Lpr_ret
Lpr_405:
    mov     x0, #2
Lpr_ret:
    ldp     x29, x30, [sp], #16
    ret

// parse_headers: x21 buf, x22 len, x23 = first header line -> x0: 0 ok, 1 malformed
//   x1 = Content-Length (0 if absent), x2 = HF_* flags, x23 = one past the empty line.
//   line = name ":" OWS value OWS CRLF; name 1..64 bytes of 0x21..0x7e except ':';
//   value bytes 0x20..0x7e or HTAB. Names matched case-insensitively. clobbers x0-x6, x9-x15
.globl parse_headers
parse_headers:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    add     x9, x21, x22                // end
    mov     x14, #0                     // content-length
    mov     x15, #0                     // flags
Lph_line:
    add     x10, x23, #2
    cmp     x10, x9
    b.hi    Lph_bad
    ldrh    w11, [x23]
    cmp     w11, #0x0a0d
    b.eq    Lph_done                    // empty line
    mov     x10, x23                    // name start
Lph_name:
    cmp     x23, x9
    b.hs    Lph_bad
    ldrb    w11, [x23]
    cmp     w11, #':'
    b.eq    Lph_name_end
    sub     w12, w11, #0x21
    cmp     w12, #0x5d
    b.hi    Lph_bad
    add     x23, x23, #1
    sub     x12, x23, x10
    cmp     x12, #HEADER_NAME_MAX
    b.hi    Lph_bad
    b       Lph_name
Lph_name_end:
    sub     x12, x23, x10               // name len
    cbz     x12, Lph_bad
    add     x23, x23, #1                // ':'
Lph_ows:
    cmp     x23, x9
    b.hs    Lph_bad
    ldrb    w11, [x23]
    cmp     w11, #' '
    ccmp    w11, #'\t', #4, ne
    b.ne    Lph_value
    add     x23, x23, #1
    b       Lph_ows
Lph_value:
    mov     x13, x23                    // value start
Lph_vscan:
    cmp     x23, x9
    b.hs    Lph_bad
    ldrb    w11, [x23]
    cmp     w11, #'\r'
    b.eq    Lph_vend
    cmp     w11, #'\t'
    b.eq    1f
    sub     w11, w11, #0x20
    cmp     w11, #0x5e
    b.hi    Lph_bad
1:  add     x23, x23, #1
    b       Lph_vscan
Lph_vend:
    add     x11, x23, #2
    cmp     x11, x9
    b.hi    Lph_bad
    ldrb    w11, [x23, #1]
    cmp     w11, #'\n'
    b.ne    Lph_bad
    mov     x11, x23                    // value end, then trim trailing OWS
Lph_trim:
    cmp     x11, x13
    b.ls    Lph_classify
    ldrb    w5, [x11, #-1]
    cmp     w5, #' '
    ccmp    w5, #'\t', #4, ne
    b.ne    Lph_classify
    sub     x11, x11, #1
    b       Lph_trim
Lph_classify:
    sub     x11, x11, x13               // value len; x10/x12 = name ptr/len, x13/x11 = value ptr/len
    mov     x0, x10
    mov     x1, x12
    adrp    x2, h_host@PAGE
    add     x2, x2, h_host@PAGEOFF
    mov     x3, #h_host_len
    bl      span_ieq
    cbz     x0, 3f
    orr     x15, x15, #HF_HOST
    b       Lph_next
3:  mov     x0, x10
    mov     x1, x12
    adrp    x2, h_connection@PAGE
    add     x2, x2, h_connection@PAGEOFF
    mov     x3, #h_connection_len
    bl      span_ieq
    cbz     x0, 5f
    mov     x0, x13
    mov     x1, x11
    adrp    x2, v_close@PAGE
    add     x2, x2, v_close@PAGEOFF
    mov     x3, #v_close_len
    bl      span_ieq
    cbz     x0, 4f
    orr     x15, x15, #HF_CLOSE
    b       Lph_next
4:  mov     x0, x13
    mov     x1, x11
    adrp    x2, v_keepalive@PAGE
    add     x2, x2, v_keepalive@PAGEOFF
    mov     x3, #v_keepalive_len
    bl      span_ieq
    cbz     x0, Lph_next
    orr     x15, x15, #HF_KEEPALIVE
    b       Lph_next
5:  mov     x0, x10
    mov     x1, x12
    adrp    x2, h_clen@PAGE
    add     x2, x2, h_clen@PAGEOFF
    mov     x3, #h_clen_len
    bl      span_ieq
    cbz     x0, Lph_next
    cbz     x11, Lph_bad                // Content-Length: 1..19 digits, nothing else
    cmp     x11, #CLEN_DIGITS_MAX
    b.hi    Lph_bad
    mov     x14, #0
    mov     x0, x13
    mov     x5, #10
6:  cbz     x11, Lph_next
    ldrb    w1, [x0], #1
    sub     w1, w1, #'0'
    cmp     w1, #9
    b.hi    Lph_bad
    madd    x14, x14, x5, x1
    sub     x11, x11, #1
    b       6b
Lph_next:
    add     x23, x23, #2                // CRLF
    b       Lph_line
Lph_done:
    add     x23, x23, #2
    mov     x0, #0
    mov     x1, x14
    mov     x2, x15
    b       Lph_ret
Lph_bad:
    mov     x0, #1
Lph_ret:
    ldp     x29, x30, [sp], #16
    ret

// u64_to_ascii: x0 value, x1 dst (>= 20 bytes) -> x0 digit count. x1 preserved. clobbers x2-x5
.globl u64_to_ascii
u64_to_ascii:
    mov     x2, #0
    mov     x3, x0
    mov     x5, #10
Lua_count:
    add     x2, x2, #1
    udiv    x3, x3, x5
    cbnz    x3, Lua_count
    add     x4, x1, x2                  // one past the last digit
Lua_emit:
    udiv    x3, x0, x5
    msub    x0, x3, x5, x0
    add     x0, x0, #'0'
    strb    w0, [x4, #-1]!
    mov     x0, x3
    cbnz    x0, Lua_emit
    mov     x0, x2
    ret

// copy_span: x0 src, x1 len, x2 dst -> x2 = dst + len. clobbers x0, x1, x3. forward copy: dst must not be inside (src, src+len)
.globl copy_span
copy_span:
    cbz     x1, Lcs_done
    ldrb    w3, [x0], #1
    strb    w3, [x2], #1
    sub     x1, x1, #1
    b       copy_span
Lcs_done:
    ret
