#!/bin/bash

clear
echo "NoMachine + VNC Cloud Shell Tunnel (Auto-Reconnect + Terminal + Telegram Alerts)"
echo "======================================"

# Ports (fixed on your side)
NX_PORT=4000
VNC_PORT=5900

# Log files
NX_LOG="pinggy_nx.log"
VNC_LOG="pinggy_vnc.log"

# Total runtime (12 hours)
LIMIT=43200  # seconds

# Telegram settings
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

# ---- FUNCTIONS ----

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" >/dev/null 2>&1
}

# Notify in terminal + Telegram
notify_user() {
    local service=$1
    local old_host=$2
    local old_port=$3
    local new_host=$4
    local new_port=$5

    echo ""
    echo -e "\033[1;33m[$service] Tunnel updated!\033[0m"
    if [ -n "$old_host" ]; then
        echo "  Old: $old_host:$old_port"
    fi
    echo "  New: $new_host:$new_port"

    # beep
    echo -ne "\a"

    local msg="$service tunnel reconnected!
New Host: $new_host:$new_port
User: user
Pass: 123456"
    send_telegram "$msg"
}

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

start_tunnel() {
    local port=$1
    local logfile=$2

    # Kill any existing tunnel on this port
    pkill -f "R0:localhost:$port" >/dev/null 2>&1
    rm -f "$logfile"

    # Start new Pinggy tunnel
    ssh -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -p 443 \
        -R0:localhost:$port \
        tcp@a.pinggy.io > "$logfile" 2>&1 &

    echo "[Pinggy] Tunnel for port $port starting..."
    sleep 5
}

get_tunnel_host() {
    local logfile=$1
    # Always take the LAST occurrence = latest tunnel
    grep -Eo 'tcp://[^ ]+' "$logfile" | tail -n1 | sed 's|tcp://||'
}

tunnel_alive() {
    local port=$1
    pgrep -f "R0:localhost:$port" >/dev/null
}

print_status() {
    local seconds=$1
    local limit=$2
    local nx_host=$3
    local nx_port=$4
    local vnc_host=$5
    local vnc_port=$6

    clear
    echo "======================================"
    echo "Tunnels Ready (Auto-Reconnect Enabled)"
    echo "Runtime: $seconds / $limit seconds"
    echo ""
    echo "NoMachine:"
    echo "  Host: $nx_host"
    echo "  Port: $nx_port"
    echo "  User: user"
    echo "  Pass: 123456"
    echo ""
    echo "VNC:"
    echo "  Host: $vnc_host"
    echo "  Port: $vnc_port"
    echo "  User: user"
    echo "  Pass: 123456"
    echo "======================================"
}

# ---- MAIN ----

# Start NoMachine container (desktop/session persists)
start_nomachine

# Start initial tunnels
start_tunnel "$NX_PORT" "$NX_LOG"
start_tunnel "$VNC_PORT" "$VNC_LOG"

# INITIAL HOST RESOLUTION
NX_HOST=""
VNC_HOST=""

for i in {1..20}; do
    NX_HOST=$(get_tunnel_host "$NX_LOG")
    VNC_HOST=$(get_tunnel_host "$VNC_LOG")

    if [ -n "$NX_HOST" ] && [ -n "$VNC_HOST" ]; then
        break
    fi

    echo "[Pinggy] Waiting for tunnels... attempt $i"
    sleep 2
done

if [ -z "$NX_HOST" ] || [ -z "$VNC_HOST" ]; then
    echo "Failed to start tunnels!"
    echo "---- NX LOG ----"
    [ -f "$NX_LOG" ] && cat "$NX_LOG"
    echo "---- VNC LOG ----"
    [ -f "$VNC_LOG" ] && cat "$VNC_LOG"
    exit 1
fi

# Initial notification (no "old" host yet)
notify_user "NoMachine" "" "" "$NX_HOST" "$NX_PORT"
notify_user "VNC" "" "" "$VNC_HOST" "$VNC_PORT"

print_status 0 "$LIMIT" "$NX_HOST" "$NX_PORT" "$VNC_HOST" "$VNC_PORT"

# ---- AUTO-RECONNECT LOOP ----
SECONDS=0
OLD_NX_HOST="$NX_HOST"
OLD_VNC_HOST="$VNC_HOST"

while [ $SECONDS -lt $LIMIT ]; do

    # Check NoMachine tunnel
    if ! tunnel_alive "$NX_PORT"; then
        echo "[Pinggy] NoMachine tunnel expired. Reconnecting..."
        start_tunnel "$NX_PORT" "$NX_LOG"

        # Wait until new host appears in log
        for j in {1..20}; do
            NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")
            if [ -n "$NEW_NX_HOST" ] && [ "$NEW_NX_HOST" != "$OLD_NX_HOST" ]; then
                break
            fi
            sleep 2
        done

        # If still empty, fallback to whatever we found
        [ -z "$NEW_NX_HOST" ] && NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")

        NX_HOST="$NEW_NX_HOST"
        notify_user "NoMachine" "$OLD_NX_HOST" "$NX_PORT" "$NX_HOST" "$NX_PORT"
        OLD_NX_HOST="$NX_HOST"
    fi

    # Check VNC tunnel
    if ! tunnel_alive "$VNC_PORT"; then
        echo "[Pinggy] VNC tunnel expired. Reconnecting..."
        start_tunnel "$VNC_PORT" "$VNC_LOG"

        # Wait until new host appears in log
        for j in {1..20}; do
            NEW_VNC_HOST=$(get_tunnel_host "$VNC_LOG")
            if [ -n "$NEW_VNC_HOST" ] && [ "$NEW_VNC_HOST" != "$OLD_VNC_HOST" ]; then
                break
            fi
            sleep 2
        done

        [ -z "$NEW_VNC_HOST" ] && NEW_VNC_HOST=$(get_tunnel_host "$VNC_LOG")

        VNC_HOST="$NEW_VNC_HOST"
        notify_user "VNC" "$OLD_VNC_HOST" "$VNC_PORT" "$VNC_HOST" "$VNC_PORT"
        OLD_VNC_HOST="$VNC_HOST"
    fi

    # Update single-clear status screen
    print_status "$SECONDS" "$LIMIT" "$NX_HOST" "$NX_PORT" "$VNC_HOST" "$VNC_PORT"

    sleep 5
done

echo ""
echo "[Script] 12-hour session finished."
