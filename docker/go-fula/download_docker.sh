#!/bin/bash

# Pull the go-fula image from Docker Hub
docker pull $GO_FULA_IMAGE:$GO_FULA_DOCKER_TAG

# Save the image as a tar file
mkdir -p dockers
docker save $GO_FULA_IMAGE:$GO_FULA_DOCKER_TAG -o dockers/go-fula.tar
