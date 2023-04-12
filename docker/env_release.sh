#,linux/arm/v7 linux/arm64 linux/amd64
export ARCH_SUPPORT="linux/arm64"

export DOCKER_REPO="functionland"

#build fxsupport
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"
export FX_SUPPORT_DOCKER_TAG="release"

#build go-fula
export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_BRANCH="main"
export GO_FULA_DOCKER_TAG="release"

#build node and node-api
export SUGARFUNGE_NODE_BRANCH="main"
export SUGARFUNGE_NODE_IMAGE="$DOCKER_REPO/node"
export GSUGARFUNGE_NODE_DOCKER_TAG="release"
export SUGARFUNGE_API_BRANCH="main"