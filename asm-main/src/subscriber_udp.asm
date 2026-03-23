; =============================================================
; subscriber_udp.asm
; Suscriptor UDP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Protocolo:
;   Suscriptor → Broker : "SUB|<tema>\n"        (registrarse en el broker)
;   Broker → Suscriptor : "MSG|<tema>|<msg>"    (actualización en vivo)
;
; Compilar:
;   nasm -f elf64 subscriber_udp.asm -o subscriber_udp.o
;   ld -o subscriber_udp subscriber_udp.o
;
; Uso: ./subscriber_udp <broker_ip> <broker_puerto> <mi_puerto> <tema>
;      Ejemplo: ./subscriber_udp 127.0.0.1 9001 9100 partido1
;
; Syscalls utilizados (ABI System V AMD64 Linux):
;   nro  nombre         descripción
;   ---  ----------     ------------------------------------------------------
;    1   sys_write      Escribe bytes en stdout para mensajes de log y salida
;    3   sys_close      Cierra el socket al finalizar el programa
;   41   sys_socket     Crea el socket UDP: socket(AF_INET, SOCK_DGRAM, 0)
;   44   sys_sendto     Envía el mensaje "SUB|<tema>\n" al broker
;   45   sys_recvfrom   Recibe los datagramas "MSG|<tema>|<msg>" del broker
;   49   sys_bind       Asocia el socket a mi_puerto para poder recibir mensajes
;   54   sys_setsockopt Configura SO_REUSEADDR para reusar el puerto local
;   60   sys_exit       Termina el proceso con el código de salida indicado
;
; Convención de llamada x86-64 (System V AMD64 ABI):
;   Argumentos: rdi, rsi, rdx, rcx, r8, r9
;   Retorno:    rax (valor de retorno de syscall o función)
;   Preservar:  rbx, rbp, r12–r15  (callee-saved; deben restaurarse)
;   Scratch:    rax, rcx, rdx, rsi, rdi, r8–r11 (caller-saved; pueden modificarse)
; =============================================================

bits 64
default rel          ; direccionamiento relativo a RIP (posición independiente)

; ── Números de syscall ───────────────────────────────────────
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_SENDTO     44
%define SYS_RECVFROM   45
%define SYS_BIND       49
%define SYS_SETSOCKOPT 54
%define SYS_EXIT       60

; ── Constantes de red ────────────────────────────────────────
%define AF_INET        2      ; familia de direcciones IPv4
%define SOCK_DGRAM     2      ; socket orientado a datagramas (UDP)
%define SOL_SOCKET     1      ; nivel de opción: socket genérico
%define SO_REUSEADDR   2      ; opción: reusar dirección/puerto local

; ── Constantes de la aplicación ──────────────────────────────
%define BUF_SIZE       512    ; tamaño máximo del buffer de recepción

; ── Macros utilitarios ───────────────────────────────────────

; Terminar el proceso con un código de salida
%macro exit_code 1
    mov  rax, SYS_EXIT
    mov  rdi, %1
    syscall
%endmacro

; Escribir un literal de cadena en stdout (fd=1)
; Uso: write_lit <etiqueta>, <longitud>
%macro write_lit 2
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [%1]
    mov  rdx, %2
    syscall
%endmacro

; =============================================================
section .data

s_uso        db "Uso: ./subscriber_udp <broker_ip> <broker_puerto> <mi_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_sub_ok     db "[Suscriptor UDP] Suscripcion enviada al tema: "
s_sub_ok_l   equ $ - s_sub_ok

s_waiting    db "[Suscriptor UDP] Esperando mensajes del broker...", 10
s_waiting_l  equ $ - s_waiting

s_recv_pre   db "[MSG] "
s_recv_pre_l equ $ - s_recv_pre

s_nl         db 10
s_nl_len     equ 1

s_err_sock   db "[Suscriptor UDP] Error: no se pudo crear el socket", 10
s_err_sock_l equ $ - s_err_sock

s_err_bind   db "[Suscriptor UDP] Error: no se pudo hacer bind al puerto local", 10
s_err_bind_l equ $ - s_err_bind

