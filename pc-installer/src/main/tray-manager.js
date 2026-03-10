const { Tray, Menu, nativeImage, shell, app } = require('electron');
const { EventEmitter } = require('events');
const path = require('path');

const TOOLTIPS = {
  red: 'Fula Node: Error',
  green: 'Fula Node: Running',
  yellow: 'Fula Node: Updating...',
  blue: 'Fula Node: Starting...',
  purple: 'Fula Node: Maintenance',
  cyan: 'Fula Node: Setup Required',
  grey: 'Fula Node: Stopped'
};

class TrayManager extends EventEmitter {
  constructor(configStore) {
    super();
    this.configStore = configStore;
    this.tray = null;
    this.currentColor = 'grey';
  }

  create() {
    const iconPath = path.join(__dirname, '..', 'assets', 'icons', 'tray-grey.png');
    this.tray = new Tray(iconPath);
    this.tray.setToolTip(TOOLTIPS.grey);
    this.updateContextMenu();
    this.tray.on('double-click', () => this.emit('open-dashboard'));
  }

  updateContextMenu() {
    const template = [
      { label: 'Fula Node', enabled: false },
      { type: 'separator' },
      { label: 'Dashboard', click: () => this.emit('open-dashboard') },
      { label: 'Setup Wizard', click: () => this.emit('open-wizard') },
      { type: 'separator' },
      { label: 'Start', click: () => this.emit('start') },
      { label: 'Stop', click: () => this.emit('stop') },
      { label: 'Restart', click: () => this.emit('restart') },
      { type: 'separator' },
      { label: 'View Logs', click: () => this.emit('open-logs') },
      { label: 'Open Data Folder', click: () => {
        const dataDir = this.configStore.getDataDir();
        if (dataDir) shell.openPath(dataDir);
      }},
      { type: 'separator' },
      { label: 'Quit', click: () => { this.emit('quit'); app.quit(); } }
    ];
    this.tray.setContextMenu(Menu.buildFromTemplate(template));
  }

  setStatus(color) {
    if (!this.tray || this.currentColor === color) return;
    const iconPath = path.join(__dirname, '..', 'assets', 'icons', `tray-${color}.png`);
    try {
      this.tray.setImage(iconPath);
      this.tray.setToolTip(TOOLTIPS[color] || 'Fula Node');
      // Only update currentColor after the image was successfully set,
      // so a failed setImage doesn't prevent future retries.
      this.currentColor = color;
    } catch (e) {
      // Icon file may not exist yet during development
    }
  }

  showNotification(title, body) {
    if (this.tray) {
      this.tray.displayBalloon({ title, content: body });
    }
  }

  destroy() {
    if (this.tray) {
      this.tray.destroy();
      this.tray = null;
    }
  }
}

module.exports = TrayManager;
