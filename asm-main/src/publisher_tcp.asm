; =============================================================
; publisher_tcp.asm
; Publicador TCP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Este programa se conecta al broker TCP y envía eventos de un
; partido. A diferencia del publisher UDP (que manda y se olvida),
; aquí TCP garantiza que cada mensaje llega al broker en orden
; y sin pérdida.
;
; Diferencia clave con el publisher UDP:
;   UDP: sendto() en cada mensaje, sin conexión establecida.
;        Si el paquete se pierde, nadie se entera.
;   TCP: connect() una sola vez al inicio. Luego write() para
;        cada mensaje por la misma conexión. El kernel reenvía
;        automáticamente si hay pérdida en la red.
;
; El flujo es:
;   1. socket()   → crear socket TCP (SOCK_STREAM)
;   2. connect()  → 3-way handshake con el broker
;   3. loop:
;        read()   → leer línea del teclado
;        write()  → enviar "PUB|<tema>|<mensaje>\n" al broker
;
; Por qué no necesitamos bind()?
; El kernel asigna un puerto efímero local automáticamente
; cuando connect() establece la conexión. El broker no necesita
; saber nuestro puerto: ya tiene el fd de la conexión abierta.
;
; Uso: ./publisher_tcp <broker_ip> <broker_puerto> <tema>
;      Ejemplo: ./publisher_tcp 127.0.0.1 9000 partido1
;
; Compilar:
;   nasm -f elf64 publisher_tcp.asm -o publisher_tcp.o
;   ld -o publisher_tcp publisher_tcp.o
;
; Syscalls:
;   0  read    - leer línea del teclado (stdin)
;   1  write   - enviar PUB al broker y mostrar confirmación
;   3  close   - cerrar el socket al terminar
;   41 socket  - crear el socket TCP
;   42 connect - conectarse al broker
;   60 exit    - salir del programa
; =============================================================

bits 64
default rel

%define SYS_READ       0
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_CONNECT    42
%define SYS_EXIT       60

%define AF_INET        2
%define SOCK_STREAM    1       ; TCP

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

s_uso        db "Uso: ./publisher_tcp <broker_ip> <broker_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_conn_ok    db "[Publicador TCP] Conectado al broker", 10
s_conn_ok_l  equ $ - s_conn_ok

s_prompt     db "[Publicador TCP] Escribe el evento (Ctrl+D para salir): ", 10
s_prompt_len equ $ - s_prompt

s_sent       db "[Publicador TCP] Mensaje enviado", 10
s_sent_len   equ $ - s_sent

s_eof        db "[Publicador TCP] EOF, cerrando", 10
s_eof_len    equ $ - s_eof

s_nl         db 10
s_nl_len     equ 1

; Prefijo fijo del datagrama. El paquete completo queda:
;   "PUB|partido1|Gol de Messi\n"
s_pub_prefix  db "PUB|"
s_pub_pref_l  equ $ - s_pub_prefix

s_err_socket db "[Publicador TCP] Error: no se pudo crear el socket", 10
s_err_sock_l equ $ - s_err_socket

s_err_conn   db "[Publicador TCP] Error: no se pudo conectar al broker (esta corriendo?)", 10
s_err_conn_l equ $ - s_err_conn

s_err_send   db "[Publicador TCP] Error: fallo el envio (broker cerro la conexion?)", 10
s_err_send_l equ $ - s_err_send

section .bss

sock_fd       resd 1

; struct sockaddr_in del broker:
;   +0  sin_family  (2) = AF_INET
;   +2  sin_port    (2) en network byte order
;   +4  sin_addr    (4) en network byte order
;   +8  sin_zero    (8) = 0
broker_addr   resb 16

; Buffer interno para el nombre del tema
tema_buf      resb MAX_TOPIC

; Buffer donde cae lo que escribe el usuario en el teclado
stdin_buf     resb BUF_SIZE

; Buffer donde armamos el paquete completo antes de enviarlo
send_buf      resb BUF_SIZE

section .text
    global _start

