#!/bin/bash

git clone -b $SUGARFUNGE_NODE_BRANCH https://github.com/functionland/sugarfunge-node
docker buildx build --platform $ARCH_SUPPORT -t $SUGARFUNGE_NODE_IMAGE:$GSUGARFUNGE_NODE_DOCKER_TAG --push .
