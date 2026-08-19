Looking at your request, you want the script to be smarter about tmux session detection. Here's the improved version:

```bash
#!/bin/bash

###############################################################################
# tmux auto-attach / auto-start (for persistence) - SMART DETECTION
###############################################################################

TMUX_SESSION="mrbot"

# Function: Check if the mrbot session is actually running a live NoMachine tunnel
session_has_live_rdp() {
    # 1. Session must exist
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || return 1

    # 2. There must be a live Pinggy tunnel process (ssh -R0:localhost:4000)
    if ! pgrep -f "R0:localhost:4000" >/dev/null 2>&1; then
        return 1
    fi

    # 3. The NoMachine container must be up and running
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nomachine-xfce4$'; then
        return 1
    fi

    # All good: there is a healthy running RDP/NoMachine session
    return 0
}

# If not already inside tmux and tmux is available
if [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    if [ "$MRBOT_TMUX_WRAPPED" != "1" ]; then
        export MRBOT_TMUX_WRAPPED=1

        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            if session_has_live_rdp; then
                echo "[tmux] Existing session '$TMUX_SESSION' has a LIVE NoMachine tunnel."
                echo "[tmux] Attaching to it (not restarting)..."
                sleep 1
                tmux attach -t "$TMUX_SESSION"
                exit 0
            else
                echo "[tmux] Session '$TMUX_SESSION' exists but has NO live NoMachine display/tunnel."
                echo "[tmux] Killing stale session and starting fresh..."

                # Kill stale tmux session
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null

                # Clean up any leftover tunnel / container from the dead session
                pkill -f "R0:localhost:4000" >/dev/null 2>&1
                docker rm -f nomachine-xfce4 >/dev/null 2>&1

                sleep 1

                echo "[tmux] Creating fresh session '$TMUX_SESSION'..."
                tmux new -s "$TMUX_SESSION" "bash \"$0\"; echo; echo \"[mrbotmaker] Script finished. Press ENTER to close tmux window.\"; read"
                exit 0
            fi
        else
            echo "[tmux] No existing session. Creating new session '$TMUX_SESSION'..."
            tmux new -s "$TMUX_SESSION" "bash \"$0\"; echo; echo \"[mrbotmaker] Script finished. Press ENTER to close tmux window.\"; read"
            exit 0
        fi
    fi
fi

###############################################################################
# MAIN SCRIPT
###############################################################################

clear
echo "NoMachine Cloud Shell Tunnel (Auto-Reconnect + Telegram Alerts)"
echo "================================================================"
echo "Tip:"
echo "  - This script is tmux-aware and SMART:"
echo "      * If an existing '$TMUX_SESSION' session already has a LIVE"
echo "        NoMachine tunnel, it attaches to it instead of restarting."
echo "      * If the session exists but is dead/stale, it is killed and a"
echo "        fresh one is started automatically."
echo "  - Detach with Ctrl+B then D and it will keep running."
echo "================================================================"

# NoMachine port (inside container and host)
NX_PORT=4000

# Log file for Pinggy
NX_LOG="pinggy_nx.log"

# Total runtime (1 month = 30 days)
LIMIT=$((30 * 24 * 3600))   # seconds

# Pinggy window (1 hour)
IP_WINDOW=3600

# Telegram
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

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
User: user
Pass: 123456"
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

# Detect whether a healthy NoMachine container is ALREADY running.
# Returns 0 if running, 1 if not.
nomachine_container_alive() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nomachine-xfce4$'
}

start_nomachine() {
    # If a healthy container is already running, DO NOT restart it.
    if nomachine_container_alive; then
        printf "\rStep 1/2: Existing NoMachine container detected -> reusing it. done.\n"
        return 0
    fi

    (
        docker rm -f nomachine-xfce4 >/dev/null 2>&1
        docker run --rm -d --network host --privileged \
          --name nomachine-xfce4 \
          -e PASSWORD=123456 \
          -e USER=user \
          --cap-add=SYS_PTRACE \
          --shm-size=1g \
          thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1
        sleep 5
    ) &
    spinner $! "Step 1/2: Starting NoMachine container"
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

print_static_info() {
    local nx_host=$1
    local nx_port=$2

    echo ""
    echo "====================================================================="
    echo "NOMACHINE CONNECTION INFO (Stable - will NOT be rewritten, safe to copy):"
    echo ""
    echo "Host: $nx_host"
    echo "Port: $nx_port"
    echo "User: user"
    echo "Pass: 123456"
    echo ""
    echo "Use the NoMachine client and create a new connection with:"
    echo "  Protocol: NX"
    echo "  Host: (above Host)"
    echo "  Port: (above Port)"
    echo "====================================================================="
    echo "Status line (below) will update time only; text above will not change."
    echo "====================================================================="
}

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

start_nomachine
start_tunnel "$NX_PORT" "$NX_LOG"

echo "Waiting for NoMachine tunnel host assignment..."

NX_HOST=""

for i in {1..40}; do
    NX_HOST=$(get_tunnel_host "$NX_LOG")

    if [ -n "$NX_HOST" ]; then
        echo "Tunnel host assigned."
        break
    fi

    printf "\rWaiting for tunnel host assignment (attempt %d/40)..." "$i"
    sleep 2
done
echo ""

if [ -z "$NX_HOST" ]; then
    echo "Failed to start NoMachine tunnel!"
    echo "---- NX LOG ----"
    [ -f "$NX_LOG" ] && cat "$NX_LOG"
    exit 1
fi

notify_user "NoMachine" "" "" "$NX_HOST" "$NX_PORT"

print_static_info "$NX_HOST" "$NX_PORT"

SECONDS=0
OLD_NX_HOST="$NX_HOST"

print_status_line "$SECONDS" "$LIMIT"

while [ $SECONDS -lt $LIMIT ]; do
    # Reconnect NoMachine tunnel if needed
    if ! tunnel_alive "$NX_PORT"; then
        echo ""
        echo "[Pinggy] NoMachine tunnel disconnected (expired or internet break). Reconn
