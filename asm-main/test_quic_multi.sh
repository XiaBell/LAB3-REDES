#!/bin/bash
# Prueba: 1 broker QUIC, 2 suscriptores y 2 publicadores (mismo tema).
# Cumple escenario tipo lab (varios procesos simultaneos). Requiere `make quic`.
set -e
cd "$(dirname "$0")"

for b in bin/broker_quic bin/subscriber_quic bin/publisher_quic; do
  if [[ ! -x "$b" ]]; then
    echo "Falta $b — ejecuta: make quic"
    exit 1
  fi
done

pkill -f 'broker_quic ' 2>/dev/null || true
pkill -f 'subscriber_quic ' 2>/dev/null || true
sleep 0.4

BPORT=9002
TOPIC="partido-demo"

./bin/broker_quic "$BPORT" > /tmp/qbrk.log 2>&1 &
BRK=$!
sleep 0.5

./bin/subscriber_quic 127.0.0.1 "$BPORT" 9200 "$TOPIC" > /tmp/qsub1.log 2>&1 &
S1=$!
./bin/subscriber_quic 127.0.0.1 "$BPORT" 9201 "$TOPIC" > /tmp/qsub2.log 2>&1 &
S2=$!
sleep 0.5

# Dos publicadores al mismo tema: lineas alternas (cada uno >= 5 mensajes)
( for i in 1 2 3 4 5; do echo "PUB-A evento-$i"; sleep 0.15; done ) \
  | ./bin/publisher_quic 127.0.0.1 "$BPORT" "$TOPIC" > /tmp/qpubA.log 2>&1 &
PA=$!

( for i in 1 2 3 4 5; do echo "PUB-B evento-$i"; sleep 0.15; done ) \
  | ./bin/publisher_quic 127.0.0.1 "$BPORT" "$TOPIC" > /tmp/qpubB.log 2>&1 &
PB=$!

wait $PA $PB
sleep 1

kill $S1 $S2 $BRK 2>/dev/null || true
wait $S1 2>/dev/null || true
wait $S2 2>/dev/null || true
wait $BRK 2>/dev/null || true

echo "=== Broker (ultimas 25 lineas) ==="
tail -25 /tmp/qbrk.log
echo "=== Suscriptor 1 (seq / orden) ==="
grep -E 'seq=|\(en orden\)|AVISO' /tmp/qsub1.log || cat /tmp/qsub1.log
echo "=== Suscriptor 2 ==="
grep -E 'seq=|\(en orden\)|AVISO' /tmp/qsub2.log || cat /tmp/qsub2.log
echo "=== Publicador A ==="
tail -8 /tmp/qpubA.log
echo "=== Publicador B ==="
tail -8 /tmp/qpubB.log
