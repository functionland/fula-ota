#!/bin/bash

#,linux/arm/v7
export ARCH_SUPPORT="linux/amd64,linux/arm64"

export TAG="release"
export DOCKER_REPO="smzahraee"
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"

export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_BRANCH="master"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker login 

docker buildx create --name multiarch --driver docker-container --use

echo "Building $FX_SUPPORT_IMAGE ..."
cd $SCRIPTS_DIR/../docker/fxsupport/ && ./build.sh


echo "Building $GO_FULA_IMAGE ..."
cd $SCRIPTS_DIR/../docker/go-fula/ && ./build.sh

