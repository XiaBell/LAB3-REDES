; publisher_quic.asm
; Publicador QUIC del lab 3
;
; Este es el programa que "publica" eventos deportivos al broker.
; La diferencia con el publisher UDP normal es que este espera confirmacion
; de que el broker recibio el mensaje, y si no llega la confirmacion en
; 1 segundo, reenvía el mismo mensaje hasta 5 veces.
;
; Eso es basicamente lo que hace QUIC: usar UDP pero agregando confirmaciones
; de entrega (ACK) y reenvio automatico (retransmision) a mano.
;
; El ACK usa el seq del publicador; el broker asigna otro seq monotonico por tema
; en los MSG a suscriptores si hay varios publicadores del mismo partido.
;
; El flujo de cada mensaje es:
;   1. Leer una linea del teclado
;   2. Armar el paquete: [num_secuencia][tipo DATA][longitud_tema][tema][mensaje]
;   3. Mandarlo al broker con sendto()
;   4. Esperar 1 segundo a que llegue el ACK usando select()
;      - Si llega el ACK correcto: incrementar el numero de secuencia y pedir otro mensaje
;      - Si se acaba el tiempo sin ACK: reenviar el mismo paquete (retransmision)
;      - Si se reintento 5 veces sin exito: saltar al siguiente mensaje
;
; Por que select() y no solo recvfrom()?
; recvfrom() bloquea para siempre esperando datos. Con select() podemos
; decirle "espera maximo 1 segundo, y si no llega nada avisame".
;
; Uso: ./publisher_quic <broker_ip> <broker_puerto> <tema>
;      despues el programa lee mensajes del teclado uno por uno
;
; Compilar:
;   nasm -f elf64 publisher_quic.asm -o ../bin/publisher_quic.o
;   ld -o ../bin/publisher_quic ../bin/publisher_quic.o
;
; Syscalls:
;   0  read      - leer del teclado (stdin)
;   1  write     - imprimir en pantalla
;   23 select    - esperar ACK con tiempo limite de 1 segundo
;   41 socket    - crear socket UDP
;   44 sendto    - mandar el paquete al broker
;   45 recvfrom  - recibir el ACK del broker
;   60 exit      - salir

bits 64
default rel

%define SYS_READ       0
%define SYS_WRITE      1
%define SYS_SELECT     23
%define SYS_SOCKET     41
%define SYS_SENDTO     44
%define SYS_RECVFROM   45
%define SYS_EXIT       60

%define AF_INET        2
%define SOCK_DGRAM     2

; tipos del protocolo QUIC
%define TYPE_DATA      0x01
%define TYPE_ACK       0x02

%define BUF_SIZE       512
%define MAX_TOPIC      64
%define MAX_RETRIES    5      ; maximo de reintentos antes de abandonar un mensaje

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

s_uso        db "Uso: ./publisher_quic <broker_ip> <broker_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_prompt     db "[QUIC-PUB] Escribe el evento (Ctrl+D para salir): ", 10
s_prompt_len equ $ - s_prompt

s_sending    db "[QUIC-PUB] Enviando seq="
s_sending_l  equ $ - s_sending

s_sending2   db " ..."
s_sending2_l equ $ - s_sending2

s_ack_ok     db " -> ACK ok, mensaje confirmado", 10
s_ack_ok_l   equ $ - s_ack_ok

; no llego ACK en 1 segundo
s_timeout    db "[QUIC-PUB] Timeout, reenviando...", 10
s_timeout_l  equ $ - s_timeout

; llego algo pero no era el ACK que esperabamos
s_bad_ack    db "[QUIC-PUB] ACK incorrecto, reenviando...", 10
s_bad_ack_l  equ $ - s_bad_ack

; se acabaron los reintentos
s_max_retry  db "[QUIC-PUB] Se agotaron los reintentos, descartando mensaje", 10
s_max_retry_l equ $ - s_max_retry

s_eof        db "[QUIC-PUB] EOF, cerrando", 10
s_eof_len    equ $ - s_eof

s_nl         db 10
s_nl_len     equ 1

section .bss

sock_fd      resd 1
broker_addr  resb 16

; numero de secuencia: empieza en 1 y sube 1 por cada mensaje confirmado
; el subscriber usa este numero para saber si se perdio algun mensaje
seq_num      resd 1

