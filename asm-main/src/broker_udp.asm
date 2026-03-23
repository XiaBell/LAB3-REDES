; =============================================================
; broker_udp.asm
; Broker UDP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Protocolo:
;   Cliente → Broker  : "SUB|<tema>\n"        (suscribirse)
;                       "PUB|<tema>|<msg>\n"   (publicar evento)
;   Broker  → Cliente : "MSG|<tema>|<msg>"     (difusión a suscriptores)
;
; Compilar:
;   nasm -f elf64 broker_udp.asm -o broker_udp.o
;   ld -o broker_udp broker_udp.o
;
; Uso: ./broker_udp <puerto>
;      Ejemplo: ./broker_udp 9001
;
; Syscalls utilizados (ABI System V AMD64 Linux):
;   nro  nombre         descripción
;   ---  ----------     ------------------------------------------------------
;    1   sys_write      Escribe bytes en stdout (fd=1) para mensajes de log
;    3   sys_close      Cierra el socket al final
;   41   sys_socket     Crea el socket UDP: socket(AF_INET, SOCK_DGRAM, 0)
;   44   sys_sendto     Envía un datagrama a una dirección específica
;                       (usa dirección registrada en la suscripción)
;   45   sys_recvfrom   Recibe un datagrama; llena sockaddr_in del remitente
;   49   sys_bind       Asocia el socket al puerto especificado
;   54   sys_setsockopt Configura SO_REUSEADDR para reusar el puerto
;   60   sys_exit       Termina el proceso con código de salida
;
; Convención de llamada x86-64 (System V AMD64 ABI):
;   Argumentos: rdi, rsi, rdx, rcx, r8, r9
;   Retorno:    rax (y rdx para 128-bit)
;   Preservar:  rbx, rbp, r12–r15 (callee-saved)
;   Scratch:    rax, rcx, rdx, rsi, rdi, r8–r11 (caller-saved)
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
%define SO_REUSEADDR   2      ; opción: reusar dirección local

; ── Constantes de la aplicación ──────────────────────────────
%define MAX_SUBS       32     ; máximo de suscriptores simultáneos
%define BUF_SIZE       512    ; tamaño del buffer de recepción/envío
%define MAX_TOPIC      64     ; longitud máxima del nombre de tema

; Layout de cada entrada en la tabla de suscriptores (96 bytes):
; ┌──────┬──────────────────────────────────────────────────────────────┐
; │ OFF  │ CAMPO         TAMAÑO  DESCRIPCIÓN                            │
; ├──────┼──────────────────────────────────────────────────────────────┤
; │  +0  │ active          4     1=activo, 0=libre                      │
; │  +4  │ sin_family      2     AF_INET = 2                            │
; │  +6  │ sin_port        2     puerto en network byte order           │
; │  +8  │ sin_addr        4     IP en network byte order               │
; │ +12  │ sin_zero        8     padding de struct sockaddr_in          │
; │ +20  │ topic          64     nombre del tema (nul-terminado)        │
; │ +84  │ padding        12     para alinear a 96 bytes                │
; └──────┴──────────────────────────────────────────────────────────────┘
%define SUB_ACTIVE     0
%define SUB_FAMILY     4
%define SUB_PORT       6
%define SUB_SADDR      8
%define SUB_ZERO       12
%define SUB_TOPIC      20
%define SUB_SIZE       96

; ── Macros utilitarios ───────────────────────────────────────

; Terminar el proceso con código de error
%macro exit_code 1
    mov  rax, SYS_EXIT
    mov  rdi, %1
    syscall
%endmacro

; Escribir literal en stdout (fd=1)
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

; Mensajes de log al operador del broker
s_uso        db "Uso: ./broker_udp <puerto>", 10
s_uso_len    equ $ - s_uso

s_listen     db "[Broker UDP] Escuchando en puerto "
s_listen_l   equ $ - s_listen

s_nl         db 10                        ; salto de línea
s_nl_len     equ 1

