#!/bin/bash

###############################################################################
# SESSION IDENTITY - What this script manages
###############################################################################
SESSION_NAME="mrbot"
SESSION_MARKER="MRBOT_NOMACHINE_SESSION"   # env-var marker inside the session

###############################################################################
# tmux auto-attach / auto-start (for persistence)
###############################################################################

if [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    if [ "$MRBOT_TMUX_WRAPPED" != "1" ]; then
        export MRBOT_TMUX_WRAPPED=1

        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then

            # ----------------------------------------------------------------
            # A session called "mrbot" exists.
            # Check whether it is actually running our NoMachine stack.
            # We do that by looking for the marker env-var OR for the
            # key processes (the SSH tunnel and the docker container).
            # ----------------------------------------------------------------
            NX_RUNNING=0

            # 1) Check docker container
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "nomachine-xfce4"; then
                NX_RUNNING=1
            fi

            # 2) Check SSH tunnel process
            if pgrep -f "R0:localhost:4000" >/dev/null 2>&1; then
                NX_RUNNING=$((NX_RUNNING + 1))
            fi

            if [ "$NX_RUNNING" -ge 1 ]; then
                # Session looks healthy – just attach
                echo "[tmux] Session '$SESSION_NAME' is alive with NoMachine stack. Attaching..."
                tmux attach -t "$SESSION_NAME"
                exit 0
            else
                # Session exists but NoMachine is NOT running inside it.
                # Kill the stale session and start fresh.
                echo "[tmux] Session '$SESSION_NAME' exists but NoMachine stack is NOT running."
                echo "[tmux] Killing stale session and starting fresh..."
                tmux kill-session -t "$SESSION_NAME" 2>/dev/null
                sleep 1

                echo "[tmux] Creating new session '$SESSION_NAME'..."
                tmux new -s "$SESSION_NAME" "bash \"$0\"; echo; echo \"[mrbot] Script finished. Press ENTER to close.\"; read"
                exit 0
            fi

        else
            # No session at all – create one fresh
            echo "[tmux] No existing session. Creating '$SESSION_NAME'..."
            tmux new -s "$SESSION_NAME" "bash \"$0\"; echo; echo \"[mrbot] Script finished. Press ENTER to close.\"; read"
            exit 0
        fi
    fi
fi

###############################################################################
# MAIN SCRIPT  (runs inside tmux from here on)
###############################################################################

# Mark this session so re-entry checks can find it
export MRBOT_NOMACHINE_SESSION=1

clear
echo "NoMachine Cloud Shell Tunnel (Auto-Reconnect + Telegram Alerts)"
echo "================================================================"
echo "Tip:"
echo "  - Running inside tmux session: '$SESSION_NAME'"
echo "  - Detach any time with Ctrl+B then D – tunnel keeps running."
echo "  - Re-run this script to re-attach automatically."
echo "================================================================"

# ── Ports & files ──────────────────────────────────────────────────────────
NX_PORT=4000
NX_LOG="pinggy_nx.log"

# ── Timing ─────────────────────────────────────────────────────────────────
LIMIT=$((30 * 24 * 3600))   # 30 days in seconds
IP_WINDOW=3600               # Pinggy free window

# ── Telegram ───────────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

###############################################################################
# FUNCTIONS
###############################################################################

send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] \
       && [ "$TELEGRAM_BOT_TOKEN" != "YOUR_BOT_TOKEN_HERE" ] \
       && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" >/dev/null 2>&1
    fi
}

notify_user() {
    local service=$1 old_host=$2 old_port=$3 new_host=$4 new_port=$5
    echo ""
    echo -e "\033[1;33m[$service] Tunnel updated!\033[0m"
    [ -n "$old_host" ] && echo "  Old: $old_host:$old_port"
    echo "  New: $new_host:$new_port"
    echo -ne "\a"
    send_telegram "$service tunnel reconnected!
New Host : $new_host:$new_port
User     : user
Pass     : 123456"
}

spinner() {
    local pid=$1 message=$2 delay=0.15 spin='-\|/' i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r%s %s" "$message" "${spin:$i:1}"
        sleep "$delay"
    done
    printf "\r%s ... done.\n" "$message"
}

# ── Docker / tunnel helpers ─────────────────────────────────────────────────

nomachine_container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^nomachine-xfce4$"
}

tunnel_alive() {
    pgrep -f "R0:localhost:$1" >/dev/null 2>&1
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
        sleep 5
    ) &
    spinner $! "Step 1/2: Starting NoMachine container"
}

start_tunnel() {
    local port=$1 logfile=$2
    (
        pkill -f "R0:localhost:$port" >/dev/null 2>&1
        rm -f "$logfile"
        ssh -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=30 \
            -o ServerAliveCountMax=3 \
            -p 443 \
            -R0:localhost:"$port" \
            tcp@a.pinggy.io > "$logfile" 2>&1 &
        sleep 5
    ) &
    spinner $! "Step 2/2: Starting Pinggy tunnel for port $port"
}

get_tunnel_host() {
    grep -Eo 'tcp://[^ ]+' "$1" 2>/dev/null | tail -n1 | sed 's|tcp://||'
}

format_time() {
    local s=$1
    local d=$((s/86400)) h=$(( (s%86400)/3600 )) m=$(( (s%3600)/60 )) sec=$((s%60))
    [ $d -gt 0 ] \
        && printf "%dd:%02dh:%02dm:%02ds" "$d" "$h" "$m" "$sec" \
        || printf "%02dh:%02dm:%02ds"          "$h" "$m" "$sec"
}

