#!/bin/bash
# test_udp_10pub.sh
# Prueba UDP: 1 broker + 2 suscriptores + 10 publishers automaticos
cd "$(dirname "$0")"

# ── Limpiar procesos anteriores ────────────────────────────────
pkill -f broker_udp     2>/dev/null
pkill -f subscriber_udp 2>/dev/null
pkill -f publisher_udp  2>/dev/null
sleep 0.5

# ── Broker ─────────────────────────────────────────────────────
echo "[*] Iniciando broker UDP en puerto 9001..."
./bin/broker_udp 9001 > /tmp/broker_udp_out.txt 2>&1 &
BROKER_PID=$!
sleep 1

# ── Suscriptores ───────────────────────────────────────────────
echo "[*] Iniciando suscriptor 1 (puerto 9100, tema: partido1)..."
./bin/subscriber_udp 127.0.0.1 9001 9100 partido1 > /tmp/sub1_udp_out.txt 2>&1 &
SUB1_PID=$!

echo "[*] Iniciando suscriptor 2 (puerto 9101, tema: partido1)..."
./bin/subscriber_udp 127.0.0.1 9001 9101 partido1 > /tmp/sub2_udp_out.txt 2>&1 &
SUB2_PID=$!
sleep 1

# ── 10 Publishers automaticos ──────────────────────────────────
# Sin sleep entre publishers: todos se lanzan al mismo tiempo para
# generar contención real en el broker y forzar desorden UDP.
# Cada publisher manda 5 mensajes seguidos para aumentar la carga.
echo "[*] Lanzando 10 publishers UDP simultaneamente (5 mensajes c/u)..."

# Cronologia del partido: cada publisher cubre una parte del juego
EVENTOS=(
    "Min 1: Pitido inicial, comienza el partido"
    "Min 10: Tiro libre para el equipo local"
    "Min 23: GOL del local! Cabezazo de Martinez"
    "Min 35: Tarjeta amarilla al defensa visitante"
    "Min 45: Penalti a favor del visitante"
    "Min 45+2: GOL del visitante! Empate 1-1"
    "Min 46: Inicio del segundo tiempo"
    "Min 58: Sustitucion: entra Neymar por el local"
    "Min 70: GOL del local! Contragolpe rapido 2-1"
    "Min 90+3: Pitido final, victoria del local 2-1"
)

PUB_PIDS=()
for i in $(seq 0 9); do
    MSG="${EVENTOS[$i]}"
    PUB_NUM=$((i + 1))
    (
        printf '%s\n' "$MSG" | ./bin/publisher_udp 127.0.0.1 9001 partido1
    ) > /tmp/pub${PUB_NUM}_udp_out.txt 2>&1 &
    PUB_PIDS+=($!)
done
echo "[*] 10 publishers lanzados (10 eventos del partido)"

# Esperar a que todos los publishers terminen
for pid in "${PUB_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
done
echo "[*] Todos los publishers finalizaron."

sleep 1

# ── Detener suscriptores y broker ─────────────────────────────
kill $SUB1_PID $SUB2_PID 2>/dev/null
wait $SUB1_PID $SUB2_PID 2>/dev/null
kill $BROKER_PID 2>/dev/null
wait $BROKER_PID 2>/dev/null

# ── Resultados ────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  BROKER UDP"
echo "=========================================="
cat /tmp/broker_udp_out.txt

echo ""
echo "=========================================="
echo "  SUSCRIPTOR 1 (puerto 9100)"
echo "=========================================="
cat /tmp/sub1_udp_out.txt

echo ""
echo "=========================================="
echo "  SUSCRIPTOR 2 (puerto 9101)"
echo "=========================================="
cat /tmp/sub2_udp_out.txt

echo ""
echo "=========================================="
echo "  SALIDA DE PUBLISHERS (1-10)"
echo "=========================================="
for i in $(seq 1 10); do
    echo "--- Publisher $i ---"
    cat /tmp/pub${i}_udp_out.txt
done
