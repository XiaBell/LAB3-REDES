# =============================================================
# Makefile – Brokers + Subscriber Assembly x86-64 (NASM + ld)
# Laboratorio 3: Análisis Capa de Transporte y Sockets
#
# Uso del proyecto (Docker, argumentos, scripts): README.md en la raíz del repo (LAB3-REDES).
#
# Uso:
#   make              → compila todo (TCP, UDP y QUIC)
#   make tcp          → compila broker_tcp + publisher_tcp + subscriber_tcp
#   make udp          → compila broker_udp + publisher_udp + subscriber_udp
#   make sub_udp      → compila solo subscriber_udp
#   make quic         → compila el trío QUIC (broker + publisher + subscriber)
#   make clean        → elimina objetos y binarios
#   make run_tcp      → ejecuta broker TCP en puerto 9000
#   make run_pub_tcp  → publisher TCP
#   make run_sub_tcp  → suscriptor TCP
#   make run_udp      → ejecuta broker UDP en puerto 9001
#   make run_pub_udp  → publisher UDP
#   make run_sub1     → ejecuta suscriptor UDP 1 (puerto 9100, tema partido1)
#   make run_sub2     → ejecuta suscriptor UDP 2 (puerto 9101, tema partido1)
#   make run_broker_quic  → ejecuta broker QUIC en puerto 9002
#   make run_pub_quic     → ejecuta publisher QUIC (lee de stdin)
#   make run_sub_quic1    → ejecuta suscriptor QUIC 1 (puerto 9200)
#   make run_sub_quic2    → ejecuta suscriptor QUIC 2 (puerto 9201)
# =============================================================

# Herramientas
ASM    = nasm
LD     = ld
RM     = rm -f

# Flags
ASMFLAGS = -f elf64        # formato ELF 64-bit para Linux x86-64
LDFLAGS  =                 # sin librerías externas (syscalls directas)

# Directorios
SRCDIR = src
BINDIR = bin
OBJDIR = bin

# Fuentes y binarios – TCP y UDP (originales)
TCP_SRC  = $(SRCDIR)/broker_tcp.asm
UDP_SRC  = $(SRCDIR)/broker_udp.asm
SUB_SRC  = $(SRCDIR)/subscriber_udp.asm
TCP_OBJ  = $(OBJDIR)/broker_tcp.o
UDP_OBJ  = $(OBJDIR)/broker_udp.o
SUB_OBJ  = $(OBJDIR)/subscriber_udp.o
TCP_BIN  = $(BINDIR)/broker_tcp
TCP_PUB_SRC = $(SRCDIR)/publisher_tcp.asm
TCP_SUB_SRC = $(SRCDIR)/subscriber_tcp.asm
TCP_PUB_OBJ = $(OBJDIR)/publisher_tcp.o
TCP_SUB_OBJ = $(OBJDIR)/subscriber_tcp.o
TCP_PUB_BIN = $(BINDIR)/publisher_tcp
TCP_SUB_BIN = $(BINDIR)/subscriber_tcp

UDP_BIN  = $(BINDIR)/broker_udp
UDP_PUB_SRC = $(SRCDIR)/publisher_udp.asm
UDP_PUB_OBJ = $(OBJDIR)/publisher_udp.o
UDP_PUB_BIN = $(BINDIR)/publisher_udp
SUB_BIN  = $(BINDIR)/subscriber_udp

# Fuentes y binarios – QUIC (bono)
QBRK_SRC = $(SRCDIR)/broker_quic.asm
QPUB_SRC = $(SRCDIR)/publisher_quic.asm
QSUB_SRC = $(SRCDIR)/subscriber_quic.asm
QBRK_OBJ = $(OBJDIR)/broker_quic.o
QPUB_OBJ = $(OBJDIR)/publisher_quic.o
QSUB_OBJ = $(OBJDIR)/subscriber_quic.o
QBRK_BIN = $(BINDIR)/broker_quic
QPUB_BIN = $(BINDIR)/publisher_quic
QSUB_BIN = $(BINDIR)/subscriber_quic

