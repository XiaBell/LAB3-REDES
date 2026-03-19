# Brokers en Assembly x86-64
### Laboratorio 3 – Análisis Capa de Transporte y Sockets

Implementación en lenguaje ensamblador NASM de los brokers TCP y UDP
del sistema publicación-suscripción de noticias deportivas.

## Estructura del proyecto

```
asm/
├── Makefile
├── README.md
├── src/
│   ├── broker_tcp.asm   ← broker TCP con select() sin hilos
│   └── broker_udp.asm   ← broker UDP con recvfrom loop
└── bin/                 ← generado al compilar
    ├── broker_tcp
    └── broker_udp
```

## Requisitos

| Herramienta | Versión mínima | Instalar (Debian/Ubuntu) |
|---|---|---|
| NASM | 2.14 | `sudo apt install nasm` |
| binutils (ld) | 2.30 | `sudo apt install binutils` |
| Linux x86-64 | kernel ≥ 3.x | — |

## Compilar

```bash
# Compilar ambos brokers
make

# Solo TCP
make tcp

# Solo UDP
make udp

# Limpiar binarios y objetos
make clean
```

## Ejecutar

```bash
# Terminal 1 – Broker TCP
./bin/broker_tcp 9000

# Terminal 2 – Broker UDP
./bin/broker_udp 9001
```

## Protocolo de mensajes

| Dirección | Formato | Acción |
|---|---|---|
| Cliente → Broker | `SUB\|<tema>\n` | Suscribirse al tema |
| Cliente → Broker | `PUB\|<tema>\|<msg>\n` | Publicar evento |
| Broker → Suscriptor | `MSG\|<tema>\|<msg>\n` | Reenvío del broker |

Ejemplo de tema: `EquipoA_vs_EquipoB`

## Syscalls utilizados

| # | Nombre | Uso |
|---|---|---|
| 0 | sys_read | Leer datos de clientes TCP (stream) |
| 1 | sys_write | Log en stdout |
| 3 | sys_close | Cerrar conexiones |
| 23 | sys_select | Multiplexar múltiples FDs (TCP) |
| 41 | sys_socket | Crear socket TCP/UDP |
| 43 | sys_accept | Aceptar nueva conexión TCP |
| 44 | sys_sendto | Enviar datos/datagramas |
| 45 | sys_recvfrom | Recibir datagramas UDP |
| 49 | sys_bind | Asociar socket a puerto |
| 50 | sys_listen | Modo escucha (TCP) |
| 54 | sys_setsockopt | Opciones de socket |
| 60 | sys_exit | Terminar proceso |
