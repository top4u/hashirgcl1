#!/bin/bash
clear
echo "================================="
echo "      UNIVERSAL TUNNEL MANAGER"
echo "================================="

# --- Service selection ---
echo "Supports tunnels:"
echo "1 = ngrok"
echo "2 = zrok"
echo "3 = Pinggy"
echo "4 = SSH Tunnel"
echo "5 = Cloudflare"
read -p "Choose tunnel: " TUNNEL_CHOICE

echo
echo "Choose service:"
echo "1 = NoMachine"
echo "2 = VNC"
read -p "Choice: " SERVICE_CHOICE

# Assign ports
if [ "$SERVICE_CHOICE" = "1" ]; then
    SERVICE_NAME="NoMachine"
    PORT=4000
elif [ "$SERVICE_CHOICE" = "2" ]; then
    SERVICE_NAME="VNC"
    PORT=5900
else
    echo "Invalid service choice!"
    exit 1
fi

beep() { echo -e "\a"; }

# --- Docker container function ---
start_container() {
    echo "Starting $SERVICE_NAME container..."
    docker rm -f utm-container >/dev/null 2>&1
    if [ "$SERVICE_CHOICE" = "1" ]; then
        docker run --rm -d --network host --privileged --name utm-container \
          -e PASSWORD=123456 -e USER=user --cap-add=SYS_PTRACE --shm-size=1g \
          thuonghai2711/nomachine-ubuntu-desktop:wine
    else
        docker run --rm -d --network host --privileged --name utm-container \
          -e PASSWORD=123456 --shm-size=1g \
          thuonghai2711/vnc-ubuntu-desktop:wine
    fi
    sleep 5
    echo "$SERVICE_NAME container started."
}

# --- Tunnel functions ---
validate_ngrok_token() {
    local token=$1
    ./ngrok config add-authtoken "$token" &>/dev/null
    for i in {1..10}; do
        ./ngrok tcp --region "$NG_REGION" $PORT &>/dev/null &
        NG_PID=$!
        sleep 5
        HOST=$(curl -s http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p')
        if [ -n "$HOST" ]; then
            kill $NG_PID 2>/dev/null
            echo "Ngrok token valid! Tunnel ready: $HOST"
            return 0
        fi
        kill $NG_PID 2>/dev/null
    done
    return 1
}

validate_zrok_token() {
    local token=$1
    ./zrok login "$token" &>/dev/null
    for i in {1..10}; do
        if ./zrok status &>/dev/null; then
            echo "Zrok token valid!"
            return 0
        fi
        sleep 2
    done
    return 1
}

start_pinggy_tunnel() {
    pkill -f "R0:localhost:$PORT" >/dev/null 2>&1
    ssh -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -p 443 -R0:localhost:$PORT a.pinggy.io >/dev/null 2>&1 &
    sleep 8
    HOST=$(grep -o 'tcp://[^ ]*' pinggy.log | head -n1 | sed 's/tcp:\/\///')
}

start_ssh_tunnel() {
    read -p "Enter SSH host (user@host): " SSH_HOST
    read -p "Enter remote port: " SSH_PORT
    ssh -o ServerAliveInterval=30 -R $SSH_PORT:localhost:$PORT $SSH_HOST >/dev/null 2>&1 &
    HOST="$SSH_HOST:$SSH_PORT"
}

start_cloudflare_tunnel() {
    read -p "Enter Cloudflare Tunnel name: " CF_TUNNEL
    cloudflared tunnel --url tcp://localhost:$PORT run $CF_TUNNEL >/dev/null 2>&1 &
    sleep 5
    HOST="$CF_TUNNEL.localhost"
}

# --- Start tunnel based on choice ---
case $TUNNEL_CHOICE in
    1)
        if ! command -v ngrok &>/dev/null; then
            echo "Downloading ngrok..."
            wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
            tar -xzf ngrok-v3-stable-linux-amd64.tgz
            chmod +x ngrok
        fi
        echo "Get your ngrok token: https://dashboard.ngrok.com/get-started/your-authtoken"
        while true; do
            read -p "Paste ngrok token: " NG_TOKEN
            echo "Choose region: us eu ap au sa jp in"
            read -p "Region: " NG_REGION
            if validate_ngrok_token "$NG_TOKEN"; then break; else echo "Invalid token. Retry."; fi
        done
        start_container
        ./ngrok tcp --region "$NG_REGION" $PORT &>/dev/null &
        sleep 5
        HOST=$(curl -s http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p')
        ;;
    2)
        if ! command -v zrok &>/dev/null; then
            echo "Downloading zrok 1.0..."
            wget -q https://github.com/zedapp-org/zrok/releases/download/v1.0/zrok_1.0_linux_amd64.tar.gz
            tar -xzf zrok_1.0_linux_amd64.tar.gz
            chmod +x zrok
        fi
        echo "Get your zrok token: https://docs.zrok.io/docs/myzrok/upgrading/"
        while true; do
            read -p "Paste zrok token: " ZR_TOKEN
            if validate_zrok_token "$ZR_TOKEN"; then break; else echo "Invalid token. Retry."; fi
        done
        start_container
        ./zrok tcp -p $PORT >/dev/null 2>&1 &
        HOST="zrok://localhost:$PORT"
        ;;
    3)
        echo "Pinggy free tunnel (expires every 60 min, auto-reconnect will be used)"
        start_container
        start_pinggy_tunnel
        ;;
    4)
        start_ssh_tunnel
        start_container
        ;;
    5)
        start_cloudflare_tunnel
        start_container
        ;;
    *)
        echo "Invalid tunnel choice!"
        exit 1
        ;;
esac

# --- Show final info ---
clear
echo "======================================"
echo "$SERVICE_NAME Tunnel Ready"
echo "Host: $HOST"
echo "User: user"
echo "Pass: 123456"
echo "Port: $PORT"
echo "======================================"
beep

# --- Keep alive loop ---
SECONDS=0
LIMIT=43200  # 12 hours
while [ $SECONDS -lt $LIMIT ]; do
    if ! docker ps --filter "name=utm-container" --format '{{.Names}}' | grep -q utm-container; then
        echo "Container stopped! Restarting..."
        start_container
        beep
    fi
    case $TUNNEL_CHOICE in
        1)
            if ! pgrep -f ngrok >/dev/null; then
                echo "Ngrok stopped! Restarting..."
                ./ngrok tcp --region "$NG_REGION" $PORT &>/dev/null &
                beep
            fi
            ;;
        2)
            if ! pgrep -f zrok >/dev/null; then
                echo "Zrok stopped! Restarting..."
                ./zrok tcp -p $PORT >/dev/null 2>&1 &
                beep
            fi
            ;;
        3)
            start_pinggy_tunnel
            beep
            ;;
        4)
            start_ssh_tunnel
            beep
            ;;
        5)
            start_cloudflare_tunnel
            beep
            ;;
    esac
    printf "\rRunning: %d / %d s | Host: %s" $SECONDS $LIMIT "$HOST"
    sleep 5
done

echo
echo "12-hour session finished."
