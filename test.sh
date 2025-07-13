#!/bin/bash

# Check internet connectivity
echo "Checking internet connectivity..."
if ping -c 1 google.com &>/dev/null; then
    echo "Internet connectivity: OK"
else
    echo "Internet connectivity: FAILED"
    exit 1
fi

# Check Docker status
echo "Checking Docker daemon status..."
if docker info &>/dev/null; then
    echo "Docker is running."
else
    echo "Docker is not running. Please start Docker and try again."
    exit 1
fi

# Check for Cloud Shell environment indicator (if applicable)
if [ -n "$CLOUD_SHELL" ]; then
    echo "Cloud Shell environment confirmed."
else
    echo "No Cloud Shell indicator found. You may not be in Cloud Shell."
fi

# If expecting a service like ngrok on port 4040, test if it is active.
max_attempts=20
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if curl --silent --head http://127.0.0.1:4040 >&/dev/null; then
        echo "Ngrok (or expected service) is running."
        break
    else
        echo "Waiting for ngrok/service... attempt $((attempt+1)) of $max_attempts."
        sleep 5
    fi
    attempt=$((attempt+1))
done

if [ $attempt -eq $max_attempts ]; then
    echo "Service did not start in time."
    exit 1
fi

echo "Cloud Shell is ready and all checks passed."
