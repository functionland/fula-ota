const { EventEmitter } = require('events');
const fs = require('fs/promises');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileAsync = promisify(execFile);

// Plugins that require specific hardware (excluded on PC)
const PC_EXCLUDED_PLUGINS = ['loyal-agent'];

class PluginManager extends EventEmitter {
  constructor(dockerManager, configStore, logger) {
    super();
    this.dockerManager = dockerManager;
    this.configStore = configStore;
    this.logger = logger;
  }

  async getAvailablePlugins() {
    try {
      // Extract plugins info from fxsupport container
      const dataDir = this.configStore.getDataDir();
      const infoPath = path.join(dataDir, 'internal', 'plugins', 'info.json');

      // Try to get from local cache first
      try {
        const data = await fs.readFile(infoPath, 'utf-8');
        const plugins = JSON.parse(data);
        // Filter out hardware-specific plugins
        return Object.entries(plugins)
          .filter(([name]) => !PC_EXCLUDED_PLUGINS.includes(name))
          .map(([name, info]) => ({ name, ...info }));
      } catch {
        // Try to extract from fxsupport container
        await execFileAsync('docker', ['cp', `fula_fxsupport:/linux/plugins/info.json`, infoPath]);
        const data = await fs.readFile(infoPath, 'utf-8');
        const plugins = JSON.parse(data);
        return Object.entries(plugins)
          .filter(([name]) => !PC_EXCLUDED_PLUGINS.includes(name))
          .map(([name, info]) => ({ name, ...info }));
      }
    } catch (e) {
      this.logger.error(`Failed to get plugins: ${e.message}`);
      return [];
    }
  }

  async getActivePlugins() {
    try {
      const dataDir = this.configStore.getDataDir();
      const activeFile = path.join(dataDir, 'internal', 'plugins', 'active-plugins.txt');
      const content = await fs.readFile(activeFile, 'utf-8');
      return content.split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }

  async installPlugin(name) {
    // Validate plugin name: alphanumeric, hyphens, underscores only
    if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
      throw new Error(`Invalid plugin name: ${name}`);
    }
    if (PC_EXCLUDED_PLUGINS.includes(name)) {
      throw new Error(`Plugin ${name} is not available on PC`);
    }
    const dataDir = this.configStore.getDataDir();
    const pluginDir = path.join(dataDir, 'internal', 'plugins', name);

    this.logger.info(`Installing plugin: ${name}`);

    // Extract plugin files from fxsupport
    await execFileAsync('docker', ['cp', `fula_fxsupport:/linux/plugins/${name}`, pluginDir]);

    // Run docker-compose up for the plugin
    const composePath = path.join(pluginDir, 'docker-compose.yml');
    try {
      await fs.access(composePath);
      await execFileAsync('docker', ['compose', '-f', composePath, 'up', '-d']);
    } catch (e) {
      this.logger.warn(`No compose file for plugin ${name}, running install script`);
    }

    // Add to active plugins list
    const activeFile = path.join(dataDir, 'internal', 'plugins', 'active-plugins.txt');
    const active = await this.getActivePlugins();
    if (!active.includes(name)) {
      active.push(name);
      await fs.writeFile(activeFile, active.join('\n') + '\n');
    }

    this.logger.info(`Plugin ${name} installed`);
    this.emit('plugin-installed', name);
  }

  async startPlugin(name) {
    const dataDir = this.configStore.getDataDir();
    const composePath = path.join(dataDir, 'internal', 'plugins', name, 'docker-compose.yml');
    await execFileAsync('docker', ['compose', '-f', composePath, 'up', '-d']);
    this.logger.info(`Plugin ${name} started`);
  }

  async stopPlugin(name) {
    const dataDir = this.configStore.getDataDir();
    const composePath = path.join(dataDir, 'internal', 'plugins', name, 'docker-compose.yml');
    await execFileAsync('docker', ['compose', '-f', composePath, 'down']);
    this.logger.info(`Plugin ${name} stopped`);
  }

  async uninstallPlugin(name) {
    await this.stopPlugin(name).catch(() => {});
    const dataDir = this.configStore.getDataDir();

    // Remove from active list
    const activeFile = path.join(dataDir, 'internal', 'plugins', 'active-plugins.txt');
    const active = await this.getActivePlugins();
    const filtered = active.filter(p => p !== name);
    await fs.writeFile(activeFile, filtered.join('\n') + '\n');

    this.logger.info(`Plugin ${name} uninstalled`);
    this.emit('plugin-uninstalled', name);
  }
}

module.exports = PluginManager;
