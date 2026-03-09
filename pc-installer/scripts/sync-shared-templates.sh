#!/bin/bash
# sync-shared-templates.sh
#
# Generates PC-installer template files from the canonical Armbian sources.
# Prefer the Node.js version (sync-shared-templates.js) — this is a fallback.
#
# Two categories:
#   Exact copies  — straight cp from Armbian
#   Transformed   — sed replacements for bridge networking (127.0.0.1 → kubo)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARMBIAN_DIR="${REPO_ROOT}/docker/fxsupport/linux"
PC_TEMPLATES="${REPO_ROOT}/pc-installer/templates"

# ── Exact copies ──

declare -A EXACT=(
  ["kubo/config"]="kubo/config"
  ["kubo/kubo-container-init.d.sh"]="kubo/kubo-container-init.d.sh"
  ["kubo-local/config-local"]="kubo-local/config-local"
  ["kubo-local/kubo-local-container-init.d.sh"]="kubo-local/kubo-local-container-init.d.sh"
)

for src_rel in "${!EXACT[@]}"; do
  dest_rel="${EXACT[$src_rel]}"
  src="${ARMBIAN_DIR}/${src_rel}"
  dest="${PC_TEMPLATES}/${dest_rel}"

  if [ ! -f "$src" ]; then
    echo "WARNING: source not found, skipping: ${src}" >&2
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "Copied:      ${src_rel}"
done

# ── Transformed: ipfs-cluster init script ──

src="${ARMBIAN_DIR}/ipfs-cluster/ipfs-cluster-container-init.d.sh"
dest="${PC_TEMPLATES}/ipfs-cluster/ipfs-cluster-container-init.d.sh"
if [ -f "$src" ]; then
  mkdir -p "$(dirname "$dest")"
  sed -e 's/nc -z 127\.0\.0\.1 5001/nc -z kubo 5001/g' \
      -e 's|http://127\.0\.0\.1:5001|http://kubo:5001|g' \
      "$src" > "$dest"
  echo "Transformed: ipfs-cluster/ipfs-cluster-container-init.d.sh"
fi

# ── Transformed: .env.cluster ──

src="${ARMBIAN_DIR}/.env.cluster"
dest="${PC_TEMPLATES}/.env.cluster.pc"
if [ -f "$src" ]; then
  sed -e 's|IPFS_API=http://127\.0\.0\.1:5001|IPFS_API=http://kubo:5001|' \
      -e 's|CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/ip4/127\.0\.0\.1/tcp/5001|CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/dns4/kubo/tcp/5001|' \
      "$src" > "$dest"
  echo "Transformed: .env.cluster -> .env.cluster.pc"
fi

echo ""
echo "Shared template sync complete."
