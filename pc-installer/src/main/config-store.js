const Store = require('electron-store');
const crypto = require('crypto');
const os = require('os');
const path = require('path');

const isWin = process.platform === 'win32';

const schema = {
  dataDir: {
    type: 'string',
    default: isWin
      ? path.join(process.env.LOCALAPPDATA || '', 'FulaData')
      : path.join(os.homedir(), '.fula-data'),
  },
  storageDir: {
    type: 'string',
    default: '',
  },
  setupComplete: {
    type: 'boolean',
    default: false,
  },
  autoStart: {
    type: 'boolean',
    default: true,
  },
  firstRun: {
    type: 'boolean',
    default: true,
  },
  hardwareID: {
    type: 'string',
    default: '',
  },
};

const store = new Store({ schema });

module.exports = {
  store,

  getDataDir() {
    return store.get('dataDir');
  },

  setDataDir(dir) {
    store.set('dataDir', dir);
  },

  getStorageDir() {
    return store.get('storageDir') || path.join(store.get('dataDir'), 'storage');
  },

  setStorageDir(dir) {
    store.set('storageDir', dir);
  },

  isSetupComplete() {
    return store.get('setupComplete');
  },

  setSetupComplete(val) {
    store.set('setupComplete', val);
  },

  isAutoStart() {
    return store.get('autoStart');
  },

  setAutoStart(val) {
    store.set('autoStart', val);
  },

  /**
   * Get a stable hardware ID for this machine.
   * Generated once from the primary MAC address (SHA-256 hashed),
   * analogous to ARM's /proc/cpuinfo Serial+Hardware+Revision hash.
   */
  getHardwareID() {
    let id = store.get('hardwareID');
    if (id) return id;

    // Find first non-internal MAC address
    const ifaces = os.networkInterfaces();
    let mac = '';
    for (const [name, addrs] of Object.entries(ifaces)) {
      for (const addr of addrs) {
        if (!addr.internal && addr.mac && addr.mac !== '00:00:00:00:00:00') {
          mac = addr.mac;
          break;
        }
      }
      if (mac) break;
    }

    // Hash it like ARM does (SHA-256), fallback to random if no MAC found
    const source = mac || crypto.randomBytes(32).toString('hex');
    id = crypto.createHash('sha256').update(source).digest('hex');
    store.set('hardwareID', id);
    return id;
  },
};
