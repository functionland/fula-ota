#!/bin/bash

# Specify the desired platform
PLATFORM="linux/arm64"

# Pull the fxsupport image from Docker Hub for the specified platform
docker pull --platform=$PLATFORM "$FX_SUPPORT_IMAGE":"$FX_SUPPORT_DOCKER_TAG"

# Save the image as a tar file
mkdir -p dockers
docker save "$FX_SUPPORT_IMAGE":"$FX_SUPPORT_DOCKER_TAG" -o dockers/fxsupport.tar
