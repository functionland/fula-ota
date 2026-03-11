/**
 * HeadlessSetup - CLI-driven node setup that replaces the GUI wizard + mobile app flow.
 *
 * Orchestrates the complete setup: identity derivation, config writing,
 * Docker image pull, container start, and optional pool joining.
 *
 * Usage:
 *   fula-node --wallet <hex> --password <string> --authorizer <peerID> \
 *             [--chain <skale|base>] [--poolId <number>] [--data-dir <path>]
 */

const fs = require('fs/promises');
const path = require('path');
const YAML = require('yaml');

const { deriveIdentity, peerIdToBytes32 } = require('./identity-manager');
const { BlockchainManager } = require('./blockchain-manager');
const { createLogger } = require('./logger');
const { DEFAULT_DATA_DIR_WIN, DEFAULT_DATA_DIR_LINUX } = require('./constants');

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

function validateWalletHex(wallet) {
  const hex = wallet.startsWith('0x') ? wallet.slice(2) : wallet;
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
    throw new Error(
      'Invalid --wallet: must be a 64-character hex string (Ethereum private key). ' +
      'Example: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
    );
  }
}

function validatePassword(password) {
  if (!password || typeof password !== 'string' || password.length === 0) {
    throw new Error('Invalid --password: must be a non-empty string.');
  }
}

function validateAuthorizer(authorizer) {
  // libp2p Ed25519 peer IDs start with "12D3KooW" and are ~52 chars
  if (!authorizer || !authorizer.startsWith('12D3KooW') || authorizer.length < 40) {
    throw new Error(
      'Invalid --authorizer: must be a valid libp2p peer ID starting with "12D3KooW". ' +
      'This is the peer ID of the mobile device that authorizes this node.'
    );
  }
}

function validateChain(chain) {
  if (chain && !['skale', 'base'].includes(chain)) {
    throw new Error('Invalid --chain: must be "skale" or "base".');
  }
}

function validatePoolId(poolId) {
  const n = parseInt(poolId, 10);
  if (isNaN(n) || n <= 0 || String(n) !== String(poolId)) {
    throw new Error('Invalid --poolId: must be a positive integer.');
  }
  return n;
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/**
 * Parse CLI arguments from process.argv.
 * Returns null if no headless args detected (GUI mode).
 *
 * @param {string[]} argv - process.argv
 * @returns {object|null} Parsed options or null for GUI mode
 */
function parseCliArgs(argv) {
  const args = argv.slice(2); // skip node and script path

  // Quick check: if --wallet is not present, this is GUI mode
  if (!args.includes('--wallet')) {
    return null;
  }

  const options = {};

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--wallet':
        options.wallet = args[++i];
        break;
      case '--password':
        options.password = args[++i];
        break;
      case '--authorizer':
        options.authorizer = args[++i];
        break;
      case '--chain':
        options.chain = args[++i];
        break;
      case '--poolId':
      case '--pool-id':
        options.poolId = args[++i];
        break;
      case '--data-dir':
        options.dataDir = args[++i];
        break;
      case '--help':
      case '-h':
        printHelp();
        process.exit(0);
        break;
      default:
        // Ignore unknown args (Electron/Squirrel may pass their own)
        break;
    }
  }

  return options;
}

function printHelp() {
  console.log(`
Fula Node — CLI Setup Mode

Usage:
  fula-node --wallet <hex> --password <string> --authorizer <peerID> [options]

Required:
  --wallet <hex>         Ethereum wallet private key (64 hex chars, with or without 0x prefix)
  --password <string>    Password used for identity derivation (same as in mobile app)
  --authorizer <peerID>  Peer ID of the authorizing mobile device (starts with 12D3KooW)

Optional:
  --chain <skale|base>   Blockchain to join pool on (default: skale)
  --poolId <number>      Pool ID to join (requires --chain)
  --data-dir <path>      Data directory (default: platform-specific)
  --help, -h             Show this help message

Examples:
  # Basic setup (identity only, no pool):
  fula-node --wallet 0xac09...f80 --password "mypass" --authorizer 12D3KooWAaz...

  # Full setup with pool joining:
  fula-node --wallet 0xac09...f80 --password "mypass" --authorizer 12D3KooWAaz... \\
            --chain skale --poolId 1

  # Custom data directory:
  fula-node --wallet 0xac09...f80 --password "mypass" --authorizer 12D3KooWAaz... \\
            --data-dir /opt/fula-data
`);
}

