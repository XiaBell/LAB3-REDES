#!/bin/bash
# Prueba mínima UDP: broker + un suscriptor; los PUB los manda netcat (no usa publisher_udp).
# Requisitos: make udp (o al menos broker_udp + subscriber_udp), comando nc.
# Ejecutar desde asm-main/: ./test_sub.sh
cd "$(dirname "$0")"

pkill -f broker_udp 2>/dev/null
pkill -f subscriber_udp 2>/dev/null
sleep 0.5

./bin/broker_udp 9001 > /tmp/broker_out.txt 2>&1 &
BROKER_PID=$!
sleep 1

./bin/subscriber_udp 127.0.0.1 9001 9100 partido1 > /tmp/sub_out.txt 2>&1 &
SUB_PID=$!
sleep 1

# Enviar PUB con nc (UDP, con newline al final)
printf 'PUB|partido1|Gol de Messi en el minuto 90!\n' | nc -u -w1 127.0.0.1 9001
sleep 0.5
printf 'PUB|partido1|Tarjeta roja!\n' | nc -u -w1 127.0.0.1 9001
sleep 1

kill $SUB_PID 2>/dev/null
kill $BROKER_PID 2>/dev/null
wait $SUB_PID 2>/dev/null
wait $BROKER_PID 2>/dev/null

echo '=== BROKER ==='
cat /tmp/broker_out.txt
echo '=== SUSCRIPTOR ==='
cat /tmp/sub_out.txt