tema_buf     resb MAX_TOPIC
tema_len_val resb 1           ; longitud del nombre del partido

stdin_buf    resb BUF_SIZE    ; lo que escribe el usuario
send_buf     resb BUF_SIZE    ; el paquete completo listo para enviar
send_len     resd 1
ack_buf      resb 16          ; donde guardamos el ACK que llega del broker
sender_addr  resb 16
sender_len   resd 1

; fd_set para select(): 128 bytes donde cada bit representa un file descriptor
; prendemos el bit que corresponde a nuestro socket para que select lo monitoree
fd_set_buf   resb 128

; timeval para select(): cuanto tiempo esperar
; struct timeval { tv_sec, tv_usec } - cada campo es 8 bytes en x86-64
timeval_buf  resb 16

num_buf      resb 16

section .text
    global _start

_start:
    pop  rdi
    cmp  rdi, 4
    jl   .err_uso

    pop  rax                    ; argv[0] descartado
    pop  r12                    ; broker_ip
    pop  r13                    ; broker_puerto
    pop  r14                    ; tema

    ; convertir el puerto a network byte order y llenar broker_addr
    mov  rdi, r13
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8                  ; htons manual

    mov  word  [broker_addr + 0], AF_INET
    mov  word  [broker_addr + 2], cx
    mov  qword [broker_addr + 8], 0

    mov  rdi, r12
    call inet_aton_fn           ; convertir "a.b.c.d" a 32 bits
    mov  dword [broker_addr + 4], eax

    ; copiar el tema al buffer interno
    lea  rdi, [tema_buf]
    mov  rsi, r14
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    lea  rdi, [tema_buf]
    call strlen_fn
    mov  byte [tema_len_val], al

    ; crear socket UDP (sin bind porque el kernel le asigna un puerto automatico)
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_DGRAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    mov  dword [seq_num], 1     ; empezamos en secuencia 1

    write_lit s_prompt, s_prompt_len

; leer una linea del teclado y enviarla
.read_loop:
    mov  rax, SYS_READ
    xor  rdi, rdi               ; stdin = fd 0
    lea  rsi, [stdin_buf]
    mov  rdx, BUF_SIZE - 1
    syscall

    test rax, rax
    jz   .eof                   ; Ctrl+D = EOF
    js   .read_loop

    ; limpiar el \n del final
    mov  rcx, rax
    lea  rdi, [stdin_buf]
    call strip_newline
    test rcx, rcx
    jz   .read_loop             ; linea vacia, ignorar

    ; construir el paquete DATA:
    ; [seq:4][0x01:1][tema_len:1][tema][mensaje del usuario]
    lea  rdi, [send_buf]

    mov  eax, [seq_num]
    mov  dword [rdi], eax       ; numero de secuencia
    add  rdi, 4

    mov  byte [rdi], TYPE_DATA
    inc  rdi

    mov  al, [tema_len_val]
    mov  byte [rdi], al         ; cuantos bytes mide el tema
    inc  rdi

    ; copiar el nombre del partido
    lea  rsi, [tema_buf]
.copy_tema:
    mov  al, [rsi]
    test al, al
    jz   .tema_ok
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_tema
.tema_ok:

    ; copiar el mensaje del usuario
    lea  rsi, [stdin_buf]
    mov  rbx, rcx
.copy_body:
    test rbx, rbx
    jz   .body_ok
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  rbx
    jmp  .copy_body
.body_ok:

    ; guardar la longitud total del paquete
    lea  rax, [send_buf]
    sub  rdi, rax
    mov  [send_len], edi

    mov  r15d, 0                ; resetear contador de reintentos

; enviar el paquete y esperar el ACK
.send_attempt:
    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [send_buf]
    movsx rdx, dword [send_len]
    xor  r10, r10
    lea  r8, [broker_addr]
    mov  r9, 16
    syscall

    write_lit s_sending, s_sending_l
    mov  edi, [seq_num]
    lea  rsi, [num_buf]
    call itoa_clean
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_sending2, s_sending2_l
    write_lit s_nl, 1

    ; preparar select() para esperar el ACK con timeout de 1 segundo
    ;
    ; select() revisa uno o mas file descriptors y bloquea hasta que
    ; alguno tenga datos disponibles o hasta que se acabe el tiempo.
    ; Necesita un fd_set (mapa de bits de fds a monitorear) y un timeval.

    ; paso 1: zerear el fd_set completo (128 bytes)
    lea  rdi, [fd_set_buf]
    mov  ecx, 16
    xor  rax, rax
