#!/bin/bash

git clone -b "$IPFS_CLUSTER_BRANCH" https://github.com/ipfs-cluster/ipfs-cluster
cd ipfs-cluster && git pull
cd ..

docker buildx build --platform "$ARCH_SUPPORT" -t "$IPFS_CLUSTER_IMAGE":"$IPFS_CLUSTER_DOCKER_TAG" --push .
