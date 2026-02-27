#!/bin/bash
# ===============================
# UNIVERSAL TUNNEL MANAGER 2026
# ===============================

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

# Choose service
echo ""
echo "Choose service:"
echo "1 = NoMachine"
echo "2 = VNC"
read -p "Choice: " SERVICE_CHOICE

if [ "$SERVICE_CHOICE" = "1" ]; then
    SERVICE_NAME="NoMachine"
    LOCAL_PORT=4000
    DOCKER_IMAGE="thuonghai2711/nomachine-ubuntu-desktop:wine"
elif [ "$SERVICE_CHOICE" = "2" ]; then
    SERVICE_NAME="VNC"
    LOCAL_PORT=5900
    DOCKER_IMAGE="dperson/ubuntu-vnc-xfce"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

# Start Docker container
echo "Starting Docker container for $SERVICE_NAME..."
docker rm -f utman-$SERVICE_NAME >/dev/null 2>&1
docker run --rm -d --network host --privileged --name utman-$SERVICE_NAME \
    $DOCKER_IMAGE >/dev/null 2>&1
sleep 5
echo "$SERVICE_NAME container started."

# Function to beep alert
alert() {
    echo -e "\a[ALERT] $1"
}

# Function to keep tunnel alive and reconnect if needed
keep_alive() {
    local MAX_SECONDS=43200
    local INTERVAL=3000   # 50 minutes
    local ELAPSED=0

    while [ $ELAPSED -lt $MAX_SECONDS ]; do
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
        $1 # call reconnect command
        alert "Tunnel re-checked or reconnected"
    done
}

# ===============================
# TUNNEL LOGIC
# ===============================
case "$TUNNEL_CHOICE" in
    1)  # NGROK
        echo "Downloading ngrok CLI if not present..."
        if ! command -v ngrok &> /dev/null; then
            wget -O ngrok.zip https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-amd64.zip
            unzip -o ngrok.zip >/dev/null 2>&1
            chmod +x ngrok
        fi

        # Token validation
        MAX_RETRIES=10
        RETRY=0
        while [ $RETRY -lt $MAX_RETRIES ]; do
            echo ""
            echo "Get your ngrok authtoken at https://dashboard.ngrok.com/get-started/your-authtoken"
            read -p "Paste ngrok authtoken: " NGROK_TOKEN
            ./ngrok authtoken "$NGROK_TOKEN" >/dev/null 2>&1
            if ./ngrok config check >/dev/null 2>&1; then
                echo "[SUCCESS] ngrok token valid."
                break
            else
                echo "[ERROR] Invalid token."
                RETRY=$((RETRY+1))
            fi
        done
        if [ $RETRY -eq $MAX_RETRIES ]; then
            echo "[FATAL] Max retries reached for ngrok token."
            exit 1
        fi

        # Region selection
        echo "Choose ngrok region (us, eu, ap, au, sa, jp, in):"
        read -p "Region: " NGROK_REGION

        # Start tunnel
        ./ngrok tcp --region "$NGROK_REGION" $LOCAL_PORT >/dev/null &
        sleep 5
        PUBLIC_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p')
        echo "Tunnel established: $PUBLIC_URL"
        # Keep alive
        keep_alive "./ngrok tcp --region $NGROK_REGION $LOCAL_PORT >/dev/null &"
        ;;

    2)  # ZROK
        echo "Installing zrok CLI if not present..."
        if ! command -v zrok &> /dev/null; then
            sudo apt-get update -y >/dev/null
            sudo apt-get install -y zrok >/dev/null
        fi

        # Disable existing environment
        if zrok status 2>&1 | grep -q "enabled"; then
            zrok disable >/dev/null
        fi

        # Token validation with retries
        MAX_RETRIES=10
        RETRY=0
        while [ $RETRY -lt $MAX_RETRIES ]; do
            echo ""
            echo "Get your zrok token at https://myzrok.io/"
            read -p "Paste zrok token: " ZROK_TOKEN
            if zrok enable "$ZROK_TOKEN" >/dev/null 2>&1; then
                echo "[SUCCESS] Token enabled."
                break
            else
                echo "[ERROR] Token invalid or environment exists. Retrying..."
                RETRY=$((RETRY+1))
            fi
        done
        if [ $RETRY -eq $MAX_RETRIES ]; then
            echo "[FATAL] Max retries reached for zrok token."
            exit 1
        fi

        # Create reserved endpoint
        ENDPOINT_NAME="utman-$SERVICE_NAME-$(date +%s)"
        zrok reserve public 127.0.0.1:$LOCAL_PORT --unique-name $ENDPOINT_NAME >/dev/null 2>&1
        PUBLIC_URL=$(zrok share reserved $ENDPOINT_NAME 2>/dev/null | grep -o 'https://[^ ]*' | head -n1)
        echo "Tunnel established: $PUBLIC_URL"
        keep_alive "zrok enable $ZROK_TOKEN >/dev/null 2>&1 && zrok share reserved $ENDPOINT_NAME >/dev/null 2>&1"
        ;;

    3)  # Pinggy
        echo "Starting Pinggy TCP tunnel..."
        echo "Pinggy will auto-assign port and show URL."
        ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -p 443 -R0:localhost:$LOCAL_PORT a.pinggy.io >/dev/null &
        sleep 5
        PUBLIC_URL="tcp://$(hostname -I | awk '{print $1}'):$LOCAL_PORT"
        echo "Tunnel established: $PUBLIC_URL"
        keep_alive "ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -p 443 -R0:localhost:$LOCAL_PORT a.pinggy.io >/dev/null &"
        ;;

    4)  # SSH Tunnel
        echo "SSH Tunnel to remote host"
        read -p "Enter SSH user@host: " SSH_TARGET
        read -p "Enter remote port to forward: " REMOTE_PORT
        ssh -o ServerAliveInterval=30 -R$REMOTE_PORT:localhost:$LOCAL_PORT $SSH_TARGET >/dev/null &
        PUBLIC_URL="$SSH_TARGET:$REMOTE_PORT"
        echo "Tunnel established: $PUBLIC_URL"
        keep_alive "ssh -o ServerAliveInterval=30 -R$REMOTE_PORT:localhost:$LOCAL_PORT $SSH_TARGET >/dev/null &"
        ;;

    5)  # Cloudflare
        echo "Cloudflare Tunnel setup..."
        read -p "Enter CF tunnel name: " CF_TUNNEL
        cloudflared tunnel run $CF_TUNNEL >/dev/null &
        PUBLIC_URL="https://$CF_TUNNEL.trycloudflare.com"
        echo "Tunnel established: $PUBLIC_URL"
        keep_alive "cloudflared tunnel run $CF_TUNNEL >/dev/null &"
        ;;

    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# Final information display
echo ""
echo "======================================"
echo "$SERVICE_NAME is running."
echo "Access URL: $PUBLIC_URL"
echo "Local port: $LOCAL_PORT"
echo "Docker container: utman-$SERVICE_NAME"
echo "======================================"
alert "$SERVICE_NAME tunnel setup complete!"