s_err_send   db "[Suscriptor UDP] Error: no se pudo enviar la suscripcion al broker", 10
s_err_send_l equ $ - s_err_send

; Prefijo del mensaje de suscripción: "SUB|"
; El formato completo enviado al broker es "SUB|<tema>\n"
s_sub_prefix db "SUB|"
s_sub_pref_l equ $ - s_sub_prefix

; =============================================================
section .bss

sock_fd      resd 1        ; descriptor de archivo del socket UDP creado
opt_val      resd 1        ; valor para setsockopt (SO_REUSEADDR = 1)

; struct sockaddr_in del broker (dirección destino para sendto)
; Layout:
;   +0  sin_family  (2 bytes) = AF_INET
;   +2  sin_port    (2 bytes) en network byte order
;   +4  sin_addr    (4 bytes) en network byte order
;   +8  sin_zero    (8 bytes) = 0
broker_addr  resb 16

; struct sockaddr_in local (usada en bind para recibir mensajes del broker)
my_addr      resb 16

; Buffer donde se reciben los datagramas "MSG|<tema>|<msg>" del broker
recv_buf     resb BUF_SIZE

; struct sockaddr_in que recvfrom llena con la dirección del remitente
sender_addr  resb 16
sender_len   resd 1        ; tamaño de sender_addr (entry: 16, exit: tamaño real)

; Buffer de construcción del mensaje "SUB|<tema>\n" que se envía al broker
sub_msg_buf  resb 128

; =============================================================
section .text
    global _start

