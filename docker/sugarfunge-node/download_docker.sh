#!/bin/bash

# Pull the node image from Docker Hub
docker pull $SUGARFUNGE_NODE_IMAGE:$SUGARFUNGE_NODE_DOCKER_TAG

# Save the image as a tar file
mkdir -p dockers
docker save $SUGARFUNGE_NODE_IMAGE:$SUGARFUNGE_NODE_DOCKER_TAG -o dockers/sugarfunge-node.tar
