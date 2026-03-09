const { EventEmitter } = require('events');
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

class UpdateManager extends EventEmitter {
  constructor(dockerManager, logger) {
    super();
    this.dockerManager = dockerManager;
    this.logger = logger;
    this.checkInterval = null;
  }

  startStaleImageCheck(intervalMs = 3600000) {
    this.checkInterval = setInterval(() => this.checkForStaleImages(), intervalMs);
    this.logger.info('Stale image check started');
  }

  stop() {
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
  }

  async checkForStaleImages() {
    try {
      const services = [
        { container: 'fula_fxsupport', image: 'functionland/fxsupport:release_amd64' },
        { container: 'fula_go', image: 'functionland/go-fula:release_amd64' },
        { container: 'fula_gateway', image: 'functionland/fula-gateway:release_amd64' },
        { container: 'fula_pinning', image: 'functionland/fula-pinning:release_amd64' },
      ];

      let staleFound = false;
      for (const svc of services) {
        try {
          const { stdout: runningId } = await execAsync(
            `docker inspect --format="{{.Image}}" ${svc.container}`
          );
          const { stdout: currentId } = await execAsync(
            `docker inspect --format="{{.Id}}" ${svc.image}`
          );
          if (runningId.trim() !== currentId.trim()) {
            this.logger.info(`Stale image detected for ${svc.container}`);
            staleFound = true;
            break;
          }
        } catch {
          // Container may not exist
        }
      }

      if (staleFound) {
        this.logger.info('Stale images found, triggering restart');
        this.emit('stale-images');
        await this.dockerManager.restart();
      }
    } catch (e) {
      this.logger.error(`Stale image check failed: ${e.message}`);
    }
  }

  async checkForAppUpdate() {
    // Electron autoUpdater integration
    // This is a placeholder — actual implementation depends on the release feed URL
    try {
      const { autoUpdater } = require('electron');
      autoUpdater.checkForUpdates();
    } catch (e) {
      this.logger.warn(`App update check not available: ${e.message}`);
    }
  }
}

module.exports = UpdateManager;
