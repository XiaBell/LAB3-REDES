; =============================================================
; broker_tcp.asm
; Broker TCP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Este broker atiende múltiples clientes TCP en un solo proceso,
; sin hilos. El truco es select(): en lugar de bloquearse en uno
; solo, le pregunta al kernel "¿cuál de estos sockets tiene datos
; listos?" y solo entonces lee. Así puede manejar 16 clientes
; simultáneos con un único flujo de ejecución.
;
; Protocolo:
;   Cliente → Broker  : "SUB|<tema>\n"        (suscribirse a un partido)
;                       "PUB|<tema>|<msg>\n"   (publicar evento)
;   Broker  → Cliente : "MSG|<tema>|<msg>\n"   (reenvío a suscriptores)
;
; Por qué TCP y no UDP aquí?
; TCP garantiza entrega y orden. Para un sistema pub-sub donde no
; queremos perder ni un gol, TCP es la elección correcta.
; La contra es que debemos manejar fragmentación: un mensaje puede
; llegar partido en varios read(). Por eso cada cliente tiene un
; buffer de acumulación (CLI_READ_BUF) donde guardamos bytes hasta
; encontrar el \n que marca el fin de un mensaje completo.
;
; Compilar:
;   nasm -f elf64 broker_tcp.asm -o broker_tcp.o
;   ld -o broker_tcp broker_tcp.o
;
; Uso: ./broker_tcp <puerto>
;      Ejemplo: ./broker_tcp 9000
;
; Syscalls utilizados (ABI System V AMD64 Linux):
;   nro  nombre         descripción
;   ---  ----------     --------------------------------------------------------
;    0   sys_read       Lee datos de un socket de cliente (stream TCP)
;    1   sys_write      Escribe en stdout para log del broker
;    3   sys_close      Cierra el fd de un cliente desconectado
;   23   sys_select     Monitorea múltiples fds simultáneamente (sin hilos)
;   41   sys_socket     Crea el socket TCP: socket(AF_INET, SOCK_STREAM, 0)
;   43   sys_accept     Acepta una nueva conexión entrante
;   44   sys_sendto     Envía datos al socket de un suscriptor
;   49   sys_bind       Asocia el socket al puerto especificado
;   50   sys_listen     Pone el socket en modo escucha
;   54   sys_setsockopt Configura SO_REUSEADDR en el socket
;   60   sys_exit       Termina el proceso
;
; Cómo funciona fd_set para select():
;   Es un arreglo de 128 bytes (1024 bits), uno por posible fd.
;   FD_SET(fd):   byte[fd/8] |= (1 << (fd%8))  → encender el bit del fd
;   FD_ZERO:      poner los 128 bytes a cero
;   FD_ISSET(fd): byte[fd/8] & (1 << (fd%8))   → leer el bit del fd
;
; Layout de cada entrada de cliente (CLIENT_SIZE = 256 bytes):
;   +0   fd        (4)   descriptor del socket; -1 si el slot está libre
;   +4   state     (4)   0=recién conectado, 1=suscriptor registrado
;   +8   topic    (64)   nombre del tema suscrito (nul-terminado)
;   +72  buf_len   (4)   bytes acumulados en read_buf pendientes de procesar
;   +76  pad       (4)   alineación
;   +80  read_buf(176)   buffer de lectura parcial (acumula hasta encontrar \n)
; =============================================================

bits 64
default rel

; ── Números de syscall ───────────────────────────────────────
%define SYS_READ       0
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SELECT     23
%define SYS_SOCKET     41
%define SYS_ACCEPT     43
%define SYS_SENDTO     44
%define SYS_BIND       49
%define SYS_LISTEN     50
%define SYS_SETSOCKOPT 54
%define SYS_EXIT       60

; ── Constantes de red ────────────────────────────────────────
%define AF_INET        2
%define SOCK_STREAM    1       ; TCP: stream orientado a conexión
%define SOL_SOCKET     1
%define SO_REUSEADDR   2
%define BACKLOG        16      ; máximo de conexiones pendientes en la cola

