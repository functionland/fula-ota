const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('fulaNode', {
  // Docker
  checkDocker: () => ipcRenderer.invoke('check-docker'),
  checkDiskSpace: (dir) => ipcRenderer.invoke('check-disk-space', dir),
  checkPorts: (ports) => ipcRenderer.invoke('check-ports', ports),

  // Setup
  getDefaultDataDir: () => ipcRenderer.invoke('get-default-data-dir'),
  openFolderDialog: () => ipcRenderer.invoke('open-folder-dialog'),
  setupInitialize: (dataDir, storageDir) => ipcRenderer.invoke('setup-initialize', dataDir, storageDir),
  setupPullImages: () => ipcRenderer.invoke('setup-pull-images'),
  setupStart: () => ipcRenderer.invoke('setup-start'),

  // Dashboard
  getContainerStatus: () => ipcRenderer.invoke('get-container-status'),
  getContainerLogs: (name, tail) => ipcRenderer.invoke('get-container-logs', name, tail),
  restartService: (name) => ipcRenderer.invoke('restart-service', name),
  getHealthStatus: () => ipcRenderer.invoke('get-health-status'),
  getPlugins: () => ipcRenderer.invoke('get-plugins'),
  getActivePlugins: () => ipcRenderer.invoke('get-active-plugins'),
  installPlugin: (name) => ipcRenderer.invoke('install-plugin', name),
  uninstallPlugin: (name) => ipcRenderer.invoke('uninstall-plugin', name),

  // System checks
  checkMdns: () => ipcRenderer.invoke('check-mdns'),

  // Config
  getDataDir: () => ipcRenderer.invoke('get-data-dir'),
  isSetupComplete: () => ipcRenderer.invoke('is-setup-complete'),
  getLanIp: () => ipcRenderer.invoke('get-lan-ip'),

  // Events from main
  onHealthStatus: (callback) => {
    ipcRenderer.on('health-status', (_, status) => callback(status));
  },
  onPullProgress: (callback) => {
    ipcRenderer.on('pull-progress', (_, data) => callback(data));
  },
  onLaunchProgress: (callback) => {
    ipcRenderer.on('launch-progress', (_, data) => callback(data));
  },
});
