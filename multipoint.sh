#!/bin/bash

clear
echo "================================="
echo "      UNIVERSAL TUNNEL MANAGER"
echo "================================="
echo
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

# Beep function
beep() { echo -e "\a"; }

# Function to start Docker container for NoMachine/VNC
start_container() {
    echo "Starting Docker container for $SERVICE_NAME..."
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

# Function to check container running
container_alive() {
    docker ps --filter "name=utm-container" --format '{{.Names}}' | grep -q utm-container
}

# Function to start ngrok tunnel
start_ngrok() {
    if ! command -v ngrok &>/dev/null; then
        echo "Downloading ngrok..."
        wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
        tar -xzf ngrok-v3-stable-linux-amd64.tgz
        chmod +x ngrok
    fi

    read -p "Enter ngrok authtoken: " NG_TOKEN
    ./ngrok config add-authtoken "$NG_TOKEN"

    echo "Choose ngrok region: us eu ap au sa jp in"
    read -p "Region: " NG_REGION

    while true; do
        ./ngrok tcp --region "$NG_REGION" $PORT &>/dev/null &
        NG_PID=$!
        sleep 10
        HOST=$(curl -s http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p')
        if [ -n "$HOST" ]; then
            echo "Ngrok tunnel established: $HOST"
            beep
            break
        else
            kill $NG_PID 2>/dev/null
            echo "Retrying ngrok..."
        fi
    done
}

# Function to start Pinggy tunnel
start_pinggy() {
    echo "Starting Pinggy tunnel..."
    if ! command -v ssh &>/dev/null; then
        sudo apt update -y >/dev/null 2>&1
        sudo apt install -y openssh-client >/dev/null 2>&1
    fi
    while true; do
        ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R0:localhost:$PORT a.pinggy.io > pinggy.log 2>&1 &
        TUN_PID=$!
        sleep 8
        HOST=$(grep -o 'tcp://[^ ]*' pinggy.log | head -n1 | sed 's/tcp:\/\///')
        if [ -n "$HOST" ]; then
            echo "Pinggy tunnel: $HOST"
            beep
            break
        else
            kill $TUN_PID 2>/dev/null
            echo "Retrying Pinggy..."
        fi
    done
}

# Function to start zrok tunnel
start_zrok() {
    echo "Starting zrok tunnel..."
    if ! command -v zrok &>/dev/null; then
        echo "Downloading zrok client..."
        wget -q https://github.com/zr0x/zrok/releases/download/v1.0/zrok_linux_amd64.zip
        unzip -qq zrok_linux_amd64.zip
        chmod +x zrok
    fi
    read -p "Enter zrok key: " Z_KEY
    while true; do
        ./zrok tcp --key "$Z_KEY" $PORT &>/dev/null &
        Z_PID=$!
        sleep 10
        # zrok endpoint extraction placeholder
        HOST="zrok-tcp-endpoint:$PORT"
        echo "Zrok tunnel: $HOST"
        beep
        break
    done
}

# SSH Tunnel
start_ssh() {
    read -p "Enter SSH user@host: " SSH_USERHOST
    echo "Starting SSH tunnel to $SSH_USERHOST:$PORT..."
    while true; do
        ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R0:localhost:$PORT $SSH_USERHOST &
        SSH_PID=$!
        sleep 8
        HOST="$SSH_USERHOST:$PORT"
        echo "SSH Tunnel: $HOST"
        beep
        break
    done
}

# Cloudflare Tunnel (placeholder)
start_cf() {
    echo "Cloudflare tunnel setup not implemented yet"
    HOST="cf-tunnel:$PORT"
}

# Start Docker container first
start_container

# Start the selected tunnel
case $TUNNEL_CHOICE in
1)
    start_ngrok
    ;;
2)
    start_zrok
    ;;
3)
    start_pinggy
    ;;
4)
    start_ssh
    ;;
5)
    start_cf
    ;;
*)
    echo "Invalid tunnel choice!"
    exit 1
    ;;
esac

# Main 12-hour monitoring loop
echo
echo "Tunnel & $SERVICE_NAME running. Keeping alive for 12 hours..."
SECONDS=0
LIMIT=43200
while [ $SECONDS -lt $LIMIT ]; do
    # Check Docker container
    if ! container_alive; then
        echo "Docker container stopped. Restarting..."
        start_container
        beep
    fi

    # Check tunnel process
    case $TUNNEL_CHOICE in
        1)
            if ! pgrep -f ngrok >/dev/null; then
                echo "Ngrok stopped. Restarting..."
                start_ngrok
            fi
            ;;
        2)
            if ! pgrep -f zrok >/dev/null; then
                echo "Zrok stopped. Restarting..."
                start_zrok
            fi
            ;;
        3)
            if ! pgrep -f ssh >/dev/null; then
                echo "Pinggy stopped. Restarting..."
                start_pinggy
            fi
            ;;
        4)
            if ! pgrep -f ssh >/dev/null; then
                echo "SSH tunnel stopped. Restarting..."
                start_ssh
            fi
            ;;
        5)
            # Cloudflare monitoring placeholder
            ;;
    esac

    printf "\rRunning: %d / %d s | Host: %s" $SECONDS $LIMIT "$HOST"
    sleep 5
done

echo
echo "Session finished."
