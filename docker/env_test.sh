#,linux/arm/v7 linux/arm64 linux/amd64
export ARCH_SUPPORT="linux/arm64"

export DOCKER_REPO="functionland"
export TEST_TAG="${TEST_TAG:-test147}"
export DEFAULT_FX_TAG="$TEST_TAG"
export DEFAULT_FULA_TAG="$TEST_TAG"
export DEFAULT_NODE_TAG="$TEST_TAG"

#build fxsupport
export FX_SUPPORT_IMAGE="$DOCKER_REPO/fxsupport"
export FX_SUPPORT_DOCKER_TAG="$DEFAULT_FX_TAG"

#build go-fula
export GO_FULA_BRANCH="main"
export GO_FULA_IMAGE="$DOCKER_REPO/go-fula"
export GO_FULA_DOCKER_TAG="$DEFAULT_FULA_TAG"

#build ipfs-cluster
export IPFS_CLUSTER_BRANCH="master"
export IPFS_CLUSTER_IMAGE="$DOCKER_REPO/ipfs-cluster"
export IPFS_CLUSTER_DOCKER_TAG="$TEST_TAG"

#create .env in fxsupport/linux/.env
echo "docker images will produce with following variables:"
DOCKER_URI="index.docker.io"
tee fxsupport/linux/.env << END
GO_FULA=$DOCKER_URI/$DOCKER_REPO/go-fula:$GO_FULA_DOCKER_TAG
FX_SUPPROT=$DOCKER_URI/$DOCKER_REPO/fxsupport:$FX_SUPPORT_DOCKER_TAG
IPFS_CLUSTER=$DOCKER_URI/$DOCKER_REPO/ipfs-cluster:$IPFS_CLUSTER_DOCKER_TAG
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
END
