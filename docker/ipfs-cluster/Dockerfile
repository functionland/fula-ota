# Thin wrapper around the official ipfs/ipfs-cluster image.
#
# The init script bind-mounted into this container as ENTRYPOINT
# (docker/fxsupport/linux/ipfs-cluster/ipfs-cluster-container-init.d.sh)
# uses `jq` and `curl` to:
#   - fetch pool metadata from pools.fx.land
#   - rewrite service.json before starting the daemon
#   - probe local kubo API
# Neither is present in the upstream image. This wrapper installs them and
# adds nothing else. The ipfs-cluster binaries themselves come from upstream —
# no Go build, no source clone, no Go version management on our side.
#
# IPFS_CLUSTER_TAG is the upstream Docker Hub tag (e.g., "stable",
# "master-latest", or a specific version like "v1.1.6"). Passed in via
# --build-arg from CI; defaults to "stable" so a plain `docker build` works.

ARG IPFS_CLUSTER_TAG=stable
FROM ipfs/ipfs-cluster:${IPFS_CLUSTER_TAG}

# apk needs root; upstream image sets USER ipfs near the end of its Dockerfile.
USER root
RUN apk add --no-cache jq curl

# Keep USER root after install to preserve the runtime behavior of the
# previous custom build (which never set a USER directive and therefore ran
# as root). Switching to UID 1000 matches upstream's security posture but
# would be a behavioral change; revisit once init-script permissions are
# audited end-to-end against UID 1000.
# USER ipfs

# Inherit upstream's ENTRYPOINT / CMD / WORKDIR / etc. They're overridden
# anyway by docker-compose (entrypoint: /container-init.d/...).