; ── Constantes de la aplicación ──────────────────────────────
%define MAX_CLIENTS    16
%define MAX_TOPIC      64
%define FDSET_SIZE     128     ; 1024 bits / 8 = 128 bytes
%define CLIENT_SIZE    256

; Offsets dentro de cada entrada de cliente
%define CLI_FD         0
%define CLI_STATE      4
%define CLI_TOPIC      8
%define CLI_BUF_LEN    72
%define CLI_READ_BUF   80
%define CLI_READ_CAP   176     ; capacidad máxima del buffer de lectura

%define STATE_NEW      0
%define STATE_SUB      1

; ── Macros utilitarios ───────────────────────────────────────

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

; FD_SET(fd_reg, fdset_ptr_reg)
; Enciende el bit correspondiente a fd en el fd_set.
; Destruye: rax, rcx, rdx
%macro FD_SET 2
    mov   rax, %1
    mov   rcx, rax
    shr   rax, 3               ; rax = fd / 8  → índice de byte
    and   ecx, 7               ; ecx = fd % 8  → índice de bit dentro del byte
    mov   dl, 1
    shl   dl, cl               ; dl = 1 << (fd%8)
    or    byte [%2 + rax], dl
%endmacro

; FD_ISSET(fd_reg, fdset_ptr_reg) → ZF=0 si el bit está encendido
; Destruye: rax, rcx, rdx
%macro FD_ISSET 2
    mov   rax, %1
    mov   rcx, rax
    shr   rax, 3
    and   ecx, 7
    mov   dl, 1
    shl   dl, cl
    test  byte [%2 + rax], dl
%endmacro

; =============================================================
section .data

s_uso        db "Uso: ./broker_tcp <puerto>", 10
s_uso_len    equ $ - s_uso

s_listen     db "[Broker TCP] Escuchando en puerto "
s_listen_l   equ $ - s_listen

s_nl         db 10
s_nl_len     equ 1

s_conn       db "[Broker TCP] Nueva conexion fd="
s_conn_l     equ $ - s_conn

s_disc       db "[Broker TCP] Desconectado fd="
s_disc_l     equ $ - s_disc

s_sub_log    db "[Broker TCP] Suscripcion: fd="
s_sub_log_l  equ $ - s_sub_log

s_sub_tema   db " tema=["
s_sub_tema_l equ $ - s_sub_tema

s_sub_suf    db "]", 10
s_sub_suf_l  equ $ - s_sub_suf

s_pub_log    db "[Broker TCP] PUB ["
s_pub_log_l  equ $ - s_pub_log

s_pub_mid    db "]: "
s_pub_mid_l  equ $ - s_pub_mid

s_bad        db "[Broker TCP] Mensaje malformado", 10
s_bad_len    equ $ - s_bad

s_unk        db "[Broker TCP] Tipo desconocido", 10
s_unk_len    equ $ - s_unk

s_full       db "[Broker TCP] No hay espacio para mas clientes", 10
s_full_len   equ $ - s_full

s_SUB        db "SUB"
s_PUB        db "PUB"
s_MSG        db "MSG|"
s_MSG_len    equ $ - s_MSG

; =============================================================
section .bss

server_fd    resd 1
opt_val      resd 1
server_addr  resb 16
max_fd       resd 1
num_buf      resb 12

; Tabla de clientes: MAX_CLIENTS entradas de CLIENT_SIZE bytes cada una
clients      resb MAX_CLIENTS * CLIENT_SIZE

; fd_sets para select():
;   read_fds: el set que construimos nosotros antes de select()
;   tmp_fds:  la copia que pasamos a select() (la modifica al retornar)
read_fds     resb FDSET_SIZE
tmp_fds      resb FDSET_SIZE

; Buffer de salida para construir los mensajes MSG antes de enviar
out_buf      resb 1024

; =============================================================
section .text
    global _start