// ---------------------------------------------------------------------------
// Config file writers
// ---------------------------------------------------------------------------

/**
 * Write config.yaml for go-fula.
 */
async function writeConfigYaml(dataDir, opts) {
  const configPath = path.join(dataDir, 'internal', 'config.yaml');
  const config = {
    identity: opts.identity,
    authorizer: opts.authorizer,
    storeDir: '/uniondrive',
    poolName: opts.poolName || '0',
    logLevel: 'info',
    listenAddrs: ['/ip4/0.0.0.0/tcp/40001', '/ip4/0.0.0.0/udp/40001/quic'],
    disableResourceManager: true,
    maxCIDPushRate: 100,
  };
  if (opts.chainName) {
    config.chainName = opts.chainName;
  }
  await fs.mkdir(path.dirname(configPath), { recursive: true });
  await fs.writeFile(configPath, YAML.stringify(config), 'utf-8');
  return configPath;
}

/**
 * Write box_props.json for go-fula and fula-gateway.
 */
async function writeBoxProps(dataDir, props) {
  const propsPath = path.join(dataDir, 'internal', 'box_props.json');
  await fs.mkdir(path.dirname(propsPath), { recursive: true });
  await fs.writeFile(propsPath, JSON.stringify(props, null, 2), 'utf-8');
  return propsPath;
}

/**
 * Write or update .env.gofula with HARDWARE_ID.
 */
async function writeEnvGoFula(dataDir, hardwareID) {
  const envPath = path.join(dataDir, 'config', '.env.gofula');
  let content = '';
  try {
    content = await fs.readFile(envPath, 'utf-8');
  } catch {
    // File doesn't exist yet
  }
  if (!content.includes('HARDWARE_ID=')) {
    content = content.trimEnd() + `\nHARDWARE_ID=${hardwareID}\n`;
  } else {
    content = content.replace(/^HARDWARE_ID=.*$/m, `HARDWARE_ID=${hardwareID}`);
  }
  await fs.mkdir(path.dirname(envPath), { recursive: true });
  await fs.writeFile(envPath, content, 'utf-8');
  return envPath;
}

// ---------------------------------------------------------------------------
// Main orchestrator
// ---------------------------------------------------------------------------

/**
 * Run the complete headless setup flow.
 *
 * @param {object} options - CLI options
 * @param {object} deps - Injected dependencies (configStore, storageManager, dockerManager, app)
 * @returns {Promise<void>}
 */
