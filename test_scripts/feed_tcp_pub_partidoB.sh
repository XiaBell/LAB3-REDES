#!/bin/bash
# Envía varios mensajes de ejemplo al broker TCP (tema partidoB) para capturas del informe.
# Uso (dentro del contenedor, con broker y suscriptores ya en marcha):
#   ./feed_tcp_pub_partidoB.sh
# Requiere: bin/publisher_tcp, broker en 127.0.0.1:9000
set -e
cd "$(dirname "$0")"
BROKER_IP="${BROKER_IP:-127.0.0.1}"
PORT="${PORT_TCP:-9000}"
TOPIC="partidoB"

if [[ ! -x bin/publisher_tcp ]]; then
  echo "Falta bin/publisher_tcp — ejecuta: make tcp"
  exit 1
fi

delay() { sleep "${1:-0.35}"; }

{
  echo "Arranca el clásico: Equipo C recibe a Equipo D."
  delay
  echo "Primera llegada clara: remate desviado de Equipo D"
  delay
  echo "Gol de Equipo C al minuto 19"
  delay
  echo "Var revisa posible penalti — se mantiene la jugada"
  delay
  echo "Cambio: jugador 8 entra por jugador 22 en Equipo D"
  delay
  echo "Tarjeta amarilla al número 5 de Equipo C"
  delay
  echo "Gol de Equipo D al minuto 44+2"
  delay
  echo "Descanso: empate 1-1"
  delay
  echo "Gol de Equipo C de cabeza al minuto 61"
  delay
  echo "Cambio táctico en Equipo D: línea de cinco defensas"
  delay
  echo "Tarjeta amarilla al número 10 de Equipo D — se pierde la final"
  delay
  echo "Silbatazo final: empate 2-2"
} | ./bin/publisher_tcp "$BROKER_IP" "$PORT" "$TOPIC"
