; =============================================================
; subscriber_tcp.asm
; Suscriptor TCP – Sistema Publicación-Suscripción de Noticias Deportivas
;
; Este programa se conecta al broker TCP, se suscribe a un tema
; y espera mensajes en vivo. A diferencia del suscriptor UDP,
; aquí usamos TCP: hay una conexión establecida y garantía de que
; los mensajes llegan en orden y sin pérdida.
;
; Diferencia clave con el suscriptor UDP:
;   UDP: el subscriber hace bind() a un puerto propio y el broker
;        le envía datagramas con sendto() a ese puerto.
;   TCP: el subscriber hace connect() al broker. Después de eso,
;        el mismo fd sirve tanto para enviar el SUB como para
;        recibir los MSG. No necesitamos bind() ni puerto propio.
;
; El flujo completo es:
;   1. socket()   → crear socket TCP (SOCK_STREAM)
;   2. connect()  → 3-way handshake con el broker
;   3. write()    → enviar "SUB|<tema>\n" por la conexión
;   4. loop:
;        read()   → acumular bytes en recv_buf
;        buscar \n → imprimir la línea completa
;        compactar → mover el resto al inicio del buffer
;
; Por qué acumulamos en un buffer en TCP y no en UDP?
; UDP entrega datagramas completos: un sendto() = un recvfrom().
; TCP es un flujo de bytes sin fronteras: el broker puede enviar
; "MSG|partido1|Gol\n" y nosotros recibirlo en dos read() como
; "MSG|partido" y "1|Gol\n". Por eso acumulamos hasta el \n.
;
; Uso: ./subscriber_tcp <broker_ip> <broker_puerto> <tema>
;      Ejemplo: ./subscriber_tcp 127.0.0.1 9000 partido1
;
; Compilar:
;   nasm -f elf64 subscriber_tcp.asm -o subscriber_tcp.o
;   ld -o subscriber_tcp subscriber_tcp.o
;
; Syscalls:
;   0  read    - recibir mensajes del broker por la conexión TCP
;   1  write   - enviar SUB al broker y mostrar mensajes en stdout
;   3  close   - cerrar el socket al terminar
;   41 socket  - crear el socket TCP
;   42 connect - conectarse al broker (el subscriber inicia la conexión)
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
%define SOCK_STREAM    1       ; TCP: stream orientado a conexión

%define BUF_SIZE       512     ; tamaño del buffer de acumulación TCP
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

s_uso        db "Uso: ./subscriber_tcp <broker_ip> <broker_puerto> <tema>", 10
s_uso_len    equ $ - s_uso

s_conn_ok    db "[Suscriptor TCP] Conectado al broker", 10
s_conn_ok_l  equ $ - s_conn_ok

s_sub_ok     db "[Suscriptor TCP] Suscripcion enviada al tema: "
s_sub_ok_l   equ $ - s_sub_ok

s_waiting    db "[Suscriptor TCP] Esperando mensajes del broker...", 10
s_waiting_l  equ $ - s_waiting

s_disc       db "[Suscriptor TCP] Broker cerro la conexion", 10
s_disc_l     equ $ - s_disc

s_recv_pre   db "[MSG] "
s_recv_pre_l equ $ - s_recv_pre

s_nl         db 10
s_nl_len     equ 1

; Prefijo del mensaje de suscripcion.
; El broker espera exactamente "SUB|<tema>\n" para registrar al suscriptor.
s_sub_prefix db "SUB|"
s_sub_pref_l equ $ - s_sub_prefix

s_err_socket db "[Suscriptor TCP] Error: no se pudo crear el socket", 10
s_err_sock_l equ $ - s_err_socket

s_err_conn   db "[Suscriptor TCP] Error: no se pudo conectar al broker (esta corriendo?)", 10
s_err_conn_l equ $ - s_err_conn

s_err_send   db "[Suscriptor TCP] Error: no se pudo enviar la suscripcion", 10
s_err_send_l equ $ - s_err_send

section .bss

; File descriptor del socket TCP que creamos y conectamos al broker
sock_fd      resd 1

; struct sockaddr_in del broker — se llena antes de connect():
;   +0  sin_family  (2 bytes) = AF_INET = 2
;   +2  sin_port    (2 bytes) en network byte order (big-endian)
;   +4  sin_addr    (4 bytes) en network byte order
;   +8  sin_zero    (8 bytes) = 0
broker_addr  resb 16

