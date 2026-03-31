#!/bin/bash
# Envía varios mensajes de ejemplo al broker TCP (tema partidoA) para capturas del informe.
# Uso (dentro del contenedor, con broker y suscriptores ya en marcha):
#   ./feed_tcp_pub_partidoA.sh
# Requiere: bin/publisher_tcp, broker en 127.0.0.1:9000
set -e
cd "$(dirname "$0")"
BROKER_IP="${BROKER_IP:-127.0.0.1}"
PORT="${PORT_TCP:-9000}"
TOPIC="partidoA"

if [[ ! -x bin/publisher_tcp ]]; then
  echo "Falta bin/publisher_tcp — ejecuta: make tcp"
  exit 1
fi

delay() { sleep "${1:-0.35}"; }

{
  echo "Inicio del partido: Equipo A vs Equipo B."
  delay
  echo "Gol de Equipo A al minuto 12"
  delay
  echo "Tiro de esquina a favor de Equipo B"
  delay
  echo "Gol de Equipo A al minuto 32"
  delay
  echo "Cambio: jugador 10 entra por jugador 20"
  delay
  echo "Tarjeta amarilla al número 10 de Equipo B"
  delay
  echo "Lesión: sale el arquero de Equipo B por molestias"
  delay
  echo "Gol anulado por fuera de juego — Equipo A"
  delay
  echo "Penalti a favor de Equipo A — convertido, minuto 78"
  delay
  echo "Cambio doble en Equipo A: entran 14 y 7, salen 9 y 11"
  delay
  echo "Tarjeta roja directa al número 4 de Equipo B"
  delay
  echo "Final del partido: victoria de Equipo A"
} | ./bin/publisher_tcp "$BROKER_IP" "$PORT" "$TOPIC"
