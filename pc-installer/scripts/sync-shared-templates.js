#!/usr/bin/env node
/**
 * sync-shared-templates.js
 *
 * Generates PC-installer template files from the canonical Armbian sources in
 * docker/fxsupport/linux/.  Avoids maintaining duplicate copies of shared
 * config/init-script files.
 *
 * Two categories:
 *   EXACT_COPIES  — identical to the Armbian originals (straight copy)
 *   TRANSFORMED   — derived from the original with mechanical sed-style
 *                   replacements (bridge networking: 127.0.0.1 → kubo DNS)
 *
 * All generated files are git-ignored.  Only PC-specific files that can NOT
 * be derived (docker-compose.pc.yml, .env.pc, .env.gofula.pc) are committed.
 *
 * Run automatically via: npm run sync-templates
 * Hooked into:           prestart / prepackage / premake
 */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const armbianDir = path.join(repoRoot, 'docker', 'fxsupport', 'linux');
const pcTemplates = path.join(repoRoot, 'pc-installer', 'templates');

// ── Exact copies (identical to Armbian) ─────────────────────────────────────

const EXACT_COPIES = [
  { src: 'kubo/config',                              dest: 'kubo/config' },
  { src: 'kubo/kubo-container-init.d.sh',             dest: 'kubo/kubo-container-init.d.sh' },
  { src: 'kubo-local/config-local',                   dest: 'kubo-local/config-local' },
  { src: 'kubo-local/kubo-local-container-init.d.sh', dest: 'kubo-local/kubo-local-container-init.d.sh' },
];

// ── Transformed files (bridge-networking adaptations) ───────────────────────

const TRANSFORMED = [
  {
    src: 'ipfs-cluster/ipfs-cluster-container-init.d.sh',
    dest: 'ipfs-cluster/ipfs-cluster-container-init.d.sh',
    transforms: [
      // nc -z 127.0.0.1 5001 → nc -z kubo 5001
      { from: /nc -z 127\.0\.0\.1 5001/g, to: 'nc -z kubo 5001' },
      // http://127.0.0.1:5001 → http://kubo:5001 (all API calls)
      { from: /http:\/\/127\.0\.0\.1:5001/g, to: 'http://kubo:5001' },
    ],
  },
  {
    src: '.env.cluster',
    dest: '.env.cluster.pc',
    transforms: [
      { from: /IPFS_API=http:\/\/127\.0\.0\.1:5001/, to: 'IPFS_API=http://kubo:5001' },
      { from: /CLUSTER_IPFSHTTP_NODEMULTIADDRESS=\/ip4\/127\.0\.0\.1\/tcp\/5001/,
        to: 'CLUSTER_IPFSHTTP_NODEMULTIADDRESS=/dns4/kubo/tcp/5001' },
    ],
  },
];

// ── Run ─────────────────────────────────────────────────────────────────────

let count = 0;
const total = EXACT_COPIES.length + TRANSFORMED.length;

// Exact copies
for (const { src, dest } of EXACT_COPIES) {
  const srcPath = path.join(armbianDir, src);
  const destPath = path.join(pcTemplates, dest);

  if (!fs.existsSync(srcPath)) {
    console.warn(`WARNING: source not found, skipping: ${srcPath}`);
    continue;
  }

  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  fs.copyFileSync(srcPath, destPath);
  console.log(`Copied:      ${src}`);
  count++;
}

// Transformed files
for (const { src, dest, transforms } of TRANSFORMED) {
  const srcPath = path.join(armbianDir, src);
  const destPath = path.join(pcTemplates, dest);

  if (!fs.existsSync(srcPath)) {
    console.warn(`WARNING: source not found, skipping: ${srcPath}`);
    continue;
  }

  let content = fs.readFileSync(srcPath, 'utf-8');
  for (const { from, to } of transforms) {
    content = content.replace(from, to);
  }

  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  fs.writeFileSync(destPath, content, 'utf-8');
  console.log(`Transformed: ${src} -> ${dest}`);
  count++;
}

console.log(`\nShared template sync complete (${count}/${total} files).`);