# Puertos por defecto
PORT_TCP   = 9000
PORT_UDP   = 9001
PORT_SUB1  = 9100
PORT_SUB2  = 9101
PORT_QUIC  = 9002       # broker QUIC escucha aquí
PORT_QSUB1 = 9200       # suscriptor QUIC 1
PORT_QSUB2 = 9201       # suscriptor QUIC 2
BROKER_IP  = 127.0.0.1
TOPIC      = partido1

# =============================================================
# Reglas
# =============================================================

.PHONY: all tcp udp sub_udp quic clean \
        run_tcp run_pub_tcp run_sub_tcp run_udp run_pub_udp run_sub1 run_sub2 \
        run_broker_quic run_pub_quic run_sub_quic1 run_sub_quic2

# Compilar todo (TCP, UDP y QUIC)
all: $(TCP_BIN) $(TCP_PUB_BIN) $(TCP_SUB_BIN) $(UDP_BIN) $(UDP_PUB_BIN) $(SUB_BIN) $(QBRK_BIN) $(QPUB_BIN) $(QSUB_BIN)
	@echo ""
	@echo "Compilacion exitosa:"
	@echo "  $(TCP_BIN)      <- broker TCP        (puerto: $(PORT_TCP))"
	@echo "  $(TCP_PUB_BIN)  <- publisher TCP"
	@echo "  $(TCP_SUB_BIN)  <- subscriber TCP"
	@echo "  $(UDP_BIN)      <- broker UDP        (puerto: $(PORT_UDP))"
	@echo "  $(UDP_PUB_BIN)  <- publisher UDP"
	@echo "  $(SUB_BIN)      <- subscriber UDP"
	@echo "  $(QBRK_BIN)     <- broker QUIC       (puerto: $(PORT_QUIC))"
	@echo "  $(QPUB_BIN)     <- publisher QUIC"
	@echo "  $(QSUB_BIN)     <- subscriber QUIC"

# Compilar TCP (broker + publicador + suscriptor)
tcp: $(TCP_BIN) $(TCP_PUB_BIN) $(TCP_SUB_BIN)

# Compilar UDP (broker + publicador + suscriptor)
udp: $(UDP_BIN) $(UDP_PUB_BIN) $(SUB_BIN)

# Compilar solo subscriber UDP
sub_udp: $(SUB_BIN)

# Compilar el trío QUIC completo
quic: $(QBRK_BIN) $(QPUB_BIN) $(QSUB_BIN)
	@echo ""
	@echo "Compilacion QUIC exitosa:"
	@echo "  $(QBRK_BIN)  <- broker QUIC       (puerto: $(PORT_QUIC))"
	@echo "  $(QPUB_BIN)  <- publisher QUIC"
	@echo "  $(QSUB_BIN)  <- subscriber QUIC"