_start:
    pop  rdi                   ; argc
    cmp  rdi, 2
    jl   .err_uso

    pop  rax                   ; argv[0] descartado
    pop  rdi                   ; rdi = string del puerto

    call atoi_fn               ; rax = puerto en host byte order
    mov  r15d, eax             ; guardar para imprimir en el log

    ; htons manual: intercambiar bytes del puerto
    movzx ecx, ax
    rol  cx, 8                 ; cx = puerto en network byte order

    ; CRITICO: guardar el puerto en server_addr ANTES de setsockopt.
    ; setsockopt destruye rcx (caller-saved), lo que corromperia cx.
    ; Este era el bug: cx llegaba con basura al mov word [server_addr+2].
    mov  word  [server_addr + 0], AF_INET
    mov  word  [server_addr + 2], cx       ; puerto en network order — guardar YA
    mov  dword [server_addr + 4], 0        ; INADDR_ANY
    mov  qword [server_addr + 8], 0

    ; ── socket(AF_INET, SOCK_STREAM, 0) ──────────────────────
    ; SOCK_STREAM = TCP. A diferencia de SOCK_DGRAM (UDP), este socket
    ; mantiene una conexión establecida con cada cliente.
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_STREAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_sock
    mov  [server_fd], eax

    ; ── setsockopt: SO_REUSEADDR ──────────────────────────────
    ; Permite relanzar el broker inmediatamente después de cerrarlo,
    ; sin esperar que el OS libere el puerto (estado TIME_WAIT).
    mov  dword [opt_val], 1
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [server_fd]
    mov  rsi, SOL_SOCKET
    mov  rdx, SO_REUSEADDR
    lea  r10, [opt_val]
    mov  r8, 4
    syscall

    ; ── bind(fd, &server_addr, 16) — server_addr ya fue rellenada arriba ──


    mov  rax, SYS_BIND
    movsx rdi, dword [server_fd]
    lea  rsi, [server_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_bind

    ; ── listen(fd, BACKLOG) ───────────────────────────────────
    ; Pone el socket en modo pasivo. El kernel acepta hasta BACKLOG
    ; conexiones en cola mientras nosotros estamos ocupados en select().
    mov  rax, SYS_LISTEN
    movsx rdi, dword [server_fd]
    mov  rsi, BACKLOG
    syscall
    test rax, rax
    js   .err_listen

    mov  eax, [server_fd]
    mov  [max_fd], eax         ; max_fd = el fd más alto visto hasta ahora

    ; Inicializar todos los slots de clientes como inactivos (fd = -1)
    xor  ebx, ebx
.init_clients:
    cmp  ebx, MAX_CLIENTS
    jge  .init_done
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    mov  dword [clients + rax + CLI_FD], -1
    inc  ebx
    jmp  .init_clients
.init_done:

    ; Log de inicio
    write_lit s_listen, s_listen_l
    mov  edi, r15d
    lea  rsi, [num_buf]
    call itoa_fn
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_nl, 1

; =============================================================
; .select_loop : corazón del broker
;
; Cada iteración:
;   1. Construye el fd_set con todos los fds activos
;   2. Llama select() — bloquea hasta que algún fd tenga datos
;   3. Si el server_fd está listo: hay una nueva conexión
;   4. Para cada cliente listo: leer datos y procesar mensajes
; =============================================================
.select_loop:

    ; ── FD_ZERO: poner a cero los 128 bytes de read_fds ──────
    lea  rdi, [read_fds]
    xor  eax, eax
    mov  ecx, FDSET_SIZE / 8   ; 16 iteraciones de 8 bytes
.fdzero:
    mov  qword [rdi], 0
    add  rdi, 8
    dec  ecx
    jnz  .fdzero

    ; ── FD_SET: añadir server_fd para detectar nuevas conexiones
    movsx rax, dword [server_fd]
    lea  r8, [read_fds]
    FD_SET rax, r8

    ; ── FD_SET: añadir todos los clientes activos ─────────────
    xor  ebx, ebx
.build_fds:
    cmp  ebx, MAX_CLIENTS
    jge  .build_done
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    movsx r9, dword [clients + rax + CLI_FD]
    cmp  r9d, -1
    je   .build_next
    lea  r8, [read_fds]
    FD_SET r9, r8
.build_next:
    inc  ebx
    jmp  .build_fds
.build_done:

    ; ── Copiar read_fds → tmp_fds ─────────────────────────────
    ; select() sobrescribe el fd_set con los fds que quedaron listos.
    ; Pasamos una copia (tmp_fds) para no perder nuestra lista original.
    lea  rsi, [read_fds]
    lea  rdi, [tmp_fds]
    mov  ecx, FDSET_SIZE / 8
.copy_fds:
    mov  rax, [rsi]
    mov  [rdi], rax
    add  rsi, 8
    add  rdi, 8
    dec  ecx
    jnz  .copy_fds

    ; ── select(max_fd+1, &tmp_fds, NULL, NULL, NULL) ──────────
    ; nfds debe ser el fd más alto + 1 (no el número de fds).
    ; timeout=NULL → bloquea indefinidamente hasta que haya actividad.
    mov  rax, SYS_SELECT
    movsx rdi, dword [max_fd]
    inc  rdi                   ; nfds = max_fd + 1
    lea  rsi, [tmp_fds]
    xor  rdx, rdx
    xor  r10, r10
    xor  r8, r8                ; timeout = NULL → espera indefinida
    syscall
    test rax, rax
    jle  .select_loop          ; error o interrupción → reintentar

    ; ── ¿Hay nueva conexión? FD_ISSET(server_fd, tmp_fds) ────
    movsx rax, dword [server_fd]
    lea  r8, [tmp_fds]
    FD_ISSET rax, r8
    jz   .check_clients

    ; accept(): el kernel completó el 3-way handshake con el cliente.
    ; Nos entrega un fd nuevo dedicado a esa conexión.
    ; El server_fd sigue escuchando; el nuevo fd es para este cliente.
    mov  rax, SYS_ACCEPT
    movsx rdi, dword [server_fd]
    xor  rsi, rsi
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .check_clients
    mov  r12d, eax             ; r12d = fd del nuevo cliente

    ; Buscar slot libre en la tabla
    xor  ebx, ebx
.find_slot:
    cmp  ebx, MAX_CLIENTS
    jge  .no_slot
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    cmp  dword [clients + rax + CLI_FD], -1
    je   .slot_found
    inc  ebx
    jmp  .find_slot

.no_slot:
    write_lit s_full, s_full_len
    mov  rax, SYS_CLOSE
    movsx rdi, r12d
    syscall
    jmp  .check_clients

.slot_found:
    ; Inicializar el slot del nuevo cliente
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    mov  dword [clients + rax + CLI_FD],      r12d
    mov  dword [clients + rax + CLI_STATE],   STATE_NEW
    mov  dword [clients + rax + CLI_BUF_LEN], 0
    lea  rdi, [clients + rax + CLI_READ_BUF]
    mov  byte [rdi], 0         ; vaciar el buffer de lectura
    lea  rdi, [clients + rax + CLI_TOPIC]
    mov  byte [rdi], 0

    ; Actualizar max_fd si este fd es más grande
    cmp  r12d, [max_fd]
    jle  .no_max_update
    mov  [max_fd], r12d
.no_max_update:

    write_lit s_conn, s_conn_l
    mov  edi, r12d
    lea  rsi, [num_buf]
    call itoa_fn
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_nl, 1

; ── Revisar qué clientes tienen datos listos ──────────────────
.check_clients:
    xor  ebx, ebx

.cli_loop:
    cmp  ebx, MAX_CLIENTS
    jge  .select_loop

    mov  rax, rbx
    imul rax, CLIENT_SIZE
    movsx r12, dword [clients + rax + CLI_FD]
    cmp  r12d, -1
    je   .cli_next             ; slot vacío

    lea  r8, [tmp_fds]
    FD_ISSET r12, r8
    jz   .cli_next             ; este fd no tiene datos listos

    ; ── Leer datos del cliente en su buffer de acumulación ────
    ; TCP puede fragmentar los mensajes: "PUB|parti" puede llegar
    ; en un read() y "do1|gol\n" en el siguiente. Por eso acumulamos
    ; en CLI_READ_BUF hasta encontrar el \n que cierra el mensaje.
    mov  r13, rbx
    mov  rax, r13
    imul rax, CLIENT_SIZE
    lea  r14, [clients + rax]  ; r14 = puntero a la entrada del cliente

    ; Calcular dónde escribir: justo después de los bytes ya acumulados
    movsx r9, dword [r14 + CLI_BUF_LEN]
    mov  rdx, CLI_READ_CAP
    sub  rdx, r9               ; rdx = espacio libre en el buffer
    test rdx, rdx
    jle  .cli_buf_full         ; buffer lleno: descartar todo

    lea  rsi, [r14 + CLI_READ_BUF]
    add  rsi, r9               ; rsi = puntero de escritura

    mov  rax, SYS_READ
    mov  rdi, r12              ; fd del cliente
    syscall                    ; lee hasta rdx bytes → rax = bytes leídos

    test rax, rax
    jle  .cli_disconnect       ; 0 = cliente cerró la conexión (FIN TCP)

    ; Actualizar la cantidad de bytes acumulados
    add  [r14 + CLI_BUF_LEN], eax

    ; ── Procesar todas las líneas completas en el buffer ──────
    ; Un mensaje completo termina en \n. Pueden haber llegado varios
    ; en un mismo read() (mensajes cortos y red rápida).
.proc_lines:
    mov  ecx, [r14 + CLI_BUF_LEN]
    test ecx, ecx
    jz   .cli_next

    ; Buscar \n dentro de los bytes válidos del buffer
    ; Ponemos temporalmente un \0 después del último byte válido
    ; para que find_char_fn no lea más allá.
    lea  rdi, [r14 + CLI_READ_BUF]
    mov  byte [rdi + rcx], 0   ; centinela temporal
    mov  al, 10                ; '\n'
    call find_char_fn
    test rax, rax
    jz   .cli_next             ; no hay \n todavía → esperar más datos

    ; Nul-terminar la línea y eliminar \r si existe
    mov  byte [rax], 0
    cmp  rax, rdi              ; ¿el \n es el primer byte?
    je   .skip_cr_check
    cmp  byte [rax - 1], 13    ; \r (mensajes Windows)
    jne  .skip_cr_check
    mov  byte [rax - 1], 0
.skip_cr_check:

    ; Calcular cuántos bytes consume esta línea (incluyendo el \n)
    lea  rdx, [r14 + CLI_READ_BUF]
    sub  rax, rdx              ; rax = offset del \n dentro del buffer
    inc  rax                   ; rax = bytes consumidos (tema + \n)
    mov  r15, rax              ; r15 = bytes consumidos (preservar)

    ; Procesar la línea completa
    lea  rdi, [r14 + CLI_READ_BUF]
    call process_message_fn

    ; ── Compactar el buffer: mover el resto al inicio ─────────
    ; Después de procesar una línea, los bytes siguientes (si los hay)
    ; deben quedarse al inicio del buffer para el próximo read().
    mov  ecx, [r14 + CLI_BUF_LEN]
    sub  ecx, r15d             ; ecx = bytes restantes después del \n

    cmp  ecx, 0
    jle  .buf_cleared

    lea  rsi, [r14 + CLI_READ_BUF]
    lea  rdi, [r14 + CLI_READ_BUF]
    add  rsi, r15              ; rsi = inicio de los bytes restantes
.compact:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .compact

    ; Guardar nuevo buf_len (bytes que quedaron en el buffer)
    mov  ecx, [r14 + CLI_BUF_LEN]
    sub  ecx, r15d
    mov  [r14 + CLI_BUF_LEN], ecx
    jmp  .proc_lines           ; revisar si quedó otra línea completa

.buf_cleared:
    mov  dword [r14 + CLI_BUF_LEN], 0
    jmp  .proc_lines

.cli_buf_full:
    ; El buffer se llenó sin encontrar \n: mensaje inválido o muy largo.
    ; Descartar todo el contenido acumulado.
    mov  dword [r14 + CLI_BUF_LEN], 0
    jmp  .cli_next

.cli_disconnect:
    ; El cliente cerró la conexión o hubo un error de red.
    ; Liberamos su slot y cerramos el fd.
    mov  dword [r14 + CLI_FD], -1
    mov  rax, SYS_CLOSE
    mov  rdi, r12
    syscall

    write_lit s_disc, s_disc_l
    mov  edi, r12d
    lea  rsi, [num_buf]
    call itoa_fn
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_nl, 1

.cli_next:
    inc  ebx
    jmp  .cli_loop

.err_uso:   write_lit s_uso, s_uso_len
            exit_code 1
.err_sock:  exit_code 1
.err_bind:  exit_code 1
.err_listen:exit_code 1

; =============================================================
; process_message_fn(rdi = línea nul-terminada)
;
; Parsea el tipo (SUB o PUB) y ejecuta la acción correspondiente.
;
; Registros del contexto externo que usa pero NO modifica:
;   r14 = puntero a la entrada del cliente actual
; Registros que usa internamente (pushea y restaura):
;   r12, r13
; =============================================================
process_message_fn:
    push r12
    push r13

    mov  r12, rdi              ; r12 = puntero a la línea completa

    ; Encontrar el primer '|' para determinar el tipo (SUB o PUB)
    mov  al, '|'
    call find_char_fn
    test rax, rax
    jz   .pm_bad               ; no hay '|' → malformado

    lea  rdx, [r12]
    sub  rax, rdx              ; rax = longitud del tipo ("SUB" → 3)

    mov  r13, rax              ; r13 = longitud del tipo (preservar)

    ; ── SUB ──────────────────────────────────────────────────
    cmp  r13, 3
    jne  .pm_chk_pub
    lea  rdi, [r12]
    lea  rsi, [s_SUB]
    call strncmp3_fn
    test rax, rax
    jnz  .pm_chk_pub

    ; Extraer el tema: apuntar al byte después del '|'
    lea  rdi, [r12]
    mov  al, '|'
    call find_char_fn
    inc  rax                   ; rax = puntero al tema

    ; Registrar el tema en la entrada del cliente (r14, del contexto externo)
    mov  dword [r14 + CLI_STATE], STATE_SUB
    lea  rdi, [r14 + CLI_TOPIC]
    mov  rsi, rax
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    ; Log: "[Broker TCP] Suscripcion: fd=<n> tema=[<tema>]\n"
    write_lit s_sub_log, s_sub_log_l
    mov  edi, [r14 + CLI_FD]
    lea  rsi, [num_buf]
    call itoa_fn
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_sub_tema, s_sub_tema_l
    lea  rdi, [r14 + CLI_TOPIC]
    call print_cstr_fn
    write_lit s_sub_suf, s_sub_suf_l
    jmp  .pm_done

.pm_chk_pub:
    ; ── PUB ──────────────────────────────────────────────────
    cmp  r13, 3
    jne  .pm_unk
    lea  rdi, [r12]
    lea  rsi, [s_PUB]
    call strncmp3_fn
    test rax, rax
    jnz  .pm_unk

    ; Puntero al tema (después del primer '|')
    lea  rdi, [r12]
    mov  al, '|'
    call find_char_fn
    inc  rax
    ; Guardar en pila para preservarlo: find_char_fn y strncmp3_fn
    ; no deben corromperlo. Usamos r12 (ya no lo necesitamos como línea).
    mov  r12, rax              ; r12 = puntero al tema

    ; Buscar el segundo '|' para separar tema de mensaje
    mov  rdi, r12
    mov  al, '|'
    call find_char_fn
    test rax, rax
    jz   .pm_bad               ; PUB sin mensaje

    mov  byte [rax], 0         ; nul-terminar el tema sobreescribiendo el '|'
    inc  rax
    mov  r13, rax              ; r13 = puntero al mensaje

    ; Log: "[Broker TCP] PUB [<tema>]: <msg>\n"
    write_lit s_pub_log, s_pub_log_l
    mov  rdi, r12
    call print_cstr_fn
    write_lit s_pub_mid, s_pub_mid_l
    mov  rdi, r13
    call print_cstr_fn
    write_lit s_nl, 1

    ; Difundir a todos los suscriptores del tema
    mov  rdi, r12
    mov  rsi, r13
    call broadcast_tcp_fn
    jmp  .pm_done

.pm_bad:
    write_lit s_bad, s_bad_len
    jmp  .pm_done

.pm_unk:
    write_lit s_unk, s_unk_len

.pm_done:
    pop  r13
    pop  r12
    ret

; =============================================================
; broadcast_tcp_fn(rdi=topic_ptr, rsi=msg_ptr)
;
; Construye "MSG|<tema>|<msg>\n" en out_buf y lo envía con sendto()
; (equivalente a send() en TCP) a cada cliente suscrito al tema.
;
; En TCP, sendto() con addr=NULL y addrlen=0 funciona igual que send()
; porque la "dirección" ya está implícita en la conexión establecida.
; =============================================================
broadcast_tcp_fn:
    push r12
    push r13
    push r14
    push r15
    push rbx

    mov  r12, rdi              ; r12 = tema
    mov  r13, rsi              ; r13 = mensaje

    ; Construir el mensaje de difusión en out_buf
    lea  r14, [out_buf]

    ; Copiar "MSG|" (4 bytes)
    lea  rsi, [s_MSG]
    mov  ecx, s_MSG_len
.bt_pre:
    mov  al, [rsi]
    mov  [r14], al
    inc  rsi
    inc  r14
    dec  ecx
    jnz  .bt_pre

    ; Copiar el tema
    mov  rsi, r12
.bt_topic:
    mov  al, [rsi]
    test al, al
    jz   .bt_sep
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bt_topic
.bt_sep:
    mov  byte [r14], '|'
    inc  r14

    ; Copiar el mensaje
    mov  rsi, r13
.bt_msg:
    mov  al, [rsi]
    test al, al
    jz   .bt_msg_done
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bt_msg
.bt_msg_done:
    mov  byte [r14], 10        ; '\n' final (el subscriber lo usa para delimitar)
    inc  r14

    ; Longitud total del mensaje construido
    lea  rdx, [out_buf]
    sub  r14, rdx              ; r14 = longitud

    ; Recorrer la tabla de clientes y enviar a los que coinciden
    xor  ebx, ebx
    mov  r15d, MAX_CLIENTS

.bcast_loop:
    cmp  ebx, r15d
    jge  .bcast_done

    mov  rax, rbx
    imul rax, CLIENT_SIZE
    lea  r9, [clients + rax]

    movsx r10, dword [r9 + CLI_FD]
    cmp  r10d, -1
    je   .bcast_next           ; slot vacío

    cmp  dword [r9 + CLI_STATE], STATE_SUB
    jne  .bcast_next           ; no es suscriptor todavía

    ; Comparar tema
    lea  rdi, [r9 + CLI_TOPIC]
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    jnz  .bcast_next           ; tema diferente

    ; sendto(fd, out_buf, len, 0, NULL, 0)
    ; En TCP no necesitamos especificar dirección: la conexión ya está establecida.
    mov  rax, SYS_SENDTO
    mov  rdi, r10
    lea  rsi, [out_buf]
    mov  rdx, r14
    xor  r10, r10
    xor  r8, r8
    xor  r9, r9
    syscall

.bcast_next:
    inc  ebx
    jmp  .bcast_loop

.bcast_done:
    pop  rbx
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    ret

; =============================================================
; Funciones auxiliares
; =============================================================

; atoi_fn(rdi=str) → rax
atoi_fn:
    xor  eax, eax
.a_lp:
    movzx ecx, byte [rdi]
    test cl, cl
    jz   .a_end
    sub  cl, '0'
    cmp  cl, 9
    ja   .a_end
    imul eax, eax, 10
    add  eax, ecx
    inc  rdi
    jmp  .a_lp
.a_end:
    ret

; itoa_fn(edi=val, rsi=buf) → rcx=longitud
itoa_fn:
    push rbx
    mov  eax, edi
    mov  rbx, rsi
    test eax, eax
    jnz  .it_nz
    mov  byte [rsi], '0'
    mov  byte [rsi+1], 0
    mov  rcx, 1
    pop  rbx
    ret
.it_nz:
    add  rsi, 11
    mov  byte [rsi], 0
    dec  rsi
.it_lp:
    xor  edx, edx
    mov  ecx, 10
    div  ecx
    add  dl, '0'
    mov  [rsi], dl
    dec  rsi
    test eax, eax
    jnz  .it_lp
    inc  rsi
    mov  rdi, rbx
    mov  rcx, 0
.it_mv:
    mov  al, [rsi]
    test al, al
    jz   .it_mv_done
    mov  [rdi], al
    inc  rsi
    inc  rdi
    inc  rcx
    jmp  .it_mv
.it_mv_done:
    mov  byte [rdi], 0
    pop  rbx
    ret

; strlen_fn(rdi=str) → rax
strlen_fn:
    xor  eax, eax
.sl_lp:
    cmp  byte [rdi + rax], 0
    je   .sl_e
    inc  rax
    jmp  .sl_lp
.sl_e:
    ret

; strcmp_fn(rdi=s1, rsi=s2) → rax (0 si iguales)
strcmp_fn:
.sc_lp:
    mov  al, [rdi]
    cmp  al, [rsi]
    jne  .sc_d
    test al, al
    jz   .sc_eq
    inc  rdi
    inc  rsi
    jmp  .sc_lp
.sc_eq:
    xor  eax, eax
    ret
.sc_d:
    movsx eax, al
    movzx ecx, byte [rsi]
    sub  eax, ecx
    ret

; strncmp3_fn(rdi=s1, rsi=s2) → rax (0 si los primeros 3 bytes coinciden)
strncmp3_fn:
    mov  al, [rdi + 0]
    cmp  al, [rsi + 0]
    jne  .sn3_ne
    mov  al, [rdi + 1]
    cmp  al, [rsi + 1]
    jne  .sn3_ne
    mov  al, [rdi + 2]
    cmp  al, [rsi + 2]
    jne  .sn3_ne
    xor  eax, eax
    ret
.sn3_ne:
    mov  eax, 1
    ret

; strncpy_fn(rdi=dst, rsi=src, rcx=max)
; Copia hasta max bytes. Siempre nul-termina dst.
strncpy_fn:
    push rcx
.scp_lp:
    test rcx, rcx
    jz   .scp_done
    mov  al, [rsi]
    test al, al
    jz   .scp_done
    mov  [rdi], al
    inc  rdi
    inc  rsi
    dec  rcx
    jmp  .scp_lp
.scp_done:
    mov  byte [rdi], 0
    pop  rcx
    ret

; find_char_fn(rdi=str, al=char) → rax (puntero al char, o 0 si no existe)
find_char_fn:
    mov  cl, al
.fc_lp:
    mov  al, [rdi]
    test al, al
    jz   .fc_none
    cmp  al, cl
    je   .fc_found
    inc  rdi
    jmp  .fc_lp
.fc_found:
    mov  rax, rdi
    ret
.fc_none:
    xor  eax, eax
    ret

; print_cstr_fn(rdi=str) — imprime string nul-terminado en stdout
print_cstr_fn:
    push rdi
    call strlen_fn
    mov  rdx, rax
    pop  rsi
    test rdx, rdx
    jz   .pc_done
    mov  rax, SYS_WRITE
    mov  rdi, 1
    syscall
.pc_done:
    ret
