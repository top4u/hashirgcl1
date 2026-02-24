#!/bin/bash

clear
echo "NoMachine + VNC Cloud Shell Tunnel (Auto-Reconnect + Terminal + Telegram Sound Alerts)"
echo "======================================"

# Ports
NX_PORT=4000
VNC_PORT=5900

# Log files
NX_LOG="pinggy_nx.log"
VNC_LOG="pinggy_vnc.log"

# Total runtime (12 hours)
LIMIT=43200

# Telegram settings
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

# Function to send Telegram message
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" >/dev/null 2>&1
}

# Function to print and notify user in terminal with beep
notify_user() {
    local service=$1
    local host=$2
    local port=$3
    echo -e "\n\033[1;33m[$service] New tunnel assigned: $host:$port\a\033[0m"
    send_telegram "$service tunnel reconnected!\nNew Host: $host:$port\nUser: user\nPass: 123456"
}

# Start NoMachine container
start_nomachine() {
    docker rm -f nomachine-xfce4 >/dev/null 2>&1
    docker run --rm -d --network host --privileged \
      --name nomachine-xfce4 \
      -e PASSWORD=123456 \
      -e USER=user \
      --cap-add=SYS_PTRACE \
      --shm-size=1g \
      thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1
    echo "[NoMachine] Container started"
    sleep 5
}

# Start Pinggy tunnel
start_tunnel() {
    local port=$1
    local logfile=$2
    pkill -f "R0:localhost:$port" >/dev/null 2>&1
    rm -f $logfile
    ssh -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -p 443 \
        -R0:localhost:$port \
        tcp@a.pinggy.io > $logfile 2>&1 &
    echo "[Pinggy] Tunnel for port $port starting..."
    sleep 5
}

# Get tunnel host from log
get_tunnel_host() {
    local logfile=$1
    grep -Eo 'tcp://[^ ]+' "$logfile" | head -n1 | sed 's/tcp:\/\///'
}

# Check if tunnel alive
tunnel_alive() {
    local port=$1
    pgrep -f "R0:localhost:$port" >/dev/null
}

# Start NoMachine container
start_nomachine

# Start initial tunnels
start_tunnel $NX_PORT $NX_LOG
start_tunnel $VNC_PORT $VNC_LOG

# Wait for tunnels to get first host
NX_HOST=""
VNC_HOST=""
for i in {1..20}; do
    NX_HOST=$(get_tunnel_host $NX_LOG)
    VNC_HOST=$(get_tunnel_host $VNC_LOG)
    if [ ! -z "$NX_HOST" ] && [ ! -z "$VNC_HOST" ]; then break; fi
    echo "[Pinggy] Waiting for tunnels... attempt $i"
    sleep 2
done

if [ -z "$NX_HOST" ] || [ -z "$VNC_HOST" ]; then
    echo "Failed to start tunnels!"
    cat $NX_LOG
    cat $VNC_LOG
    exit 1
fi

# Initial notification
notify_user "NoMachine" "$NX_HOST" "$NX_PORT"
notify_user "VNC" "$VNC_HOST" "$VNC_PORT"

clear
echo "======================================"
echo "Tunnels Ready!"
echo "NoMachine Host: $NX_HOST"
echo "Port: $NX_PORT"
echo "User: user"
echo "Pass: 123456"
echo ""
echo "VNC Host: $VNC_HOST"
echo "Port: $VNC_PORT"
echo "User: user"
echo "Pass: 123456"
echo "======================================"

# Auto-reconnect loop
SECONDS=0
while [ $SECONDS -lt $LIMIT ]; do

    # NoMachine tunnel
    if ! tunnel_alive $NX_PORT; then
        echo ""
        echo "[Pinggy] NoMachine tunnel expired. Reconnecting..."
        start_tunnel $NX_PORT $NX_LOG
        NX_HOST=$(get_tunnel_host $NX_LOG)
        notify_user "NoMachine" "$NX_HOST" "$NX_PORT"
    fi

    # VNC tunnel
    if ! tunnel_alive $VNC_PORT; then
        echo ""
        echo "[Pinggy] VNC tunnel expired. Reconnecting..."
        start_tunnel $VNC_PORT $VNC_LOG
        VNC_HOST=$(get_tunnel_host $VNC_LOG)
        notify_user "VNC" "$VNC_HOST" "$VNC_PORT"
    fi

    # Show live status
    printf "\rRunning: %d / %d | NX: %s | VNC: %s" $SECONDS $LIMIT "$NX_HOST" "$VNC_HOST"
    sleep 5
done

echo ""
echo "[Script] 12-hour session finished."
