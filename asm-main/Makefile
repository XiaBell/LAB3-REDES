# =============================================================
# Makefile – Brokers Assembly x86-64 (NASM + ld)
# Laboratorio 3: Análisis Capa de Transporte y Sockets
#
# Uso:
#   make          → compila todos los brokers
#   make tcp      → compila solo broker_tcp
#   make udp      → compila solo broker_udp
#   make clean    → elimina objetos y binarios
#   make run_tcp  → ejecuta broker TCP en puerto 9000
#   make run_udp  → ejecuta broker UDP en puerto 9001
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
TCP_OBJ  = $(OBJDIR)/broker_tcp.o
UDP_OBJ  = $(OBJDIR)/broker_udp.o
TCP_BIN  = $(BINDIR)/broker_tcp
UDP_BIN  = $(BINDIR)/broker_udp

# Puertos por defecto
PORT_TCP = 9000
PORT_UDP = 9001

# =============================================================
# Reglas
# =============================================================

.PHONY: all tcp udp clean run_tcp run_udp

# Compilar todo
all: $(TCP_BIN) $(UDP_BIN)
	@echo ""
	@echo "Compilacion exitosa:"
	@echo "  $(TCP_BIN)  <- broker TCP  (puerto recomendado: $(PORT_TCP))"
	@echo "  $(UDP_BIN)  <- broker UDP  (puerto recomendado: $(PORT_UDP))"

# Compilar solo TCP
tcp: $(TCP_BIN)

# Compilar solo UDP
udp: $(UDP_BIN)

# ── broker_tcp ───────────────────────────────────────────────
# Paso 1: nasm ensambla el .asm → .o (ELF relocatable)
# Paso 2: ld enlaza el .o → ejecutable ELF64 sin dependencias externas
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

# ── Ejecutar ─────────────────────────────────────────────────
run_tcp: $(TCP_BIN)
	@echo "Iniciando Broker TCP en puerto $(PORT_TCP) ..."
	$(TCP_BIN) $(PORT_TCP)

run_udp: $(UDP_BIN)
	@echo "Iniciando Broker UDP en puerto $(PORT_UDP) ..."
	$(UDP_BIN) $(PORT_UDP)

# ── Limpiar ──────────────────────────────────────────────────
clean:
	$(RM) $(TCP_OBJ) $(UDP_OBJ) $(TCP_BIN) $(UDP_BIN)
	@echo "Limpieza completada."
