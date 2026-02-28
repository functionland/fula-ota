#!/bin/bash
set -e

# Define the desired platform
PLATFORM="${PLATFORM:-linux/arm64}"

# Check if the necessary variables are set
if [ -z "$FULA_GATEWAY_IMAGE" ] || [ -z "$FULA_GATEWAY_DOCKER_TAG" ]; then
    echo "The variables FULA_GATEWAY_IMAGE and FULA_GATEWAY_DOCKER_TAG must be set."
    exit 1
fi

# Pull the fula-gateway image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM "$FULA_GATEWAY_IMAGE":"$FULA_GATEWAY_DOCKER_TAG"

# Save the image as a tar file
mkdir -p dockers
docker save "$FULA_GATEWAY_IMAGE":"$FULA_GATEWAY_DOCKER_TAG" -o dockers/fula-gateway.tar

echo "Docker image saved to dockers/fula-gateway.tar"