; Buffer de acumulacion TCP: guardamos aqui los bytes que llegan
; hasta encontrar el \n que delimita un mensaje completo.
; Necesario porque TCP no preserva fronteras de mensaje.
recv_buf     resb BUF_SIZE + 1  ; +1 para el centinela \0 temporal

; Cuantos bytes validos hay actualmente en recv_buf
recv_len     resd 1

; Buffer donde construimos "SUB|<tema>\n" antes de enviarlo al broker
sub_msg_buf  resb 128

section .text
    global _start

; =============================================================
; _start: punto de entrada
;
; Layout del stack al inicio (Linux x86-64):
;   [rsp+0]  = argc
;   [rsp+8]  = argv[0]  nombre del programa
;   [rsp+16] = argv[1]  broker_ip
;   [rsp+24] = argv[2]  broker_puerto
;   [rsp+32] = argv[3]  tema
; =============================================================
_start:
    pop  rdi
    cmp  rdi, 4                ; argc debe ser 4: prog ip puerto tema
    jl   .err_uso

    pop  rax                   ; argv[0]: nombre del ejecutable, descartar
    pop  r12                   ; r12 = broker_ip    (ej: "127.0.0.1")
    pop  r13                   ; r13 = broker_puerto (ej: "9000")
    pop  r14                   ; r14 = tema          (ej: "partido1")

    ; =========================================================
    ; Convertir el puerto del broker a network byte order
    ;
    ; atoi_fn: "9000" → 9000 en rax (host byte order)
    ; rol cx, 8: intercambia los bytes del word → htons() manual
    ; Ejemplo: 9000 = 0x2328 → rol → 0x2823 (network order)
    ; =========================================================
    mov  rdi, r13
    call atoi_fn
    movzx ecx, ax
    rol  cx, 8                 ; htons: intercambiar byte alto y bajo

    ; Rellenar la estructura sockaddr_in del broker
    mov  word  [broker_addr + 0], AF_INET   ; sin_family = 2
    mov  word  [broker_addr + 2], cx        ; sin_port en network order
    mov  qword [broker_addr + 8], 0         ; sin_zero = 0

    ; Convertir la IP "a.b.c.d" a uint32 en network byte order
    ; inet_aton_fn devuelve 0x0100007F para "127.0.0.1":
    ; en memoria little-endian eso queda como bytes 7F 00 00 01,
    ; que es el correcto network byte order de 127.0.0.1.
    mov  rdi, r12
    call inet_aton_fn
    mov  dword [broker_addr + 4], eax       ; sin_addr del broker

    ; =========================================================
    ; socket(AF_INET, SOCK_STREAM, 0)
    ;
    ; SOCK_STREAM = TCP. A diferencia de SOCK_DGRAM (UDP), este
    ; socket mantiene una conexion persistente con el broker.
    ; No necesitamos bind(): connect() le asigna automaticamente
    ; un puerto efimero local al hacer el handshake.
    ; =========================================================
    mov  rax, SYS_SOCKET
    mov  rdi, AF_INET
    mov  rsi, SOCK_STREAM
    xor  rdx, rdx              ; protocolo 0: el kernel elige TCP
    syscall
    test rax, rax
    js   .err_socket
    mov  [sock_fd], eax

    ; =========================================================
    ; connect(fd, &broker_addr, 16)
    ;
    ; Inicia el 3-way handshake TCP con el broker:
    ;   subscriber → SYN     → broker
    ;   subscriber ← SYN+ACK ← broker
    ;   subscriber → ACK     → broker
    ;
    ; Despues de connect(), el fd esta listo para write()/read().
    ; Si el broker no esta corriendo, connect() falla inmediatamente
    ; con ECONNREFUSED (errno = 111).
    ; =========================================================
    mov  rax, SYS_CONNECT
    movsx rdi, dword [sock_fd]
    lea  rsi, [broker_addr]
    mov  rdx, 16
    syscall
    test rax, rax
    js   .err_connect

    write_lit s_conn_ok, s_conn_ok_l

    ; =========================================================
    ; Construir "SUB|<tema>\n" en sub_msg_buf
    ;
    ; LECCION APRENDIDA del publisher UDP:
    ; El loop copy_prefix usa ecx como contador y lo destruye.
    ; Aqui no necesitamos preservar la longitud del tema para
    ; copy_prefix, pero si la necesitamos para calcular el total.
    ; Calculamos la longitud total AL FINAL restando punteros,
    ; asi evitamos el problema completamente.
    ; =========================================================
    lea  rdi, [sub_msg_buf]    ; rdi = cursor de escritura

    ; Copiar "SUB|" — usa ecx como contador de loop (destruye rcx)
    lea  rsi, [s_sub_prefix]
    mov  ecx, s_sub_pref_l
