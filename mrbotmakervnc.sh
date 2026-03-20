#!/bin/bash

###############################################################################
# tmux auto-attach / auto-start (for persistence)
###############################################################################

# If not already inside tmux and tmux is available, re-run inside "mrbot-vnc" session
if [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    if [ "$MRBOT_VNC_TMUX_WRAPPED" != "1" ]; then
        export MRBOT_VNC_TMUX_WRAPPED=1

        if tmux has-session -t mrbot-vnc 2>/dev/null; then
            echo "[tmux] Attaching to existing session 'mrbot-vnc'..."
            tmux attach -t mrbot-vnc
            exit 0
        else
            echo "[tmux] Creating new session 'mrbot-vnc' and running this script inside it..."
            tmux new -s mrbot-vnc "bash \"$0\"; echo; echo \"[mrbot-vnc] Script finished. Press ENTER to close tmux window.\"; read"
            exit 0
        fi
    fi
fi

###############################################################################
# MAIN SCRIPT
###############################################################################

clear
echo "VNC Cloud Shell Tunnel (Auto-Reconnect + Telegram Alerts)"
echo "========================================================="
echo "Tip:"
echo "  - This script is tmux-aware."
echo "  - If you started it normally and you see this message, it's already"
echo "    running safely in tmux (session: 'mrbot-vnc') if tmux is installed."
echo "  - You can detach with Ctrl+B then D and it will keep running."
echo "========================================================="

# VNC port inside container/host
VNC_PORT=5900

# Log file for Pinggy
VNC_LOG="pinggy_vnc.log"

# Total runtime (1 month = 30 days)
LIMIT=$((30 * 24 * 3600))   # seconds

# Pinggy window (1 hour)
IP_WINDOW=3600

# Telegram
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

# VNC container image and password
VNC_IMAGE="dorowu/ubuntu-desktop-lxde-vnc"   # change if you want a different VNC image
VNC_PASSWORD="vncpassword"                   # default password for above image

# ---------------- FUNCTIONS ----------------

send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && [ "$TELEGRAM_BOT_TOKEN" != "YOUR_BOT_TOKEN_HERE" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" >/dev/null 2>&1
    fi
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
    echo -ne "\a"

    local msg="$service tunnel reconnected!
New Host: $new_host:$new_port
VNC password: $VNC_PASSWORD"
    send_telegram "$msg"
}

# Minimal spinner (used only BEFORE we print credentials)
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

start_vnc_container() {
    (
        docker rm -f vnc-desktop >/dev/null 2>&1
        docker run -d --rm --network host \
            --name vnc-desktop \
            -e VNC_PASSWORD="$VNC_PASSWORD" \
            "$VNC_IMAGE" >/dev/null 2>&1
        # give it some time to start X+VNC
        sleep 10
    ) &
    spinner $! "Step 1/2: Starting VNC desktop container"
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
        sleep 5
    ) &
    spinner $! "Step 2/2: Starting Pinggy tunnel for port $port"
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
    local d=$((seconds / 86400))
    local h=$(( (seconds % 86400) / 3600 ))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$((seconds % 60))
    if [ $d -gt 0 ]; then
        printf "%dd:%02dh:%02dm:%02ds" "$d" "$h" "$m" "$s"
    else
        printf "%02dh:%02dm:%02ds" "$h" "$m" "$s"
    fi
}

# Prints the static info ONCE (safe to copy)
print_static_info() {
    local vnc_host=$1
    local vnc_port=$2

    echo ""
    echo "====================================================================="
    echo "VNC CONNECTION INFO (Stable - will NOT be rewritten, safe to copy):"
    echo ""
    echo "Host: $vnc_host"
    echo "Port: $vnc_port"
    echo "VNC password: $VNC_PASSWORD"
    echo ""
    echo "Use your VNC client (RealVNC, TigerVNC, etc.) and connect to:"
    echo "  $vnc_host"
    echo ""
    echo "If your client requires host and port separately, use:"
    echo "  Host: (above host, without :port if needed)"
    echo "  Port: (the port part after :)"
    echo "====================================================================="
    echo "Status line (below) will update time only; text above will not change."
    echo "====================================================================="
}

# Updates ONLY one status line at the bottom using \r
print_status_line() {
    local seconds=$1
    local limit=$2

    local elapsed=$seconds
    local remaining=$((limit - elapsed))
    [ $remaining -lt 0 ] && remaining=0

    local since_last_window=$((elapsed % IP_WINDOW))
    local until_next_window=$((IP_WINDOW - since_last_window))
    if [ $until_next_window -gt $remaining ]; then
        until_next_window=$remaining
    fi

    local rt
    rt=$(format_time "$elapsed")
    local nt
    nt=$(format_time "$until_next_window")

    printf "\rRuntime: %s / %s (30 days) | Next IP window in: %s   " \
        "$rt" "$(format_time "$limit")" "$nt"
}

# ---------------- MAIN LOGIC ----------------

start_vnc_container
start_tunnel "$VNC_PORT" "$VNC_LOG"

echo "Waiting for VNC tunnel host assignment..."

VNC_HOST=""

for i in {1..40}; do
    VNC_HOST=$(get_tunnel_host "$VNC_LOG")

    if [ -n "$VNC_HOST" ]; then
        echo "Tunnel host assigned."
        break
    fi

    printf "\rWaiting for tunnel host assignment (attempt %d/40)..." "$i"
    sleep 2
done
echo ""

if [ -z "$VNC_HOST" ]; then
    echo "Failed to start VNC tunnel!"
    echo "---- VNC LOG ----"
    [ -f "$VNC_LOG" ] && cat "$VNC_LOG"
    exit 1
fi

notify_user "VNC" "" "" "$VNC_HOST" "$VNC_PORT"

# Print the credentials ONCE and never touch those lines again
print_static_info "$VNC_HOST" "$VNC_PORT"

SECONDS=0
OLD_VNC_HOST="$VNC_HOST"

# Initial status line
print_status_line "$SECONDS" "$LIMIT"

while [ $SECONDS -lt $LIMIT ]; do
    # Reconnect VNC tunnel if needed
    if ! tunnel_alive "$VNC_PORT"; then
        echo ""  # move to new line before messages
        echo "[Pinggy] VNC tunnel disconnected (expired or internet break). Reconnecting..."
        start_tunnel "$VNC_PORT" "$VNC_LOG"

        for j in {1..40}; do
            NEW_VNC_HOST=$(get_tunnel_host "$VNC_LOG")
            if [ -n "$NEW_VNC_HOST" ] && [ "$NEW_VNC_HOST" != "$OLD_VNC_HOST" ]; then
                break
            fi
            sleep 2
        done
        [ -z "$NEW_VNC_HOST" ] && NEW_VNC_HOST=$(get_tunnel_host "$VNC_LOG")

        VNC_HOST="$NEW_VNC_HOST"
        notify_user "VNC" "$OLD_VNC_HOST" "$VNC_PORT" "$VNC_HOST" "$VNC_PORT"

        echo "New VNC host: $VNC_HOST  (VNC password above stays the same)"

        OLD_VNC_HOST="$VNC_HOST"
    fi

    # Update ONLY the status line
    print_status_line "$SECONDS" "$LIMIT"

    sleep 1
done

echo ""
echo "[Script] 1-month VNC session finished."
