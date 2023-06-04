#!/bin/bash

docker buildx build --platform "$ARCH_SUPPORT" -t "$FX_SUPPORT_IMAGE:$FX_SUPPORT_DOCKER_TAG" --push .