.copy_prefix:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .copy_prefix

    ; Copiar el tema byte a byte hasta el \0
    mov  rsi, r14
.copy_topic:
    mov  al, [rsi]
    test al, al
    jz   .topic_done
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_topic
.topic_done:
    ; Agregar \n final: el broker parsea linea por linea
    mov  byte [rdi], 10
    inc  rdi

    ; Calcular longitud: (cursor_final - inicio_buffer)
    ; IMPORTANTE: guardamos la longitud en rbx ANTES de sobreescribir
    ; rdi con el file descriptor en la syscall write.
    lea  rax, [sub_msg_buf]
    sub  rdi, rax              ; rdi = longitud del mensaje
    mov  rbx, rdi              ; rbx = longitud (callee-saved, no se destruye)

    ; =========================================================
    ; write(fd, sub_msg_buf, len)
    ;
    ; En TCP, write() es equivalente a send() sin flags.
    ; La conexion ya esta establecida por connect(), asi que
    ; no necesitamos especificar destino (a diferencia de sendto en UDP).
    ; El kernel garantiza que todos los bytes llegarean al broker.
    ;
    ; Argumentos syscall:
    ;   rdi = fd del socket
    ;   rsi = buffer con los datos
    ;   rdx = cantidad de bytes a enviar
    ; =========================================================
    mov  rax, SYS_WRITE
    movsx rdi, dword [sock_fd]
    lea  rsi, [sub_msg_buf]
    mov  rdx, rbx              ; longitud calculada y guardada arriba
    syscall
    test rax, rax
    js   .err_send

    ; Mostrar confirmacion en pantalla (igual que el subscriber UDP)
    write_lit s_sub_ok, s_sub_ok_l
    mov  rdi, r14              ; r14 = tema (callee-saved: intacto)
    call print_cstr_fn
    write_lit s_nl, s_nl_len
    write_lit s_waiting, s_waiting_l

    ; Inicializar el buffer de acumulacion vacio
    mov  dword [recv_len], 0

; =============================================================
; .recv_loop: bucle principal de recepcion
;
; Diferencia con UDP:
;   UDP: recvfrom() bloquea y devuelve un datagrama completo.
;        Cada llamada = un mensaje entero. Simple.
;   TCP: read() puede devolver cualquier cantidad de bytes.
;        Acumulamos en recv_buf hasta encontrar \n.
;        Luego imprimimos la linea y compactamos el buffer.
;
; El broker envia: "MSG|partido1|Gol de Messi\n"
; Nosotros mostramos: "[MSG] MSG|partido1|Gol de Messi"
; =============================================================
.recv_loop:
    ; Calcular donde escribir en recv_buf: justo despues de los
    ; bytes ya acumulados que aun no tienen \n
    movsx r9, dword [recv_len]  ; r9 = bytes ya en el buffer
    mov  rdx, BUF_SIZE - 1
    sub  rdx, r9               ; rdx = espacio libre restante
    test rdx, rdx
    jle  .buf_full             ; buffer lleno sin \n: descartar todo

    lea  rsi, [recv_buf]
    add  rsi, r9               ; rsi = puntero de escritura

    ; =========================================================
    ; read(fd, ptr_escritura, espacio_libre)
    ;
    ; Bloquea hasta recibir ALGO del broker.
    ; Puede recibir desde 1 byte hasta espacio_libre bytes.
    ; Retorna 0 si el broker cerro la conexion (FIN TCP).
    ; Retorna negativo si hubo error de red.
    ;
    ; CRITICO: los tres argumentos deben estar correctamente
    ; seteados ANTES del syscall:
    ;   rdi = fd (el socket)
    ;   rsi = ya calculado arriba (ptr de escritura en recv_buf)
    ;   rdx = ya calculado arriba (espacio libre)
    ; =========================================================
    mov  rax, SYS_READ
    movsx rdi, dword [sock_fd]
    ; rsi y rdx ya tienen los valores correctos calculados arriba
    syscall

    test rax, rax
    jz   .disconnected         ; 0 = broker cerro la conexion (EOF TCP)
    js   .recv_loop            ; negativo = error temporal, reintentar

    ; Actualizar cuantos bytes validos hay en el buffer
    add  [recv_len], eax

