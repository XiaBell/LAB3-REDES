# =============================================================
# Makefile – Brokers + Subscriber Assembly x86-64 (NASM + ld)
# Laboratorio 3: Análisis Capa de Transporte y Sockets
#
# Uso:
#   make              → compila todo (brokers + subscriber)
#   make tcp          → compila solo broker_tcp
#   make udp          → compila solo broker_udp
#   make sub_udp      → compila solo subscriber_udp
#   make clean        → elimina objetos y binarios
#   make run_tcp      → ejecuta broker TCP en puerto 9000
#   make run_udp      → ejecuta broker UDP en puerto 9001
#   make run_sub1     → ejecuta suscriptor 1 (puerto 9100, tema partido1)
#   make run_sub2     → ejecuta suscriptor 2 (puerto 9101, tema partido1)
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

# Fuentes y binarios
TCP_SRC  = $(SRCDIR)/broker_tcp.asm
UDP_SRC  = $(SRCDIR)/broker_udp.asm
SUB_SRC  = $(SRCDIR)/subscriber_udp.asm
TCP_OBJ  = $(OBJDIR)/broker_tcp.o
UDP_OBJ  = $(OBJDIR)/broker_udp.o
SUB_OBJ  = $(OBJDIR)/subscriber_udp.o
TCP_BIN  = $(BINDIR)/broker_tcp
UDP_BIN  = $(BINDIR)/broker_udp
SUB_BIN  = $(BINDIR)/subscriber_udp

# Puertos por defecto
PORT_TCP  = 9000
PORT_UDP  = 9001
PORT_SUB1 = 9100
PORT_SUB2 = 9101
BROKER_IP = 127.0.0.1
TOPIC     = partido1

# =============================================================
# Reglas
# =============================================================

.PHONY: all tcp udp sub_udp clean run_tcp run_udp run_sub1 run_sub2

# Compilar todo
all: $(TCP_BIN) $(UDP_BIN) $(SUB_BIN)
	@echo ""
	@echo "Compilacion exitosa:"
	@echo "  $(TCP_BIN)  <- broker TCP        (puerto: $(PORT_TCP))"
	@echo "  $(UDP_BIN)  <- broker UDP        (puerto: $(PORT_UDP))"
	@echo "  $(SUB_BIN)  <- subscriber UDP"

# Compilar solo TCP
tcp: $(TCP_BIN)

# Compilar solo UDP
udp: $(UDP_BIN)

# Compilar solo subscriber UDP
sub_udp: $(SUB_BIN)

# ── broker_tcp ───────────────────────────────────────────────
$(TCP_BIN): $(TCP_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(TCP_OBJ): $(TCP_SRC)
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

# ── subscriber_udp ───────────────────────────────────────────
$(SUB_BIN): $(SUB_OBJ)
	$(LD) $(LDFLAGS) -o $@ $<
	@echo "[ld]   $< -> $@"

$(SUB_OBJ): $(SUB_SRC)
	@mkdir -p $(OBJDIR)
	$(ASM) $(ASMFLAGS) -o $@ $<
	@echo "[nasm] $< -> $@"

# ── Ejecutar ─────────────────────────────────────────────────
run_tcp: $(TCP_BIN)
	@echo "Iniciando Broker TCP en puerto $(PORT_TCP) ..."
	$(TCP_BIN) $(PORT_TCP)

run_udp: $(UDP_BIN)
	@echo "Iniciando Broker UDP en puerto $(PORT_UDP) ..."
	$(UDP_BIN) $(PORT_UDP)

run_sub1: $(SUB_BIN)
	@echo "Iniciando Suscriptor UDP 1 (mi_puerto=$(PORT_SUB1), tema=$(TOPIC)) ..."
	$(SUB_BIN) $(BROKER_IP) $(PORT_UDP) $(PORT_SUB1) $(TOPIC)

run_sub2: $(SUB_BIN)
	@echo "Iniciando Suscriptor UDP 2 (mi_puerto=$(PORT_SUB2), tema=$(TOPIC)) ..."
	$(SUB_BIN) $(BROKER_IP) $(PORT_UDP) $(PORT_SUB2) $(TOPIC)

# ── Limpiar ──────────────────────────────────────────────────
clean:
	$(RM) $(TCP_OBJ) $(UDP_OBJ) $(SUB_OBJ) $(TCP_BIN) $(UDP_BIN) $(SUB_BIN)
	@echo "Limpieza completada."
