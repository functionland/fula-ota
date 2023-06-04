#!/bin/bash

git clone -b $SUGARFUNGE_NODE_BRANCH https://github.com/functionland/sugarfunge-node
cd sugarfunge-node && git pull
cd ..
git clone -b $SUGARFUNGE_API_BRANCH https://github.com/functionland/sugarfunge-api
cd sugarfunge-api && git pull
cd ..

docker buildx build --platform $ARCH_SUPPORT -t $SUGARFUNGE_NODE_IMAGE:$GSUGARFUNGE_NODE_DOCKER_TAG --push .