; =============================================================
; .proc_lines: procesar todas las lineas completas acumuladas
;
; Un "mensaje completo" termina en \n.
; Pueden haberse acumulado varios en el mismo read() (broker
; rapido + red rapida). Los procesamos uno a uno.
; =============================================================
.proc_lines:
    mov  ecx, [recv_len]
    test ecx, ecx
    jz   .recv_loop            ; buffer vacio: volver a leer

    ; Poner un \0 temporal en recv_buf[recv_len] como centinela.
    ; Esto limita find_char_fn a los bytes validos del buffer,
    ; evitando que lea memoria no inicializada mas alla.
    lea  rdi, [recv_buf]
    mov  byte [rdi + rcx], 0   ; centinela temporal
    mov  al, 10                ; buscar '\n'
    call find_char_fn
    test rax, rax
    jz   .recv_loop            ; no hay \n aun: esperar mas bytes

    ; Tenemos una linea completa. Nul-terminarla sobreescribiendo el \n.
    mov  byte [rax], 0

    ; Eliminar \r si el mensaje viene con CRLF (clientes Windows)
    lea  rdi, [recv_buf]
    cmp  rax, rdi              ; el \n es el primer byte?
    je   .skip_cr
    cmp  byte [rax - 1], 13   ; \r antes del \n?
    jne  .skip_cr
    mov  byte [rax - 1], 0    ; eliminar el \r tambien
.skip_cr:

    ; Calcular cuantos bytes consume esta linea (offset del \n + 1 por el \n)
    ; Guardamos en r15 (callee-saved) para el compactado posterior.
    lea  rdx, [recv_buf]
    sub  rax, rdx              ; rax = offset del \n dentro del buffer
    inc  rax                   ; +1 para incluir el \n en los consumidos
    mov  r15, rax              ; r15 = bytes consumidos

    ; Imprimir "[MSG] <contenido_del_mensaje>"
    ; El broker envia "MSG|partido1|evento", lo mostramos tal cual.
    write_lit s_recv_pre, s_recv_pre_l
    lea  rdi, [recv_buf]
    call print_cstr_fn
    write_lit s_nl, s_nl_len

    ; =========================================================
    ; Compactar recv_buf: mover los bytes restantes al inicio
    ;
    ; Si llegaron dos mensajes juntos en el mismo read():
    ;   "MSG|p1|Gol\nMSG|p1|Tarjeta\n"
    ; Despues de procesar el primero, "MSG|p1|Tarjeta\n" debe
    ; quedar al inicio de recv_buf para el siguiente .proc_lines.
    ; =========================================================
    mov  ecx, [recv_len]
    sub  ecx, r15d             ; ecx = bytes restantes despues del \n

    cmp  ecx, 0
    jle  .recv_cleared         ; no quedo nada: limpiar y volver

    ; Mover los bytes restantes al inicio del buffer
    lea  rsi, [recv_buf]
    lea  rdi, [recv_buf]
    add  rsi, r15              ; rsi = inicio de los bytes restantes
.compact:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    dec  ecx
    jnz  .compact

    ; Actualizar recv_len: solo quedan los bytes que movimos
    mov  ecx, [recv_len]
    sub  ecx, r15d
    mov  [recv_len], ecx
    jmp  .proc_lines           ; revisar si quedo otra linea completa

.recv_cleared:
    ; No quedaron bytes: buffer completamente procesado
    mov  dword [recv_len], 0
    jmp  .proc_lines           ; pasar por proc_lines para ir a recv_loop

.buf_full:
    ; El buffer se lleno sin encontrar \n.
    ; Mensaje invalido o demasiado largo: descartar todo y seguir.
    mov  dword [recv_len], 0
    jmp  .recv_loop

