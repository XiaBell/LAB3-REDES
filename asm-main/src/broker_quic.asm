; broker_quic.asm
; Broker para el protocolo QUIC del lab 3
;
; Basicamente es el mismo broker UDP pero con algunas cosas extra:
; - Cuando le llega un mensaje de un publisher, le manda un ACK de vuelta
;   para confirmar que lo recibio
; - El mensaje que llega tiene un numero de secuencia, ese numero se
;   incluye en el ACK y en el reenvio a los suscriptores
;
; El formato de los paquetes ya no es texto sino binario:
;
;   Publisher manda (TYPE_DATA):
;     [0-3] numero de secuencia (4 bytes)
;     [4]   tipo = 0x01
;     [5]   cuantos bytes mide el nombre del partido
;     [6..] nombre del partido + el mensaje
;
;   Broker responde ACK al publisher (TYPE_ACK):
;     [0-3] el mismo numero de secuencia que llego
;     [4]   tipo = 0x02
;     (son solo 5 bytes en total)
;
;   Subscriber se suscribe (TYPE_SUB):
;     [0-3] secuencia (no importa en SUB)
;     [4]   tipo = 0x03
;     [5]   longitud del nombre del partido
;     [6..] nombre del partido
;
;   Broker reenvía a suscriptores (TYPE_MSG):
;     [0-3] numero de secuencia asignado por el broker (monotonico por tema)
;           asi varios publicadores del mismo partido no repiten el mismo seq
;     [4]   tipo = 0x04
;     [5]   longitud del nombre del partido
;     [6..] nombre del partido + el mensaje
;
; Uso: ./broker_quic <puerto>
;
; Compilar:
;   nasm -f elf64 broker_quic.asm -o ../bin/broker_quic.o
;   ld -o ../bin/broker_quic ../bin/broker_quic.o
;
; Syscalls que se usan:
;   1  write     - imprimir cosas en pantalla
;   3  close     - cerrar el socket
;   41 socket    - crear el socket UDP
;   44 sendto    - mandar el ACK y los MSG a suscriptores
;   45 recvfrom  - recibir datagramas
;   49 bind      - asociar el socket al puerto
;   54 setsockopt - reusar el puerto si se reinicia el broker
;   60 exit      - salir del programa

bits 64
default rel

; numeros de syscall de Linux x86-64
%define SYS_WRITE      1
%define SYS_CLOSE      3
%define SYS_SOCKET     41
%define SYS_SENDTO     44
%define SYS_RECVFROM   45
%define SYS_BIND       49
%define SYS_SETSOCKOPT 54
%define SYS_EXIT       60

; constantes de red
%define AF_INET        2   ; IPv4
%define SOCK_DGRAM     2   ; UDP (datagramas, sin conexion)
%define SOL_SOCKET     1
%define SO_REUSEADDR   2   ; para poder reusar el puerto rapido al reiniciar

; tipos de paquete del protocolo
%define TYPE_DATA      0x01
%define TYPE_ACK       0x02
%define TYPE_SUB       0x03
%define TYPE_MSG       0x04

%define MAX_SUBS       32
%define MAX_TOPICS     32          ; temas distintos con contador de seq propio
%define BUF_SIZE       512
%define MAX_TOPIC      64
%define TOPIC_ENTRY_SIZE (MAX_TOPIC + 4)   ; nombre + dword siguiente seq

; cada entrada en la tabla de suscriptores ocupa 96 bytes
; guarda: si esta activo, ip, puerto, nombre del partido
%define SUB_ACTIVE     0
%define SUB_FAMILY     4
%define SUB_PORT       6
%define SUB_SADDR      8
%define SUB_ZERO       12
%define SUB_TOPIC      20
%define SUB_SIZE       96

; salir con codigo de error
%macro exit_code 1
    mov  rax, SYS_EXIT
    mov  rdi, %1
    syscall
%endmacro

; imprimir un string que esta en .data
%macro write_lit 2
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [%1]
    mov  rdx, %2
    syscall
%endmacro

section .data

s_uso        db "Uso: ./broker_quic <puerto>", 10
s_uso_len    equ $ - s_uso

s_listen     db "[Broker QUIC] Escuchando en puerto "
s_listen_l   equ $ - s_listen

s_nl         db 10
s_nl_len     equ 1

s_data_pre   db "[Broker QUIC] DATA seq="
s_data_pre_l equ $ - s_data_pre

s_data_mid   db " tema="
s_data_mid_l equ $ - s_data_mid

s_data_sep   db " : "
s_data_sep_l equ $ - s_data_sep

s_ack_sent   db " -> ACK enviado", 10
s_ack_sent_l equ $ - s_ack_sent

