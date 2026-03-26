# Lab 3 – Sockets en Assembler (x86-64)

Sistema pub-sub de noticias deportivas implementado en NASM para Linux.
Tiene tres versiones: TCP, UDP y QUIC (bono). Cada una tiene su broker, publisher y subscriber.

## Estructura

```
asm-main/
├── Makefile
├── src/
│   ├── broker_tcp.asm
│   ├── broker_udp.asm
│   ├── subscriber_udp.asm
│   ├── broker_quic.asm
│   ├── publisher_quic.asm
│   └── subscriber_quic.asm
└── bin/          ← se genera al compilar
```

## Requisitos

Necesitas Linux x86-64 con `nasm`, `binutils` y `make`. Si estás en Mac o Windows usá Docker:

```bash
docker run --rm -it --platform linux/amd64 -v "$(pwd)":/app -w /app ubuntu:22.04 bash
apt update && apt install -y nasm binutils make
```

---

## TCP

> pendiente

---

## UDP

> pendiente

---

## QUIC (bono)

QUIC usa UDP por debajo pero le agrega confirmaciones de entrega (ACK), retransmisión automática si no llega el ACK, y números de secuencia para detectar mensajes perdidos o desordenados.

### Compilar

```bash
make quic
```

### Desplegar

Necesitás 4 terminales. Abrí cada una con `docker exec -it <ID> bash` (el ID lo ves con `docker ps`).

**Terminal 1 – Broker** (arrancá este primero):
```bash
./bin/broker_quic 9002
```

**Terminal 2 – Suscriptor 1:**
```bash
./bin/subscriber_quic 127.0.0.1 9002 9200 partido1
```

**Terminal 3 – Suscriptor 2:**
```bash
./bin/subscriber_quic 127.0.0.1 9002 9201 partido1
```

**Terminal 4 – Publisher** (acá escribís los mensajes):
```bash
./bin/publisher_quic 127.0.0.1 9002 partido1
```

Cuando aparezca el prompt escribí el evento y presioná Enter:
```
[QUIC-PUB] Escribe el evento (Ctrl+D para salir):
Gol de EquipoA al minuto 23
```

### Qué debería verse

Publisher confirma entrega:
```
[QUIC-PUB] Enviando seq=1 ...
[QUIC-PUB] seq=1 -> ACK ok, mensaje confirmado
```

Broker recibe y reenvía:
```
[Broker QUIC] DATA seq=1 tema=partido1 : Gol de EquipoA al minuto 23 -> ACK enviado
```

Suscriptores reciben con estado de orden:
```
[QUIC-SUB] seq=1 [partido1] : Gol de EquipoA al minuto 23 (en orden)
```
