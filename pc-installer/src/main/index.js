const { app, BrowserWindow, ipcMain, shell, dialog } = require('electron');
const os = require('os');
const path = require('path');

// Handle Squirrel.Windows install/uninstall events (must be early, before app.ready)
if (process.platform === 'win32') {
  const squirrelEvent = process.argv[1];
  if (squirrelEvent) {
    const { spawnSync } = require('child_process');
    const updateExe = path.resolve(process.execPath, '..', '..', 'Update.exe');
    const exeName = path.basename(process.execPath);

    switch (squirrelEvent) {
      case '--squirrel-install':
      case '--squirrel-updated':
        // Create/update Start Menu and Desktop shortcuts
        spawnSync(updateExe, ['--createShortcut', exeName], { detached: true });
        app.quit();
        break;
      case '--squirrel-uninstall':
        // Remove shortcuts and disable auto-start
        spawnSync(updateExe, ['--removeShortcut', exeName], { detached: true });
        app.setLoginItemSettings({ openAtLogin: false });
        app.quit();
        break;
      case '--squirrel-obsolete':
        app.quit();
        break;
    }
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
  if (dashboardWindow) {
    if (dashboardWindow.isMinimized()) dashboardWindow.restore();
    dashboardWindow.focus();
  }
});

app.on('ready', async () => {
  // Initialize logger (console only until data dir is known)
  logger = createLogger();
  logger.info('Fula Node starting...');

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

  // Check if first run or setup needed
  if (configStore.isSetupComplete()) {
    await startServices();
  } else {
    trayManager.setStatus('cyan');
    openWizard();
  }

  // Register IPC handlers
  registerIpcHandlers();
});

async function startServices() {
  const dataDir = configStore.getDataDir();
  if (!dataDir) return;

  // Upgrade logger to file-based
  logger = createLogger(path.join(dataDir, 'logs'));

  trayManager.setStatus('blue');

  try {
    await dockerManager.start();

    // Start health monitor
    healthMonitor = new HealthMonitor(dockerManager, configStore, logger);
    healthMonitor.on('status', (status) => {
      trayManager.setStatus(status.color);
      if (dashboardWindow && !dashboardWindow.isDestroyed()) {
        dashboardWindow.webContents.send('health-status', status);
      }
    });
    healthMonitor.on('needs-restart', async () => {
      logger.warn('Health monitor triggered restart');
      trayManager.setStatus('yellow');
      await dockerManager.restart();
    });
    healthMonitor.start(HEALTH_CHECK_INTERVAL);

    // Start mDNS after a delay to let kubo initialize
    setTimeout(async () => {
      try {
        const http = require('http');
        const req = http.request({ hostname: '127.0.0.1', port: PORTS.kuboApi, path: '/api/v0/id', method: 'POST', timeout: 5000 }, (res) => {
          let data = '';
          res.on('data', chunk => data += chunk);
          res.on('end', () => {
            try {
              const { ID } = JSON.parse(data);
              if (ID) mdnsAdvertiser.start(ID);
            } catch {}
          });
        });
        req.on('error', () => {});
        req.end();
      } catch {}
    }, 30000);

    // Start stale image checker
    updateManager.startStaleImageCheck();
  } catch (e) {
    logger.error(`Failed to start services: ${e.message}`);
    trayManager.setStatus('red');
  }
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
  ipcMain.handle('get-health-status', () => healthMonitor ? healthMonitor.runAllChecks() : null);
  ipcMain.handle('get-plugins', () => pluginManager.getAvailablePlugins());
  ipcMain.handle('get-active-plugins', () => pluginManager.getActivePlugins());
  ipcMain.handle('install-plugin', (_, name) => pluginManager.installPlugin(name));
  ipcMain.handle('uninstall-plugin', (_, name) => pluginManager.uninstallPlugin(name));

  // Config
  ipcMain.handle('get-data-dir', () => configStore.getDataDir());
  ipcMain.handle('is-setup-complete', () => configStore.isSetupComplete());

  // Network
  ipcMain.handle('get-lan-ip', () => {
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
      for (const iface of interfaces[name]) {
        if (iface.family === 'IPv4' && !iface.internal) {
          return iface.address;
        }
      }
    }
    return null;
  });
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
