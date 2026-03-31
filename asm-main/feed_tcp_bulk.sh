#!/bin/bash
# Envia N mensajes de prueba por TCP hacia publisher_tcp (stdin -> broker).
# Uso:
#   ./feed_tcp_bulk.sh                 # 1000 mensajes, tema partidoA
#   ./feed_tcp_bulk.sh 2000 partidoB   # 2000 mensajes, tema partidoB
# Variables opcionales:
#   BROKER_IP (default 127.0.0.1), PORT_TCP (default 9000), FEED_DELAY (default 0.0)
set -euo pipefail

cd "$(dirname "$0")"

COUNT="${1:-1000}"
TOPIC="${2:-partidoA}"
BROKER_IP="${BROKER_IP:-127.0.0.1}"
PORT="${PORT_TCP:-9000}"
DELAY="${FEED_DELAY:-0.01}"

if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -le 0 ]]; then
  echo "COUNT invalido: '$COUNT' (usa entero > 0)" >&2
  exit 1
fi

if [[ ! -x bin/publisher_tcp ]]; then
  echo "Falta bin/publisher_tcp. Ejecuta: make tcp" >&2
  exit 1
fi

send_stream() {
  local i
  for ((i = 1; i <= COUNT; i++)); do
    echo "Prueba TCP mensaje $i/$COUNT - carga automatizada"
    if [[ "$DELAY" != "0" && "$DELAY" != "0.0" ]]; then
      sleep "$DELAY"
    fi
  done
}

echo "[feed_tcp_bulk] Enviando $COUNT mensajes a $BROKER_IP:$PORT tema='$TOPIC'" >&2
send_stream | ./bin/publisher_tcp "$BROKER_IP" "$PORT" "$TOPIC"
echo "[feed_tcp_bulk] Listo." >&2

