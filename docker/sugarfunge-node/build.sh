#!/bin/bash

# Clone and update the repositories
git clone -b "$SUGARFUNGE_NODE_BRANCH" https://github.com/functionland/sugarfunge-node
cd sugarfunge-node && git pull
cd ..
git clone -b "$SUGARFUNGE_API_BRANCH" https://github.com/functionland/sugarfunge-api
cd sugarfunge-api && git pull
cd ..
git clone -b "$PROOF_ENGINE_BRANCH" https://github.com/functionland/proof-engine
cd proof-engine && git pull
cd ..

# Extract TARGETARCH from ARCH_SUPPORT
if [[ "$ARCH_SUPPORT" == "linux/arm64" ]]; then
  TARGETARCH="arm64"
elif [[ "$ARCH_SUPPORT" == "linux/amd64" ]]; then
  TARGETARCH="amd64"
else
  echo "Unsupported ARCH_SUPPORT value: $ARCH_SUPPORT"
  exit 1
fi

# Build the Docker image with the build argument
docker buildx build --platform "$ARCH_SUPPORT" -t "$SUGARFUNGE_NODE_IMAGE":"$SUGARFUNGE_NODE_DOCKER_TAG" --build-arg TARGETARCH="$TARGETARCH" --push .
