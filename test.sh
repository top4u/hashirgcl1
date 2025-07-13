#!/bin/bash

# 1. Check Internet connectivity
echo "Checking internet connectivity..."
if ping -c 1 google.com &>/dev/null; then
    echo "Internet connectivity: OK"
else
    echo "Internet connectivity: FAILED"
    exit 1
fi

# 2. Check Docker daemon status
echo "Checking Docker daemon status..."
if docker info &>/dev/null; then
    echo "Docker is running."
else
    echo "Docker is not running. Please start Docker and try again."
    exit 1
fi

# 3. Check for an expected Cloud Shell environment variable (specific to your Cloud Shell)
if [ -n "$CLOUD_SHELL" ]; then
    echo "Cloud Shell environment confirmed."
else
    echo "Not running in a recognized Cloud Shell environment."
fi

# 4. Sample: Check that ngrok (if running) is active before proceeding
maxattempt=20
delay=5
attempt=0
while [ $attempt -lt $maxattempt ]; do
    response=$(curl --silent --show-error http://127.0.0.1:4040/api/tunnels)
    if [[ "$response" == *"public_url"* ]]; then
        echo "Ngrok tunnel detected."
        break
    else
        echo "Waiting for ngrok tunnel... attempt $((attempt+1)) of $maxattempt."
        sleep $delay
    fi
    attempt=$((attempt+1))
done

if [ $attempt -eq $maxattempt ]; then
    echo "Ngrok tunnel did not start in time."
    exit 1
fi

echo "All checks passed. Cloud Shell should be ready."