s_sub_pre    db "[Broker QUIC] SUB registrado para ["
s_sub_pre_l  equ $ - s_sub_pre

s_sub_suf    db "]", 10
s_sub_suf_l  equ $ - s_sub_suf

s_bad        db "[Broker QUIC] Paquete muy corto, ignorado", 10
s_bad_len    equ $ - s_bad

s_unk        db "[Broker QUIC] Tipo desconocido, ignorado", 10
s_unk_len    equ $ - s_unk

s_dup        db "[Broker QUIC] Suscriptor ya registrado", 10
s_dup_len    equ $ - s_dup

s_full       db "[Broker QUIC] Tabla de suscriptores llena", 10
s_full_len   equ $ - s_full

section .bss

sock_fd      resd 1
opt_val      resd 1
server_addr  resb 16
recv_buf     resb BUF_SIZE
recv_len     resd 1           ; cuantos bytes recibimos en el ultimo recvfrom
sender_addr  resb 16          ; ip y puerto de quien nos mando el paquete
sender_len   resd 1
subs         resb MAX_SUBS * SUB_SIZE
subs_count   resd 1
out_buf      resb BUF_SIZE    ; aca construimos el MSG antes de mandarlo
ack_buf      resb 8           ; aca construimos el ACK (solo 5 bytes)
tema_tmp     resb 70          ; copia del nombre del partido con null al final
num_buf      resb 16
topic_entries resb MAX_TOPICS * TOPIC_ENTRY_SIZE
emergency_seq resd 1          ; si la tabla de temas esta llena (raro)

section .text
    global _start