.disconnected:
    ; El broker cerro la conexion (envio FIN TCP).
    ; Cerramos nuestro socket y salimos limpiamente.
    write_lit s_disc, s_disc_l
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
    ; connect() fallo: el broker no esta corriendo, IP/puerto incorrectos,
    ; o firewall bloqueando. Mostramos el error antes de salir.
    write_lit s_err_conn, s_err_conn_l
    exit_code 1

.err_send:
    write_lit s_err_send, s_err_send_l
    exit_code 1

; =============================================================
; find_char_fn(rdi=str, al=char) → rax
;
; Busca el caracter 'al' en el string 'str' byte a byte.
; Se detiene en el primer \0 (centinela) o al encontrar el caracter.
; Retorna puntero al caracter encontrado, o 0 si no existe.
;
; Uso tipico: buscar \n para encontrar fin de linea en TCP.
; =============================================================
find_char_fn:
    mov  cl, al                ; guardar el caracter buscado
                               ; (al se sobreescribe en el loop)
.fc_lp:
    mov  al, [rdi]
    test al, al
    jz   .fc_none              ; llegamos al centinela \0 sin encontrar
    cmp  al, cl
    je   .fc_found
    inc  rdi
    jmp  .fc_lp
.fc_found:
    mov  rax, rdi
    ret
.fc_none:
    xor  eax, eax              ; 0 = no encontrado
    ret

; =============================================================
; atoi_fn(rdi=str) → rax
; Convierte string ASCII decimal a entero sin signo.
; Para cuando encuentra caracter no numerico o \0.
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
; Cuenta bytes hasta el \0 terminal. No cuenta el \0.
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
; print_cstr_fn(rdi=str)
; Imprime un string nul-terminado en stdout usando sys_write.
; Calcula la longitud con strlen_fn. No imprime si esta vacio.
; =============================================================
print_cstr_fn:
    push rdi
    call strlen_fn             ; rax = longitud
    mov  rdx, rax
    pop  rsi                   ; rsi = puntero al string
    test rdx, rdx
    jz   .pc_done
    mov  rax, SYS_WRITE
    mov  rdi, 1                ; stdout
    syscall
.pc_done:
    ret

; =============================================================
; inet_aton_fn(rdi=str) → eax
;
; Convierte "a.b.c.d" al uint32 que va en sockaddr_in.sin_addr.
;
; Endianness: x86 es little-endian. "127.0.0.1" debe quedar en
; MEMORIA como los bytes 7F 00 00 01 (network byte order).
; Eso equivale al valor 0x0100007F en un registro x86.
;
; El algoritmo desplaza cada octeto con shl segun su posicion:
;   octeto 127, shift  0: eax = 0x0000007F
;   octeto   0, shift  8: or  = 0x0000007F  (0 desplazado no cambia)
;   octeto   0, shift 16: or  = 0x0000007F
;   octeto   1, shift 24: or  = 0x0100007F  ← valor final en eax
;
; Al escribir en memoria: mov dword [broker_addr+4], eax
; el CPU almacena los bytes como: 7F 00 00 01 = 127.0.0.1 correcto.
; =============================================================
inet_aton_fn:
    push rbx
    push r12
    push r13
    push r14

    mov  r12, rdi              ; r12 = puntero al string IP
    xor  r13d, r13d            ; r13 = acumulador del resultado
    xor  r14d, r14d            ; r14 = bits de desplazamiento (0,8,16,24)

.ia_octet:
    xor  eax, eax              ; eax = valor decimal del octeto actual
.ia_digit:
    movzx ecx, byte [r12]
    test cl, cl
    jz   .ia_store             ; fin de string: guardar ultimo octeto
    cmp  cl, '.'
    je   .ia_dot               ; separador: guardar octeto y continuar
    sub  cl, '0'
    cmp  cl, 9
    ja   .ia_store
    imul eax, eax, 10
    add  eax, ecx
    inc  r12
    jmp  .ia_digit
.ia_dot:
    inc  r12                   ; saltar el '.'
.ia_store:
    mov  ecx, r14d
    shl  eax, cl               ; posicionar el octeto en su lugar
    or   r13d, eax             ; acumular en el resultado
    add  r14d, 8
    cmp  r14d, 32
    jl   .ia_octet

    mov  eax, r13d             ; retornar resultado listo para sin_addr

    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret
