; =============================================================
; publisher_udp.asm
; Publicador UDP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Este es el programa que "publica" eventos deportivos al broker.
; A diferencia del publisher QUIC, este usa UDP puro: manda el mensaje
; y no espera confirmacion de que llego. Si el paquete se pierde en la
; red, nadie se entera. Es mas simple pero menos confiable.
;
; Eso es exactamente la naturaleza de UDP: rapido, sin conexion,
; sin garantias de entrega. Perfecto para cosas donde la velocidad
; importa mas que la confiabilidad (como puntajes en vivo).
;
; El flujo de cada mensaje es:
;   1. Leer una linea del teclado
;   2. Armar el datagrama: "PUB|<tema>|<mensaje>\n"
;   3. Mandarlo al broker con sendto() y olvidarse
;   4. Pedir el siguiente mensaje
;
; Por que no necesitamos select() aqui?
; Porque no esperamos respuesta. En UDP puro mandas y listo.
; No hay ACK, no hay timeout, no hay reenvio. El broker recibe
; o no recibe, pero el publisher ya paso al siguiente mensaje.
;
; Uso: ./publisher_udp <broker_ip> <broker_puerto> <tema>
;      despues el programa lee mensajes del teclado uno por uno
;
; Compilar:
;   nasm -f elf64 publisher_udp.asm -o publisher_udp.o
;   ld -o publisher_udp publisher_udp.o
;
; Syscalls:
;   0  read    - leer del teclado (stdin)
;   1  write   - imprimir en pantalla
;   3  close   - cerrar el socket al salir
;   41 socket  - crear el socket UDP
;   44 sendto  - mandar el paquete al broker
;   60 exit    - salir del programa
; =============================================================

bits 64
default rel

%define SYS_READ       0
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_SENDTO     44
%define SYS_EXIT       60

%define AF_INET        2
%define SOCK_DGRAM     2

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

s_uso        db "Uso: ./publisher_udp <broker_ip> <broker_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_prompt     db "[PUB-UDP] Escribe el evento (Ctrl+D para salir): ", 10
s_prompt_len equ $ - s_prompt

s_sent       db "[PUB-UDP] Mensaje enviado", 10
s_sent_len   equ $ - s_sent

s_eof        db "[PUB-UDP] EOF, cerrando", 10
s_eof_len    equ $ - s_eof

s_nl         db 10
s_nl_len     equ 1

s_pub_prefix  db "PUB|"
s_pub_pref_l  equ $ - s_pub_prefix

section .bss

sock_fd       resd 1
broker_addr   resb 16
tema_buf      resb MAX_TOPIC
tema_len_val  resb 1
stdin_buf     resb BUF_SIZE
send_buf      resb BUF_SIZE
send_len     resd 1

section .text
    global _start

_start:
    pop  rdi
    cmp  rdi, 4
    jl   .err_uso

    pop  rax                    ; argv[0]
    pop  r12                    ; broker_ip
    pop  r13                    ; broker_puerto
    pop  r14                    ; tema

    ; Convertir puerto a network byte order
    mov  rdi, r13
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8                  ; htons manual

    mov  word  [broker_addr + 0], AF_INET
    mov  word  [broker_addr + 2], cx
    mov  qword [broker_addr + 8], 0

    ; Convertir IP del broker
    ; inet_aton_fn produce 0x0100007F para "127.0.0.1":
    ; en memoria little-endian eso queda como bytes 7F 00 00 01,
    ; que es el correcto network byte order de 127.0.0.1.
    mov  rdi, r12
    call inet_aton_fn
    mov  dword [broker_addr + 4], eax

    ; Copiar tema al buffer interno
    lea  rdi, [tema_buf]
    mov  rsi, r14
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    lea  rdi, [tema_buf]
    call strlen_fn
    mov  byte [tema_len_val], al

    ; socket(AF_INET, SOCK_DGRAM, 0)
    ; No hacemos bind(): el kernel asigna un puerto local automaticamente
    ; cuando ejecutamos el primer sendto().
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_DGRAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    write_lit s_prompt, s_prompt_len

