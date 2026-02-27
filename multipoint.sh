#!/bin/bash

#########################################
# CONFIG
#########################################
RUNTIME=43200       # 12 hours default
START_TIME=$(date +%s)

#########################################
# BEEP FUNCTION
#########################################
beep() {
    echo -e "\a"
}

#########################################
# HEADER
#########################################
clear
echo "================================="
echo " UNIVERSAL TUNNEL MANAGER"
echo "================================="
echo
echo "Supports:"
echo "1 = ngrok"
echo "2 = zrok"
echo "3 = Pinggy"
echo "4 = SSH Tunnel"
echo "5 = Cloudflare"
echo

#########################################
# SELECT TUNNEL
#########################################
read -p "Choose tunnel: " TUNNEL

#########################################
# SELECT SERVICE
#########################################
echo
echo "Choose service:"
echo "1 = NoMachine"
echo "2 = VNC"
read SERVICE

#########################################
# NO MACHINE INSTALL & START
#########################################
install_nomachine() {
    if [ -d "/usr/NX" ]; then
        echo "NoMachine already installed"
        return
    fi

    echo "Installing NoMachine..."
    rm -f ~/nomachine.deb
    wget -q https://download.nomachine.com/download/8.11/Linux/nomachine_8.11.3_4_amd64.deb -O ~/nomachine.deb

    if [ ! -f ~/nomachine.deb ] || [ $(stat -c%s ~/nomachine.deb) -lt 200000000 ]; then
        echo "Download failed or incomplete. Exiting."
        exit 1
    fi

    sudo apt update -y
    sudo apt install -y ./nomachine.deb || sudo apt --fix-broken install -y
    echo "NoMachine installed successfully."
    sudo /usr/NX/bin/nxserver --start
    sleep 3
    echo "NoMachine running on port 4000"
    PORT=4000
    beep
}

#########################################
# VNC INSTALL & START
#########################################
install_vnc() {
    echo "Installing TigerVNC..."
    sudo apt update -y
    sudo apt install -y tigervnc-standalone-server
    echo "VNC installed"
    beep
}

start_vnc() {
    read -p "Enter display number (example 1): " DISPLAY
    vncserver :$DISPLAY
    PORT=$((5900 + DISPLAY))
    echo "VNC running on port $PORT"
    beep
}

#########################################
# SERVICE SELECT
#########################################
if [ "$SERVICE" = "1" ]; then
    install_nomachine
else
    install_vnc
    start_vnc
fi

#########################################
# NGROK
#########################################
ngrok_setup() {
    if ! command -v ngrok &>/dev/null; then
        wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
        tar -xzf ngrok-v3-stable-linux-amd64.tgz
        chmod +x ngrok
    fi

    read -p "Enter ngrok authtoken: " TOKEN
    ./ngrok config add-authtoken $TOKEN
}

ngrok_run() {
    while true; do
        echo "Starting ngrok..."
        beep
        ./ngrok tcp $PORT &
        PID=$!
        sleep 20
        curl -s localhost:4040/api/tunnels | grep tcp
        wait $PID
        echo "Ngrok reconnecting..."
        beep
    done
}

#########################################
# ZROK 1.0
#########################################
zrok_setup() {
    if ! command -v zrok &>/dev/null; then
        wget -q https://get.openziti.io/zrok/latest/zrok_linux_amd64.tar.gz
        tar -xzf zrok_linux_amd64.tar.gz
        chmod +x zrok
        mv zrok ~/zrok
    fi

    echo "Login to zrok dashboard and get enable token"
    read -p "Enter zrok enable token: " TOKEN
    ~/zrok enable $TOKEN

    read -p "Enter reserved endpoint name: " ENDPOINT
    ~/zrok reserve public 127.0.0.1:$PORT --unique-name $ENDPOINT
}

zrok_run() {
    while true; do
        echo "Starting zrok tunnel..."
        beep
        ~/zrok share reserved $ENDPOINT
        echo "zrok tunnel restarted"
        beep
    done
}

#########################################
# Pinggy
#########################################
pinggy_run() {
    while true; do
        echo "Starting Pinggy tunnel..."
        beep
        ssh -o ServerAliveInterval=30 -R0:localhost:$PORT tcp@a.pinggy.io -p 443
        echo "Pinggy tunnel assigned new port"
        beep
        sleep 5
    done
}

#########################################
# SSH Tunnel
#########################################
ssh_run() {
    read -p "SSH Host: " HOST
    read -p "SSH User: " USER
    read -p "SSH Port: " SSHPORT
    read -p "Remote port: " RPORT

    while true; do
        echo "Starting SSH tunnel..."
        beep
        ssh -N -R $RPORT:localhost:$PORT $USER@$HOST -p $SSHPORT
        echo "SSH tunnel dropped, reconnecting..."
        beep
        sleep 5
    done
}

#########################################
# Cloudflare Tunnel
#########################################
cloudflare_setup() {
    if ! command -v cloudflared &>/dev/null; then
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x cloudflared
    fi

    echo "Login to Cloudflare dashboard"
    ./cloudflared tunnel login
    read -p "Enter tunnel name: " TUNNELNAME
    ./cloudflared tunnel create $TUNNELNAME
}

cloudflare_run() {
    ./cloudflared tunnel --url tcp://localhost:$PORT
}

#########################################
# AUTOSTART OPTION
#########################################
autostart() {
    read -p "Enable autostart on boot? (y/n): " AUTO
    if [ "$AUTO" = "y" ]; then
        mkdir -p ~/tunnel_autostart
        cp "$0" ~/tunnel_autostart/start_tunnel.sh
        chmod +x ~/tunnel_autostart/start_tunnel.sh
        (crontab -l 2>/dev/null; echo "@reboot ~/tunnel_autostart/start_tunnel.sh") | crontab -
        echo "Autostart enabled"
        beep
    fi
}

#########################################
# RUN SELECTED TUNNEL
#########################################
case $TUNNEL in
1)
    ngrok_setup
    autostart
    ngrok_run
    ;;
2)
    zrok_setup
    autostart
    zrok_run
    ;;
3)
    autostart
    pinggy_run
    ;;
4)
    autostart
    ssh_run
    ;;
5)
    cloudflare_setup
    autostart
    cloudflare_run
    ;;
*)
    echo "Invalid selection"
    ;;
esac

#########################################
# TIMER LOOP
#########################################
while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW-START_TIME))
    printf "\rRunning: %d / %d seconds" $ELAPSED $RUNTIME
    if [ $ELAPSED -gt $RUNTIME ]; then
        echo
        echo "12 hours finished"
        beep
        break
    fi
    sleep 10
done
