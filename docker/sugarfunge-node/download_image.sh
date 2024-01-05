#!/bin/bash

# Define the desired platform
PLATFORM="linux/arm64"

# Check if the necessary variables are set
if [ -z "$SUGARFUNGE_NODE_IMAGE" ] || [ -z "$SUGARFUNGE_NODE_DOCKER_TAG" ]; then
    echo "The variables SUGARFUNGE_NODE_IMAGE and SUGARFUNGE_NODE_DOCKER_TAG must be set."
    exit 1
fi

# Pull the node image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM $SUGARFUNGE_NODE_IMAGE:$SUGARFUNGE_NODE_DOCKER_TAG

# Save the image as a tar file
mkdir -p dockers
docker save $SUGARFUNGE_NODE_IMAGE:$SUGARFUNGE_NODE_DOCKER_TAG -o dockers/node.tar

echo "Docker image saved to dockers/node.tar"
