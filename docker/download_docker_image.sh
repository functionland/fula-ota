#!/bin/bash

# Ensure Docker is logged in
echo "Logging into Docker Hub..."
docker login

# Pull the images from Docker Hub
echo "Pulling Docker images..."
docker pull $GO_FULA
docker pull $FX_SUPPORT
docker pull $SUGARFUNGE_NODE

# Save the images as tar files
mkdir -p dockers
echo "Saving images as tar files..."
docker save $GO_FULA -o dockers/go-fula.tar
docker save $FX_SUPPORT -o dockers/fx-support.tar
docker save $SUGARFUNGE_NODE -o dockers/sugarfunge-node.tar

# Optional: Clean up
echo "Cleaning up..."
docker system prune -af