# ── broker_tcp ───────────────────────────────────────────────
$(TCP_BIN): $(TCP_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(TCP_OBJ): $(TCP_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

$(TCP_PUB_BIN): $(TCP_PUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(TCP_PUB_OBJ): $(TCP_PUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

$(TCP_SUB_BIN): $(TCP_SUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(TCP_SUB_OBJ): $(TCP_SUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

# ── broker_udp ───────────────────────────────────────────────
$(UDP_BIN): $(UDP_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(UDP_OBJ): $(UDP_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

$(UDP_PUB_BIN): $(UDP_PUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(UDP_PUB_OBJ): $(UDP_PUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

# ── subscriber_udp ───────────────────────────────────────────
$(SUB_BIN): $(SUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(SUB_OBJ): $(SUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

# ── Compilar QUIC ────────────────────────────────────────────
$(QBRK_BIN): $(QBRK_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(QBRK_OBJ): $(QBRK_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

$(QPUB_BIN): $(QPUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(QPUB_OBJ): $(QPUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

$(QSUB_BIN): $(QSUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(QSUB_OBJ): $(QSUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

# ── Ejecutar TCP/UDP ──────────────────────────────────────────
run_tcp: $(TCP_BIN)
	@echo "Iniciando Broker TCP en puerto $(PORT_TCP) ..."
	$(TCP_BIN) $(PORT_TCP)

run_pub_tcp: $(TCP_PUB_BIN)
	@echo "Publisher TCP → $(BROKER_IP):$(PORT_TCP) tema=$(TOPIC)"
	$(TCP_PUB_BIN) $(BROKER_IP) $(PORT_TCP) $(TOPIC)

run_sub_tcp: $(TCP_SUB_BIN)
	@echo "Subscriber TCP → $(BROKER_IP):$(PORT_TCP) tema=$(TOPIC)"
	$(TCP_SUB_BIN) $(BROKER_IP) $(PORT_TCP) $(TOPIC)

run_udp: $(UDP_BIN)
	@echo "Iniciando Broker UDP en puerto $(PORT_UDP) ..."
	$(UDP_BIN) $(PORT_UDP)

run_pub_udp: $(UDP_PUB_BIN)
	@echo "Publisher UDP → $(BROKER_IP):$(PORT_UDP) tema=$(TOPIC)"
	$(UDP_PUB_BIN) $(BROKER_IP) $(PORT_UDP) $(TOPIC)

run_sub1: $(SUB_BIN)
	@echo "Iniciando Suscriptor UDP 1 (mi_puerto=$(PORT_SUB1), tema=$(TOPIC)) ..."
	$(SUB_BIN) $(BROKER_IP) $(PORT_UDP) $(PORT_SUB1) $(TOPIC)

run_sub2: $(SUB_BIN)
	@echo "Iniciando Suscriptor UDP 2 (mi_puerto=$(PORT_SUB2), tema=$(TOPIC)) ..."
	$(SUB_BIN) $(BROKER_IP) $(PORT_UDP) $(PORT_SUB2) $(TOPIC)

# ── Ejecutar QUIC ─────────────────────────────────────────────
run_broker_quic: $(QBRK_BIN)
	@echo "Iniciando Broker QUIC en puerto $(PORT_QUIC) ..."
	$(QBRK_BIN) $(PORT_QUIC)

run_pub_quic: $(QPUB_BIN)
	@echo "Iniciando Publisher QUIC (broker=$(BROKER_IP):$(PORT_QUIC), tema=$(TOPIC)) ..."
	$(QPUB_BIN) $(BROKER_IP) $(PORT_QUIC) $(TOPIC)

run_sub_quic1: $(QSUB_BIN)
	@echo "Iniciando Suscriptor QUIC 1 (mi_puerto=$(PORT_QSUB1), tema=$(TOPIC)) ..."
	$(QSUB_BIN) $(BROKER_IP) $(PORT_QUIC) $(PORT_QSUB1) $(TOPIC)

run_sub_quic2: $(QSUB_BIN)
	@echo "Iniciando Suscriptor QUIC 2 (mi_puerto=$(PORT_QSUB2), tema=$(TOPIC)) ..."
	$(QSUB_BIN) $(BROKER_IP) $(PORT_QUIC) $(PORT_QSUB2) $(TOPIC)

# ── Limpiar ──────────────────────────────────────────────────
clean:
	$(RM) $(TCP_OBJ) $(TCP_PUB_OBJ) $(TCP_SUB_OBJ) \
	      $(UDP_OBJ) $(UDP_PUB_OBJ) $(SUB_OBJ) \
	      $(QBRK_OBJ) $(QPUB_OBJ) $(QSUB_OBJ) \
	      $(TCP_BIN) $(TCP_PUB_BIN) $(TCP_SUB_BIN) \
	      $(UDP_BIN) $(UDP_PUB_BIN) $(SUB_BIN) \
	      $(QBRK_BIN) $(QPUB_BIN) $(QSUB_BIN)
	@echo "Limpieza completada."
