#!/bin/bash

clear
echo "NoMachine + VNC Cloud Shell Tunnel (Auto-Reconnect + Terminal + Telegram Alerts)"
echo "==============================================================================="

# Ports (fixed on your side)
NX_PORT=4000
VNC_PORT=5900

# Log files
NX_LOG="pinggy_nx.log"
VNC_LOG="pinggy_vnc.log"

# Total runtime (12 hours)
LIMIT=43200  # seconds

# Expected Pinggy 1-hour window (when new IP is likely)
IP_WINDOW=3600  # seconds

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

# Small spinner for progress feedback
spinner() {
    local pid=$1
    local message="$2"
    local delay=0.15
    local spin='-\|/'

    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r%s %s" "$message" "${spin:$i:1}"
        sleep $delay
    done
    printf "\r%s ... done.\n" "$message"
}

start_nomachine() {
    (
        docker rm -f nomachine-xfce4 >/dev/null 2>&1
        docker run --rm -d --network host --privileged \
          --name nomachine-xfce4 \
          -e PASSWORD=123456 \
          -e USER=user \
          --cap-add=SYS_PTRACE \
          --shm-size=1g \
          thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1
        # Give container a little time to settle
        sleep 5
    ) &
    spinner $! "Step 1/3: Starting NoMachine container"
}

start_tunnel() {
    local port=$1
    local logfile=$2

    (
        pkill -f "R0:localhost:$port" >/dev/null 2>&1
        rm -f "$logfile"

        ssh -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -p 443 \
            -R0:localhost:$port \
            tcp@a.pinggy.io > "$logfile" 2>&1 &
        # Let ssh spawn properly
        sleep 5
    ) &
    spinner $! "Step 2/3: Starting Pinggy tunnel for port $port"
}

get_tunnel_host() {
    local logfile=$1
    grep -Eo 'tcp://[^ ]+' "$logfile" | tail -n1 | sed 's|tcp://||'
}

tunnel_alive() {
    local port=$1
    pgrep -f "R0:localhost:$port" >/dev/null
}

format_time() {
    local seconds=$1
    local h=$((seconds / 3600))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$((seconds % 60))
    printf "%02dh:%02dm:%02ds" "$h" "$m" "$s"
}

print_status() {
    local seconds=$1
    local limit=$2
    local nx_host=$3
    local nx_port=$4
    local vnc_host=$5
    local vnc_port=$6

    local elapsed=$seconds
    local remaining=$((limit - elapsed))
    [ $remaining -lt 0 ] && remaining=0

    # Time until next “IP window”
    local since_last_window=$((elapsed % IP_WINDOW))
    local until_next_window=$((IP_WINDOW - since_last_window))
    if [ $until_next_window -gt $remaining ]; then
        until_next_window=$remaining
    fi

    clear
    echo "==============================================================================="

    echo "Cloud Shell: NoMachine + VNC (Auto-Reconnect)"
    echo "-------------------------------------------------------------------------------"
    echo "Total Runtime:  $(format_time "$elapsed")  /  $(format_time "$limit")"
    echo "Next IP window in: $(format_time "$until_next_window")"
    echo "  (When Pinggy may rotate the tunnel and a NEW host:port will be shown)"
    echo "==============================================================================="

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
    echo "==============================================================================="
    echo "Notes:"
    echo "  - If your connection drops around the IP window time, check here or Telegram"
    echo "    for the NEW host:port."
    echo "  - Your desktop session & files stay the same; only the tunnel changes."
    echo "==============================================================================="
}

# ---- MAIN ----

# Step 1: Start NoMachine container with progress feedback
start_nomachine

# Step 2: Start tunnels (NoMachine + VNC) with visible progress
start_tunnel "$NX_PORT" "$NX_LOG"
start_tunnel "$VNC_PORT" "$VNC_LOG"

# Step 3: Waiting for tunnel assignment
echo "Step 3/3: Waiting for tunnel host assignment..."

NX_HOST=""
VNC_HOST=""

for i in {1..20}; do
    NX_HOST=$(get_tunnel_host "$NX_LOG")
    VNC_HOST=$(get_tunnel_host "$VNC_LOG")

    if [ -n "$NX_HOST" ] && [ -n "$VNC_HOST" ]; then
        echo "Step 3/3: Tunnel hosts assigned."
        break
    fi

    printf "\rStep 3/3: Waiting for tunnel host assignment (attempt %d/20)..." "$i"
    sleep 2
done
echo ""

if [ -z "$NX_HOST" ] || [ -z "$VNC_HOST" ]; then
    echo "Failed to start tunnels!"
    echo "---- NX LOG ----"
    [ -f "$NX_LOG" ] && cat "$NX_LOG"
    echo "---- VNC LOG ----"
    [ -f "$VNC_LOG" ] && cat "$VNC_LOG"
    exit 1
fi

# Initial notification (no previous host)
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
        echo ""
        echo "[Pinggy] NoMachine tunnel expired. Reconnecting..."
        start_tunnel "$NX_PORT" "$NX_LOG"

        # Wait for a different host, if possible
        for j in {1..20}; do
            NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")
            if [ -n "$NEW_NX_HOST" ] && [ "$NEW_NX_HOST" != "$OLD_NX_HOST" ]; then
                break
            fi
            sleep 2
        done
        [ -z "$NEW_NX_HOST" ] && NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")

        NX_HOST="$NEW_NX_HOST"
        notify_user "NoMachine" "$OLD_NX_HOST" "$NX_PORT" "$NX_HOST" "$NX_PORT"
        OLD_NX_HOST="$NX_HOST"
    fi

    # Check VNC tunnel
    if ! tunnel_alive "$VNC_PORT"; then
        echo ""
        echo "[Pinggy] VNC tunnel expired. Reconnecting..."
        start_tunnel "$VNC_PORT" "$VNC_LOG"

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

    # Refresh status with remaining time + next IP window
    print_status "$SECONDS" "$LIMIT" "$NX_HOST" "$NX_PORT" "$VNC_HOST" "$VNC_PORT"

    sleep 5
done

echo ""
echo "[Script] 12-hour session finished."
