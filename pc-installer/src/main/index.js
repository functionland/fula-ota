const { app, BrowserWindow, ipcMain, shell, dialog } = require('electron');
const fs = require('fs').promises;
const os = require('os');
const path = require('path');

// Handle Squirrel.Windows install/uninstall events (must be early, before app.ready)
if (process.platform === 'win32') {
  const squirrelEvent = process.argv[1];
  if (
    squirrelEvent === '--squirrel-install' ||
    squirrelEvent === '--squirrel-updated' ||
    squirrelEvent === '--squirrel-uninstall' ||
    squirrelEvent === '--squirrel-obsolete'
  ) {
    const { spawnSync, execSync } = require('child_process');
    const updateExe = path.resolve(process.execPath, '..', '..', 'Update.exe');
    const exeName = path.basename(process.execPath);

    if (squirrelEvent === '--squirrel-install' || squirrelEvent === '--squirrel-updated') {
      spawnSync(updateExe, ['--createShortcut', exeName]);

      // Add Windows Firewall rules for mDNS and Fula services.
      // Uses UAC elevation (Start-Process -Verb RunAs) to get admin privileges.
      // User sees a single UAC prompt during install/update.
      try {
        const fs = require('fs');
        const osTmpDir = require('os').tmpdir();
        const fwBat = path.join(osTmpDir, 'fula-fw.bat');
        fs.writeFileSync(fwBat, [
          '@echo off',
          'netsh advfirewall firewall delete rule name="Fula Node" >nul 2>&1',
          `netsh advfirewall firewall add rule name="Fula Node" dir=in action=allow program="${process.execPath}" enable=yes profile=any`,
          'netsh advfirewall firewall delete rule name="Fula Node mDNS" >nul 2>&1',
          'netsh advfirewall firewall add rule name="Fula Node mDNS" dir=in action=allow protocol=udp localport=5353 enable=yes profile=any',
          'netsh advfirewall firewall delete rule name="Fula Node Services" >nul 2>&1',
          'netsh advfirewall firewall add rule name="Fula Node Services" dir=in action=allow protocol=tcp localport=3500,4001,9000,9094 enable=yes profile=any',
        ].join('\r\n'));
        // PowerShell Start-Process with -Verb RunAs triggers a UAC elevation prompt
        execSync(
          `powershell -Command "Start-Process '${fwBat.replace(/'/g, "''")}' -Verb RunAs -Wait"`,
          { timeout: 60000, stdio: 'ignore' }
        );
        try { fs.unlinkSync(fwBat); } catch {}
      } catch {
        // UAC declined or PowerShell unavailable — non-fatal.
        // Windows may show its own "allow network access" dialog at runtime.
      }

      // Force-kill ALL old running instances so the relaunch after update
      // gets the single-instance lock and runs the new code.
      try {
        const myPid = process.pid;
        execSync(
          `taskkill /F /IM "${exeName}" /FI "PID ne ${myPid}"`,
          { encoding: 'utf-8', timeout: 10000, stdio: 'ignore' }
        );
      } catch {
        // No other instances running — that's fine
      }
      // Let OS release resources (ports, tray icon, single-instance lock).
      // Squirrel will relaunch the app automatically after this handler exits.
      spawnSync('timeout', ['/t', '3', '/nobreak'], { stdio: 'ignore' });
    } else if (squirrelEvent === '--squirrel-uninstall') {
      spawnSync(updateExe, ['--removeShortcut', exeName]);
      // Clean up firewall rules
      try { execSync('netsh advfirewall firewall delete rule name="Fula Node" >nul 2>&1', { stdio: 'ignore' }); } catch {}
      try { execSync('netsh advfirewall firewall delete rule name="Fula Node mDNS" >nul 2>&1', { stdio: 'ignore' }); } catch {}
      try { execSync('netsh advfirewall firewall delete rule name="Fula Node Services" >nul 2>&1', { stdio: 'ignore' }); } catch {}
    }

    // process.exit is synchronous — guarantees no further code runs
    process.exit(0);
  }
}

