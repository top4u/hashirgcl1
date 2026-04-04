#!/bin/bash

###############################################################################
# tmux auto-attach / auto-start (for persistence)
###############################################################################

# If not already inside tmux and tmux is available, re-run inside "mrbot" session
if [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    # Are we already in the special "child" mode to avoid recursion?
    if [ "$MRBOT_TMUX_WRAPPED" != "1" ]; then
        export MRBOT_TMUX_WRAPPED=1

        # If session "mrbot" exists, attach and run this script inside it
        if tmux has-session -t mrbot 2>/dev/null; then
            echo "[tmux] Attaching to existing session 'mrbot'..."
            tmux attach -t mrbot
            exit 0
        else
            echo "[tmux] Creating new session 'mrbot' and running this script inside it..."
            tmux new -s mrbot "bash \"$0\"; echo; echo \"[mrbotmaker] Script finished. Press ENTER to close tmux window.\"; read"
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
echo "  - This script is tmux-aware."
echo "  - If you started it normally and you see this message, it's already"
echo "    running safely in tmux (session: 'mrbot') if tmux is installed."
echo "  - You can detach with Ctrl+B then D and it will keep running."
echo "================================================================"

# Ask for root credentials
echo ""
echo "================================================================"
echo "ROOT ACCESS REQUIRED FOR DOCKER OPERATIONS"
echo "================================================================"
echo "This script needs root privileges to run Docker containers."
echo ""

# Function to ask for credentials
get_credentials() {
    read -p "Enter root username (default: root): " ROOT_USER
    ROOT_USER=${ROOT_USER:-root}
    
    read -s -p "Enter root password: " ROOT_PASSWORD
    echo ""
    read -s -p "Confirm root password: " ROOT_PASSWORD_CONFIRM
    echo ""
    
    if [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; then
        echo "Passwords do not match! Please try again."
        echo ""
        get_credentials
    fi
}

get_credentials

# Test root credentials and get root access
echo ""
echo "Testing root credentials and gaining root access..."

# Create a temporary script to test credentials and run commands as root
TEST_SCRIPT=$(mktemp)
cat > "$TEST_SCRIPT" << 'EOF'
#!/bin/bash
echo "Authentication successful!"
echo "Root user: $(whoami)"
docker --version 2>/dev/null || echo "Docker not found"
EOF
chmod +x "$TEST_SCRIPT"

# Try to execute as root using expect for automation
if command -v expect >/dev/null 2>&1; then
    # Use expect to automate sudo/su with password
    EXPECT_SCRIPT=$(mktemp)
    cat > "$EXPECT_SCRIPT" << EOF
#!/usr/bin/expect -f
set timeout 10
spawn sudo -S bash "$TEST_SCRIPT"
expect "password:" { send "$ROOT_PASSWORD\r" }
expect eof
EOF
    chmod +x "$EXPECT_SCRIPT"
    
    if "$EXPECT_SCRIPT" 2>/dev/null | grep -q "Authentication successful"; then
        echo "✓ Root credentials verified successfully!"
        ROOT_ACCESS_CMD="sudo -S bash"
        USE_EXPECT=1
    else
        echo "✗ Root credentials verification failed!"
        echo "Please check your username and password."
        exit 1
    fi
    rm -f "$EXPECT_SCRIPT"
else
    # Fallback to asking user to run commands manually if expect is not available
    echo "Warning: 'expect' command not found. Please install it or run:"
    echo "  sudo apt-get install expect -y"
    echo ""
    echo "For now, please enter your password manually when prompted."
    echo ""
    
    # Test with simple sudo command
    echo "$ROOT_PASSWORD" | sudo -S echo "Testing..." 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✓ Root credentials verified successfully!"
        ROOT_ACCESS_CMD="echo \"$ROOT_PASSWORD\" | sudo -S bash"
        USE_EXPECT=0
    else
        echo "✗ Root credentials verification failed!"
        echo "Please check your password."
        exit 1
    fi
fi

rm -f "$TEST_SCRIPT"

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

start_nomachine() {
    # Use root credentials to run docker commands
    if [ "$USE_EXPECT" -eq 1 ]; then
        # Create a script to run docker commands as root
        DOCKER_SCRIPT=$(mktemp)
        cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/bash
docker rm -f nomachine-xfce4 >/dev/null 2>&1
docker run --rm -d --network host --privileged \
  --name nomachine-xfce4 \
  -e PASSWORD=123456 \
  -e USER=user \
  --cap-add=SYS_PTRACE \
  --shm-size=1g \
  thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1
EOF
        chmod +x "$DOCKER_SCRIPT"
        
        # Run the docker script with expect
        EXPECT_SCRIPT=$(mktemp)
        cat > "$EXPECT_SCRIPT" << EOF
#!/usr/bin/expect -f
set timeout 30
spawn sudo -S bash "$DOCKER_SCRIPT"
expect "password:" { send "$ROOT_PASSWORD\r" }
expect eof
EOF
        chmod +x "$EXPECT_SCRIPT"
        "$EXPECT_SCRIPT" >/dev/null 2>&1 &
        rm -f "$EXPECT_SCRIPT" "$DOCKER_SCRIPT"
    else
        # Use echo pipe method
        (echo "$ROOT_PASSWORD" | sudo -S docker rm -f nomachine-xfce4 >/dev/null 2>&1
        echo "$ROOT_PASSWORD" | sudo -S docker run --rm -d --network host --privileged \
          --name nomachine-xfce4 \
          -e PASSWORD=123456 \
          -e USER=user \
          --cap-add=SYS_PTRACE \
          --shm-size=1g \
          thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null 2>&1) &
    fi
    
    spinner $! "Step 1/2: Starting NoMachine container"
    sleep 5
}

start_tunnel() {
    local port=$1
    local logfile=$2

    (
        # Kill existing tunnel processes
        pkill -f "R0:localhost:$port" >/dev/null 2>&1
        rm -f "$logfile"

        # SSH options here help handle connection breaks:
        # - ServerAliveInterval / CountMax: detect dead connections
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

# Prints the static info ONCE (so user can select/copy safely)
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

# Print the credentials ONCE and never touch those lines again
print_static_info "$NX_HOST" "$NX_PORT"

SECONDS=0
OLD_NX_HOST="$NX_HOST"

# Initial status line
print_status_line "$SECONDS" "$LIMIT"

while [ $SECONDS -lt $LIMIT ]; do
    # Reconnect NoMachine tunnel if needed
    if ! tunnel_alive "$NX_PORT"; then
        echo ""  # move to new line before messages
        echo "[Pinggy] NoMachine tunnel disconnected (expired or internet break). Reconnecting..."
        start_tunnel "$NX_PORT" "$NX_LOG"

        for j in {1..40}; do
            NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")
            if [ -n "$NEW_NX_HOST" ] && [ "$NEW_NX_HOST" != "$OLD_NX_HOST" ]; then
                break
            fi
            sleep 2
        done
        [ -z "$NEW_NX_HOST" ] && NEW_NX_HOST=$(get_tunnel_host "$NX_LOG")

        NX_HOST="$NEW_NX_HOST"
        notify_user "NoMachine" "$OLD_NX_HOST" "$NX_PORT" "$NX_HOST" "$NX_PORT"

        echo "New NoMachine host: $NX_HOST:$NX_PORT  (credentials above stay the same)"

        OLD_NX_HOST="$NX_HOST"
    fi

    # Update ONLY the status line (no clear, no full repaint)
    print_status_line "$SECONDS" "$LIMIT"

    sleep 1
done

echo ""
echo "[Script] 1-month session finished."
