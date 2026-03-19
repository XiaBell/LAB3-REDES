; =============================================================
; broker_tcp.asm
; Broker TCP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Protocolo:
;   Cliente → Broker  : "SUB|<tema>\n"        (suscribirse a un partido)
;                       "PUB|<tema>|<msg>\n"   (publicar evento del partido)
;   Broker  → Cliente : "MSG|<tema>|<msg>\n"   (reenvío a suscriptores)
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
;    1   sys_write      Escribe en stdout para log del broker
;    3   sys_close      Cierra el fd de un cliente desconectado
;   41   sys_socket     Crea el socket TCP: socket(AF_INET, SOCK_STREAM, 0)
;   43   sys_accept     Acepta una nueva conexión entrante
;   49   sys_bind       Asocia el socket al puerto especificado
;   50   sys_listen     Pone el socket en modo escucha
;   54   sys_setsockopt Configura SO_REUSEADDR en el socket
;   60   sys_exit       Termina el proceso
;   23   sys_select     Monitorea múltiples fds simultáneamente (sin hilos)
;    0   sys_read       Lee datos de un socket de cliente (stream TCP)
;   44   sys_sendto     Envía datos al socket de un suscriptor (puede usarse
;                       también sys_write con fd, pero sendto es más explícito)
;
; Arquitectura de multiplexado:
;   Se usa select() para atender múltiples clientes TCP en un solo proceso
;   sin hilos (pthread).  El bucle principal:
;     1. Construye un fd_set con el socket servidor y todos los clientes activos.
;     2. Llama a select(), que bloquea hasta que algún fd esté listo.
;     3. Si el socket servidor está listo: acepta una nueva conexión.
;     4. Para cada cliente listo: lee datos, procesa mensajes completos.
;
;   fd_set es un arreglo de 128 bytes (1024 bits).
;   FD_SET(fd):    byte [fdset + fd/8] |= (1 << (fd%8))
;   FD_ZERO:       poner a cero los 128 bytes
;   FD_ISSET(fd):  byte [fdset + fd/8] & (1 << (fd%8)) != 0
;
; Layout de cliente (256 bytes por entrada):
;   +0   fd         (4)  descriptor del socket, -1 si inactivo
;   +4   state      (4)  0=nuevo, 1=suscriptor
;   +8   topic     (64)  tema suscrito (vacío si state=0)
;   +72  buf_len    (4)  bytes acumulados en read_buf (aún sin '\n')
;   +76  pad        (4)  alineación
;   +80  read_buf (176)  buffer de lectura parcial por cliente
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
%define SOCK_STREAM    1       ; TCP orientado a conexión
%define SOL_SOCKET     1
%define SO_REUSEADDR   2
%define BACKLOG        16      ; cola de conexiones pendientes

; ── Constantes de la aplicación ──────────────────────────────
%define MAX_CLIENTS    16      ; máximo de clientes simultáneos
%define MAX_TOPIC      64
%define FDSET_SIZE     128     ; bytes de un fd_set (1024 bits / 8)
%define CLIENT_SIZE    256     ; bytes por entrada de cliente
%define CLI_FD         0       ; offset: fd del cliente
%define CLI_STATE      4       ; offset: estado (0=nuevo, 1=suscriptor)
%define CLI_TOPIC      8       ; offset: tema suscrito
%define CLI_BUF_LEN    72      ; offset: longitud de datos en read_buf
%define CLI_READ_BUF   80      ; offset: buffer de lectura parcial
%define CLI_READ_CAP   176     ; capacidad del read_buf (bytes)

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

; FD_SET(fd, fdset_ptr):  fdset[fd/8] |= (1 << (fd%8))
; Parámetros: %1 = registro con fd, %2 = registro con ptr a fdset
; Destruye: rax, rcx, rdx
%macro FD_SET 2
    mov   rax, %1
    mov   rcx, rax
    shr   rax, 3               ; rax = fd / 8  (índice de byte)
    and   ecx, 7               ; ecx = fd % 8  (índice de bit)
    mov   dl, 1
    shl   dl, cl               ; dl = 1 << (fd%8)
    or    byte [%2 + rax], dl
