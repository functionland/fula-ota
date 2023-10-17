#!/bin/bash


SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo login to ${DOCKER_REPO}
docker login 
#docker buildx rm multiarch
#docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect multiarch >/dev/null 2>&1 || docker buildx create --name multiarch --driver docker-container --use


#build fxsupport
echo "Building $FX_SUPPORT_IMAGE ..."
cd ${SCRIPTS_DIR}/fxsupport/ && bash ./build.sh

#build go-fula
echo "Building $GO_FULA_IMAGE ..."
cd ${SCRIPTS_DIR}/go-fula/ && bash ./build.sh

#build node and node-api
echo "Building $SUGARFUNGE_NODE_IMAGE ..."
cd ${SCRIPTS_DIR}/sugarfunge-node/ && bash ./build.sh
