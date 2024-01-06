#!/bin/bash

# Define the desired platform
PLATFORM="linux/arm64"

# Check if the necessary variables are set
if [ -z "$GO_FULA_IMAGE" ] || [ -z "$GO_FULA_DOCKER_TAG" ]; then
    echo "The variables GO_FULA_IMAGE and GO_FULA_DOCKER_TAG must be set."
    exit 1
fi

# Pull the go-fula image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM "$GO_FULA_IMAGE":"$GO_FULA_DOCKER_TAG"

# Save the image as a tar file
mkdir -p dockers
docker save "$GO_FULA_IMAGE":"$GO_FULA_DOCKER_TAG" -o dockers/go-fula.tar

echo "Docker image saved to dockers/go-fula.tar"
