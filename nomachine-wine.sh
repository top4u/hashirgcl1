#!/bin/bash

# Download and set up ng.sh from GitHub
wget -O ng.sh https://github.com/kmille36/Docker-Ubuntu-Desktop-NoMachine/raw/main/ngrok.sh > /dev/null 2>&1
chmod +x ng.sh
./ng.sh

# Function to jump to a label in the script
function goto {
    label=$1
    cd 
    cmd=$(sed -n "/^:[[:blank:]][[:blank:]]*${label}/{:a;n;p;ba};" "$0" | grep -v ':$')
    eval "$cmd"
    exit
}

: ngrok
clear
echo "Go to: https://dashboard.ngrok.com/get-started/your-authtoken"
read -p "Paste Ngrok Authtoken: " CRP
./ngrok authtoken "$CRP"

clear
echo "Repo: https://github.com/kmille36/Docker-Ubuntu-Desktop-NoMachine"
echo "======================="
echo "Choose ngrok region (for better connection):"
echo "======================="
echo "us - United States (Ohio)"
echo "eu - Europe (Frankfurt)"
echo "ap - Asia/Pacific (Singapore)"
echo "au - Australia (Sydney)"
echo "sa - South America (Sao Paulo)"
echo "jp - Japan (Tokyo)"
echo "in - India (Mumbai)"
read -p "Choose ngrok region: " CRP
./ngrok tcp --region "$CRP" 4000 &>/dev/null &

# Wait for ngrok tunnel to become available: try up to 10 times, waiting 5 seconds between attempts
attempt=0
maxattempt=10
while [ $attempt -lt $maxattempt ]; do
  if curl --silent --show-error http://127.0.0.1:4040/api/tunnels > /dev/null 2>&1; then
      echo "Ngrok tunnel established successfully!"
      break
  else
      attempt=$((attempt+1))
      echo "Waiting for ngrok tunnel... attempt $attempt of $maxattempt."
      sleep 5
  fi
done

if [ $attempt -eq $maxattempt ]; then
  echo "Ngrok Error! Please try again!"
  sleep 1
  goto ngrok
fi

# Start the Docker container running NoMachine with XFCE4/Wine
docker run --rm -d --network host --privileged --name nomachine-xfce4 \
  -e PASSWORD=123456 -e USER=user --cap-add=SYS_PTRACE --shm-size=1g \
  thuonghai2711/nomachine-ubuntu-desktop:wine

clear
echo "NoMachine: https://www.nomachine.com/download"
echo "Done! NoMachine Information:"
echo "IP Address:"
curl --silent --show-error http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p'
echo "User: user"
echo "Passwd: MrBotMaker"
echo "VM can't connect? Restart Cloud Shell then re-run script."

# Simple progress timeout loop (runs for 43200 seconds, adjust as needed)
seq 1 43200 | while read i; do 
  echo -en "\r Running .     $i s /43200 s"
  sleep 0.1
  echo -en "\r Running ..    $i s /43200 s"
  sleep 0.1
  echo -en "\r Running ...   $i s /43200 s"
  sleep 0.1
  echo -en "\r Running ....  $i s /43200 s"
  sleep 0.1
  echo -en "\r Running ..... $i s /43200 s"
  sleep 0.1
  echo -en "\r Running     . $i s /43200 s"
  sleep 0.1
  echo -en "\r Running  .... $i s /43200 s"
  sleep 0.1
  echo -en "\r Running   ... $i s /43200 s"
  sleep 0.1
  echo -en "\r Running    .. $i s /43200 s"
  sleep 0.1
  echo -en "\r Running     . $i s /43200 s"
  sleep 0.1
done
