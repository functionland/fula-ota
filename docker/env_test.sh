#,linux/arm/v7 linux/arm64 linux/amd64
export ARCH_SUPPORT="linux/arm64"

export DOCKER_REPO="functionland"
export DEFAULT_FX_TAG="test17"
export DEFAULT_FULA_TAG="test17"
export DEFAULT_NODE_TAG="release"

#build fxsupport
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"
export FX_SUPPORT_DOCKER_TAG="$DEFAULT_FX_TAG"

#build go-fula
export GO_FULA_BRANCH="blockchain-package"
export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_DOCKER_TAG="$DEFAULT_FULA_TAG"

#build node and node-api
export SUGARFUNGE_NODE_BRANCH="main"
export SUGARFUNGE_API_BRANCH="main"
export SUGARFUNGE_NODE_IMAGE="$DOCKER_REPO/node"
export GSUGARFUNGE_NODE_DOCKER_TAG="$DEFAULT_NODE_TAG"


#create docker.env in fxsupport/linux/docker.env
echo "docker images will produce with following variables:"
DOCKER_URI="index.docker.io"
tee fxsupport/linux/docker.env << END
GO_FULA=$DOCKER_URI/$DOCKER_REPO/go-fula:$GO_FULA_DOCKER_TAG
FX_SUPPROT=$DOCKER_URI/$DOCKER_REPO/fxsupport:$FX_SUPPORT_DOCKER_TAG
SUGARFUNGE_NODE=$DOCKER_URI/$DOCKER_REPO/node:$GSUGARFUNGE_NODE_DOCKER_TAG
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
END