async function runHeadlessSetup(options, deps) {
  const { configStore, storageManager, dockerManager, app } = deps;

  // 1. Validate all inputs upfront
  console.log('Validating inputs...');
  validateWalletHex(options.wallet);
  validatePassword(options.password);
  validateAuthorizer(options.authorizer);
  if (options.chain) validateChain(options.chain);
  let poolId = null;
  if (options.poolId) {
    poolId = validatePoolId(options.poolId);
    if (!options.chain) {
      options.chain = 'skale'; // default chain
      console.log('No --chain specified, defaulting to skale');
    }
  }

  // 2. Initialize storage
  const dataDir = options.dataDir ||
    (process.platform === 'win32' ? DEFAULT_DATA_DIR_WIN : DEFAULT_DATA_DIR_LINUX);
  const storageDir = path.join(dataDir, 'storage');

  console.log(`Data directory: ${dataDir}`);
  configStore.setDataDir(dataDir);

  const logger = createLogger(path.join(dataDir, 'logs'));
  logger.info('Headless CLI setup starting...');

  // Update logger on managers
  if (storageManager) storageManager.logger = logger;
  if (dockerManager) dockerManager.logger = logger;

  await storageManager.initialize(dataDir, storageDir);

  // Copy templates
  const resourcesDir = app.isPackaged
    ? path.join(process.resourcesPath, 'templates')
    : path.join(__dirname, '..', '..', 'templates');
  await storageManager.copyTemplates(dataDir, resourcesDir);
  await dockerManager.writeComposeFiles(resourcesDir);
  logger.info('Storage initialized and templates copied');

  // 3. Generate hardware ID
  const hardwareID = configStore.getHardwareID();
  logger.info(`Hardware ID: ${hardwareID.slice(0, 8)}...`);

  // 4. Derive identity
  console.log('Deriving identity from wallet + password...');
  const { identity, kuboPeerId, clusterPeerId } = await deriveIdentity(
    options.password,
    options.wallet,
    hardwareID,
  );
  logger.info(`Cluster Peer ID: ${clusterPeerId}`);
  logger.info(`Kubo (Blox) Peer ID: ${kuboPeerId}`);

  // 5. Write config.yaml
  const configPath = await writeConfigYaml(dataDir, {
    identity,
    authorizer: options.authorizer,
    poolName: poolId ? String(poolId) : '0',
    chainName: options.chain || '',
  });
  logger.info(`Wrote ${configPath}`);

  // 6. Write box_props.json
  const propsPath = await writeBoxProps(dataDir, {
    client_peer_id: options.authorizer,
    blox_peer_id: kuboPeerId,
    blox_seed: identity,
    ipfs_cluster_peer_id: clusterPeerId,
  });
  logger.info(`Wrote ${propsPath}`);

  // 7. Write .env.gofula
  const envPath = await writeEnvGoFula(dataDir, hardwareID);
  logger.info(`Wrote ${envPath}`);

  // 8. Check Docker
  console.log('Checking Docker...');
  const dockerStatus = await dockerManager.checkDockerInstalled();
  if (!dockerStatus.installed) {
    throw new Error(
      'Docker is not installed. Please install Docker Desktop (Windows) or Docker Engine (Linux) first.'
    );
  }
  if (!dockerStatus.running) {
    throw new Error(
      'Docker daemon is not running. Please start Docker and try again.'
    );
  }

  // 9. Pull Docker images
  console.log('Pulling Docker images (this may take several minutes)...');
  // Listen for per-image progress events
  dockerManager.on('pull-progress', (msg) => {
    const line = msg.toString().trim();
    if (line) process.stdout.write(`  ${line}\n`);
  });
  try {
    await dockerManager.pullImages();
    console.log('Docker images pulled successfully.');
  } catch (err) {
    logger.warn(`Image pull failed (will try to start with cached images): ${err.message}`);
    console.log('Warning: Image pull failed. Attempting to start with cached images...');
  }

  // 10. Start Docker services
  console.log('Starting Docker services...');
  await dockerManager.start();
  logger.info('Docker services started');

  // 11. Pool joining (if requested)
  if (poolId && options.chain) {
    console.log(`Joining pool ${poolId} on ${options.chain}...`);
    const bc = new BlockchainManager(options.chain, options.wallet, logger);
    await bc.validatePool(poolId);
    await bc.ensureTokenApproval(poolId);
    const peerBytes32 = peerIdToBytes32(kuboPeerId);
    const { txHash } = await bc.joinPool(poolId, peerBytes32);
    console.log(`Pool join transaction: ${txHash}`);
  }

  // 12. Mark setup complete
  configStore.setSetupComplete(true);

  // 13. Print summary
  console.log('\n=== Setup Complete ===');
  console.log(`  Data Directory:    ${dataDir}`);
  console.log(`  Blox Peer ID:      ${kuboPeerId}`);
  console.log(`  Cluster Peer ID:   ${clusterPeerId}`);
  console.log(`  Authorizer:        ${options.authorizer}`);
  if (poolId) {
    console.log(`  Pool:              ${poolId} on ${options.chain}`);
  }
  console.log(`  Hardware ID:       ${hardwareID.slice(0, 16)}...`);
  console.log('');
  console.log('The Fula node is now running. Docker services will restart automatically on reboot.');
  console.log('To check status: docker ps --filter label=com.docker.compose.project=fula');
  logger.info('Headless setup completed successfully');
}

module.exports = {
  parseCliArgs,
  runHeadlessSetup,
  // Exported for testing / reuse:
  validateWalletHex,
  validatePassword,
  validateAuthorizer,
  validateChain,
  validatePoolId,
  writeConfigYaml,
  writeBoxProps,
  writeEnvGoFula,
};
