// apollod-min: socket, bind, listen, accept, read, write, close. Every connection gets 200 OK.

.equ SYS_exit,       1
.equ SYS_read,       3
.equ SYS_write,      4
.equ SYS_close,      6
.equ SYS_accept,     30
.equ SYS_socket,     97
.equ SYS_bind,       104
.equ SYS_setsockopt, 105
.equ SYS_listen,     106

.equ AF_INET,        2
.equ SOCK_STREAM,    1
.equ SOL_SOCKET,     0xffff
.equ SO_REUSEADDR,   0x0004
.equ SO_NOSIGPIPE,   0x1022
.equ EINTR,          4
.equ ECONNABORTED,   53
.equ BACKLOG,        128
.equ BUF_CAP,        8192

.macro sys nr
    mov     x16, #\nr
    svc     #0x80
.endm

.section __TEXT,__const
sockaddr:   .byte   16, AF_INET, 0x1f, 0x90, 127, 0, 0, 1
            .byte   0, 0, 0, 0, 0, 0, 0, 0
resp:       .ascii  "HTTP/1.1 200 OK\r\n"
            .ascii  "Content-Length: 2\r\n"
            .ascii  "Connection: close\r\n"
            .ascii  "\r\n"
resp_body:  .ascii  "OK"
.equ resp_len, . - resp
.if . - resp_body != 2
.error "Content-Length"
.endif

.data
one:        .long   1
.zerofill __DATA,__bss,buf,BUF_CAP,4

// x19 = listen fd, x20 = client fd
.text
.globl _start
.p2align 2
_start:
    mov     x0, #AF_INET
    mov     x1, #SOCK_STREAM
    mov     x2, #0
    sys     SYS_socket
    b.cs    die
    mov     x19, x0
    mov     x0, x19
    mov     x1, #SOL_SOCKET
    mov     x2, #SO_REUSEADDR
    adrp    x3, one@PAGE
    add     x3, x3, one@PAGEOFF
    mov     x4, #4
    sys     SYS_setsockopt
    b.cs    die
    mov     x0, x19
    mov     x1, #SOL_SOCKET                 // x1 is clobbered by the trap
    mov     x2, #SO_NOSIGPIPE
    adrp    x3, one@PAGE
    add     x3, x3, one@PAGEOFF
    mov     x4, #4
    sys     SYS_setsockopt
    b.cs    die
    mov     x0, x19
    adrp    x1, sockaddr@PAGE
    add     x1, x1, sockaddr@PAGEOFF
    mov     x2, #16
    sys     SYS_bind
    b.cs    die
    mov     x0, x19
    mov     x1, #BACKLOG
    sys     SYS_listen
    b.cs    die
accept_loop:
    mov     x0, x19
    mov     x1, #0
    mov     x2, #0
    sys     SYS_accept
    b.cs    accept_err
    mov     x20, x0
    adrp    x1, buf@PAGE
    add     x1, x1, buf@PAGEOFF
    mov     x2, #BUF_CAP
    sys     SYS_read
    mov     x0, x20
    adrp    x1, resp@PAGE
    add     x1, x1, resp@PAGEOFF
    mov     x2, #resp_len
    sys     SYS_write
    mov     x0, x20
    sys     SYS_close
    b       accept_loop
accept_err:
    cmp     x0, #EINTR
    b.eq    accept_loop
    cmp     x0, #ECONNABORTED
    b.eq    accept_loop
die:
    mov     x0, #1
    sys     SYS_exit
