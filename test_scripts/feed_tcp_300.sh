#!/bin/bash
# Envía 300 mensajes de prueba al broker TCP (mismo formato PUB|tema|cuerpo).
# Uso (dentro del contenedor, broker en marcha):
#   ./feed_tcp_300.sh              → tema partidoA, puerto 9000
#   ./feed_tcp_300.sh partidoB     → otro tema
# Variables opcionales: BROKER_IP (default 127.0.0.1), PORT_TCP (default 9000)
set -e
cd "$(dirname "$0")"
BROKER_IP="${BROKER_IP:-127.0.0.1}"
PORT="${PORT_TCP:-9000}"
TOPIC="${1:-partidoA}"

if [[ ! -x bin/publisher_tcp ]]; then
  echo "Falta bin/publisher_tcp — ejecuta: make tcp"
  exit 1
fi

DELAY="${FEED_DELAY:-0.05}"

delay() { sleep "$DELAY"; }

{
  for i in $(seq 1 300); do
    echo "Prueba TCP mensaje $i/300 — evento de prueba automatizado"
    delay
  done
} | ./bin/publisher_tcp "$BROKER_IP" "$PORT" "$TOPIC"

echo "[feed_tcp_300] Listo: 300 mensajes enviados al tema $TOPIC" >&2