; =============================================================
; _start : punto de entrada del programa
;
; Estado inicial del stack (Linux x86-64 ELF):
;   [rsp+0]   = argc          (número de argumentos)
;   [rsp+8]   = argv[0]       (nombre del programa)
;   [rsp+16]  = argv[1]       = broker_ip   (string "a.b.c.d")
;   [rsp+24]  = argv[2]       = broker_puerto
;   [rsp+32]  = argv[3]       = mi_puerto   (puerto donde el suscriptor escucha)
;   [rsp+40]  = argv[4]       = tema        (ej. "partido1")
; =============================================================
_start:
    pop  rdi                    ; rdi = argc
    cmp  rdi, 5
    jl   .err_uso               ; se necesitan los 4 argumentos obligatorios

    pop  rax                    ; argv[0]: nombre del programa (descartado)
    pop  r12                    ; r12 = broker_ip   (argv[1])
    pop  r13                    ; r13 = broker_puerto string (argv[2])
    pop  r14                    ; r14 = mi_puerto string     (argv[3])
    pop  r15                    ; r15 = tema                 (argv[4])

    ; ── Convertir broker_puerto → network byte order ──────────
    ; atoi_fn transforma el string ASCII en entero de 32 bits (host order).
    ; htons manual: intercambiar byte alto y bajo del word de 16 bits.
    mov  rdi, r13
    call atoi_fn                ; rax = broker_puerto en host byte order
    movzx ecx, ax               ; ecx = valor de 16 bits
    rol  cx, 8                  ; cx = broker_puerto en network byte order (big-endian)

    ; Llenar los campos de broker_addr
    mov  word  [broker_addr + 0], AF_INET  ; sin_family = 2
    mov  word  [broker_addr + 2], cx       ; sin_port (network order)
    ; sin_addr se completa abajo tras convertir la IP
    mov  qword [broker_addr + 8], 0        ; sin_zero = 0

    ; ── Convertir mi_puerto → network byte order ──────────────
    mov  rdi, r14
    call atoi_fn                ; rax = mi_puerto en host byte order
    movzx ecx, ax
    rol  cx, 8                  ; cx = mi_puerto en network byte order

    ; Llenar los campos de my_addr (para bind)
    mov  word  [my_addr + 0], AF_INET      ; sin_family = 2
    mov  word  [my_addr + 2], cx           ; sin_port (network order)
    mov  dword [my_addr + 4], 0            ; sin_addr = INADDR_ANY (0.0.0.0)
    mov  qword [my_addr + 8], 0            ; sin_zero = 0

    ; ── Convertir broker_ip (dotted decimal) → uint32 network order ──
    ; inet_aton_fn parsea "a.b.c.d" y retorna el entero en network byte order:
    ; resultado = a | (b<<8) | (c<<16) | (d<<24)   [little-endian x86]
    ; Esto coloca el primer octeto en el byte de menor dirección, igual que
    ; la función inet_aton() de la libc.
    mov  rdi, r12
    call inet_aton_fn           ; rax = IP en network byte order
    mov  dword [broker_addr + 4], eax      ; sin_addr del broker

    ; ── socket(AF_INET, SOCK_DGRAM, 0) ───────────────────────
    ; Crea un socket UDP. SOCK_DGRAM indica que cada operación de
    ; envío/recepción es un datagrama independiente (sin conexión).
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET           ; familia: IPv4
    mov  rsi, SOCK_DGRAM        ; tipo: datagrama UDP
    xor  rdx, rdx               ; protocolo: 0 (elige UDP automáticamente)
    syscall
    test rax, rax
    js   .err_socket            ; rax < 0 → error al crear el socket
    mov  [sock_fd], eax         ; guardar el descriptor del socket

    ; ── setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt_val, 4) ─
    ; Permite reusar el puerto local aunque esté en TIME_WAIT.
    mov  dword [opt_val], 1     ; habilitar la opción (valor 1 = activar)
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [sock_fd]  ; fd del socket
    mov  rsi, SOL_SOCKET        ; nivel: socket genérico
    mov  rdx, SO_REUSEADDR      ; opción: reusar dirección
    lea  r10, [opt_val]         ; puntero al valor de la opción
    mov  r8, 4                  ; tamaño del valor (4 bytes = sizeof(int))
    syscall
    ; No es crítico si falla; continuamos de todos modos

    ; ── bind(fd, &my_addr, 16) ────────────────────────────────
    ; Asocia el socket al puerto local (mi_puerto) para que el broker
    ; pueda identificar la dirección del suscriptor via recvfrom y luego
    ; enviarle los mensajes MSG con sendto a esa misma dirección.
    mov  rax, SYS_BIND
    movsx rdi, dword [sock_fd]  ; fd del socket
    lea  rsi, [my_addr]         ; struct sockaddr_in con mi puerto
    mov  rdx, 16                ; sizeof(struct sockaddr_in)
    syscall
    test rax, rax
    js   .err_bind              ; rax < 0 → error al hacer bind

    ; ── Construir el mensaje "SUB|<tema>\n" en sub_msg_buf ────
    ; El broker identifica el tipo por el prefijo antes del primer '|'.
    ; Al recibir "SUB|<tema>\n", registra la dirección del remitente
    ; (obtenida por recvfrom) junto con el tema en su tabla de suscriptores.
    lea  rdi, [sub_msg_buf]     ; rdi = cursor de escritura en sub_msg_buf

    ; Copiar el prefijo "SUB|" (4 bytes)
    lea  rsi, [s_sub_prefix]
    mov  ecx, s_sub_pref_l
.copy_prefix:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .copy_prefix

    ; Copiar el tema hasta el nul-terminador
    mov  rsi, r15               ; rsi = puntero al string del tema
.copy_topic:
    mov  al, [rsi]
    test al, al
    jz   .topic_done
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_topic
.topic_done:
    mov  byte [rdi], 10         ; '\n': el broker lo usa para delimitar el mensaje
    inc  rdi

    ; Calcular la longitud total del mensaje construido
    lea  rdx, [sub_msg_buf]     ; rdx = inicio del buffer
    sub  rdi, rdx               ; rdi = longitud total del mensaje
    mov  rbx, rdi               ; rbx = longitud (preservar para sendto)

    ; ── sendto(fd, sub_msg_buf, len, 0, &broker_addr, 16) ─────
    ; Envía el mensaje de suscripción al broker.
    ; UDP no establece conexión; la dirección destino se especifica en cada llamada.
    ; El kernel tomará la IP:puerto local (fijados por bind) como origen,
    ; así el broker puede registrar la dirección del suscriptor.
    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]  ; fd del socket
    lea  rsi, [sub_msg_buf]     ; buffer con "SUB|<tema>\n"
    mov  rdx, rbx               ; longitud del mensaje
    xor  r10, r10               ; flags = 0
    lea  r8, [broker_addr]      ; dirección destino: broker
    mov  r9, 16                 ; sizeof(struct sockaddr_in)
    syscall
    test rax, rax
    js   .err_send              ; rax < 0 → error al enviar

    ; ── Confirmar suscripción en stdout ───────────────────────
    write_lit s_sub_ok, s_sub_ok_l
    mov  rdi, r15               ; rdi = puntero al tema
    call print_cstr_fn
    write_lit s_nl, s_nl_len

    write_lit s_waiting, s_waiting_l

