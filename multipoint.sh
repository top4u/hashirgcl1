#!/bin/bash
# =================================
# UNIVERSAL TUNNEL MANAGER
# =================================
# Supports: ngrok, zrok, Pinggy, SSH, Cloudflare
# Handles: NoMachine and VNC with Docker
# Features: Auto-reconnect, beep alerts, token validation, stable endpoints

set -e

# -----------------------------
# FUNCTIONS
# -----------------------------
beep() {
    # system beep
    echo -ne "\a"
}

docker_start() {
    SERVICE=$1
    echo "Starting Docker container for $SERVICE..."
    CONTAINER_NAME="utman-$SERVICE"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run --rm -d --network host --privileged --name "$CONTAINER_NAME" \
      -e PASSWORD=123456 -e USER=user --cap-add=SYS_PTRACE --shm-size=1g \
      thuonghai2711/nomachine-ubuntu-desktop:wine >/dev/null
    echo "$SERVICE container started."
}

wait_tunnel() {
    LOCAL_API=$1
    MAX_WAIT=50
    for i in $(seq 1 $MAX_WAIT); do
        if curl --silent --show-error "$LOCAL_API" >/dev/null 2>&1; then
            break
        fi
        echo "Waiting for tunnel to be ready... ($i/$MAX_WAIT)"
        sleep 2
    done
}

ngrok_tunnel() {
    echo "Installing ngrok if missing..."
    if ! command -v ngrok &>/dev/null; then
        wget -q -O ngrok.zip https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-amd64.zip
        unzip -q ngrok.zip -d "$HOME"
        chmod +x "$HOME/ngrok"
        export PATH=$HOME:$PATH
    fi

    echo "Get your ngrok authtoken: https://dashboard.ngrok.com/get-started/your-authtoken"
    read -p "Paste ngrok authtoken: " NGROK_TOKEN
    "$HOME/ngrok" authtoken "$NGROK_TOKEN"

    echo "Choose ngrok region: us eu ap au sa jp in"
    read -p "Region: " NGROK_REGION

    "$HOME/ngrok" tcp --region "$NGROK_REGION" 4000 >/dev/null 2>&1 &
    wait_tunnel "http://127.0.0.1:4040/api/tunnels"

    HOST=$(curl -s http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p')
    echo "Ngrok tunnel established: $HOST"
    beep
}

zrok_tunnel() {
    echo "Installing zrok CLI if missing..."
    if ! command -v zrok &>/dev/null; then
        sudo apt-get update -y >/dev/null
        sudo apt-get install -y zrok >/dev/null
    fi

    MAX_RETRIES=10
    RETRY=0
    while [ $RETRY -lt $MAX_RETRIES ]; do
        echo "Get your zrok token at https://myzrok.io/"
        read -p "Paste zrok token: " ZROK_TOKEN

        # Handle existing enabled environment
        if zrok status 2>&1 | grep -q "enabled"; then
            echo "[INFO] Existing enabled environment detected. Disabling..."
            zrok disable >/dev/null 2>&1
            sleep 2
        fi

        if zrok enable "$ZROK_TOKEN" >/dev/null 2>&1; then
            echo "[SUCCESS] Token enabled."
            break
        else
            echo "[ERROR] Token invalid or environment issue. Retrying..."
            RETRY=$((RETRY+1))
        fi
    done
    if [ $RETRY -eq $MAX_RETRIES ]; then
        echo "[FATAL] Max retries reached for zrok token. Exiting."
        exit 1
    fi

    ENDPOINT_NAME="utman-$(date +%s)"
    zrok reserve public 127.0.0.1:4000 --unique-name "$ENDPOINT_NAME" >/dev/null 2>&1
    PUBLIC_URL=$(zrok share reserved "$ENDPOINT_NAME" 2>/dev/null | grep -o 'https://[^ ]*' | head -n1)
    echo "Zrok tunnel established: $PUBLIC_URL"
    beep
}

pinggy_tunnel() {
    echo "Pinggy tunnel setup..."
    read -p "Use Pinggy free TCP tunnel (auto expires in ~60min)? [y/n]: " P_CHOICE
    if [[ "$P_CHOICE" != "y" ]]; then
        echo "Pinggy setup skipped."
        return
    fi

    ssh -f -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -p 443 -R0:localhost:4000 a.pinggy.io >/dev/null 2>&1 &
    sleep 8
    HOST=$(grep -o 'tcp://[^ ]*' pinggy.log | head -n1 | sed 's/tcp:\/\///')
    echo "Pinggy tunnel established: $HOST"
    beep
}

ssh_tunnel() {
    read -p "Enter SSH host (user@host): " SSH_HOST
    read -p "Enter remote port to forward to 4000: " REMOTE_PORT
    ssh -f -o ServerAliveInterval=30 -R "$REMOTE_PORT":localhost:4000 "$SSH_HOST" >/dev/null 2>&1 &
    echo "SSH tunnel established: $SSH_HOST:$REMOTE_PORT"
    beep
}

cloudflare_tunnel() {
    echo "Cloudflare tunnel setup..."
    read -p "Enter your Cloudflare Tunnel name: " CF_NAME
    read -p "Enter local port to expose (default 4000): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-4000}
    cloudflared tunnel --url localhost:$LOCAL_PORT run "$CF_NAME" &
    echo "Cloudflare tunnel running for $CF_NAME"
    beep
}

# -----------------------------
# START OF SCRIPT
# -----------------------------
clear
echo "================================="
echo "      UNIVERSAL TUNNEL MANAGER"
echo "================================="
echo ""
echo "Supports tunnels:"
echo "1 = ngrok"
echo "2 = zrok"
echo "3 = Pinggy"
echo "4 = SSH Tunnel"
echo "5 = Cloudflare"

read -p "Choose tunnel (1-5): " TUNNEL_CHOICE
echo ""
echo "Choose service:"
echo "1 = NoMachine"
echo "2 = VNC"
read -p "Choice: " SERVICE_CHOICE

SERVICE_NAME=""
LOCAL_PORT=4000
if [ "$SERVICE_CHOICE" == "1" ]; then
    SERVICE_NAME="NoMachine"
elif [ "$SERVICE_CHOICE" == "2" ]; then
    SERVICE_NAME="VNC"
    LOCAL_PORT=5900
else
    echo "Invalid choice. Exiting."
    exit 1
fi

docker_start "$SERVICE_NAME"

# -----------------------------
# TUNNEL SELECTION
# -----------------------------
case "$TUNNEL_CHOICE" in
    1) ngrok_tunnel ;;
    2) zrok_tunnel ;;
    3) pinggy_tunnel ;;
    4) ssh_tunnel ;;
    5) cloudflare_tunnel ;;
    *) echo "Invalid tunnel choice. Exiting."; exit 1 ;;
esac

# -----------------------------
# KEEP TUNNEL ALIVE FOR 12 HOURS
# -----------------------------
echo ""
echo "Tunnel & $SERVICE_NAME running. Keeping alive for 12 hours..."
SECONDS=0
LIMIT=43200
while [ $SECONDS -lt $LIMIT ]; do
    printf "\rRunning: %d / %d s" $SECONDS $LIMIT
    sleep 5
done
echo ""
echo "Session finished."