const TrayManager = require('./tray-manager');
const DockerManager = require('./docker-manager');
const { HealthMonitor } = require('./health-monitor');
const StorageManager = require('./storage-manager');
const PortChecker = require('./firewall-manager');
const PluginManager = require('./plugin-manager');
const UpdateManager = require('./update-manager');
const MdnsAdvertiser = require('./mdns-advertiser');
const configStore = require('./config-store');
const { createLogger } = require('./logger');
const { PORTS, HEALTH_CHECK_INTERVAL, DEFAULT_DATA_DIR_WIN, DEFAULT_DATA_DIR_LINUX } = require('./constants');

let trayManager;
let dockerManager;
let healthMonitor;
let storageManager;
let portChecker;
let pluginManager;
let updateManager;
let mdnsAdvertiser;
let logger;
let wizardWindow = null;
let dashboardWindow = null;

// Single instance lock
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
}

app.on('second-instance', () => {
  if (dashboardWindow && !dashboardWindow.isDestroyed()) {
    if (dashboardWindow.isMinimized()) dashboardWindow.restore();
    dashboardWindow.focus();
  } else if (wizardWindow && !wizardWindow.isDestroyed()) {
    if (wizardWindow.isMinimized()) wizardWindow.restore();
    wizardWindow.focus();
  } else if (configStore.isSetupComplete()) {
    openDashboard();
  } else {
    openWizard();
  }
});

app.on('ready', async () => {
  // Initialize logger (console only until data dir is known)
  logger = createLogger();
  logger.info(`Fula Node v${app.getVersion()} starting...`);

  // Initialize managers
  storageManager = new StorageManager(logger);
  dockerManager = new DockerManager(configStore, logger);
  portChecker = new PortChecker(logger);
  pluginManager = new PluginManager(dockerManager, configStore, logger);
  updateManager = new UpdateManager(dockerManager, logger);
  mdnsAdvertiser = new MdnsAdvertiser(logger);

  // Create tray icon
  trayManager = new TrayManager(configStore);
  trayManager.create();

  // Wire tray events
  trayManager.on('open-dashboard', openDashboard);
  trayManager.on('open-wizard', openWizard);
  trayManager.on('start', async () => {
    trayManager.setStatus('blue');
    try { await dockerManager.start(); } catch (e) { logger.error(e.message); }
  });
  trayManager.on('stop', async () => {
    trayManager.setStatus('grey');
    try { await dockerManager.stop(); } catch (e) { logger.error(e.message); }
  });
  trayManager.on('restart', async () => {
    trayManager.setStatus('yellow');
    try { await dockerManager.restart(); } catch (e) { logger.error(e.message); }
  });
  trayManager.on('open-logs', () => {
    const dataDir = configStore.getDataDir();
    if (dataDir) shell.openPath(path.join(dataDir, 'logs'));
  });

  // Detect app update by comparing stored version with current
  const currentVersion = app.getVersion();
  const previousVersion = configStore.store.get('lastRunVersion');
  const wasUpdated = previousVersion && previousVersion !== currentVersion;
  configStore.store.set('lastRunVersion', currentVersion);

  // Check if first run or setup needed
  if (configStore.isSetupComplete()) {
    await startServices();
    openDashboard();

    if (wasUpdated) {
      dialog.showMessageBox({
        type: 'info',
        title: 'Fula Node Updated',
        message: `Fula Node has been updated to v${currentVersion}`,
        detail: `Previous version: v${previousVersion}\n\nThe node is now running with the latest version.`,
        buttons: ['OK'],
      });
    }
  } else {
    trayManager.setStatus('cyan');
    openWizard();
  }

  // Register IPC handlers
  registerIpcHandlers();
});