; =============================================================
; .recv_loop : bucle principal de recepción de mensajes
;
; Espera indefinidamente datagramas del broker con el formato:
;   "MSG|<tema>|<contenido del evento>"
; y los imprime en stdout.
; =============================================================
.recv_loop:
    ; Inicializar sender_len antes de cada recvfrom
    mov  dword [sender_len], 16

    ; recvfrom(fd, recv_buf, BUF_SIZE-1, 0, &sender_addr, &sender_len)
    ; Bloquea hasta recibir un datagrama.
    ; sender_addr se llena con la IP:puerto del remitente (el broker).
    ; Retorna en rax el número de bytes recibidos, o valor negativo si hay error.
    mov  rax, SYS_RECVFROM
    movsx rdi, dword [sock_fd]  ; fd del socket
    lea  rsi, [recv_buf]        ; buffer destino
    mov  rdx, BUF_SIZE - 1      ; máximo de bytes a leer (dejar 1 para nul)
    xor  r10, r10               ; flags = 0
    lea  r8,  [sender_addr]     ; OUT: dirección del remitente (el broker)
    lea  r9,  [sender_len]      ; IN/OUT: tamaño de sender_addr
    syscall

    test rax, rax
    jle  .recv_loop             ; 0 bytes o error → volver a esperar

    ; Nul-terminar y limpiar '\r'/'\n' del final del datagrama recibido
    mov  rcx, rax               ; rcx = bytes recibidos
    lea  rdi, [recv_buf]
    call strip_newline          ; rcx = longitud tras eliminar terminadores

    test rcx, rcx
    jz   .recv_loop             ; datagrama vacío → ignorar

    ; Imprimir "[MSG] <contenido>\n" en stdout
    ; El contenido tiene el formato "MSG|<tema>|<evento>" según el broker
    write_lit s_recv_pre, s_recv_pre_l
    lea  rdi, [recv_buf]
    call print_cstr_fn
    write_lit s_nl, s_nl_len

    jmp  .recv_loop

; ── Manejadores de error y salida ────────────────────────────
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

; =============================================================
; inet_aton_fn(rdi=str) → rax : convierte "a.b.c.d" a uint32 en network byte order
;
; Parsea cada octeto decimal separado por '.' y construye el entero de 32 bits
; en el formato big-endian (network order) que espera sin_addr:
;
;   resultado = a | (b << 8) | (c << 16) | (d << 24)
;
; En un sistema little-endian (x86-64), esto coloca el primer octeto 'a' en
; el byte de menor dirección de memoria, equivalente al comportamiento de
; inet_aton() de la libc.
;
; Ejemplo: "127.0.0.1" → 0x0100007F (little-endian representation of 127.0.0.1)
;
; Preserva: rbx, r12, r13, r14
; =============================================================
inet_aton_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi              ; r12 = puntero actual en la cadena IP
    xor  r13d, r13d            ; r13d = resultado acumulado en network order
    xor  r14d, r14d            ; r14d = desplazamiento de bits (0→8→16→24)

.ia_octet:
    xor  eax, eax              ; eax = acumulador del octeto actual

