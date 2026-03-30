# Lab 3 – Sockets en Assembler (x86-64)

Práctica de **redes / sockets** en **NASM** con syscalls de **Linux x86-64** (sin la API de sockets de C). El mismo esquema (publicador–broker–suscriptor, temas tipo “partido”) está en **TCP**, **UDP** y **QUIC de laboratorio** (bono).

**QUIC aquí** no es el protocolo IETF de internet: es **UDP** binario con **ACK** al publicador y **secuencias** hacia suscriptores (`broker_quic.asm`, `publisher_quic.asm`, `subscriber_quic.asm`).

---

## Mac, Windows o Linux: cómo está pensado el repo

- Puedes **clonar y editar** el proyecto en **cualquier sistema** (Mac, Windows, Linux). Los `.asm` son texto; no “pertenecen” a un solo fabricante de PC.
- El **Makefile** genera ejecutables **ELF para Linux x86-64** (no son aplicaciones nativas de macOS ni `.exe` de Windows). Eso es lo que pide el laboratorio.
- La forma **prevista de compilar y ejecutar** es **siempre con Docker**: dentro del contenedor hay un Linux donde corren `nasm`, `ld`, `make` y los binarios en `./bin/`. Así no hace falta instalar un toolchain complejo en el Mac o en Windows.
- Si el código se escribió o probó en un **Mac**, el binario resultante es igualmente **Linux**; en Mac no conviene ejecutar esos ELF fuera de Docker salvo que sepas lo que haces.

**Resumen:** usa **Docker** en Mac, Windows o Linux; el contenedor es el entorno oficial del laboratorio.

---

## Qué hay en el repo

```
LAB3-REDES/
├── README.md                 ← este archivo (cómo compilar y ejecutar)
└── asm-main/
    ├── Makefile              ← reglas `make` y `make run_*`
    ├── src/
    │   ├── broker_tcp.asm, publisher_tcp.asm, subscriber_tcp.asm
    │   ├── broker_udp.asm, publisher_udp.asm, subscriber_udp.asm
    │   └── broker_quic.asm, publisher_quic.asm, subscriber_quic.asm
    ├── bin/                  ← se genera al compilar (objetos y ejecutables)
    ├── test_sub.sh           ← prueba UDP con netcat
    ├── test_quic_multi.sh    ← varios procesos QUIC
    └── debug_broker.sh       ← broker UDP + strace (opcional)
```

---

## Dónde está la documentación

| Qué | Dónde |
|-----|--------|
| Cómo compilar, Docker, puertos, ejemplos de ejecución | Este **README** |
| Targets `make`, `make tcp`, `make run_*`, variables `PORT_*`, `TOPIC` | **`asm-main/Makefile`** (comentarios al inicio) |
| Propósito del programa, **uso en línea de comandos**, cómo compilarlo a mano, syscalls y formato de mensajes | **Cabecera** de cada archivo en **`asm-main/src/*.asm`** (primeros bloques de comentarios `;`) |

Los comentarios dentro del código (etiquetas, fragmentos de lógica) están en los `.asm` según fue necesario en el desarrollo; no hace falta duplicar todo aquí.

---

## Protocolo (resumen; el detalle está en los `.asm`)

- **TCP** — Líneas de texto con salto de línea. Prefijos **SUB**, **PUB**, **MSG** y campos separados por **`|`** (ver `broker_tcp.asm`). El broker multiplexa con **`select`** hasta **16** clientes (`MAX_CLIENTS`).

- **UDP** — Mismo estilo de texto **SUB / PUB / MSG** (`broker_udp.asm`). Hasta **32** suscriptores en tabla (`MAX_SUBS`).

- **QUIC (bono)** — Estructura binaria y tipos en los comentarios de `broker_quic.asm`. **ACK** con el mismo **seq** que envió el publicador; **MSG** con **seq** que asigna el broker **por tema**. Límites **32** suscriptores y **32** temas con seq (`MAX_SUBS`, `MAX_TOPICS`).

### Argumentos de los ejecutables

| Programa | Argumentos |
|----------|------------|
| `broker_tcp`, `broker_udp`, `broker_quic` | `<puerto>` |
| `publisher_tcp`, `publisher_udp`, `publisher_quic` | `<ip_broker> <puerto_broker> <tema>` |
| `subscriber_tcp` | `<ip_broker> <puerto_broker> <tema>` |
| `subscriber_udp`, `subscriber_quic` | `<ip_broker> <puerto_broker> <puerto_local> <tema>` |

El **Makefile** define por defecto `BROKER_IP=127.0.0.1`, `TOPIC=partido1` y los puertos de la tabla siguiente.

---

## Requisitos en tu máquina (solo Docker)

| Sistema | Qué instalar |
|---------|----------------|
| **macOS** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Intel o Apple Silicon). Mantén la aplicación abierta hasta que el motor esté listo. |
| **Windows** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) (con WSL2 si el instalador lo pide). |
| **Linux** | Docker Engine y permisos para tu usuario (`docker` sin `sudo`, según la distribución). |

Dentro del contenedor Ubuntu se instalan **`nasm`**, **`binutils`** y **`make`** con `apt` (ver abajo). No hace falta tener NASM instalado en el Mac o en Windows.

**`--platform linux/amd64`:** inclúyelo en los `docker run` si tu Mac es **Apple Silicon** (M1/M2/…) o si el equipo es **ARM**. En un PC Linux **x86-64** a veces se puede omitir, pero dejarlo no causa problema.

---

## Docker (compilar y ejecutar)

Abre una terminal **en la carpeta del repositorio** donde está **`asm-main`** (por ejemplo `LAB3-REDES`).

