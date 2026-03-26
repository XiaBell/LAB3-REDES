; subscriber_quic.asm
; Suscriptor QUIC - lab 3
;
; Se registra en el broker y recibe mensajes del partido.
; El seq en TYPE_MSG lo pone el broker y es monotonico por tema, asi varios
; publicadores del mismo partido no generan seq duplicados en el suscriptor.
; Con eso se detecta perdida/desorden entre mensajes del flujo agregado.
;
; Uso: ./subscriber_quic <broker_ip> <broker_puerto> <mi_puerto> <tema>
; Compilar:
;   nasm -f elf64 subscriber_quic.asm -o ../bin/subscriber_quic.o
;   ld -o ../bin/subscriber_quic ../bin/subscriber_quic.o

bits 64
default rel

%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_SENDTO     44
%define SYS_RECVFROM   45
%define SYS_BIND       49
%define SYS_SETSOCKOPT 54
%define SYS_EXIT       60

%define AF_INET        2
%define SOCK_DGRAM     2
%define SOL_SOCKET     1
%define SO_REUSEADDR   2

%define TYPE_SUB       0x03
%define TYPE_MSG       0x04

%define BUF_SIZE       512
%define MAX_TOPIC      64

%macro exit_code 1
    mov  rax, SYS_EXIT
    mov  rdi, %1
    syscall
%endmacro

%macro write_lit 2
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [%1]
    mov  rdx, %2
    syscall
%endmacro

section .data

s_uso        db "Uso: ./subscriber_quic <broker_ip> <broker_puerto> <mi_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_sub_ok     db "[QUIC-SUB] Suscripcion enviada para tema: "
s_sub_ok_l   equ $ - s_sub_ok

s_waiting    db "[QUIC-SUB] Esperando mensajes...", 10
s_waiting_l  equ $ - s_waiting

; inicio de cada linea de mensaje: "[QUIC-SUB] seq=N [tema] : "
s_msg_pre    db "[QUIC-SUB] seq="
s_msg_pre_l  equ $ - s_msg_pre

s_msg_tema   db " ["
s_msg_tema_l equ $ - s_msg_tema

s_msg_sep    db "] : "
s_msg_sep_l  equ $ - s_msg_sep

; estado del orden al final de cada linea
s_orden_ok   db " (en orden)", 10
s_orden_ok_l equ $ - s_orden_ok

; llego un numero mayor al esperado: se saltaron mensajes
s_orden_gap  db " (AVISO: se saltaron numeros, posible perdida de mensajes)", 10
s_orden_gap_l equ $ - s_orden_gap

; llego un numero ya visto: duplicado o llego tarde
s_orden_dup  db " (AVISO: numero de secuencia repetido, posible duplicado)", 10
s_orden_dup_l equ $ - s_orden_dup

s_nl         db 10
s_nl_len     equ 1

s_err_sock   db "[QUIC-SUB] Error creando socket", 10
s_err_sock_l equ $ - s_err_sock

s_err_bind   db "[QUIC-SUB] Error en bind", 10
s_err_bind_l equ $ - s_err_bind

s_err_send   db "[QUIC-SUB] Error mandando suscripcion", 10
s_err_send_l equ $ - s_err_send

section .bss

sock_fd       resd 1
opt_val       resd 1
broker_addr   resb 16          ; a donde mandamos el SUB
my_addr       resb 16          ; nuestro puerto local (para el bind)
recv_buf      resb BUF_SIZE
sender_addr   resb 16
sender_len    resd 1
sub_buf       resb 128         ; paquete de suscripcion que mandamos al inicio

; ultimo numero de secuencia que procesamos
; empieza en 0, el primer mensaje tiene seq=1 que es exactamente 0+1 = en orden
last_recv_seq resd 1

tema_tmp      resb 70          ; nombre del partido extraido del MSG, con null
num_buf       resb 16

section .text
    global _start

