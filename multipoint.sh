#!/bin/bash

#######################################
# CONFIG
#######################################

RUNTIME=43200
START_TIME=$(date +%s)

#######################################
# BEEP
#######################################

beep() {
    echo -e "\a"
}

#######################################
# HEADER
#######################################

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

#######################################
# CHOOSE TUNNEL
#######################################

read -p "Choose tunnel: " TUNNEL

#######################################
# SERVICE TYPE
#######################################

echo
echo "Choose service:"
echo "1 = NoMachine"
echo "2 = VNC"
echo

read SERVICE

#######################################
# NOMACHINE
#######################################

start_nomachine() {

PORT=4000

if ! command -v nxserver &> /dev/null
then
    echo "Installing NoMachine..."
    wget -q https://download.nomachine.com/download/8.11/Linux/nomachine_8.11.3_4_amd64.deb
    sudo dpkg -i nomachine*.deb
fi

sudo /usr/NX/bin/nxserver --start

echo
echo "NoMachine running on port 4000"
beep

}

#######################################
# VNC
#######################################

start_vnc() {

echo "Display number:"
read DISPLAY

PORT=$((5900+DISPLAY))

sudo apt install -y tigervnc-standalone-server > /dev/null

vncserver :$DISPLAY

echo
echo "VNC running on $PORT"
beep

}

#######################################
# START SERVICE
#######################################

if [ "$SERVICE" = "1" ]; then
    start_nomachine
else
    start_vnc
fi

#######################################
# NGROK
#######################################

ngrok_setup() {

echo
echo "Enter ngrok authtoken:"
read TOKEN

if ! command -v ngrok &> /dev/null
then
wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar -xzf *.tgz
chmod +x ngrok
fi

./ngrok config add-authtoken $TOKEN

}

ngrok_run() {

while true
do

echo "Starting ngrok..."
beep

./ngrok tcp $PORT &

PID=$!

sleep 20

curl -s localhost:4040/api/tunnels | grep tcp

wait $PID

echo "Reconnecting ngrok..."
beep

done

}

#######################################
# ZROK
#######################################

zrok_setup() {

if ! command -v zrok &> /dev/null
then
wget -q https://get.openziti.io/zrok/latest/zrok_linux_amd64.tar.gz
tar -xzf zrok*.tar.gz
chmod +x zrok
mv zrok ~/zrok
fi

echo "Enter enable token:"
read TOKEN

~/zrok enable $TOKEN

echo "Endpoint name:"
read ENDPOINT

~/zrok reserve public 127.0.0.1:$PORT --unique-name $ENDPOINT

}

zrok_run() {

while true
do

echo "Starting zrok..."
beep

~/zrok share reserved $ENDPOINT

echo "Reconnecting..."
beep

done

}

#######################################
# PINGGY
#######################################

pinggy_run() {

while true
do

echo "Starting Pinggy..."
beep

ssh -o ServerAliveInterval=30 \
-R0:localhost:$PORT \
tcp@a.pinggy.io \
-p 443

echo
echo "New tunnel assigned"
beep

sleep 5

done

}

#######################################
# SSH TUNNEL
#######################################

ssh_run() {

echo "SSH Host:"
read HOST

echo "SSH User:"
read USER

echo "SSH Port:"
read SSHPORT

echo "Remote Port:"
read RPORT

while true
do

echo "Starting SSH tunnel..."
beep

ssh -N \
-R $RPORT:localhost:$PORT \
$USER@$HOST \
-p $SSHPORT

echo "Tunnel dropped"
beep

sleep 5

done

}

#######################################
# CLOUDFLARE
#######################################

cloudflare_setup() {

if ! command -v cloudflared &> /dev/null
then
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
fi

echo "Login to Cloudflare..."
./cloudflared tunnel login

echo "Tunnel name:"
read TUNNELNAME

./cloudflared tunnel create $TUNNELNAME

}

cloudflare_run() {

./cloudflared tunnel --url tcp://localhost:$PORT

}

#######################################
# AUTOSTART
#######################################

autostart() {

echo
echo "Enable autostart? y/n"
read AUTO

if [ "$AUTO" = "y" ]; then

mkdir -p ~/.config/autostart

cat <<EOF > ~/start_tunnel.sh
bash $(pwd)/tunnel_manager.sh
EOF

chmod +x ~/start_tunnel.sh

echo "@reboot ~/start_tunnel.sh" >> crontab.tmp
crontab crontab.tmp
rm crontab.tmp

echo "Autostart enabled"
fi

}

#######################################
# RUN SELECTED
#######################################

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
echo "Invalid"
;;

esac

#######################################
# TIMER
#######################################

while true
do

NOW=$(date +%s)
ELAPSED=$((NOW-START_TIME))

echo "Running: $ELAPSED / $RUNTIME"

if [ $ELAPSED -gt $RUNTIME ]; then
echo "12 hours finished"
break
fi

sleep 60

done
