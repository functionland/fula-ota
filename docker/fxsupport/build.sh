#!/bin/bash

tee linux/docker.env << END
GO_FULA=index.docker.io/$DOCKER_REPO/go-fula:$GO_FULA_DOCKER_TAG
FX_SUPPROT=index.docker.io/$DOCKER_REPO/fxsupport:$FX_SUPPORT_DOCKER_TAG
SUGARFUNGE_NODE=index.docker.io/$DOCKER_REPO/node:$GSUGARFUNGE_NODE_DOCKER_TAG
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
END

docker buildx build --platform $ARCH_SUPPORT -t $FX_SUPPORT_IMAGE:$FX_SUPPORT_DOCKER_TAG --push .