**Montar el volumen** (elige según tu terminal):

- **macOS / Linux** (bash o zsh): `"$(pwd)"` como abajo.
- **Windows PowerShell** (en la carpeta del repo): cambia el volumen a  
  `-v "${PWD}:/app"`
- **Windows CMD**: puedes usar  
  `-v %cd%:/app`  
  (si falla, escribe la ruta completa del proyecto, por ejemplo `C:\ruta\LAB3-REDES`).

Ejemplo **macOS / Linux** (copiar y pegar desde la raíz del repo):

```bash
docker run --rm -it --platform linux/amd64 \
  -v "$(pwd)":/app -w /app/asm-main \
  -p 9000:9000 -p 9001:9001 -p 9002:9002 \
  -p 9100-9101:9100-9101 -p 9200-9201:9200-9201 \
  ubuntu:22.04 bash
```

Ya **dentro** del contenedor:

```bash
apt update && apt install -y nasm binutils make
make
```

Los **`-p`** sirven si quieres usar **Wireshark en la máquina anfitriona** (Mac/Windows/Linux). Si solo pruebas con `127.0.0.1` dentro del contenedor, puedes omitirlos.

**Varias terminales en el mismo contenedor** (sin `--rm`):

```bash
docker run -d --name lab3-redes --platform linux/amd64 \
  -v "$(pwd)":/app -w /app/asm-main \
  -p 9000:9000 -p 9001:9001 -p 9002:9002 \
  -p 9100-9101:9100-9101 -p 9200-9201:9200-9201 \
  ubuntu:22.04 sleep infinity
docker exec -it lab3-redes bash
```

En **Windows**, reemplaza `$(pwd)` por `${PWD}` (PowerShell) o la ruta adecuada en el `-v` del `docker run` y del `docker run -d`.

Puertos y variables del Makefile:

| Variable | Valor típico |
|----------|----------------|
| `PORT_TCP` | 9000 |
| `PORT_UDP` | 9001 |
| `PORT_SUB1` / `PORT_SUB2` | 9100 / 9101 (UDP) |
| `PORT_QUIC` | 9002 |
| `PORT_QSUB1` / `PORT_QSUB2` | 9200 / 9201 (QUIC) |

---

## Compilar

Todo desde **`asm-main/`**:

```bash
make          # TCP + UDP + QUIC
make tcp      # solo TCP (broker + pub + sub)
make udp      # solo UDP (broker + pub + sub)
make sub_udp  # solo subscriber_udp
make quic     # solo QUIC
make clean
```

---

## Ejecutar

**TCP** — Orden habitual: broker, luego suscriptores, luego publicadores.

```bash
./bin/broker_tcp 9000
./bin/subscriber_tcp 127.0.0.1 9000 partido1
./bin/publisher_tcp 127.0.0.1 9000 partido1
```

Atajos: `make run_tcp`, `make run_sub_tcp`, `make run_pub_tcp`.

**UDP**

```bash
./bin/broker_udp 9001
./bin/subscriber_udp 127.0.0.1 9001 9100 partido1
./bin/publisher_udp 127.0.0.1 9001 partido1
```

Atajos: `make run_udp`, `make run_sub1`, `make run_sub2`, `make run_pub_udp`.

**QUIC (bono)**

```bash
./bin/broker_quic 9002
./bin/subscriber_quic 127.0.0.1 9002 9200 partido1
./bin/publisher_quic 127.0.0.1 9002 partido1
```

Atajos: `make run_broker_quic`, `make run_sub_quic1`, `make run_sub_quic2`, `make run_pub_quic`. El publicador lee líneas; **Ctrl+D** termina.

Ejemplo de mensajes en consola (cadenas definidas en el código): el publicador puede mostrar líneas como `[QUIC-PUB] Enviando seq=1 ...` y luego `[QUIC-PUB] Enviando seq=1 -> ACK ok, mensaje confirmado`; el broker `[Broker QUIC] DATA seq=... tema=... : ... -> ACK enviado`; el suscriptor `[QUIC-SUB] seq=... [tema] : ... (en orden)` cuando el seq sigue al anterior.

---

## Scripts en `asm-main/`

| Script | Qué hace | Dependencias |
|--------|-----------|----------------|
| **`test_sub.sh`** | Levanta `broker_udp` y un `subscriber_udp`, envía dos **PUB** con **`nc`**, muestra salidas en `/tmp`. | `bin/broker_udp`, `bin/subscriber_udp`, comando **`nc`** |
| **`test_quic_multi.sh`** | Un broker QUIC, dos suscriptores y dos publicadores al tema **`partido-demo`**; registros en `/tmp`. | `make quic` antes; **`chmod +x`** si hace falta |
| **`debug_broker.sh`** | Arranca **`broker_udp`** bajo **`strace`** filtrando `recvfrom` para ver qué llega al syscall. | `bin/broker_udp`, **`strace`**, **`nc`** |

---

## Wireshark

Con puertos mapeados en Docker, en el equipo anfitrión se pueden usar filtros del estilo `tcp.port == 9000`, `udp.port == 9001` o `udp.port == 9002`.

---

## Sin Docker (opcional, solo Linux x86-64 nativo)

Solo tiene sentido en un **equipo Linux de 64 bits (x86-64)**. Instala `nasm`, `binutils` y `make`, entra en `asm-main` y ejecuta `make`. En **ARM** (por ejemplo Raspberry Pi) el laboratorio sigue haciéndose con **Docker** y `--platform linux/amd64`.

En **Mac y Windows** no documentamos ejecución nativa: el flujo previsto es **Docker**.
