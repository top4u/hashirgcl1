#!/bin/bash

clear
echo "NoMachine Cloud Shell Tunnel (Extended)"
echo "No authtoken required"
echo "======================================"

NX_PORT=4000
VNC_PORT=5900
LIMIT=43200

NX_LOG="pinggy_nx.log"
VNC_LOG="pinggy_vnc.log"

# Cleanup old containers
docker rm -f nomachine-xfce4 >/dev/null 2>&1

echo "Starting NoMachine container..."

docker run --rm -d --network host --privileged \
  --name nomachine-xfce4 \
  -e PASSWORD=123456 \
  -e USER=user \
  --cap-add=SYS_PTRACE \
  --shm-size=1g \
  thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1

sleep 6

start_nx_tunnel() {
    pkill -f "R0:localhost:$NX_PORT" >/dev/null 2>&1
    rm -f $NX_LOG

    ssh -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -p 443 \
        -R0:localhost:$NX_PORT \
        a.pinggy.io > $NX_LOG 2>&1 &

    sleep 8
}

start_vnc_tunnel() {
    pkill -f "R0:localhost:$VNC_PORT" >/dev/null 2>&1
    rm -f $VNC_LOG

    ssh -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -p 443 \
        -R0:localhost:$VNC_PORT \
        a.pinggy.io > $VNC_LOG 2>&1 &

    sleep 8
}

get_nx_ip() {
    grep -o 'tcp://[^ ]*' $NX_LOG | head -n1 | sed 's/tcp:\/\///'
}

get_vnc_ip() {
    grep -o 'tcp://[^ ]*' $VNC_LOG | head -n1 | sed 's/tcp:\/\///'
}

nx_alive() {
    pgrep -f "R0:localhost:$NX_PORT" >/dev/null
}

vnc_alive() {
    pgrep -f "R0:localhost:$VNC_PORT" >/dev/null
}

echo "Starting tunnels..."
start_nx_tunnel
start_vnc_tunnel

NX_HOST=$(get_nx_ip)
VNC_HOST=$(get_vnc_ip)

clear
echo "======================================"
echo "Tunnel Ready"
echo "======================================"
echo ""
echo "NoMachine:"
echo "$NX_HOST"
echo "Port: $NX_PORT"
echo ""
echo "VNC:"
echo "$VNC_HOST"
echo "Port: $VNC_PORT"
echo ""
echo "User: user"
echo "Pass: 123456"
echo ""
echo "======================================"

SECONDS=0

while [ $SECONDS -lt $LIMIT ]; do

    if ! nx_alive; then
        echo ""
        echo "Restarting NoMachine tunnel..."
        start_nx_tunnel
        NX_HOST=$(get_nx_ip)
        echo "New NX Host: $NX_HOST"
    fi

    if ! vnc_alive; then
        echo ""
        echo "Restarting VNC tunnel..."
        start_vnc_tunnel
        VNC_HOST=$(get_vnc_ip)
        echo "New VNC Host: $VNC_HOST"
    fi

    printf "\rRunning: %d / %d | NX: %s" $SECONDS $LIMIT "$NX_HOST"
    sleep 5

done

echo ""
echo "Session finished"