_start:
    ; Layout del stack: argc, argv[0], argv[1], argv[2], argv[3]
    pop  rdi
    cmp  rdi, 4                ; necesitamos broker_ip, puerto, tema
    jl   .err_uso

    pop  rax                   ; argv[0]: nombre del ejecutable, descartar
    pop  r12                   ; r12 = broker_ip    (ej: "127.0.0.1")
    pop  r13                   ; r13 = broker_puerto (ej: "9000")
    pop  r14                   ; r14 = tema          (ej: "partido1")

    ; =========================================================
    ; Convertir el puerto a network byte order
    ;
    ; atoi_fn: "9000" → 9000 en rax
    ; rol cx, 8: intercambia los bytes → htons() manual
    ; =========================================================
    mov  rdi, r13
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8                 ; htons manual

    mov  word  [broker_addr + 0], AF_INET
    mov  word  [broker_addr + 2], cx
    mov  qword [broker_addr + 8], 0

    ; Convertir IP del broker a uint32 en network byte order.
    ; inet_aton_fn produce 0x0100007F para "127.0.0.1":
    ; en memoria little-endian eso queda como 7F 00 00 01 = correcto.
    mov  rdi, r12
    call inet_aton_fn
    mov  dword [broker_addr + 4], eax

    ; Copiar el tema al buffer interno para usarlo en cada mensaje
    lea  rdi, [tema_buf]
    mov  rsi, r14
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    ; =========================================================
    ; socket(AF_INET, SOCK_STREAM, 0)
    ;
    ; SOCK_STREAM = TCP. No necesitamos bind(): connect() le
    ; asigna un puerto efímero local automáticamente.
    ; =========================================================
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_STREAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    ; =========================================================
    ; connect(fd, &broker_addr, 16)
    ;
    ; Establece la conexión TCP con el broker.
    ; Después de esta llamada, el fd queda listo para write().
    ; =========================================================
    mov  rax, SYS_CONNECT
    movsx rdi, dword [sock_fd]
    lea  rsi, [broker_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_connect

    write_lit s_conn_ok, s_conn_ok_l
    write_lit s_prompt, s_prompt_len

; =============================================================
; Bucle principal: leer del teclado → construir paquete → enviar
; =============================================================
.read_loop:
    ; read(0, stdin_buf, BUF_SIZE-1) — bloquea hasta Enter o Ctrl+D
    mov  rax, SYS_READ
    xor  rdi, rdi              ; fd 0 = stdin
    lea  rsi, [stdin_buf]
    mov  rdx, BUF_SIZE - 1
    syscall

    test rax, rax
    jz   .eof                  ; Ctrl+D = EOF
    js   .read_loop            ; error temporal, reintentar

    ; Quitar \n y \r del final del buffer
    mov  rcx, rax              ; rcx = bytes leídos
    lea  rdi, [stdin_buf]
    call strip_newline

    ; Calcular longitud real del mensaje sin el \n
    lea  rdi, [stdin_buf]
    call strlen_fn             ; rax = longitud del mensaje limpio

    test rax, rax
    jz   .read_loop            ; línea vacía: ignorar

    ; =========================================================
    ; LECCION APRENDIDA del publisher UDP:
    ; Guardar la longitud del mensaje en rbx ANTES de construir
    ; el paquete. El loop copy_prefix usa ecx como contador y
    ; destruye rcx. Si guardamos después, rbx = 0 y el mensaje
    ; llega vacío al broker.
    ; =========================================================
    mov  rbx, rax              ; rbx = longitud del mensaje (callee-saved)

    ; =========================================================
    ; Construir el paquete: "PUB|<tema>|<mensaje>\n"
    ;
    ;   send_buf:  P U B | p a r t i d o 1 | G o l \n
    ;              ^^^^ prefijo
    ;                   ^^^^^^^^^ tema
    ;                             ^ separador
    ;                              ^^^ mensaje del usuario
    ;                                  ^ newline final
    ; =========================================================
    lea  rdi, [send_buf]       ; rdi = cursor de escritura

    ; Copiar "PUB|" — este loop destruye ecx/rcx
    lea  rsi, [s_pub_prefix]
    mov  ecx, s_pub_pref_l
.copy_prefix:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .copy_prefix

    ; Copiar el tema hasta \0
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

    ; Separador entre tema y mensaje
    mov  byte [rdi], '|'
    inc  rdi

    ; Copiar el mensaje del usuario (rbx bytes, guardados antes del loop)
    lea  rsi, [stdin_buf]
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

    ; Newline final: el broker parsea línea por línea delimitando con \n
    mov  byte [rdi], 10
    inc  rdi

    ; Longitud total = cursor_final - inicio_send_buf
    ; Guardamos en rbx (callee-saved) ANTES de sobreescribir rdi con el fd
    lea  rax, [send_buf]
    sub  rdi, rax              ; rdi = longitud del paquete
    mov  rbx, rdi              ; rbx = longitud (preservar para write)

    ; =========================================================
    ; write(fd, send_buf, len)
    ;
    ; En TCP, write() envía por la conexión establecida.
    ; No necesitamos especificar destino: el kernel sabe a dónde
    ; va porque connect() ya fijó el otro extremo.
    ; El kernel maneja retransmisión si hay pérdida en la red.
    ; =========================================================
    mov  rax, SYS_WRITE
    movsx rdi, dword [sock_fd]
    lea  rsi, [send_buf]
    mov  rdx, rbx              ; longitud guardada antes del mov al fd
    syscall
    test rax, rax
    js   .err_send             ; error de red: salir

    write_lit s_sent, s_sent_len
    write_lit s_prompt, s_prompt_len
    jmp  .read_loop

.eof:
    write_lit s_eof, s_eof_len
    mov  rax, SYS_CLOSE
    movsx rdi, dword [sock_fd]
    syscall
    exit_code 0

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1

.err_socket:
    write_lit s_err_socket, s_err_sock_l
    exit_code 1

.err_connect:
    write_lit s_err_conn, s_err_conn_l
    exit_code 1

.err_send:
    write_lit s_err_send, s_err_send_l
    exit_code 1

; =============================================================
; atoi_fn(rdi=str) → rax
; Convierte string ASCII decimal a entero sin signo.
; =============================================================
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

; =============================================================
; strlen_fn(rdi=str) → rax
; Cuenta bytes hasta \0 terminal. No cuenta el \0.
; =============================================================
strlen_fn:
    xor  eax, eax
.sl_lp:
    cmp  byte [rdi + rax], 0
    je   .sl_done
    inc  rax
    jmp  .sl_lp
.sl_done:
    ret

; =============================================================
; strncpy_fn(rdi=dst, rsi=src, rcx=max)
; Copia hasta max bytes. Siempre nul-termina dst.
; =============================================================
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

; =============================================================
; strip_newline(rdi=buf, rcx=len)
; Elimina \n (10) y \r (13) del final reemplazándolos con \0.
; Camina desde el último byte hacia atrás.
; =============================================================
strip_newline:
    test rcx, rcx
    jz   .sn_end
    mov  rsi, rdi
    add  rsi, rcx
    dec  rsi                   ; rsi = último byte del buffer
.sn_lp:
    cmp  rsi, rdi
    jl   .sn_end
    mov  al, [rsi]
    cmp  al, 10                ; \n
    je   .sn_rem
    cmp  al, 13                ; \r
    je   .sn_rem
    jmp  .sn_end               ; caracter normal: parar
.sn_rem:
    mov  byte [rsi], 0
    dec  rsi
    dec  rcx
    jmp  .sn_lp
.sn_end:
    ret

; =============================================================
; inet_aton_fn(rdi=str) → eax
;
; Convierte "a.b.c.d" a uint32 para sockaddr_in.sin_addr.
; En x86 little-endian, "127.0.0.1" queda en memoria como:
;   7F 00 00 01 (network byte order correcto).
; Eso equivale al valor 0x0100007F en un registro x86.
;
; Algoritmo: desplaza cada octeto con shl según su índice:
;   octeto 127, shift  0 → 0x0000007F
;   octeto   0, shift  8 → 0x0000007F
;   octeto   0, shift 16 → 0x0000007F
;   octeto   1, shift 24 → 0x0100007F ← valor final
; =============================================================
inet_aton_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi
    xor  r13d, r13d            ; acumulador del resultado
    xor  r14d, r14d            ; bits de desplazamiento (0,8,16,24)

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