print_static_info() {
    local host=$1 port=$2
    echo ""
    echo "====================================================================="
    echo " NOMACHINE CONNECTION INFO  (safe to copy – will NOT be rewritten)"
    echo "====================================================================="
    echo "  Host     : $host"
    echo "  Port     : $port"
    echo "  User     : user"
    echo "  Pass     : 123456"
    echo "  Protocol : NX"
    echo "====================================================================="
    echo " Status line below updates in-place; everything above stays fixed."
    echo "====================================================================="
}

print_status_line() {
    local elapsed=$1 limit=$2
    local remaining=$(( limit - elapsed ))
    [ $remaining -lt 0 ] && remaining=0
    local since=$(( elapsed % IP_WINDOW ))
    local until_next=$(( IP_WINDOW - since ))
    [ $until_next -gt $remaining ] && until_next=$remaining
    printf "\rRuntime: %s / %s | Next IP window in: %s   " \
        "$(format_time "$elapsed")" \
        "$(format_time "$limit")" \
        "$(format_time "$until_next")"
}

###############################################################################
# PRE-FLIGHT: decide what needs (re)starting
###############################################################################

echo ""
echo "=== Pre-flight check ==="

NEED_CONTAINER=1
NEED_TUNNEL=1

# ── Container check ───────────────────────────────────────────────────────
if nomachine_container_running; then
    echo "[✓] NoMachine container already running – will reuse."
    NEED_CONTAINER=0
else
    echo "[✗] NoMachine container not running – will start fresh."
fi

# ── Tunnel check ──────────────────────────────────────────────────────────
if tunnel_alive "$NX_PORT"; then
    echo "[✓] Pinggy SSH tunnel already alive on port $NX_PORT – will reuse."
    NEED_TUNNEL=0

    # Try to recover host from existing log
    EXISTING_HOST=$(get_tunnel_host "$NX_LOG")
    if [ -n "$EXISTING_HOST" ]; then
        echo "[✓] Existing tunnel host: $EXISTING_HOST"
    fi
else
    echo "[✗] Pinggy tunnel not running – will start fresh."
fi

echo "========================"
echo ""

###############################################################################
# START ONLY WHAT IS NEEDED
###############################################################################

if [ "$NEED_CONTAINER" -eq 1 ]; then
    start_nomachine
else
    echo "Skipping container start (already running)."
fi

if [ "$NEED_TUNNEL" -eq 1 ]; then
    start_tunnel "$NX_PORT" "$NX_LOG"
else
    echo "Skipping tunnel start (already running)."
fi

###############################################################################
# WAIT FOR TUNNEL HOST
###############################################################################

echo "Waiting for tunnel host assignment..."
NX_HOST=""

for i in $(seq 1 40); do
    NX_HOST=$(get_tunnel_host "$NX_LOG")
    if [ -n "$NX_HOST" ]; then
        echo "Tunnel host assigned: $NX_HOST"
        break
    fi
    printf "\r  Attempt %d/40 ..." "$i"
    sleep 2
done
echo ""

if [ -z "$NX_HOST" ]; then
    echo "[ERROR] Failed to obtain NoMachine tunnel host!"
    echo "---- Pinggy log ----"
    [ -f "$NX_LOG" ] && cat "$NX_LOG"
    exit 1
fi

notify_user "NoMachine" "" "" "$NX_HOST" "$NX_PORT"
print_static_info "$NX_HOST" "$NX_PORT"

###############################################################################
# MAIN LOOP  – monitor & auto-reconnect
###############################################################################

SECONDS=0
OLD_NX_HOST="$NX_HOST"
print_status_line "$SECONDS" "$LIMIT"

while [ $SECONDS -lt $LIMIT ]; do

    # ── Container watchdog ──────────────────────────────────────────────
    if ! nomachine_container_running; then
        echo ""
        echo "[Docker] NoMachine container died! Restarting..."
        start_nomachine
    fi

    # ── Tunnel watchdog ─────────────────────────────────────────────────
    if ! tunnel_alive "$NX_PORT"; then
        echo ""
        echo "[Pinggy] Tunnel disconnected – reconnecting..."
        start_tunnel "$NX_PORT" "$NX_LOG"

        NEW_NX_HOST=""
        for j in $(seq 1 40); do
            NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")
            # Accept new host even if it's the same (Pinggy may reuse addresses)
            if [ -n "$NEW_NX_HOST" ]; then
                break
            fi
            sleep 2
        done
        [ -z "$NEW_NX_HOST" ] && NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")

        if [ -n "$NEW_NX_HOST" ]; then
            notify_user "NoMachine" "$OLD_NX_HOST" "$NX_PORT" "$NEW_NX_HOST" "$NX_PORT"
            echo "  New host: $NEW_NX_HOST:$NX_PORT  (credentials above unchanged)"
            NX_HOST="$NEW_NX_HOST"
            OLD_NX_HOST="$NX_HOST"
        else
            echo "[WARN] Could not obtain new tunnel host. Will retry next cycle."
        fi
    fi

    # ── Status line ─────────────────────────────────────────────────────
    print_status_line "$SECONDS" "$LIMIT"
    sleep 1
done

echo ""
echo "[Script] 30-day session finished."
