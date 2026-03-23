#!/bin/bash
cd "$(dirname "$0")"
pkill -f broker_udp 2>/dev/null; sleep 0.3

strace -e trace=recvfrom -s 200 ./bin/broker_udp 9001 \
    > /tmp/b_out.txt 2> /tmp/b_strace.txt &
BPK=$!
sleep 0.8

printf 'PUB|partido1|Gol!\n' | nc -u -w1 127.0.0.1 9001
sleep 0.5

kill $BPK 2>/dev/null; wait $BPK 2>/dev/null

echo "=== STDOUT ==="
cat /tmp/b_out.txt
echo "=== STRACE (recvfrom) ==="
cat /tmp/b_strace.txt
