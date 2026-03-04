#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker buildx build --platform "${ARCH_SUPPORT:-linux/arm64}" \
  -t "${FULA_PINNING_IMAGE:-functionland/fula-pinning}:${FULA_PINNING_DOCKER_TAG:-release}" \
  ${PUSH:+--push} \
  "$SCRIPT_DIR"