.read_loop:
    ; read() bloquea hasta que el usuario presiona Enter o Ctrl+D
    mov  rax, SYS_READ
    xor  rdi, rdi               ; fd 0 = stdin
    lea  rsi, [stdin_buf]
    mov  rdx, BUF_SIZE - 1
    syscall

    test rax, rax
    jz   .eof                   ; Ctrl+D = EOF
    js   .read_loop

    ; Quitar \n / \r del final del buffer
    mov  rcx, rax
    lea  rdi, [stdin_buf]
    call strip_newline

    ; Obtener longitud real del mensaje ya limpio
    lea  rdi, [stdin_buf]
    call strlen_fn
    ; rax = longitud del mensaje

    test rax, rax
    jz   .read_loop             ; linea vacia, ignorar

    ; =========================================================
    ; IMPORTANTE: guardar la longitud del mensaje en rbx AHORA,
    ; antes de construir el paquete. Los loops de copy_prefix y
    ; copy_tema usan ecx/rcx como contador y lo destruyen.
    ; Si guardaramos rbx despues, tendria valor 0.
    ; =========================================================
    mov  rbx, rax               ; rbx = longitud del mensaje, seguro aqui

    ; =========================================================
    ; Construir paquete: "PUB|<tema>|<mensaje>\n"
    ; rdi avanza como puntero de escritura en send_buf
    ; =========================================================
    lea  rdi, [send_buf]

    ; Copiar "PUB|" — usa ecx como contador, destruye rcx
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

    ; Separador
    mov  byte [rdi], '|'
    inc  rdi

    ; Copiar el mensaje del usuario (rbx bytes)
    ; rbx fue guardado antes de que copy_prefix destruyera rcx
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

    ; Newline final que el broker usa como delimitador
    mov  byte [rdi], 10
    inc  rdi

    ; Longitud total del paquete = puntero_final - puntero_inicio
    lea  rax, [send_buf]
    sub  rdi, rax
    mov  [send_len], edi

    ; sendto(sock, send_buf, len, 0, &broker_addr, 16)
    ; Le damos la direccion del broker en cada llamada porque UDP
    ; no tiene conexion establecida: cada paquete lleva su propio destino.
    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [send_buf]
    movsx rdx, dword [send_len]
    xor  r10, r10
    lea  r8, [broker_addr]
    mov  r9, 16
    syscall

    write_lit s_sent, s_sent_len
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
    exit_code 1

; =============================================================
; atoi_fn(rdi=str) -> rax
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
; strlen_fn(rdi=str) -> rax
; Cuenta bytes hasta encontrar el \0 terminal.
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
; Copia hasta max bytes de src a dst. Siempre pone \0 al final.
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
; Elimina \n y \r del final del buffer reemplazandolos con \0.
; =============================================================
strip_newline:
    test rcx, rcx
    jz   .sn_end
    mov  rsi, rdi
    add  rsi, rcx
    dec  rsi                    ; rsi apunta al ultimo byte
.sn_lp:
    cmp  rsi, rdi
    jl   .sn_end
    mov  al, [rsi]
    cmp  al, 10                 ; \n
    je   .sn_rem
    cmp  al, 13                 ; \r
    je   .sn_rem
    jmp  .sn_end
.sn_rem:
    mov  byte [rsi], 0
    dec  rsi
    dec  rcx
    jmp  .sn_lp
.sn_end:
    ret

; =============================================================
; inet_aton_fn(rdi=str) -> eax
; Convierte "a.b.c.d" a uint32 para sockaddr_in.sin_addr.
;
; En x86 little-endian, "127.0.0.1" debe quedar en MEMORIA como:
;   7F 00 00 01  (network byte order = big-endian)
; Eso corresponde al valor 0x0100007F en un registro x86.
;
; El algoritmo desplaza cada octeto a su posicion con shl:
;   octeto 127, shift  0 → 0x0000007F
;   octeto   0, shift  8 → 0x0000007F
;   octeto   0, shift 16 → 0x0000007F
;   octeto   1, shift 24 → 0x0100007F  ← valor final en eax
; Al escribir ese valor en memoria, el CPU lo almacena como:
;   7F 00 00 01 = 127.0.0.1 en network byte order. Correcto.
; =============================================================
inet_aton_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi               ; puntero al string IP
    xor  r13d, r13d             ; acumulador del resultado
    xor  r14d, r14d             ; bits de desplazamiento (0, 8, 16, 24)

.ia_octet:
    xor  eax, eax               ; acumular valor decimal del octeto actual
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
    shl  eax, cl                ; posicionar octeto segun su indice
    or   r13d, eax              ; acumular
    add  r14d, 8
    cmp  r14d, 32
    jl   .ia_octet

    mov  eax, r13d

    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret