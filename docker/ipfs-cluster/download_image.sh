#!/bin/bash

# Define the desired platform
PLATFORM="linux/arm64"

# Check if the necessary variables are set
if [ -z "$IPFS_CLUSTER_IMAGE" ] || [ -z "$IPFS_CLUSTER_DOCKER_TAG" ]; then
    echo "The variables IPFS_CLUSTER_IMAGE and IPFS_CLUSTER_DOCKER_TAG must be set."
    exit 1
fi

# Pull the ipfs-cluster image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM "$IPFS_CLUSTER_IMAGE":"$IPFS_CLUSTER_DOCKER_TAG"

# Save the image as a tar file
mkdir -p dockers
docker save "$IPFS_CLUSTER_IMAGE":"$IPFS_CLUSTER_DOCKER_TAG" -o dockers/ipfs-cluster.tar

echo "Docker image saved to dockers/ipfs-cluster.tar"
