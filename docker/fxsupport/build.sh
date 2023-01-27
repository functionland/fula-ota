#!/bin/bash


docker buildx build --platform $ARCH_SUPPORT -t $FX_SUPPORT_IMAGE:$TAG --push .
