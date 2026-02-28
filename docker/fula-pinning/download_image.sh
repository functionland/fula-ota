#!/bin/bash

# Define the desired platform
PLATFORM="linux/arm64"

# Check if the necessary variables are set
if [ -z "$FULA_PINNING_IMAGE" ] || [ -z "$FULA_PINNING_DOCKER_TAG" ]; then
    echo "The variables FULA_PINNING_IMAGE and FULA_PINNING_DOCKER_TAG must be set."
    exit 1
fi

# Pull the fula-pinning image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM "$FULA_PINNING_IMAGE":"$FULA_PINNING_DOCKER_TAG"

# Save the image as a tar file
mkdir -p dockers
docker save "$FULA_PINNING_IMAGE":"$FULA_PINNING_DOCKER_TAG" -o dockers/fula-pinning.tar

echo "Docker image saved to dockers/fula-pinning.tar"