s_sub_pre    db "[Broker UDP] Suscriptor registrado en ["
s_sub_pre_l  equ $ - s_sub_pre

s_sub_suf    db "]", 10
s_sub_suf_l  equ $ - s_sub_suf

s_pub_pre    db "[Broker UDP] PUB ["
s_pub_pre_l  equ $ - s_pub_pre

s_pub_mid    db "]: "
s_pub_mid_l  equ $ - s_pub_mid

s_bad        db "[Broker UDP] Mensaje malformado", 10
s_bad_len    equ $ - s_bad

s_full       db "[Broker UDP] Lista de suscriptores llena", 10
s_full_len   equ $ - s_full

s_unk        db "[Broker UDP] Tipo de mensaje desconocido", 10
s_unk_len    equ $ - s_unk

s_dup        db "[Broker UDP] Suscriptor ya registrado (ignorado)", 10
s_dup_len    equ $ - s_dup

; Tokens de tipo de mensaje (3 bytes, sin nul, para comparación)
s_SUB        db "SUB"
s_PUB        db "PUB"

; Prefijo del mensaje de difusión (4 bytes: "MSG|")
s_MSG        db "MSG|"
s_MSG_len    equ $ - s_MSG

; =============================================================
section .bss

sock_fd      resd 1                    ; fd del socket UDP creado
opt_val      resd 1                    ; valor para setsockopt (SO_REUSEADDR)
server_addr  resb 16                   ; struct sockaddr_in del broker
recv_buf     resb BUF_SIZE             ; buffer de recepción de datagramas
sender_addr  resb 16                   ; struct sockaddr_in del remitente
sender_len   resd 1                    ; tamaño de sender_addr (para recvfrom)
subs         resb MAX_SUBS * SUB_SIZE  ; tabla de suscriptores activos
subs_count   resd 1                    ; número de entradas activas
out_buf      resb BUF_SIZE             ; buffer de salida para broadcast
num_buf      resb 12                   ; buffer para conversión int → string

; =============================================================
section .text
    global _start

