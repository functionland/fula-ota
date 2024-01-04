#!/bin/bash

# Pull the fxsupport image from Docker Hub
docker pull $FX_SUPPORT_IMAGE:$FX_SUPPORT_DOCKER_TAG

# Save the image as a tar file
mkdir -p dockers
docker save $FX_SUPPORT_IMAGE:$FX_SUPPORT_DOCKER_TAG -o dockers/fxsupport.tar