.ia_digit:
    movzx ecx, byte [r12]
    test cl, cl
    jz   .ia_store             ; fin de cadena: almacenar último octeto
    cmp  cl, '.'
    je   .ia_dot               ; separador: almacenar octeto y continuar
    sub  cl, '0'               ; convertir ASCII → dígito
    cmp  cl, 9
    ja   .ia_store             ; carácter no numérico: fin anticipado
    imul eax, eax, 10          ; desplazar acumulador un lugar decimal
    add  eax, ecx              ; sumar el dígito
    inc  r12                   ; avanzar al siguiente carácter
    jmp  .ia_digit

.ia_dot:
    inc  r12                   ; saltar el '.'
    ; caer en .ia_store para almacenar el octeto recién parseado

.ia_store:
    ; Desplazar el octeto a su posición correcta y acumularlo en el resultado
    ; Ejemplo: octeto 127, shift 0  → or r13d, 127         → 0x0000007F
    ;          octeto   0, shift 8  → or r13d, 0 << 8      → 0x0000007F
    ;          octeto   0, shift 16 → or r13d, 0 << 16     → 0x0000007F
    ;          octeto   1, shift 24 → or r13d, 1 << 24     → 0x0100007F
    mov  ecx, r14d             ; ecx = número de bits a desplazar
    shl  eax, cl               ; posicionar el octeto en el byte correcto
    or   r13d, eax             ; acumular en el resultado
    add  r14d, 8               ; el siguiente octeto irá 8 bits más arriba
    cmp  r14d, 32
    jl   .ia_octet             ; quedan octetos por parsear

    ; Los 4 octetos han sido procesados
    mov  eax, r13d             ; retornar el resultado en eax/rax

    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; =============================================================
; atoi_fn(rdi=str) → rax : convierte string ASCII decimal a entero sin signo
;
; No maneja signo negativo (los números de puerto son siempre positivos).
; Se detiene ante el primer carácter no numérico o nul-terminador.
; =============================================================
atoi_fn:
    xor  eax, eax              ; acumulador = 0
.atoi_lp:
    movzx ecx, byte [rdi]
    test cl, cl
    jz   .atoi_end             ; fin de cadena
    sub  cl, '0'
    cmp  cl, 9
    ja   .atoi_end             ; carácter no numérico → terminar
    imul eax, eax, 10
    add  eax, ecx
    inc  rdi
    jmp  .atoi_lp
.atoi_end:
    ret

; =============================================================
; strlen_fn(rdi=str) → rax : longitud de cadena nul-terminada
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
; strip_newline(rdi=buf, rcx=len) → rcx : longitud tras eliminar terminadores
;
; Elimina '\r' (13) y '\n' (10) del final del buffer colocando un nul (0)
; en su lugar. Retorna la nueva longitud en rcx.
; =============================================================
strip_newline:
    test rcx, rcx
    jz   .sn_end
    mov  rsi, rdi
    add  rsi, rcx
    dec  rsi                   ; rsi = puntero al último byte del buffer
.sn_lp:
    cmp  rsi, rdi
    jl   .sn_end               ; no quedan bytes que revisar
    mov  al, [rsi]
    cmp  al, 10                ; '\n'
    je   .sn_rem
    cmp  al, 13                ; '\r'
    je   .sn_rem
    jmp  .sn_end               ; otro carácter → fin de limpieza
.sn_rem:
    mov  byte [rsi], 0         ; reemplazar terminador por nul
    dec  rsi
    dec  rcx
    jmp  .sn_lp
.sn_end:
    ret

; =============================================================
; print_cstr_fn(rdi=str) : escribe una cadena nul-terminada en stdout (fd=1)
;
; Calcula la longitud con strlen_fn y llama a sys_write.
; No imprime nada si la cadena está vacía.
; =============================================================
print_cstr_fn:
    push rdi
    call strlen_fn             ; rax = longitud de la cadena
    mov  rdx, rax
    pop  rsi                   ; rsi = puntero a la cadena (primer argumento guardado)
    test rdx, rdx
    jz   .pc_end               ; cadena vacía → no hacer nada
    mov  rax, SYS_WRITE
    mov  rdi, 1                ; fd = stdout
    syscall
.pc_end:
    ret
