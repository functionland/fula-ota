#!/bin/bash
# Build the thin-wrapper ipfs-cluster image.
# No source clone needed — Dockerfile FROMs the upstream Docker Hub image
# and only layers jq + curl on top.

set -e

# IPFS_CLUSTER_UPSTREAM_TAG is the Docker Hub tag we wrap (stable, master-latest,
# or a pinned version). Set in docker/env_release.sh / env_test.sh.
: "${IPFS_CLUSTER_UPSTREAM_TAG:?IPFS_CLUSTER_UPSTREAM_TAG must be set (e.g. via env_release.sh)}"
: "${IPFS_CLUSTER_IMAGE:?IPFS_CLUSTER_IMAGE must be set}"
: "${IPFS_CLUSTER_DOCKER_TAG:?IPFS_CLUSTER_DOCKER_TAG must be set}"
: "${ARCH_SUPPORT:?ARCH_SUPPORT must be set}"

docker buildx build \
    --platform "$ARCH_SUPPORT" \
    --build-arg IPFS_CLUSTER_TAG="$IPFS_CLUSTER_UPSTREAM_TAG" \
    -t "$IPFS_CLUSTER_IMAGE":"$IPFS_CLUSTER_DOCKER_TAG" \
    --push .
