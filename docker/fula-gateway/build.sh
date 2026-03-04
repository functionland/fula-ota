#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/fula-local-gateway"

if [ ! -f "$BUILD_DIR/Cargo.toml" ]; then
  echo "ERROR: fula-local-gateway crate not found at $BUILD_DIR"
  exit 1
fi

docker buildx build --platform "${ARCH_SUPPORT:-linux/arm64}" \
  -t "${FULA_GATEWAY_IMAGE:-functionland/fula-gateway}:${FULA_GATEWAY_DOCKER_TAG:-release}" \
  ${PUSH:+--push} \
  "$BUILD_DIR"
