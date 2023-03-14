#!/bin/bash


SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker login 

docker buildx create --name multiarch --driver docker-container --use


#,linux/arm/v7 linux/arm64 linux/amd64
export ARCH_SUPPORT="linux/arm64,linux/amd64"

export TAG="release"
export DOCKER_REPO="functionland"

#build fxsupport
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"
export FX_SUPPORT_DOCKER_TAG="release"
echo "Building $FX_SUPPORT_IMAGE ..."
cd $SCRIPTS_DIR/fxsupport/ && ./build.sh

#build go-fula
export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_BRANCH="main"
export GO_FULA_DOCKER_TAG="release"
echo "Building $GO_FULA_IMAGE ..."
cd $SCRIPTS_DIR/go-fula/ && ./build.sh

#build node and node-api
export SUGARFUNGE_NODE_BRANCH="main"
export SUGARFUNGE_NODE_IMAGE="$DOCKER_REPO/node"
export GSUGARFUNGE_NODE_DOCKER_TAG="release"
export SUGARFUNGE_API_BRANCH="main"
echo "Building $SUGARFUNGE_NODE_IMAGE ..."
cd $SCRIPTS_DIR/sugarfunge-node/ && ./build.sh