.zero_fds:
    mov  qword [rdi], rax
    add  rdi, 8
    dec  ecx
    jnz  .zero_fds

    ; paso 2: prender el bit del socket en el fd_set
    ; si sock_fd = 3, ponemos el bit 3 = 0x08 en el primer qword
    movsx rax, dword [sock_fd]
    mov  ecx, eax
    mov  rdx, 1
    shl  rdx, cl                ; rdx = 1 << sock_fd
    mov  qword [fd_set_buf], rdx

    ; paso 3: timeout = 1 segundo, 0 microsegundos
    mov  qword [timeval_buf],     1
    mov  qword [timeval_buf + 8], 0

    ; paso 4: llamar select()
    ; select(sock_fd+1, &fd_set, NULL, NULL, &timeval)
    movsx rdi, dword [sock_fd]
    inc  rdi                    ; nfds = fd mas alto + 1
    lea  rsi, [fd_set_buf]
    xor  rdx, rdx               ; no monitorear escritura
    xor  r10, r10               ; no monitorear excepciones
    lea  r8, [timeval_buf]
    mov  rax, SYS_SELECT
    syscall

    ; si rax=0 se acabo el tiempo, si rax<0 hubo error, si rax>0 hay datos
    test rax, rax
    jz   .do_timeout
    js   .do_timeout

    ; hay datos: leer el ACK
    mov  dword [sender_len], 16
    mov  rax, SYS_RECVFROM
    movsx rdi, dword [sock_fd]
    lea  rsi, [ack_buf]
    mov  rdx, 16
    xor  r10, r10
    lea  r8, [sender_addr]
    lea  r9, [sender_len]
    syscall

    ; verificar que sea un ACK y que el seq coincida con el que enviamos
    cmp  byte [ack_buf + 4], TYPE_ACK
    jne  .do_bad_ack

    mov  eax, dword [ack_buf]
    cmp  eax, dword [seq_num]
    jne  .do_bad_ack

    ; ACK correcto: el broker confirmo que recibio el mensaje
    write_lit s_sending, s_sending_l
    mov  edi, [seq_num]
    lea  rsi, [num_buf]
    call itoa_clean
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_ack_ok, s_ack_ok_l

    inc  dword [seq_num]        ; siguiente mensaje va con el proximo numero

    write_lit s_prompt, s_prompt_len
    jmp  .read_loop

; llego algo pero no era el ACK que esperabamos
.do_bad_ack:
    inc  r15d
    cmp  r15d, MAX_RETRIES
    jge  .max_retries
    write_lit s_bad_ack, s_bad_ack_l
    jmp  .send_attempt

; se acabo el tiempo de espera sin recibir ACK
.do_timeout:
    inc  r15d
    cmp  r15d, MAX_RETRIES
    jge  .max_retries
    write_lit s_timeout, s_timeout_l
    jmp  .send_attempt          ; reenviar el mismo paquete con el mismo seq

; demasiados reintentos, el broker no esta respondiendo
.max_retries:
    write_lit s_max_retry, s_max_retry_l
    inc  dword [seq_num]
    write_lit s_prompt, s_prompt_len
    jmp  .read_loop

.eof:
    write_lit s_eof, s_eof_len
    exit_code 0

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1

.err_socket:
    exit_code 1

; funciones auxiliares

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

strip_newline:
    test rcx, rcx
    jz   .sn_end
    mov  rsi, rdi
    add  rsi, rcx
    dec  rsi
.sn_lp:
    cmp  rsi, rdi
    jl   .sn_end
    mov  al, [rsi]
    cmp  al, 10
    je   .sn_rem
    cmp  al, 13
    je   .sn_rem
    jmp  .sn_end
.sn_rem:
    mov  byte [rsi], 0
    dec  rsi
    dec  rcx
    jmp  .sn_lp
.sn_end:
    ret

; convierte "a.b.c.d" a un entero de 32 bits en network byte order
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