/** Detect the host's public IP via an external service. Returns null on failure. */
async function getPublicIp() {
  return new Promise((resolve) => {
    const https = require('https');
    const req = https.get('https://api.ipify.org', { timeout: 5000 }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => {
        const ip = body.trim();
        resolve(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(ip) ? ip : null);
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

/**
 * Patch kubo config for Docker Desktop networking:
 * 1. Inject host LAN IP (+ public IP if detectable) into AppendAnnounce
 *    so kubo advertises reachable addresses to the DHT.
 * 2. Set Internal.Libp2pForceReachability = "private" so kubo always
 *    considers itself behind NAT and requests relay v2 reservations.
 *    (AutoNAT can't work inside Docker bridge — it only sees container IPs.)
 */
async function injectKuboAnnounceAddrs(dataDir) {
  const lanIp = getLanIp();
  if (!lanIp) {
    logger.warn('injectKuboAnnounceAddrs: no LAN IP found, skipping');
    return;
  }

  const announceAddrs = [
    `/ip4/${lanIp}/tcp/4001`,
    `/ip4/${lanIp}/udp/4001/quic-v1`,
    `/ip4/${lanIp}/udp/4001/quic-v1/webtransport`,
  ];

  // Try to detect public IP for internet DHT reachability
  const publicIp = await getPublicIp();
  if (publicIp && publicIp !== lanIp) {
    announceAddrs.push(
      `/ip4/${publicIp}/tcp/4001`,
      `/ip4/${publicIp}/udp/4001/quic-v1`,
      `/ip4/${publicIp}/udp/4001/quic-v1/webtransport`,
    );
    logger.info(`injectKuboAnnounceAddrs: detected public IP ${publicIp}`);
  }

  const configPaths = [
    path.join(dataDir, 'internal', 'ipfs_data', 'config'),
    path.join(dataDir, 'config', 'kubo', 'config'),
  ];

  for (const cfgPath of configPaths) {
    try {
      const raw = await fs.readFile(cfgPath, 'utf-8');
      const cfg = JSON.parse(raw);
      cfg.Addresses = cfg.Addresses || {};
      cfg.Addresses.AppendAnnounce = announceAddrs;
      // Force kubo to consider itself behind NAT so it always requests
      // relay v2 reservations. Docker bridge prevents AutoNAT from working.
      cfg.Internal = cfg.Internal || {};
      cfg.Internal.Libp2pForceReachability = 'private';
      await fs.writeFile(cfgPath, JSON.stringify(cfg, null, 2), 'utf-8');
      logger.info(`injectKuboAnnounceAddrs: patched ${cfgPath} — LAN=${lanIp}${publicIp ? `, public=${publicIp}` : ''}, forcePrivate=true`);
    } catch (err) {
      if (err.code !== 'ENOENT') {
        logger.warn(`injectKuboAnnounceAddrs: failed to patch ${cfgPath}: ${err.message}`);
      }
    }
  }
}

async function startServices() {
  const dataDir = configStore.getDataDir();
  if (!dataDir) return;

  // Upgrade logger to file-based
  logger = createLogger(path.join(dataDir, 'logs'));
  logger.info(`Fula Node v${app.getVersion()} startServices() — exe: ${process.execPath}`);

  // Update logger reference in all managers that were created with the
  // console-only logger before the data dir was known.
  if (mdnsAdvertiser) mdnsAdvertiser.logger = logger;
  if (dockerManager) dockerManager.logger = logger;
  if (storageManager) storageManager.logger = logger;
  if (portChecker) portChecker.logger = logger;
  if (pluginManager) pluginManager.logger = logger;
  if (updateManager) updateManager.logger = logger;

  // Stop existing health monitor / mDNS polling if startServices is called again
  // (prevents multiple monitors stacking up and causing restart storms)
  if (healthMonitor) {
    healthMonitor.stop();
    healthMonitor.removeAllListeners();
    healthMonitor = null;
  }
  if (mdnsAuthorizerPollTimer) {
    clearInterval(mdnsAuthorizerPollTimer);
    mdnsAuthorizerPollTimer = null;
  }

  trayManager.setStatus('blue');

  // Re-apply templates on every launch to pick up fixes (e.g. CRLF stripping,
  // compose changes) delivered by app updates.  This is idempotent.
  try {
    const resourcesDir = app.isPackaged
      ? path.join(process.resourcesPath, 'templates')
      : path.join(__dirname, '..', '..', 'templates');
    await storageManager.copyTemplates(dataDir, resourcesDir);
    await dockerManager.writeComposeFiles(resourcesDir);
    logger.info('Templates re-applied from bundled resources');
  } catch (e) {
    logger.warn(`Template re-apply failed (non-fatal): ${e.message}`);
  }

  // Inject host LAN IP into kubo's AppendAnnounce so it advertises
  // reachable addresses to the DHT (Docker containers can't see the host IP).
  await injectKuboAnnounceAddrs(dataDir);

  // Start docker containers — failure is non-fatal because the health
  // monitor (below) will track the real state continuously.
  try {
    await dockerManager.start();
  } catch (e) {
    logger.warn(`Docker start failed (health monitor will track): ${e.message}`);
  }

  // ALWAYS start the health monitor — it is the single source of truth
  // for tray color.  Even if docker-compose failed, the monitor will
  // detect running/stopped containers and set the correct color.
  healthMonitor = new HealthMonitor(dockerManager, configStore, logger);
  healthMonitor.on('status', (status) => {
    trayManager.setStatus(status.color);
    if (dashboardWindow && !dashboardWindow.isDestroyed()) {
      // Transform checks object into array format for dashboard renderer
      const checksArray = Object.entries(status.checks).map(([name, c]) => ({
        name,
        status: c.ok ? 'ok' : 'fail',
        detail: c.detail || '',
      }));
      dashboardWindow.webContents.send('health-status', {
        color: status.color,
        checks: checksArray,
        issues: status.issues,
      });
    }
  });
  healthMonitor.on('needs-restart', async () => {
    logger.warn('Health monitor triggered restart');
    trayManager.setStatus('yellow');
    try { await dockerManager.restart(); } catch (e) { logger.error(e.message); }
  });
  healthMonitor.start(HEALTH_CHECK_INTERVAL);

  // Start mDNS after a delay to let containers initialize
  logger.info('mDNS: scheduling startMdnsWithContainerProps in 30s');
  setTimeout(() => {
    logger.info('mDNS: 30s timer fired, calling startMdnsWithContainerProps now');
    startMdnsWithContainerProps();
  }, 30000);

  // Start stale image checker
  updateManager.startStaleImageCheck();
}

/** Fetch a JSON response from a local HTTP endpoint. Returns parsed body or null. */
function fetchLocalJson(port, path, method = 'GET', timeout = 5000) {
  return new Promise((resolve) => {
    const http = require('http');
    const req = http.request({ hostname: '127.0.0.1', port, path, method, timeout }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
}

let mdnsAuthorizerPollTimer = null;

/**
 * Verify kubo's Internal.Libp2pForceReachability is set to "private" via API.
 * Kubo repo migrations (Go struct serialization) can wipe this field.
 * If wiped, re-set via API and restart kubo so it takes effect.
 */
async function ensureKuboNetworkConfig() {
  const current = await fetchLocalJson(
    PORTS.kuboApi,
    '/api/v0/config?arg=Internal.Libp2pForceReachability',
    'POST'
  );
  if (current?.Value === 'private') {
    logger.info('ensureKuboNetworkConfig: ForceReachabilityPrivate already set');
    return false;
  }

  logger.info('ensureKuboNetworkConfig: setting Internal.Libp2pForceReachability=private via API (migration wiped it)');
  await fetchLocalJson(
    PORTS.kuboApi,
    '/api/v0/config?arg=Internal.Libp2pForceReachability&arg=private',
    'POST'
  );

  // Restart kubo so the setting takes effect (it's read at daemon startup)
  logger.info('ensureKuboNetworkConfig: restarting kubo to apply ForceReachabilityPrivate');
  try {
    await dockerManager.restartService('kubo');
  } catch (e) {
    logger.warn(`ensureKuboNetworkConfig: kubo restart failed: ${e.message}`);
  }
  return true;
}

/** Gather peer IDs and properties from running containers, then start mDNS.
 *  Retries up to 6 times (every 15s) if kubo or go-fula aren't ready yet. */
async function startMdnsWithContainerProps(attempt = 0) {
  const MAX_RETRIES = 6;
  logger.info(`mDNS: startMdnsWithContainerProps attempt=${attempt}`);
  try {
    // Fetch kubo peer ID (POST /api/v0/id)
    const kuboId = await fetchLocalJson(PORTS.kuboApi, '/api/v0/id', 'POST');
    const bloxPeerIdString = kuboId?.ID || '';
    logger.info(`mDNS: kuboId=${bloxPeerIdString || '(empty)'}`);

    // Ensure relay config survived kubo startup (migrations can wipe it).
    // If kubo needed a restart, retry mDNS setup after it comes back up.
    if (bloxPeerIdString && attempt === 0) {
      const restarted = await ensureKuboNetworkConfig();
      if (restarted) {
        logger.info('mDNS: kubo restarted for relay config, retrying in 20s');
        setTimeout(() => startMdnsWithContainerProps(0), 20000);
        return;
      }
    }

    // Fetch go-fula properties (GET /properties) — includes hardwareID, authorizer
    logger.info('mDNS: fetching go-fula properties...');
    const goFulaProps = await fetchLocalJson(PORTS.goFulaWap, '/properties');
    const hardwareID = goFulaProps?.hardwareID || '';
    const authorizer = goFulaProps?.authorizer || '';
    logger.info(`mDNS: hardwareID=${hardwareID || '(empty)'}, authorizer=${authorizer || '(empty)'}`);

    if (!bloxPeerIdString && !hardwareID && attempt < MAX_RETRIES) {
      logger.info(`mDNS: containers not ready yet (attempt ${attempt + 1}/${MAX_RETRIES}), retrying in 15s...`);
      setTimeout(() => startMdnsWithContainerProps(attempt + 1), 15000);
      return;
    }

    // Fetch ipfs-cluster peer ID (GET /id) — optional, may not be running
    const clusterInfo = await fetchLocalJson(PORTS.clusterApi, '/id');
    const ipfsClusterID = clusterInfo?.id || '';
    logger.info(`mDNS: clusterID=${ipfsClusterID || '(empty)'}, calling mdnsAdvertiser.start()...`);

    await mdnsAdvertiser.start({
      bloxPeerIdString,
      authorizer,
      hardwareID,
      poolName: '',
      ipfsClusterID,
      wapPort: PORTS.goFulaWap,
    });
    logger.info('mDNS: mdnsAdvertiser.start() completed');

    // Start polling go-fula /properties every 60s to detect authorizer changes
    startAuthorizerPolling();
  } catch (e) {
    if (logger) logger.warn(`mDNS startup failed: ${e.message}`);
    if (attempt < MAX_RETRIES) {
      setTimeout(() => startMdnsWithContainerProps(attempt + 1), 15000);
    }
  }
}

/** Poll go-fula /properties periodically; re-advertise mDNS when authorizer or bloxPeerIdString changes. */
function startAuthorizerPolling() {
  if (mdnsAuthorizerPollTimer) return;
  let lastAuthorizer = mdnsAdvertiser.lastTxt?.authorizer || '';
  let lastBloxPeerId = mdnsAdvertiser.lastTxt?.bloxPeerIdString || '';

  mdnsAuthorizerPollTimer = setInterval(async () => {
    try {
      const props = await fetchLocalJson(PORTS.goFulaWap, '/properties');
      if (!props) return;
      const currentAuthorizer = props.authorizer || '';
      const currentKuboPeerId = props.kubo_peer_id || '';
      let needsUpdate = false;
      const updates = {};

      if (currentAuthorizer !== lastAuthorizer) {
        lastAuthorizer = currentAuthorizer;
        updates.authorizer = currentAuthorizer;
        needsUpdate = true;
        logger.info(`Authorizer changed to: ${currentAuthorizer || '(empty)'}`);
      }
      // Re-advertise when kubo peer ID becomes available (was empty on initial start)
      if (currentKuboPeerId && currentKuboPeerId !== lastBloxPeerId) {
        lastBloxPeerId = currentKuboPeerId;
        updates.bloxPeerIdString = currentKuboPeerId;
        needsUpdate = true;
        logger.info(`bloxPeerIdString changed to: ${currentKuboPeerId}`);
      }
      if (needsUpdate) {
        logger.info('Re-advertising mDNS with updated properties');
        await mdnsAdvertiser.updateAdvertisement(updates);
      }
    } catch {}
  }, 60000);
}

function openWizard() {
  if (wizardWindow && !wizardWindow.isDestroyed()) {
    wizardWindow.focus();
    return;
  }
  wizardWindow = new BrowserWindow({
    width: 800,
    height: 600,
    resizable: false,
    icon: path.join(__dirname, '..', 'assets', 'icons', 'fula.ico'),
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'Fula Node Setup'
  });
  wizardWindow.loadFile(path.join(__dirname, '..', 'renderer', 'wizard', 'index.html'));
  wizardWindow.setMenuBarVisibility(false);
  wizardWindow.on('closed', () => { wizardWindow = null; });
}

function openDashboard() {
  if (dashboardWindow && !dashboardWindow.isDestroyed()) {
    dashboardWindow.focus();
    return;
  }
  dashboardWindow = new BrowserWindow({
    width: 900,
    height: 700,
    icon: path.join(__dirname, '..', 'assets', 'icons', 'fula.ico'),
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'Fula Node Dashboard'
  });
  dashboardWindow.loadFile(path.join(__dirname, '..', 'renderer', 'dashboard', 'index.html'));
  dashboardWindow.setMenuBarVisibility(false);
  dashboardWindow.on('closed', () => { dashboardWindow = null; });
}

function registerIpcHandlers() {
  // Docker checks
  ipcMain.handle('check-docker', () => dockerManager.checkDockerInstalled());
  ipcMain.handle('check-disk-space', (_, dir) => storageManager.checkDiskSpace(dir));
  ipcMain.handle('check-ports', (_, ports) => portChecker.checkPortAvailability(ports));

  // Setup flow
  ipcMain.handle('get-default-data-dir', () => {
    return process.platform === 'win32' ? DEFAULT_DATA_DIR_WIN : DEFAULT_DATA_DIR_LINUX;
  });

  ipcMain.handle('open-folder-dialog', async () => {
    const result = await dialog.showOpenDialog({
      properties: ['openDirectory', 'createDirectory'],
      title: 'Select Fula Node Data Directory',
    });
    if (result.canceled || !result.filePaths.length) return null;
    return result.filePaths[0];
  });

  ipcMain.handle('setup-initialize', async (_, dataDir, storageDir) => {
    try {
      configStore.setDataDir(dataDir);
      if (storageDir) {
        configStore.setStorageDir(storageDir);
      }
      const effectiveStorageDir = configStore.getStorageDir();
      await storageManager.initialize(dataDir, effectiveStorageDir);
      // In packaged app: extraResource puts templates/ in process.resourcesPath
      // In dev: templates/ is at ../../templates relative to this file
      const resourcesDir = app.isPackaged
        ? path.join(process.resourcesPath, 'templates')
        : path.join(__dirname, '..', '..', 'templates');
      await storageManager.copyTemplates(dataDir, resourcesDir);
      // Write compose files with FULA_DATA_DIR / FULA_STORAGE_DIR substitution
      await dockerManager.writeComposeFiles(resourcesDir);
      return { success: true };
    } catch (e) {
      return { success: false, error: e.message };
    }
  });

  ipcMain.handle('setup-pull-images', async () => {
    try {
      await dockerManager.pullImages();
      return { success: true };
    } catch (e) {
      return { success: false, error: e.message };
    }
  });

  ipcMain.handle('setup-start', async () => {
    try {
      configStore.setSetupComplete(true);
      await startServices();
      return { success: true };
    } catch (e) {
      return { success: false, error: e.message };
    }
  });

  // Dashboard
  ipcMain.handle('get-container-status', () => dockerManager.getContainerStatus());
  ipcMain.handle('get-container-logs', (_, name, tail) => dockerManager.getContainerLogs(name, tail));
  ipcMain.handle('restart-service', (_, name) => dockerManager.restartService(name));
  ipcMain.handle('get-health-status', async () => {
    if (!healthMonitor) return null;
    const result = await healthMonitor.runAllChecks({ skipAutoRecovery: true });
    // Transform checks object into array format for dashboard renderer
    const checksArray = Object.entries(result.checks).map(([name, c]) => ({
      name,
      status: c.ok ? 'ok' : 'fail',
      detail: c.detail || '',
    }));
    return { color: result.color, checks: checksArray, issues: result.issues };
  });
  ipcMain.handle('get-plugins', () => pluginManager.getAvailablePlugins());
  ipcMain.handle('get-active-plugins', () => pluginManager.getActivePlugins());
  ipcMain.handle('install-plugin', (_, name) => pluginManager.installPlugin(name));
  ipcMain.handle('uninstall-plugin', (_, name) => pluginManager.uninstallPlugin(name));

  // Config
  ipcMain.handle('get-data-dir', () => configStore.getDataDir());
  ipcMain.handle('is-setup-complete', () => configStore.isSetupComplete());

  // Network
  ipcMain.handle('get-lan-ip', () => getLanIp());
}

/**
 * Find the real LAN IP, skipping Docker/WSL/Hyper-V virtual adapters
 * and link-local (169.254.x.x) addresses.
 */
function getLanIp() {
  const interfaces = os.networkInterfaces();
  const skipPatterns = ['docker', 'vethernet', 'wsl', 'hyper-v', 'vmware', 'virtualbox', 'vbox'];

  // First pass: physical adapters only, skip link-local
  for (const [name, addrs] of Object.entries(interfaces)) {
    const lowerName = name.toLowerCase();
    if (skipPatterns.some(p => lowerName.includes(p))) continue;
    for (const iface of addrs) {
      if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.')) {
        return iface.address;
      }
    }
  }
  // Fallback: any non-internal, non-link-local IPv4
  for (const [name, addrs] of Object.entries(interfaces)) {
    for (const iface of addrs) {
      if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.')) {
        return iface.address;
      }
    }
  }
  return null;
}

// Keep app running in tray
app.on('window-all-closed', (e) => {
  // Don't quit — keep running in system tray
});

let isQuitting = false;
app.on('before-quit', async (e) => {
  if (isQuitting) return;

  if (healthMonitor) healthMonitor.stop();
  if (updateManager) updateManager.stop();
  if (mdnsAuthorizerPollTimer) { clearInterval(mdnsAuthorizerPollTimer); mdnsAuthorizerPollTimer = null; }
  if (mdnsAdvertiser) mdnsAdvertiser.stop();

  // Gracefully stop Docker containers before exiting
  if (dockerManager && configStore.isSetupComplete()) {
    isQuitting = true;
    e.preventDefault();
    try {
      await Promise.race([
        dockerManager.stop(),
        new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 15000)),
      ]);
    } catch (err) {
      if (logger) logger.warn(`Graceful shutdown failed: ${err.message}`);
    }
    if (trayManager) trayManager.destroy();
    app.exit(0);
  } else {
    if (trayManager) trayManager.destroy();
  }
});

// Auto-start on login — only register after setup is complete
if (configStore.isSetupComplete() && configStore.isAutoStart()) {
  app.setLoginItemSettings({
    openAtLogin: true,
    openAsHidden: true,
  });
}