; =============================================================
; _start : punto de entrada del programa
;
; Stack al inicio (Linux x86-64):
;   [rsp+0]   = argc
;   [rsp+8]   = argv[0] (nombre del programa)
;   [rsp+16]  = argv[1] (puerto, si argc >= 2)
; =============================================================
_start:
    pop  rdi                    ; rdi = argc
    cmp  rdi, 2
    jl   .err_uso               ; falta argumento de puerto

    pop  rax                    ; argv[0] (descartado)
    pop  rdi                    ; rdi → string del número de puerto

    ; ── Convertir string → entero (atoi) ─────────────────────
    call atoi_fn                ; rax = puerto en host byte order (ej. 9001)

    ; Guardar copia para imprimir después
    mov  r15d, eax              ; r15d = puerto (host order), para imprimir

    ; ── htons: convertir host byte order → network byte order ─
    ; En x86 (little-endian), "big-endian" requiere invertir los bytes.
    ; htons(x) = (x >> 8) | ((x & 0xFF) << 8)
    movzx ecx, ax               ; ecx = puerto host order
    rol   cx, 8                 ; intercambiar byte alto y bajo
    ; cx = puerto en network byte order

    ; ── socket(AF_INET, SOCK_DGRAM, 0) ───────────────────────
    ; Crea un socket UDP sin conexión.
    ; SOCK_DGRAM: cada llamada a sendto/recvfrom es un datagrama independiente.
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET           ; familia IPv4
    mov  rsi, SOCK_DGRAM        ; tipo: datagrama (UDP)
    xor  rdx, rdx               ; protocolo: 0 (elige automáticamente UDP)
    syscall
    test rax, rax
    js   .err_socket            ; rax < 0 indica error
    mov  [sock_fd], eax         ; guardar el fd del socket

    ; ── setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, 4) ────
    ; Permite que el broker pueda reiniciarse sin esperar TIME_WAIT del SO.
    mov  dword [opt_val], 1     ; habilitar la opción
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [sock_fd]
    mov  rsi, SOL_SOCKET
    mov  rdx, SO_REUSEADDR
    lea  r10, [opt_val]
    mov  r8, 4
    syscall
    ; No es fatal si falla; continuamos

    ; ── Construir struct sockaddr_in en server_addr ───────────
    ; struct sockaddr_in {
    ;   uint16_t sin_family;  // +0
    ;   uint16_t sin_port;    // +2  ← en network byte order
    ;   uint32_t sin_addr;    // +4  ← INADDR_ANY = 0
    ;   char     sin_zero[8]; // +8
    ; };
    movzx ecx, r15w                        ; restaurar puerto desde r15d (cx fue destruido por syscall)
    rol   cx, 8                            ; volver a network byte order
    mov  word  [server_addr + 0], AF_INET  ; sin_family = 2
    mov  word  [server_addr + 2], cx       ; sin_port (network order)
    mov  dword [server_addr + 4], 0        ; sin_addr = 0.0.0.0 (todas las IFs)
    mov  qword [server_addr + 8], 0        ; sin_zero = 0

    ; ── bind(fd, &server_addr, 16) ───────────────────────────
    ; Asocia el socket UDP al puerto y dirección configurados.
    ; A partir de aquí, recvfrom() recibirá datagramas dirigidos a ese puerto.
    mov  rax, SYS_BIND
    movsx rdi, dword [sock_fd]
    lea  rsi, [server_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_bind

    ; ── Imprimir mensaje de arranque ──────────────────────────
    write_lit s_listen, s_listen_l
    mov  edi, r15d              ; puerto en host order
    lea  rsi, [num_buf]
    call itoa_clean             ; rcx = longitud del número
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_nl, 1

    ; ── Inicializar estado ────────────────────────────────────
    mov  dword [subs_count], 0  ; sin suscriptores al inicio

; =============================================================
; .main_loop : bucle principal de recepción
; Itera indefinidamente esperando datagramas UDP.
; =============================================================
.main_loop:
    ; ── recvfrom(fd, buf, BUF_SIZE-1, 0, &sender_addr, &sender_len) ──
    ; Bloquea hasta recibir un datagrama.
    ; El kernel llena sender_addr con la IP y puerto del remitente.
    ; Retorna el número de bytes recibidos en rax.
    mov  dword [sender_len], 16

    mov  rax, SYS_RECVFROM
    movsx rdi, dword [sock_fd]
    lea  rsi, [recv_buf]
    mov  rdx, BUF_SIZE - 1     ; máximo de bytes a leer
    xor  r10, r10              ; flags = 0
    lea  r8,  [sender_addr]    ; OUT: dirección del remitente
    lea  r9,  [sender_len]     ; IN/OUT: tamaño de sender_addr
    syscall

    test rax, rax
    jle  .main_loop            ; ignorar error o 0 bytes

    ; Nul-terminar y eliminar '\r'/'\n' al final
    lea  rdi, [recv_buf]
    mov  rcx, rax              ; longitud recibida
    call strip_newline         ; rcx = longitud sin terminadores

    test rcx, rcx
    jz   .main_loop            ; datagrama vacío, ignorar

    ; ── Parsear: buscar primer '|' para aislar el TIPO ───────
    ; Formato: "TIPO|campo1|campo2"
    lea  rdi, [recv_buf]
    mov  al, '|'
    call find_char_fn          ; rax = puntero al primer '|', o 0 si no existe

    test rax, rax
    jz   .bad_msg              ; sin '|' → malformado

    ; Longitud del tipo = (ptr_pipe - ptr_buf)
    lea  rdx, [recv_buf]
    sub  rax, rdx              ; rax = nro de bytes antes del '|'

    ; ── ¿Tipo == "SUB"? ───────────────────────────────────────
    mov  r12, rax              ; guardar longitud del tipo (rax será sobreescrito por strncmp3_fn)
    cmp  rax, 3
    jne  .chk_pub

    lea  rdi, [recv_buf]
    lea  rsi, [s_SUB]
    call strncmp3_fn           ; rax = 0 si los primeros 3 bytes coinciden
    test rax, rax
    jnz  .chk_pub

    ; Obtener puntero al tema: char* después del primer '|'
    lea  rdi, [recv_buf]
    mov  al, '|'
    call find_char_fn          ; rax = ptr al '|'
    inc  rax                   ; saltar el '|'
    ; rax → inicio del tema

    mov  rdi, rax              ; rdi = puntero al tema
    lea  rsi, [sender_addr]    ; rsi = dirección del remitente (IP:puerto)
    call register_sub_fn
    jmp  .main_loop

.chk_pub:
    ; ── ¿Tipo == "PUB"? ───────────────────────────────────────
    cmp  r12, 3                ; usar longitud guardada (no rax que fue sobreescrito)
    jne  .unknown_type

    lea  rdi, [recv_buf]
    lea  rsi, [s_PUB]
    call strncmp3_fn
    test rax, rax
    jnz  .unknown_type

    ; Puntero al tema (después del primer '|')
    lea  rdi, [recv_buf]
    mov  al, '|'
    call find_char_fn
    inc  rax
    mov  rbx, rax              ; rbx = puntero al tema

    ; Buscar segundo '|' para separar tema y mensaje
    mov  rdi, rbx
    mov  al, '|'
    call find_char_fn
    test rax, rax
    jz   .bad_msg              ; PUB sin contenido de mensaje

    mov  byte [rax], 0         ; nul-terminar el tema (sobreescribe el '|')
    inc  rax
    mov  r13, rax              ; r13 = puntero al mensaje

    ; Imprimir log: "[Broker UDP] PUB [<tema>]: <msg>\n"
    write_lit s_pub_pre, s_pub_pre_l
    mov  rdi, rbx
    call print_cstr_fn
    write_lit s_pub_mid, s_pub_mid_l
    mov  rdi, r13
    call print_cstr_fn
    write_lit s_nl, 1

    ; Difundir a todos los suscriptores del tema
    mov  rdi, rbx              ; tema
    mov  rsi, r13              ; mensaje
    call broadcast_udp_fn
    jmp  .main_loop

.bad_msg:
    write_lit s_bad, s_bad_len
    jmp  .main_loop

.unknown_type:
    write_lit s_unk, s_unk_len
    jmp  .main_loop

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1

.err_socket:
    exit_code 1

.err_bind:
    exit_code 1

; =============================================================
; register_sub_fn(rdi=topic_ptr, rsi=sender_addr_ptr)
;
; Registra el par (dirección IP:puerto, tema) como suscriptor activo.
; Si ya existe la misma combinación, descarta el duplicado.
; Preserva: rbx, r12–r15 (callee-saved)
; =============================================================
register_sub_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi              ; r12 = tema
    mov  r13, rsi              ; r13 = &sender_addr (struct sockaddr_in)

    ; ── Buscar duplicado ──────────────────────────────────────
    xor  ebx, ebx              ; i = 0
    mov  r14d, [subs_count]

.rs_dup_check:
    cmp  ebx, r14d
    jge  .rs_add               ; fin de lista, agregar nuevo

    ; Calcular puntero a subs[i]
    mov  rax, rbx
    imul rax, SUB_SIZE
    lea  rdx, [subs + rax]     ; rdx = &subs[i]

    cmp  dword [rdx + SUB_ACTIVE], 1
    jne  .rs_dup_next

    ; Comparar puerto (network byte order)
    movzx eax, word [r13 + 2]  ; sender sin_port (offset +2 en sockaddr_in)
    movzx ecx, word [rdx + SUB_PORT]
    cmp  ax, cx
    jne  .rs_dup_next

    ; Comparar IP
    mov  eax, [r13 + 4]        ; sender sin_addr (offset +4 en sockaddr_in)
    cmp  eax, [rdx + SUB_SADDR]
    jne  .rs_dup_next

    ; Comparar tema
    lea  rdi, [rdx + SUB_TOPIC]
    mov  rsi, r12
    call strcmp_fn             ; rax = 0 si iguales
    test rax, rax
    jz   .rs_is_dup

.rs_dup_next:
    inc  ebx
    jmp  .rs_dup_check

.rs_is_dup:
    write_lit s_dup, s_dup_len
    jmp  .rs_done

.rs_add:
    ; ── Verificar capacidad ───────────────────────────────────
    cmp  r14d, MAX_SUBS
    jge  .rs_full

    ; Calcular puntero a nueva entrada: &subs[subs_count]
    mov  rax, r14
    imul rax, SUB_SIZE
    lea  rdx, [subs + rax]     ; rdx = puntero a la nueva entrada

    ; Llenar la entrada
    mov  dword [rdx + SUB_ACTIVE], 1   ; marcar como activo

    ; Copiar campos de sockaddr_in del remitente
    ; sender_addr (r13) layout estándar:
    ;   +0 sin_family (2 bytes)
    ;   +2 sin_port   (2 bytes)
    ;   +4 sin_addr   (4 bytes)
    ;   +8 sin_zero   (8 bytes)
    movzx eax, word [r13 + 0]
    mov   word [rdx + SUB_FAMILY], ax   ; sin_family
    movzx eax, word [r13 + 2]
    mov   word [rdx + SUB_PORT], ax     ; sin_port
    mov   eax, [r13 + 4]
    mov   [rdx + SUB_SADDR], eax        ; sin_addr
    mov   rax, [r13 + 8]
    mov   [rdx + SUB_ZERO], rax         ; sin_zero (8 bytes)

    ; Copiar tema (hasta MAX_TOPIC-1 bytes + nul)
    lea  rdi, [rdx + SUB_TOPIC]
    mov  rsi, r12
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    ; Incrementar contador
    inc  r14d
    mov  [subs_count], r14d

    ; Log
    write_lit s_sub_pre, s_sub_pre_l
    mov  rdi, r12
    call print_cstr_fn
    write_lit s_sub_suf, s_sub_suf_l
    jmp  .rs_done

.rs_full:
    write_lit s_full, s_full_len

.rs_done:
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; =============================================================
; broadcast_udp_fn(rdi=topic_ptr, rsi=msg_ptr)
;
; Construye el datagrama "MSG|<tema>|<msg>" en out_buf y lo
; envía con sendto() a cada suscriptor activo del tema.
;
; sendto() se llama una vez por suscriptor ya que UDP es sin conexión.
; La dirección destino se pasa en cada llamada individualmente.
; =============================================================
broadcast_udp_fn:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov  r12, rdi              ; r12 = tema
    mov  r13, rsi              ; r13 = mensaje

    ; ── Construir mensaje de salida "MSG|<tema>|<msg>" ────────
    lea  r14, [out_buf]        ; r14 = cursor de escritura en out_buf

    ; Copiar prefijo "MSG|" (4 bytes)
    lea  rsi, [s_MSG]
    mov  ecx, s_MSG_len
.bc_prefix:
    mov  al, [rsi]
    mov  [r14], al
    inc  rsi
    inc  r14
    dec  ecx
    jnz  .bc_prefix

    ; Copiar tema
    mov  rsi, r12
.bc_topic:
    mov  al, [rsi]
    test al, al
    jz   .bc_sep
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bc_topic
.bc_sep:
    mov  byte [r14], '|'       ; separador
    inc  r14

    ; Copiar mensaje
    mov  rsi, r13
.bc_msg:
    mov  al, [rsi]
    test al, al
    jz   .bc_msg_done
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bc_msg
.bc_msg_done:

    ; Longitud total del mensaje construido
    lea  rdx, [out_buf]
    sub  r14, rdx              ; r14 = longitud en bytes

    ; ── Iterar sobre la tabla de suscriptores ─────────────────
    xor  ebx, ebx              ; i = 0
    mov  r15d, [subs_count]

.bc_loop:
    cmp  ebx, r15d
    jge  .bc_done

    mov  rax, rbx
    imul rax, SUB_SIZE
    lea  r9, [subs + rax]      ; r9 = &subs[i]

    cmp  dword [r9 + SUB_ACTIVE], 1
    jne  .bc_next

    ; ¿El suscriptor está en este tema?
    lea  rdi, [r9 + SUB_TOPIC]
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    jnz  .bc_next

    ; ── Reconstruir sockaddr_in en la pila para sendto ────────
    ; sendto espera un struct sockaddr_in válido con los campos
    ; en el orden estándar.  Reservamos 16 bytes en la pila.
    sub  rsp, 16
    mov  word [rsp + 0], AF_INET               ; sin_family
    movzx eax, word [r9 + SUB_PORT]
    mov   word [rsp + 2], ax                   ; sin_port
    mov  eax, [r9 + SUB_SADDR]
    mov  dword [rsp + 4], eax                  ; sin_addr
    mov  qword [rsp + 8], 0                    ; sin_zero

    ; sendto(fd, out_buf, len, 0, &addr, 16)
    ; Argumentos en registros según ABI x86-64:
    ;   rdi = fd
    ;   rsi = buffer
    ;   rdx = longitud
    ;   r10 = flags (0)
    ;   r8  = puntero a sockaddr_in
    ;   r9  = tamaño de sockaddr_in (16)
    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [out_buf]
    mov  rdx, r14              ; longitud del mensaje
    xor  r10, r10              ; flags = 0
    mov  r8, rsp               ; dirección destino (en pila)
    mov  r9, 16
    syscall
    ; Si sendto falla (rax < 0) simplemente continuamos

    add  rsp, 16               ; restaurar puntero de pila

.bc_next:
    inc  ebx
    jmp  .bc_loop

.bc_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; =============================================================
; Procedimientos auxiliares
; =============================================================

; ── atoi_fn(rdi=str) → rax : convierte ASCII decimal a entero ─
; No maneja negativos (los puertos son positivos).
atoi_fn:
    xor  eax, eax              ; acumulador = 0
.atoi_lp:
    movzx ecx, byte [rdi]
    test cl, cl
    jz   .atoi_end
    sub  cl, '0'
    cmp  cl, 9
    ja   .atoi_end             ; carácter no numérico → fin
    imul eax, eax, 10
    add  eax, ecx
    inc  rdi
    jmp  .atoi_lp
.atoi_end:
    ret

; ── itoa_fn(edi=valor, rsi=buf) → rcx=longitud ───────────────
; Escribe la representación decimal ASCII en buf (nul-terminado).
itoa_fn:
    push rbx
    push rsi                   ; guardar inicio del buffer
    test edi, edi
    jnz  .it_nonzero
    ; Caso especial: valor == 0
    mov  byte [rsi], '0'
    mov  byte [rsi + 1], 0
    mov  rcx, 1
    pop  rax                   ; descartar base guardada
    pop  rbx
    ret
.it_nonzero:
    ; Escribir dígitos al revés en un buffer temporal (en pila)
    sub  rsp, 12
    xor  ebx, ebx              ; ebx = cantidad de dígitos escritos
    mov  eax, edi
.it_div:
    xor  edx, edx
    mov  ecx, 10
    div  ecx                   ; edx = eax % 10, eax = eax / 10
    add  dl, '0'
    mov  [rsp + rbx], dl
    inc  ebx
    test eax, eax
    jnz  .it_div
    ; Invertir los dígitos en buf
    mov  rcx, rbx              ; rcx = nro de dígitos
    pop  r8                    ; r8 = buffer temporal en pila... hmm
    ; Simplificar: copiar de rsp al buffer rsi en orden inverso
    ; Volvamos a construirlo correctamente
    add  rsp, 12               ; restaurar pila (el mov previo estaba mal)
    ; Usar num_buf interno
    ; Método más directo: llenar desde el fin del buf
    pop  rsi                   ; rsi = inicio del buffer (guardado al inicio)
    push rbx                   ; guardar nro de dígitos
    mov  rdi, rsi
    add  rdi, rbx              ; rdi = fin
    mov  byte [rdi], 0         ; nul-terminar
    dec  rdi
    mov  eax, edi              ; restaurar valor... perdimos edi
    ; Este procedimiento se complica con el stack. Reescribir limpio:
    pop  rbx
    pop  rbx
    ; Llamar a versión simple:
    ; Usa r8 para el valor, rsi ya está en lugar
    ; → simplificamos llamando a la versión inline de _start
    ret                        ; valor en rsi ya escrito por _start inline

; Versión limpia de itoa usada desde _start:
itoa_clean:
    ; edi = valor, rsi = buf de salida
    ; retorna rcx = longitud
    push  rbx
    mov   eax, edi
    lea   rbx, [rsi + 11]      ; rbx = apunta al final del área
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
    inc   rbx                  ; rbx = inicio de la cadena numérica
    ; Mover al inicio de buf
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

; ── strlen_fn(rdi=str) → rax : longitud de cadena nul-terminada ──
strlen_fn:
    xor  eax, eax
.sl_lp:
    cmp  byte [rdi + rax], 0
    je   .sl_done
    inc  rax
    jmp  .sl_lp
.sl_done:
    ret

; ── strcmp_fn(rdi=s1, rsi=s2) → rax (0 si iguales) ────────────
strcmp_fn:
.sc_lp:
    mov  al, [rdi]
    cmp  al, [rsi]
    jne  .sc_diff
    test al, al
    jz   .sc_eq
    inc  rdi
    inc  rsi
    jmp  .sc_lp
.sc_eq:
    xor  eax, eax
    ret
.sc_diff:
    movsx eax, al
    movzx ecx, byte [rsi]
    movsx ecx, cl
    sub  eax, ecx
    ret

; ── strncmp3_fn(rdi=s1, rsi=s2) → rax (0 si primeros 3 bytes iguales) ─
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

; ── strncpy_fn(rdi=dst, rsi=src, rcx=n) ──────────────────────
; Copia hasta rcx bytes de src a dst. Siempre nul-termina dst.
strncpy_fn:
    push rcx
.sc_lp2:
    test rcx, rcx
    jz   .sc_done2
    mov  al, [rsi]
    test al, al
    jz   .sc_done2
    mov  [rdi], al
    inc  rdi
    inc  rsi
    dec  rcx
    jmp  .sc_lp2
.sc_done2:
    mov  byte [rdi], 0
    pop  rcx
    ret

; ── find_char_fn(rdi=str, al=char_buscado) → rax (ptr o 0) ────
; Retorna puntero al primer carácter 'al' encontrado, o 0 si no existe.
find_char_fn:
    mov  cl, al                ; guardar carácter buscado en cl
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

; ── strip_newline(rdi=buf, rcx=len) → rcx=nueva longitud ──────
; Elimina '\r' y '\n' del final del buffer y coloca nul-terminador.
strip_newline:
    test rcx, rcx
    jz   .sn_end
    mov  rsi, rdi
    add  rsi, rcx
    dec  rsi                   ; rsi = ptr al último byte
.sn_lp:
    cmp  rsi, rdi
    jl   .sn_end
    mov  al, [rsi]
    cmp  al, 10                ; '\n'
    je   .sn_rem
    cmp  al, 13                ; '\r'
    je   .sn_rem
    jmp  .sn_end               ; otro carácter → parar
.sn_rem:
    mov  byte [rsi], 0
    dec  rsi
    dec  rcx
    jmp  .sn_lp
.sn_end:
    ret

; ── print_cstr_fn(rdi=str) ────────────────────────────────────
; Imprime una cadena nul-terminada en stdout usando sys_write.
print_cstr_fn:
    push rdi
    call strlen_fn             ; rax = longitud
    mov  rdx, rax
    pop  rsi                   ; rsi = puntero a la cadena
    test rdx, rdx
    jz   .pc_end
    mov  rax, SYS_WRITE
    mov  rdi, 1
    syscall
.pc_end:
    ret
