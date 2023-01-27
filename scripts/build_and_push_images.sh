#!/bin/bash

export ARCH_SUPPORT="linux/amd64,linux/arm64,linux/arm/v7"

export DOCKER_REPO="smzahraee"
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"

export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_BRANCH="master"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#before runnig following commands run bellow command for enabling push to dockerhub


docker login 

docker buildx create --name multiarch --driver docker-container --use

$SCRIPTS_DIR/../docker/fxsupport/build.sh

cd $SCRIPTS_DIR/../docker/go-fula/
$SCRIPTS_DIR/../docker/go-fula/build.sh

cd $SCRIPTS_DIR/