%endmacro

; FD_ISSET(fd, fdset_ptr) → ZF=0 si el bit está activo
; Parámetros: %1 = registro con fd, %2 = registro con ptr a fdset
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
max_fd       resd 1            ; fd máximo para select() nfds = max_fd+1
num_buf      resb 12

; Tabla de clientes: MAX_CLIENTS entradas de CLIENT_SIZE bytes
clients      resb MAX_CLIENTS * CLIENT_SIZE

; fd_sets para select() — se reconstruyen en cada iteración
read_fds     resb FDSET_SIZE
tmp_fds      resb FDSET_SIZE   ; copia de trabajo que select() modifica

; Buffer temporal de salida para difusión
out_buf      resb 1024

; =============================================================
section .text
    global _start

; =============================================================
; _start
; =============================================================
_start:
    pop  rdi                   ; argc
    cmp  rdi, 2
    jl   .err_uso

    pop  rax                   ; argv[0] (descartado)
    pop  rdi                   ; rdi = argv[1] = string del puerto

    call atoi_fn               ; rax = puerto host order
    mov  r15d, eax             ; guardar para imprimir

    ; htons: intercambiar bytes
    movzx ecx, ax
    rol  cx, 8                 ; cx = puerto network order

    ; ── socket(AF_INET, SOCK_STREAM, 0) ──────────────────────
    ; SOCK_STREAM = TCP, orientado a conexión y flujo de bytes.
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_STREAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_sock
    mov  [server_fd], eax

    ; ── setsockopt: SO_REUSEADDR ──────────────────────────────
    mov  dword [opt_val], 1
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [server_fd]
    mov  rsi, SOL_SOCKET
    mov  rdx, SO_REUSEADDR
    lea  r10, [opt_val]
    mov  r8, 4
    syscall

    ; ── Construir sockaddr_in ─────────────────────────────────
    mov  word  [server_addr + 0], AF_INET
    mov  word  [server_addr + 2], cx
    mov  dword [server_addr + 4], 0
    mov  qword [server_addr + 8], 0

    ; ── bind(fd, &addr, 16) ───────────────────────────────────
    mov  rax, SYS_BIND
    movsx rdi, dword [server_fd]
    lea  rsi, [server_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_bind

    ; ── listen(fd, BACKLOG) ───────────────────────────────────
    ; Pone el socket en modo pasivo: acepta hasta BACKLOG conexiones
    ; en cola antes de que las procesemos con accept().
    mov  rax, SYS_LISTEN
    movsx rdi, dword [server_fd]
    mov  rsi, BACKLOG
    syscall
    test rax, rax
    js   .err_listen

    ; Inicializar max_fd con el server_fd
    mov  eax, [server_fd]
    mov  [max_fd], eax

    ; Inicializar tabla de clientes: todos los fd = -1 (inactivos)
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

    ; Imprimir mensaje de inicio
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
; .select_loop : bucle principal de multiplexado con select()
;
; select() permite esperar eventos en múltiples file descriptors
; a la vez sin bloquear en uno solo.  Es el núcleo del broker TCP.
; =============================================================
.select_loop:

    ; ── Paso 1: FD_ZERO(read_fds) ────────────────────────────
    ; Poner a cero los 128 bytes del fd_set de lectura.
    lea  rdi, [read_fds]
    xor  eax, eax
    mov  ecx, FDSET_SIZE / 8   ; 16 iteraciones de 8 bytes
.fdzero:
    mov  qword [rdi], 0
    add  rdi, 8
    dec  ecx
    jnz  .fdzero

    ; ── Paso 2: FD_SET(server_fd, &read_fds) ─────────────────
    ; Añadir el socket servidor para detectar nuevas conexiones.
    movsx rax, dword [server_fd]
    lea  r8, [read_fds]
    FD_SET rax, r8

    ; ── Paso 3: FD_SET para cada cliente activo ───────────────
    xor  ebx, ebx
.build_fds:
    cmp  ebx, MAX_CLIENTS
    jge  .build_done
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    movsx r9, dword [clients + rax + CLI_FD]
    cmp  r9d, -1
    je   .build_next           ; slot inactivo

    lea  r8, [read_fds]
    FD_SET r9, r8              ; añadir fd del cliente al set
.build_next:
    inc  ebx
    jmp  .build_fds
.build_done:

    ; ── Paso 4: Copiar read_fds → tmp_fds ─────────────────────
    ; select() modifica el fd_set pasado; guardamos el original.
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

    ; ── Paso 5: select(max_fd+1, &tmp_fds, NULL, NULL, NULL) ─
    ; Argumentos en registros (ABI x86-64):
    ;   rdi = nfds = max_fd + 1
    ;   rsi = *readfds = &tmp_fds
    ;   rdx = *writefds = NULL
    ;   r10 = *exceptfds = NULL
    ;   r8  = *timeout = NULL  (bloqueante: espera indefinidamente)
    mov  rax, SYS_SELECT
    movsx rdi, dword [max_fd]
    inc  rdi                   ; nfds = max_fd + 1
    lea  rsi, [tmp_fds]
    xor  rdx, rdx              ; writefds = NULL
    xor  r10, r10              ; exceptfds = NULL
    xor  r8, r8                ; timeout = NULL (bloqueante)
    syscall

    test rax, rax
    jle  .select_loop          ; error o 0 fds listos → reintentar

    ; ── Paso 6: ¿Hay nueva conexión en server_fd? ─────────────
    movsx rax, dword [server_fd]
    lea  r8, [tmp_fds]
    FD_ISSET rax, r8
    jz   .check_clients        ; no hay nueva conexión

    ; accept(server_fd, NULL, NULL)
    ; Acepta la conexión TCP entrante.  El 3-way handshake ya fue
    ; completado por el kernel; recibimos un fd nuevo para el cliente.
    mov  rax, SYS_ACCEPT
    movsx rdi, dword [server_fd]
    xor  rsi, rsi              ; no nos importa la dirección del cliente aquí
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .check_clients        ; error en accept

    mov  r12d, eax             ; r12d = fd del nuevo cliente

    ; Buscar slot libre en la tabla de clientes
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
    ; No hay espacio: cerrar la conexión recién aceptada
    write_lit s_full, s_full_len
    mov  rax, SYS_CLOSE
    movsx rdi, r12d
    syscall
    jmp  .check_clients

.slot_found:
    ; Inicializar slot del nuevo cliente
    mov  rax, rbx
    imul rax, CLIENT_SIZE
    mov  dword [clients + rax + CLI_FD],      r12d
    mov  dword [clients + rax + CLI_STATE],   STATE_NEW
    mov  dword [clients + rax + CLI_BUF_LEN], 0
    ; Limpiar topic
    lea  rdi, [clients + rax + CLI_TOPIC]
    mov  byte [rdi], 0

    ; Actualizar max_fd si el nuevo fd es mayor
    cmp  r12d, [max_fd]
    jle  .no_max_update
    mov  [max_fd], r12d
.no_max_update:

    ; Log: "[Broker TCP] Nueva conexion fd=<n>\n"
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

; ── Paso 7: Revisar clientes listos para leer ─────────────────
.check_clients:
    xor  ebx, ebx              ; i = 0

.cli_loop:
    cmp  ebx, MAX_CLIENTS
    jge  .select_loop          ; fin de clientes → siguiente iteración select

    mov  rax, rbx
    imul rax, CLIENT_SIZE
    movsx r12, dword [clients + rax + CLI_FD]
    cmp  r12d, -1
    je   .cli_next             ; slot inactivo

    lea  r8, [tmp_fds]
    FD_ISSET r12, r8
    jz   .cli_next             ; este fd no está listo

    ; ── Leer datos del cliente ─────────────────────────────────
    ; TCP es un flujo de bytes; los mensajes pueden llegar fragmentados.
    ; Acumulamos en read_buf hasta encontrar '\n'.
    mov  r13, rbx              ; r13 = índice del cliente
    mov  rax, r13
    imul rax, CLIENT_SIZE
    lea  r14, [clients + rax]  ; r14 = puntero a la entrada del cliente

    ; Puntero al inicio del espacio libre en read_buf
    movsx r9, dword [r14 + CLI_BUF_LEN]
    lea  rdi, [r14 + CLI_READ_BUF]
    add  rdi, r9               ; rdi = ptr a donde leer

    ; Espacio disponible en el buffer
    mov  rdx, CLI_READ_CAP
    sub  rdx, r9               ; rdx = bytes disponibles
    test rdx, rdx
    jle  .cli_buf_full         ; buffer lleno: descartar datos

    ; sys_read(fd, buf_ptr, nbytes)
    ; Lee hasta rdx bytes del stream TCP del cliente.
    ; Retorna 0 si el cliente cerró la conexión (EOF).
    mov  rax, SYS_READ
    mov  rdi, r12              ; fd del cliente
    ; rdi necesita ser el fd, pero lo sobreescribimos con r12 arriba
    ; Corregir: guardar puntero de escritura en rsi
    lea  rsi, [r14 + CLI_READ_BUF]
    mov r9d, [r14 + CLI_BUF_LEN]
    add  rsi, r9               ; rsi = puntero de escritura
    mov  rdx, CLI_READ_CAP
    sub  rdx, r9               ; rdx = espacio libre
    mov  rax, SYS_READ
    mov  rdi, r12
    syscall

    test rax, rax
    jle  .cli_disconnect       ; 0 = EOF (cliente cerró), <0 = error

    ; Actualizar buf_len
    add  [r14 + CLI_BUF_LEN], eax

    ; ── Procesar todas las líneas completas acumuladas ─────────
    ; Buscar '\n' en el buffer acumulado.
.proc_lines:
    mov ecx, [r14 + CLI_BUF_LEN]
    test ecx, ecx
    jz   .cli_next

    lea  rdi, [r14 + CLI_READ_BUF]
    mov  al, 10                ; '\n'
    ; Buscar '\n' en los primeros ecx bytes
    call find_char_fn
    test rax, rax
    jz   .cli_next             ; sin '\n' → esperar más datos

    ; rax = puntero al '\n'.  La línea va de read_buf hasta rax (inclusive).
    mov  byte [rax], 0         ; reemplazar '\n' con nul → línea completa

    ; Eliminar '\r' si lo hay antes del '\n'
    test rax, rax
    jz   .skip_cr
    cmp  byte [rax - 1], 13    ; '\r'
    jne  .skip_cr
    mov  byte [rax - 1], 0
.skip_cr:

    ; Procesar la línea: r14 = puntero al cliente, rbx = índice
    lea  rdi, [r14 + CLI_READ_BUF]  ; rdi = inicio de la línea
    call process_message_fn

    ; Compactar el buffer: mover el resto hacia el inicio
    lea  rsi, [r14 + CLI_READ_BUF]
    ; rax sigue apuntando al byte del '\n' (ahora nul)
    ; Calcular cuántos bytes quedan después del '\n'
    lea  rdx, [r14 + CLI_READ_BUF]
    sub  rax, rdx              ; rax = offset del '\0' (antes '\n')
    inc  rax                   ; rax = bytes consumidos (incluyendo el '\n')

    mov ecx, [r14 + CLI_BUF_LEN]
    sub  ecx, eax              ; ecx = bytes restantes

    ; Mover bytes restantes al inicio
    lea  rsi, [r14 + CLI_READ_BUF]
    mov  rdi, rsi
    add  rsi, rax              ; rsi = inicio del resto
    test ecx, ecx
    jle  .buf_compacted
.compact:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .compact
.buf_compacted:
    mov ecx, [r14 + CLI_BUF_LEN]
    ; Recalcular correctamente buf_len restante
    lea  rdx, [r14 + CLI_READ_BUF]
    ; Recalcular: nuevo buf_len = anterior - bytes_consumidos
    ; (ecx ya tiene el valor anterior, el cálculo está arriba)
    mov ecx, [r14 + CLI_BUF_LEN]
    ; Rehacer cálculo limpio
    lea  rsi, [r14 + CLI_READ_BUF]
    ; Encontrar primer nul o contar bytes hasta nul
    ; Simplificar: guardar nuevo len antes del compact
    ; → El cálculo está correcto en ecx = buf_len - bytes_consumidos
    ; Guardar nuevo buf_len
    ; (ecx = bytes restantes calculado arriba, perdido en el loop)
    ; Usar strlen sobre el buffer para recalcular
    lea  rdi, [r14 + CLI_READ_BUF]
    ; El buffer ahora contiene solo los bytes que no se procesaron.
    ; Calcular su longitud contando hasta nul o usando el valor calculado.
    ; Usamos el CLI_BUF_LEN que debemos actualizar:
    ; Guardamos el offset de bytes consumidos en r9 antes del compact
    ; Reescribir de forma más clara:
    jmp  .buf_done             ; valor correcto ya calculado

.buf_done:
    ; Simplificación: recalcular buf_len como strlen del buffer restante
    lea  rdi, [r14 + CLI_READ_BUF]
    call strlen_fn             ; rax = longitud del contenido restante
    mov  [r14 + CLI_BUF_LEN], eax

    jmp  .proc_lines           ; continuar procesando líneas

.cli_buf_full:
    ; Buffer lleno sin '\n': descartar todo (mensaje inválido/muy largo)
    mov  dword [r14 + CLI_BUF_LEN], 0
    jmp  .cli_next

.cli_disconnect:
    ; Cliente cerró la conexión (EOF) o error de lectura.
    ; Desactivar el slot y cerrar el fd.
    mov  dword [r14 + CLI_FD], -1

    ; sys_close(fd): libera el descriptor de fichero TCP.
    ; El kernel cierra el canal (envía FIN al cliente si no lo había hecho).
    mov  rax, SYS_CLOSE
    mov  rdi, r12
    syscall

    ; Log
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

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1
.err_sock:
    exit_code 1
.err_bind:
    exit_code 1
.err_listen:
    exit_code 1

; =============================================================
; process_message_fn(rdi=linea_nul_terminada)
;
; Parsea una línea recibida de un cliente y ejecuta la acción:
;   SUB → registrar este fd como suscriptor del tema
;   PUB → difundir el mensaje a suscriptores del tema
;
; Contexto de llamada: r14 = puntero a la entrada del cliente,
;                      r12 = fd del cliente, r13 = índice del cliente.
; =============================================================
process_message_fn:
    push rbx
    push r12
    push r13

    ; rdi ya tiene el puntero a la línea
    mov  rbx, rdi              ; rbx = línea

    ; Buscar primer '|'
    mov  al, '|'
    call find_char_fn
    test rax, rax
    jz   .pm_bad

    lea  rdx, [rbx]
    sub  rax, rdx              ; rax = longitud del tipo

    ; ── SUB ──────────────────────────────────────────────────
    cmp  rax, 3
    jne  .pm_chk_pub
    lea  rdi, [rbx]
    lea  rsi, [s_SUB]
    call strncmp3_fn
    test rax, rax
    jnz  .pm_chk_pub

    ; Extraer tema (después del '|')
    lea  rdi, [rbx]
    mov  al, '|'
    call find_char_fn
    inc  rax                   ; rax = puntero al tema

    ; Registrar tema en la entrada del cliente (r14)
    ; r14 apunta a la entrada del cliente (del bucle externo)
    mov  dword [r14 + CLI_STATE], STATE_SUB
    lea  rdi, [r14 + CLI_TOPIC]
    mov  rsi, rax              ; rsi = puntero al tema
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    ; Log
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
    cmp  rax, 3
    jne  .pm_unk
    lea  rdi, [rbx]
    lea  rsi, [s_PUB]
    call strncmp3_fn
    test rax, rax
    jnz  .pm_unk

    ; Puntero al tema
    lea  rdi, [rbx]
    mov  al, '|'
    call find_char_fn
    inc  rax
    mov  r12, rax              ; r12 = puntero al tema

    ; Puntero al mensaje (después del segundo '|')
    mov  rdi, r12
    mov  al, '|'
    call find_char_fn
    test rax, rax
    jz   .pm_bad               ; PUB sin mensaje

    mov  byte [rax], 0         ; nul-terminar el tema
    inc  rax
    mov  r13, rax              ; r13 = puntero al mensaje

    ; Log
    write_lit s_pub_log, s_pub_log_l
    mov  rdi, r12
    call print_cstr_fn
    write_lit s_pub_mid, s_pub_mid_l
    mov  rdi, r13
    call print_cstr_fn
    write_lit s_nl, 1

    ; Difundir
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
    pop  rbx
    ret

; =============================================================
; broadcast_tcp_fn(rdi=topic_ptr, rsi=msg_ptr)
;
; Recorre la tabla de clientes.  Para cada cliente con state=SUB
; y tema coincidente, envía "MSG|<tema>|<msg>\n" usando sendto().
; En TCP, sendto() sin dirección (r8=0, r9=0) equivale a send().
; =============================================================
broadcast_tcp_fn:
    push r12
    push r13
    push r14
    push r15
    push rbx

    mov  r12, rdi              ; r12 = tema
    mov  r13, rsi              ; r13 = mensaje

    ; ── Construir mensaje "MSG|<tema>|<msg>\n" en out_buf ─────
    lea  r14, [out_buf]

    lea  rsi, [s_MSG]
    mov  ecx, s_MSG_len
.bt_pre:
    mov  al, [rsi]
    mov  [r14], al
    inc  rsi
    inc  r14
    dec  ecx
    jnz  .bt_pre

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
    mov  byte [r14], 10        ; '\n' final
    inc  r14

    ; Longitud
    lea  rdx, [out_buf]
    sub  r14, rdx              ; r14 = longitud total

    ; ── Iterar clientes ───────────────────────────────────────
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
    je   .bcast_next

    cmp  dword [r9 + CLI_STATE], STATE_SUB
    jne  .bcast_next

    ; ¿Mismo tema?
    lea  rdi, [r9 + CLI_TOPIC]
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    jnz  .bcast_next

    ; sendto(fd, out_buf, len, 0, NULL, 0)
    ; En TCP, send(fd, buf, len, 0) ≡ sendto con addr=NULL.
    ; Envía el flujo de bytes al socket TCP establecido.
    mov  rax, SYS_SENDTO
    mov  rdi, r10              ; fd del suscriptor
    lea  rsi, [out_buf]
    mov  rdx, r14              ; longitud
    xor  r10, r10              ; flags = 0
    xor  r8, r8                ; addr = NULL (no se necesita en TCP)
    xor  r9, r9                ; addrlen = 0
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
; Procedimientos auxiliares (idénticos a broker_udp.asm)
; =============================================================

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

; itoa_fn(edi=val, rsi=buf) → rcx=len
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
    ; mover al inicio del buffer
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

strlen_fn:
    xor  eax, eax
.sl_lp:
    cmp  byte [rdi + rax], 0
    je   .sl_e
    inc  rax
    jmp  .sl_lp
.sl_e:
    ret

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

strncpy_fn:
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
    ret

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