_start:
    pop  rdi
    cmp  rdi, 2
    jl   .err_uso

    pop  rax                    ; argv[0] lo descartamos
    pop  rdi                    ; argv[1] = el puerto

    call atoi_fn                ; convertir string a numero
    mov  r15d, eax              ; guardar el puerto para imprimirlo despues

    ; htons: pasar el puerto a big-endian (formato de red)
    movzx ecx, ax
    rol  cx, 8

    ; crear socket UDP
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_DGRAM
    xor  rdx, rdx
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    ; SO_REUSEADDR permite reiniciar el broker sin esperar que el puerto quede libre
    mov  dword [opt_val], 1
    mov  rax, SYS_SETSOCKOPT
    movsx rdi, dword [sock_fd]
    mov  rsi, SOL_SOCKET
    mov  rdx, SO_REUSEADDR
    lea  r10, [opt_val]
    mov  r8, 4
    syscall

    ; llenar la estructura sockaddr_in para el bind
    movzx ecx, r15w
    rol  cx, 8
    mov  word  [server_addr + 0], AF_INET
    mov  word  [server_addr + 2], cx
    mov  dword [server_addr + 4], 0   ; 0.0.0.0 = acepta de cualquier IP
    mov  qword [server_addr + 8], 0

    ; bind: decirle al SO que este socket va a recibir en ese puerto
    mov  rax, SYS_BIND
    movsx rdi, dword [sock_fd]
    lea  rsi, [server_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_bind

    write_lit s_listen, s_listen_l
    mov  edi, r15d
    lea  rsi, [num_buf]
    call itoa_clean
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_nl, 1

    mov  dword [subs_count], 0

; bucle principal: esperamos datagramas y los procesamos
.main_loop:
    mov  dword [sender_len], 16

    mov  rax, SYS_RECVFROM
    movsx rdi, dword [sock_fd]
    lea  rsi, [recv_buf]
    mov  rdx, BUF_SIZE - 1
    xor  r10, r10
    lea  r8,  [sender_addr]
    lea  r9,  [sender_len]
    syscall

    ; minimo 6 bytes para que tenga un encabezado QUIC valido
    cmp  rax, 6
    jl   .pkt_bad

    ; poner null al final para poder tratar el cuerpo como string
    mov  [recv_len], eax
    lea  rdi, [recv_buf]
    add  rdi, rax
    mov  byte [rdi], 0

    ; el tipo del paquete esta en el byte 4
    movzx eax, byte [recv_buf + 4]

    cmp  al, TYPE_SUB
    je   .handle_sub

    cmp  al, TYPE_DATA
    je   .handle_data

    write_lit s_unk, s_unk_len
    jmp  .main_loop

.pkt_bad:
    write_lit s_bad, s_bad_len
    jmp  .main_loop

; llego un paquete de suscripcion
.handle_sub:
    ; sacar el nombre del partido y copiarlo con null al final
    movzx ecx, byte [recv_buf + 5]   ; byte 5 = cuantos bytes mide el tema
    cmp  ecx, MAX_TOPIC - 1
    jle  .sub_len_ok
    mov  ecx, MAX_TOPIC - 1
.sub_len_ok:
    lea  rdi, [tema_tmp]
    lea  rsi, [recv_buf + 6]
    call raw_copy_fn

    lea  rdi, [tema_tmp]
    lea  rsi, [sender_addr]
    call register_sub_fn
    jmp  .main_loop

; llego un mensaje de datos del publisher
.handle_data:
    ; leer el numero de secuencia (primeros 4 bytes)
    mov  r12d, dword [recv_buf]

    ; extraer el tema
    movzx r13d, byte [recv_buf + 5]
    cmp  r13d, MAX_TOPIC - 1
    jle  .data_len_ok
    mov  r13d, MAX_TOPIC - 1
.data_len_ok:
    lea  rdi, [tema_tmp]
    lea  rsi, [recv_buf + 6]
    mov  ecx, r13d
    call raw_copy_fn

    ; el cuerpo del mensaje empieza despues del tema
    lea  r14, [recv_buf + 6]
    add  r14, r13

    ; mandar ACK al publisher: mismo seq_num + tipo ACK
    ; esto le avisa al publisher que recibimos su mensaje
    mov  dword [ack_buf], r12d
    mov  byte  [ack_buf + 4], TYPE_ACK

    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [ack_buf]
    mov  rdx, 5
    xor  r10, r10
    lea  r8,  [sender_addr]
    mov  r9,  16
    syscall

    ; log en pantalla
    write_lit s_data_pre, s_data_pre_l
    mov  edi, r12d
    lea  rsi, [num_buf]
    call itoa_clean
    mov  rax, SYS_WRITE
    mov  rdi, 1
    lea  rsi, [num_buf]
    mov  rdx, rcx
    syscall
    write_lit s_data_mid, s_data_mid_l
    lea  rdi, [tema_tmp]
    call print_cstr_fn
    write_lit s_data_sep, s_data_sep_l
    mov  rdi, r14
    call print_cstr_fn
    write_lit s_ack_sent, s_ack_sent_l

    ; seq en MSG: broker lo asigna por tema (varios pubs en el mismo partido)
    lea  rdi, [tema_tmp]
    call topic_next_seq_fn
    mov  r15d, eax

    ; reenviar el mensaje a todos los suscriptores del tema
    lea  rdi, [tema_tmp]
    mov  rsi, r14
    mov  edx, r15d
    call broadcast_quic_fn

    jmp  .main_loop

.err_uso:
    write_lit s_uso, s_uso_len
    exit_code 1

.err_socket:
    exit_code 1

.err_bind:
    exit_code 1

; raw_copy_fn(rdi=dst, rsi=src, ecx=n)
; copia exactamente n bytes (no para en null) y pone null al final
; se usa porque el nombre del partido viene con longitud explicita, no con null
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

; register_sub_fn(rdi=tema, rsi=sender_addr)
; registra al suscriptor en la tabla si no esta ya
register_sub_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi
    mov  r13, rsi

    ; revisar si ya esta registrado (evitar duplicados)
    xor  ebx, ebx
    mov  r14d, [subs_count]

.rs_dup_check:
    cmp  ebx, r14d
    jge  .rs_add

    mov  rax, rbx
    imul rax, SUB_SIZE
    lea  rdx, [subs + rax]

    cmp  dword [rdx + SUB_ACTIVE], 1
    jne  .rs_dup_next

    movzx eax, word [r13 + 2]
    movzx ecx, word [rdx + SUB_PORT]
    cmp  ax, cx
    jne  .rs_dup_next

    mov  eax, [r13 + 4]
    cmp  eax, [rdx + SUB_SADDR]
    jne  .rs_dup_next

    lea  rdi, [rdx + SUB_TOPIC]
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    jz   .rs_is_dup

.rs_dup_next:
    inc  ebx
    jmp  .rs_dup_check

.rs_is_dup:
    write_lit s_dup, s_dup_len
    jmp  .rs_done

.rs_add:
    cmp  r14d, MAX_SUBS
    jge  .rs_full

    mov  rax, r14
    imul rax, SUB_SIZE
    lea  rdx, [subs + rax]

    mov  dword [rdx + SUB_ACTIVE], 1
    movzx eax, word [r13 + 0]
    mov   word [rdx + SUB_FAMILY], ax
    movzx eax, word [r13 + 2]
    mov   word [rdx + SUB_PORT], ax
    mov   eax, [r13 + 4]
    mov   [rdx + SUB_SADDR], eax
    mov   rax, [r13 + 8]
    mov   [rdx + SUB_ZERO], rax

    lea  rdi, [rdx + SUB_TOPIC]
    mov  rsi, r12
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn

    inc  r14d
    mov  [subs_count], r14d

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

; topic_next_seq_fn(rdi=tema cstr null-terminated)
; devuelve eax = numero de secuencia para TYPE_MSG en ese tema
; mantiene un contador por tema (hasta MAX_TOPICS entradas)
topic_next_seq_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi
    xor  ebx, ebx
    mov  r13d, -1

.tns_search:
    cmp  ebx, MAX_TOPICS
    jge  .tns_done_search

    mov  rax, rbx
    imul rax, TOPIC_ENTRY_SIZE
    lea  r14, [topic_entries + rax]

    cmp  byte [r14], 0
    je   .tns_empty

    mov  rdi, r14
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    je   .tns_match

    inc  ebx
    jmp  .tns_search

.tns_empty:
    cmp  r13d, 0
    jge  .tns_empty_skip
    mov  r13d, ebx
.tns_empty_skip:
    inc  ebx
    jmp  .tns_search

.tns_done_search:
    cmp  r13d, 0
    jl   .tns_emergency

    mov  ebx, r13d
    mov  rax, rbx
    imul rax, TOPIC_ENTRY_SIZE
    lea  r14, [topic_entries + rax]

    mov  rdi, r14
    mov  rsi, r12
    mov  rcx, MAX_TOPIC - 1
    call strncpy_fn
    mov  dword [r14 + MAX_TOPIC], 2
    mov  eax, 1
    jmp  .tns_out

.tns_match:
    mov  eax, dword [r14 + MAX_TOPIC]
    inc  dword [r14 + MAX_TOPIC]
    jmp  .tns_out

.tns_emergency:
    inc  dword [emergency_seq]
    mov  eax, dword [emergency_seq]

.tns_out:
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; broadcast_quic_fn(rdi=tema, rsi=cuerpo, edx=seq_num)
; construye el paquete MSG y lo manda a cada suscriptor del tema
broadcast_quic_fn:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov  r12, rdi
    mov  r13, rsi
    mov  r15d, edx

    ; armar el paquete MSG en out_buf
    lea  r14, [out_buf]

    mov  dword [r14], r15d    ; seq_num (4 bytes)
    add  r14, 4

    mov  byte [r14], TYPE_MSG ; tipo (1 byte)
    inc  r14

    ; longitud del tema
    mov  rdi, r12
    call strlen_fn
    mov  byte [r14], al
    inc  r14

    ; copiar el nombre del partido
    mov  rsi, r12
.bq_tema:
    mov  al, [rsi]
    test al, al
    jz   .bq_tema_done
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bq_tema
.bq_tema_done:

    ; copiar el cuerpo del mensaje
    mov  rsi, r13
.bq_body:
    mov  al, [rsi]
    test al, al
    jz   .bq_body_done
    mov  [r14], al
    inc  rsi
    inc  r14
    jmp  .bq_body
.bq_body_done:

    ; calcular cuantos bytes tiene el paquete
    lea  rax, [out_buf]
    sub  r14, rax

    ; recorrer la tabla y mandar a quien corresponda
    xor  ebx, ebx
.bq_loop:
    mov  eax, [subs_count]
    cmp  ebx, eax
    jge  .bq_done

    mov  rax, rbx
    imul rax, SUB_SIZE
    lea  r8, [subs + rax]

    cmp  dword [r8 + SUB_ACTIVE], 1
    jne  .bq_next

    lea  rdi, [r8 + SUB_TOPIC]
    mov  rsi, r12
    call strcmp_fn
    test rax, rax
    jnz  .bq_next

    ; armar el sockaddr_in del suscriptor en la pila y mandar
    sub  rsp, 16
    mov  word [rsp + 0], AF_INET
    movzx eax, word [r8 + SUB_PORT]
    mov  word [rsp + 2], ax
    mov  eax, [r8 + SUB_SADDR]
    mov  dword [rsp + 4], eax
    mov  qword [rsp + 8], 0

    mov  rax, SYS_SENDTO
    movsx rdi, dword [sock_fd]
    lea  rsi, [out_buf]
    mov  rdx, r14
    xor  r10, r10
    mov  r8, rsp
    mov  r9, 16
    syscall

    add  rsp, 16

.bq_next:
    inc  ebx
    jmp  .bq_loop

.bq_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; funciones auxiliares (mismas que en el resto del proyecto)

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

strncpy_fn:
    push rcx
.sn_lp:
    test rcx, rcx
    jz   .sn_done
    mov  al, [rsi]
    test al, al
    jz   .sn_done
    mov  [rdi], al
    inc  rdi
    inc  rsi
    dec  rcx
    jmp  .sn_lp
.sn_done:
    mov  byte [rdi], 0
    pop  rcx
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