_start:
    pop  rdi
    cmp  rdi, 5
    jl   .err_uso

    pop  rax                    ; argv[0] descartado
    pop  r12                    ; broker_ip
    pop  r13                    ; broker_puerto
    pop  r14                    ; mi_puerto
    pop  r15                    ; tema

    ; llenar broker_addr
    mov  rdi, r13
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8
    mov  word  [broker_addr + 0], AF_INET
    mov  word  [broker_addr + 2], cx
    mov  qword [broker_addr + 8], 0

    mov  rdi, r12
    call inet_aton_fn
    mov  dword [broker_addr + 4], eax

    ; llenar my_addr para el bind
    mov  rdi, r14
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8
    mov  word  [my_addr + 0], AF_INET
    mov  word  [my_addr + 2], cx
    mov  dword [my_addr + 4], 0   ; 0.0.0.0 = cualquier interfaz
    mov  qword [my_addr + 8], 0

    ; crear socket UDP
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_DGRAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    mov  dword [opt_val], 1
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [sock_fd]
    mov  rsi, SOL_SOCKET
    mov  rdx, SO_REUSEADDR
    lea  r10, [opt_val]
    mov  r8, 4
    syscall

    ; bind al puerto local: necesario para recibir los MSG del broker
    ; sin bind el broker no sabe a que puerto enviarnos los mensajes
    mov  rax, SYS_BIND
    movsx rdi, dword [sock_fd]
    lea  rsi, [my_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_bind

    ; construir el paquete SUB: [seq=0][TYPE_SUB][tema_len][tema]
    lea  rdi, [sub_buf]

    mov  dword [rdi], 0         ; seq = 0 (el broker lo ignora en SUBs)
    add  rdi, 4

    mov  byte [rdi], TYPE_SUB
    inc  rdi

    ; guardar puntero al campo tema_len y dejar espacio
    push rdi
    inc  rdi
    mov  rbx, rdi               ; rbx = donde empieza el tema en el buffer

    ; copiar el tema
    mov  rsi, r15
.copy_sub_tema:
    mov  al, [rsi]
    test al, al
    jz   .sub_tema_done
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_sub_tema
.sub_tema_done:
    ; calcular longitud del tema y escribirla en el campo que dejamos
    mov  rax, rdi
    sub  rax, rbx               ; rax = longitud del tema
    pop  rdx                    ; rdx = puntero al campo tema_len
    mov  byte [rdx], al

    ; longitud total del paquete
    lea  rax, [sub_buf]
    sub  rdi, rax
    mov  rbx, rdi

    ; mandar el paquete de suscripcion al broker
    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [sub_buf]
    mov  rdx, rbx
    xor  r10, r10
    lea  r8, [broker_addr]
    mov  r9, 16
    syscall
    test rax, rax
    js   .err_send

    write_lit s_sub_ok, s_sub_ok_l
    mov  rdi, r15
    call print_cstr_fn
    write_lit s_nl, 1
    write_lit s_waiting, s_waiting_l

    mov  dword [last_recv_seq], 0  ; antes del primer mensaje

; loop de recepcion
.recv_loop:
    mov  dword [sender_len], 16

    mov  rax, SYS_RECVFROM
    movsx rdi, dword [sock_fd]
    lea  rsi, [recv_buf]
    mov  rdx, BUF_SIZE - 1
    xor  r10, r10
    lea  r8,  [sender_addr]
    lea  r9,  [sender_len]
    syscall

    cmp  rax, 6
    jl   .recv_loop

    ; null al final para tratar el cuerpo como string
    lea  rdi, [recv_buf]
    add  rdi, rax
    mov  byte [rdi], 0

    ; solo procesamos TYPE_MSG
    cmp  byte [recv_buf + 4], TYPE_MSG
    jne  .recv_loop

    ; sacar el numero de secuencia (bytes 0-3)
    mov  r12d, dword [recv_buf]

    ; sacar el nombre del partido (byte 5 = longitud, bytes 6.. = el nombre)
    movzx r13d, byte [recv_buf + 5]
    cmp  r13d, MAX_TOPIC - 1
    jle  .tema_len_ok
    mov  r13d, MAX_TOPIC - 1
.tema_len_ok:
    lea  rdi, [tema_tmp]
    lea  rsi, [recv_buf + 6]
    mov  ecx, r13d
    call raw_copy_fn

    ; el cuerpo empieza despues del encabezado + el nombre del partido
    lea  r14, [recv_buf + 6]
    add  r14, r13

    ; verificar el orden comparando con el ultimo seq que recibimos
    mov  eax, r12d                      ; seq que acaba de llegar
    mov  ecx, dword [last_recv_seq]     ; ultimo seq que procesamos
    inc  ecx                            ; el que esperabamos recibir

    cmp  eax, ecx
    je   .order_ok
    jg   .order_gap
    ; si eax < ecx: llego un numero menor al esperado = duplicado

.order_dup:
    call .print_msg
    write_lit s_orden_dup, s_orden_dup_l
    ; no actualizamos last_recv_seq porque ya tenemos un numero mas alto
    jmp  .recv_loop

.order_ok:
    call .print_msg
    write_lit s_orden_ok, s_orden_ok_l
    mov  dword [last_recv_seq], r12d
    jmp  .recv_loop

.order_gap:
    ; llego un numero mayor al esperado: se saltaron mensajes
    ; en QUIC real el broker retransmitiria, pero aqui solo lo reportamos
    call .print_msg
    write_lit s_orden_gap, s_orden_gap_l
    mov  dword [last_recv_seq], r12d    ; actualizar para que los siguientes
    jmp  .recv_loop                     ; se comparen desde este punto

; imprime la linea del mensaje: "[QUIC-SUB] seq=N [tema] : cuerpo"
; se llama desde los tres casos de orden de arriba
.print_msg:
    write_lit s_msg_pre, s_msg_pre_l

    mov  edi, r12d
    lea  rsi, [num_buf]
    call itoa_clean
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall

    write_lit s_msg_tema, s_msg_tema_l
    lea  rdi, [tema_tmp]
    call print_cstr_fn
    write_lit s_msg_sep, s_msg_sep_l
    mov  rdi, r14
    call print_cstr_fn

    ret

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1

.err_socket:
    write_lit s_err_sock, s_err_sock_l
    exit_code 1

.err_bind:
    write_lit s_err_bind, s_err_bind_l
    exit_code 1

.err_send:
    write_lit s_err_send, s_err_send_l
    exit_code 1

; raw_copy_fn(rdi=dst, rsi=src, ecx=n)
; copia n bytes exactos y pone null al final
raw_copy_fn:
    test ecx, ecx
    jz   .rc_done
.rc_lp:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .rc_lp
.rc_done:
    mov  byte [rdi], 0
    ret

; funciones auxiliares estandar del proyecto

atoi_fn:
    xor  eax, eax
.atoi_lp:
    movzx ecx, byte [rdi]
    test cl, cl
    jz   .atoi_end
    sub  cl, '0'
    cmp  cl, 9
    ja   .atoi_end
    imul eax, eax, 10
    add  eax, ecx
    inc  rdi
    jmp  .atoi_lp
.atoi_end:
    ret

itoa_clean:
    push  rbx
    mov   eax, edi
    lea   rbx, [rsi + 11]
    mov   byte [rbx], 0
    dec   rbx
.ic_loop:
    xor   edx, edx
    mov   ecx, 10
    div   ecx
    add   dl, '0'
    mov   [rbx], dl
    dec   rbx
    test  eax, eax
    jnz   .ic_loop
    inc   rbx
    mov   rdi, rsi
    mov   rcx, 0
.ic_mv:
    mov   al, [rbx]
    test  al, al
    jz    .ic_mv_done
    mov   [rdi], al
    inc   rbx
    inc   rdi
    inc   rcx
    jmp   .ic_mv
.ic_mv_done:
    mov   byte [rdi], 0
    pop   rbx
    ret

strlen_fn:
    xor  eax, eax
.sl_lp:
    cmp  byte [rdi + rax], 0
    je   .sl_done
    inc  rax
    jmp  .sl_lp
.sl_done:
    ret

strncpy_fn:
    push rcx
.sc_lp:
    test rcx, rcx
    jz   .sc_done
    mov  al, [rsi]
    test al, al
    jz   .sc_done
    mov  [rdi], al
    inc  rdi
    inc  rsi
    dec  rcx
    jmp  .sc_lp
.sc_done:
    mov  byte [rdi], 0
    pop  rcx
    ret

inet_aton_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi
    xor  r13d, r13d
    xor  r14d, r14d

.ia_octet:
    xor  eax, eax
.ia_digit:
    movzx ecx, byte [r12]
    test cl, cl
    jz   .ia_store
    cmp  cl, '.'
    je   .ia_dot
    sub  cl, '0'
    cmp  cl, 9
    ja   .ia_store
    imul eax, eax, 10
    add  eax, ecx
    inc  r12
    jmp  .ia_digit
.ia_dot:
    inc  r12
.ia_store:
    mov  ecx, r14d
    shl  eax, cl
    or   r13d, eax
    add  r14d, 8
    cmp  r14d, 32
    jl   .ia_octet
    mov  eax, r13d

    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

print_cstr_fn:
    push rdi
    call strlen_fn
    mov  rdx, rax
    pop  rsi
    test rdx, rdx
    jz   .pc_end
    mov  rax, SYS_WRITE
    mov  rdi, 1
    syscall
.pc_end:
    ret
