#!/bin/bash

clear
echo "NoMachine Cloud Shell Tunnel"
echo "Using Pinggy TCP"
echo "======================================"

PORT=4000
LOGFILE="pinggy.log"
LIMIT=43200

echo "[1/3] Starting container..."

docker rm -f nomachine-xfce4 >/dev/null 2>&1

docker run --rm -d --network host --privileged \
  --name nomachine-xfce4 \
  -e PASSWORD=123456 \
  -e USER=user \
  --cap-add=SYS_PTRACE \
  --shm-size=1g \
  thuonghai2711/nomachine-ubuntu-desktop:wine

sleep 5

echo "[2/3] Starting tunnel..."

rm -f $LOGFILE

ssh -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -p 443 \
    -R0:localhost:$PORT \
    tcp@a.pinggy.io > $LOGFILE 2>&1 &

echo "Waiting for tunnel..."

TUNNEL=""

for i in {1..30}
do
    TUNNEL=$(grep -Eo 'tcp://[^ ]+' $LOGFILE | head -n1 | sed 's/tcp:\/\///')

    if [ ! -z "$TUNNEL" ]; then
        break
    fi

    echo "Attempt $i..."
    sleep 2
done

if [ -z "$TUNNEL" ]; then
    echo ""
    echo "Tunnel failed"
    cat $LOGFILE
    exit 1
fi

clear
echo "======================================"
echo "Tunnel Ready"
echo "======================================"
echo ""
echo "Host:"
echo "$TUNNEL"
echo ""
echo "User: user"
echo "Pass: 123456"
echo "Port: auto"
echo ""
echo "======================================"

SECONDS=0

while [ $SECONDS -lt $LIMIT ]
do
    printf "\rRunning: %d / %d | %s" $SECONDS $LIMIT "$TUNNEL"
    sleep 5
done

echo ""
echo "Finished"
