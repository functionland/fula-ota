const Store = require('electron-store');
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
};
