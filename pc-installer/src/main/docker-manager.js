/**
 * DockerManager - Manages Docker Compose lifecycle for Fula Node PC installer.
 *
 * Replaces fula.sh's dockerComposeUp / dockerComposeDown / purgeGhostContainers
 * in a cross-platform Node.js module suitable for Electron.
 *
 * All docker compose commands use:
 *   -f <composeFile> --project-name fula
 * so that containers are labelled consistently regardless of directory name.
 */

const { EventEmitter } = require('events');
const { execFile, spawn } = require('child_process');
const { promisify } = require('util');
const path = require('path');
const fs = require('fs/promises');

const execFileAsync = promisify(execFile);

/** Default timeout for docker commands (2 minutes). */
const CMD_TIMEOUT = 120_000;
/** Timeout for lightweight docker commands like ps, info (30 seconds). */
const SHORT_TIMEOUT = 30_000;
/** Timeout for docker compose pull (5 minutes — image downloads can be slow). */
const PULL_TIMEOUT = 300_000;
/** Timeout for docker info probes during waitForDocker (15 seconds — fast iteration). */
const PROBE_TIMEOUT = 15_000;

class DockerManager extends EventEmitter {
  /**
   * @param {object} configStore - Provides get('dataDir') and other settings.
   * @param {object} logger      - Logger with info/warn/error methods.
   */
  constructor(configStore, logger) {
    super();
    this.configStore = configStore;
    this.logger = logger;
    this._composeCommand = null; // cached after first detection
    this._mainWindow = null;
  }

  /**
   * Set the BrowserWindow reference so IPC progress events can be sent
   * to the renderer during pull/launch operations.
   * @param {BrowserWindow|null} win
   */
  setMainWindow(win) {
    this._mainWindow = win;
  }

  /** Send an IPC event to the renderer if a window is available. */
  _sendToRenderer(channel, data) {
    if (this._mainWindow && !this._mainWindow.isDestroyed()) {
      this._mainWindow.webContents.send(channel, data);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /** Resolved data directory from the config store. */
  _getDataDir() {
    return this.configStore.getDataDir();
  }

  /** Absolute path to the compose file inside dataDir/config/. */
  _getComposeFilePath() {
    return path.join(this._getDataDir(), 'config', 'docker-compose.pc.yml');
  }

  /** Absolute path to the .env file inside dataDir/config/. */
  _getEnvFilePath() {
    return path.join(this._getDataDir(), 'config', '.env.pc');
  }

  /**
   * Build the common prefix args shared by every compose invocation.
   * @returns {string[]}
   */
  async _composeArgs() {
    const composeFile = this._getComposeFilePath();
    const envFile = this._getEnvFilePath();
    return ['-f', composeFile, '--env-file', envFile, '--project-name', 'fula'];
  }

  /**
   * Execute a docker compose command and return { stdout, stderr }.
   * @param {string[]} args  - Arguments appended after the common prefix.
   * @returns {Promise<{stdout: string, stderr: string}>}
   */
  async _runCompose(args, timeout = CMD_TIMEOUT) {
    const cmd = await this.getDockerComposePath();
    const prefixArgs = await this._composeArgs();

    // cmd may be 'docker compose' (two tokens) or 'docker-compose' (one token)
    const tokens = cmd.split(/\s+/);
    const binary = tokens[0];
    const extraTokens = tokens.slice(1); // e.g. ['compose'] for plugin form
    const fullArgs = [...extraTokens, ...prefixArgs, ...args];

    this.logger.info(`docker-manager: ${binary} ${fullArgs.join(' ')}`);
    return execFileAsync(binary, fullArgs, { maxBuffer: 10 * 1024 * 1024, timeout });
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /**
   * Check whether Docker is installed and the daemon is running.
   * @returns {Promise<{installed: boolean, running: boolean, error: string|null}>}
   */
  async checkDockerInstalled() {
    try {
      await execFileAsync('docker', ['info'], { timeout: 15000 });
      return { installed: true, running: true, error: null };
    } catch (err) {
      const msg = (err.stderr || err.message || '').toLowerCase();
      // Docker binary exists but daemon is not running
      if (msg.includes('cannot connect') || msg.includes('is the docker daemon running')) {
        return { installed: true, running: false, error: err.message };
      }
      // Docker binary not found at all
      return { installed: false, running: false, error: err.message };
    }
  }

  /**
   * Determine the working compose command on this system.
   * Tries the V2 plugin form (`docker compose`) first, then the standalone
   * `docker-compose` binary.
   * @returns {Promise<string>} e.g. 'docker compose' or 'docker-compose'
   */
  async getDockerComposePath() {
    if (this._composeCommand) return this._composeCommand;

    // Try V2 plugin form first
    try {
      await execFileAsync('docker', ['compose', 'version'], { timeout: 10000 });
      this._composeCommand = 'docker compose';
      return this._composeCommand;
    } catch {
      // ignore
    }

    // Try standalone binary
    try {
      await execFileAsync('docker-compose', ['version'], { timeout: 10000 });
      this._composeCommand = 'docker-compose';
      return this._composeCommand;
    } catch {
      // ignore
    }

    throw new Error(
      'Neither "docker compose" (V2 plugin) nor "docker-compose" (standalone) found. ' +
        'Please install Docker Desktop or Docker Compose.'
    );
  }

  /**
   * Copy compose & env template files from app resources into dataDir/config/,
   * replacing ${FULA_DATA_DIR} placeholders with the real dataDir path.
   *
   * @param {string} resourcesDir - Path to the bundled resources directory
   *                                 (e.g. app.getPath('extraResources')).
   */
  async writeComposeFiles(resourcesDir) {
    const dataDir = this._getDataDir();
    const configDir = path.join(dataDir, 'config');

    try {
      await fs.mkdir(configDir, { recursive: true });

      const filesToCopy = [
        { src: 'docker-compose.pc.yml', dest: 'docker-compose.pc.yml' },
        { src: '.env.pc', dest: '.env.pc' },
        { src: '.env.cluster.pc', dest: '.env.cluster' },
        { src: '.env.gofula.pc', dest: '.env.gofula' },
      ];

      for (const { src: srcName, dest: destName } of filesToCopy) {
        const src = path.join(resourcesDir, srcName);
        const dest = path.join(configDir, destName);

        let content = await fs.readFile(src, 'utf-8');

        // Replace placeholders with actual paths.
        // On Windows, convert backslashes to forward slashes so YAML
        // doesn't interpret sequences like \U, \J as escape characters.
        const normalizedDir = dataDir.replace(/\\/g, '/');
        const storageDir = this.configStore.getStorageDir
          ? this.configStore.getStorageDir()
          : path.join(dataDir, 'storage');
        const normalizedStorageDir = storageDir.replace(/\\/g, '/');
        content = content.replace(/\$\{FULA_DATA_DIR\}/g, normalizedDir);
        content = content.replace(/\$\{FULA_STORAGE_DIR\}/g, normalizedStorageDir);

        await fs.writeFile(dest, content, 'utf-8');
        this.logger.info(`docker-manager: wrote ${dest}`);
      }
    } catch (err) {
      this.logger.error(`docker-manager: writeComposeFiles failed: ${err.message}`);
      throw err;
    }
  }

  /**
   * Pull all images defined in the compose file.
   * Emits 'pull-progress' events with raw Docker output lines.
   * Sends per-image IPC progress to the renderer via 'pull-progress' channel.
   */
  async pullImages() {
    // Discover which images need pulling by reading the compose config
    let imageList = [];
    try {
      const { stdout } = await this._runCompose(['config', '--images'], SHORT_TIMEOUT);
      imageList = stdout.trim().split('\n').filter(Boolean);
    } catch {
      // Fallback: pull all at once without per-image tracking
    }

    const cmd = await this.getDockerComposePath();
    const prefixArgs = await this._composeArgs();
    const tokens = cmd.split(/\s+/);
    const binary = tokens[0];
    const extraTokens = tokens.slice(1);
    const total = imageList.length;

    this.logger.info(`docker-manager: pulling images... (${total} discovered)`);

    if (total > 0) {
      // Pull images one by one for per-image progress reporting
      for (let i = 0; i < total; i++) {
        const image = imageList[i];
        const imageName = image.split('/').pop().split(':')[0]; // short display name
        this._sendToRenderer('pull-progress', {
          image: imageName, status: 'pulling', current: i + 1, total,
        });
        this.emit('pull-progress', `Pulling ${image}...\n`);

        try {
          await execFileAsync('docker', ['pull', image], {
            maxBuffer: 10 * 1024 * 1024,
            timeout: PULL_TIMEOUT,
          });
          this._sendToRenderer('pull-progress', {
            image: imageName, status: 'done', current: i + 1, total,
          });
          this.emit('pull-progress', `Pulled ${image}\n`);
        } catch (err) {
          // Check if image is already cached locally
          try {
            await execFileAsync('docker', ['image', 'inspect', image], { timeout: SHORT_TIMEOUT });
            this._sendToRenderer('pull-progress', {
              image: imageName, status: 'cached', current: i + 1, total,
            });
            this.emit('pull-progress', `Using cached ${image}\n`);
          } catch {
            this._sendToRenderer('pull-progress', {
              image: imageName, status: 'error', current: i + 1, total,
            });
            this.logger.warn(`docker-manager: pull failed for ${image}: ${err.message}`);
            throw err;
          }
        }
      }
      this.logger.info('docker-manager: pull complete');
      return { stdout: '', stderr: '' };
    }

    // Fallback: bulk pull (no per-image progress)
    const fullArgs = [...extraTokens, ...prefixArgs, 'pull'];
    return new Promise((resolve, reject) => {
      const child = execFile(binary, fullArgs, { maxBuffer: 10 * 1024 * 1024, timeout: PULL_TIMEOUT }, (err, stdout, stderr) => {
        if (err) {
          this.logger.error(`docker-manager: pull failed: ${err.message}`);
          return reject(err);
        }
        this.logger.info('docker-manager: pull complete');
        resolve({ stdout, stderr });
      });

      if (child.stdout) {
        child.stdout.on('data', (chunk) => {
          this.emit('pull-progress', chunk.toString());
        });
      }
      if (child.stderr) {
        child.stderr.on('data', (chunk) => {
          this.emit('pull-progress', chunk.toString());
        });
      }
    });
  }

  /**
   * Wait for the Docker daemon to become responsive.
   * If Docker Desktop is unresponsive on Windows, kills and relaunches it,
   * then waits up to ~3 minutes for it to initialize.
   * @returns {Promise<boolean>} true if daemon is ready
   */
  async waitForDocker(maxAttempts = 15) {
    let restartAttempted = false;

    for (let i = 1; i <= maxAttempts; i++) {
      try {
        await execFileAsync('docker', ['info'], { timeout: PROBE_TIMEOUT });
        if (i > 1) this.logger.info('docker-manager: Docker daemon is now responsive');
        return true;
      } catch (err) {
        this.logger.warn(`docker-manager: Docker not ready (attempt ${i}/${maxAttempts}): ${err.message}`);

        // On Windows, try restarting Docker Desktop (once)
        if (!restartAttempted && process.platform === 'win32') {
          restartAttempted = true;
          await this._restartDockerDesktop();
          // Give Docker Desktop extra time to initialize after relaunch
          this.logger.info('docker-manager: waiting 30s for Docker Desktop to initialize...');
          await new Promise(r => setTimeout(r, 30_000));
        } else if (i < maxAttempts) {
          // Wait 15s between probes (Docker Desktop startup can take 60-120s)
          await new Promise(r => setTimeout(r, 15_000));
        }
      }
    }
    return false;
  }

  /**
   * Kill Docker Desktop and relaunch it.
   * Tries multiple launch methods since execFile can fail silently on Windows.
   * @private
   */
  async _restartDockerDesktop() {
    this.logger.info('docker-manager: attempting to restart Docker Desktop...');

    // Kill all Docker Desktop processes
    try {
      await execFileAsync('taskkill', ['/IM', 'Docker Desktop.exe', '/F'], { timeout: 15_000 });
      this.logger.info('docker-manager: killed Docker Desktop.exe');
    } catch {
      this.logger.info('docker-manager: Docker Desktop.exe was not running (or taskkill failed)');
    }

    // Also kill the backend service which can hang independently
    try {
      await execFileAsync('taskkill', ['/IM', 'com.docker.backend.exe', '/F'], { timeout: 10_000 });
    } catch {
      // not critical
    }

    // Wait for processes to fully exit
    await new Promise(r => setTimeout(r, 5_000));

    // Try to find Docker Desktop executable
    const candidates = [
      `${process.env.ProgramFiles || 'C:\\Program Files'}\\Docker\\Docker\\Docker Desktop.exe`,
      `${process.env.LOCALAPPDATA || ''}\\Docker\\Docker Desktop.exe`,
      `${process.env.ProgramFiles || 'C:\\Program Files'}\\Docker\\Docker Desktop\\Docker Desktop.exe`,
    ].filter(p => p && !p.startsWith('\\'));

    let launched = false;

    for (const ddPath of candidates) {
      try {
        await fs.access(ddPath);
        this.logger.info(`docker-manager: launching Docker Desktop from ${ddPath}`);

        // Use spawn with shell:true for reliable Windows process launch
        const child = spawn(`"${ddPath}"`, [], {
          shell: true,
          detached: true,
          stdio: 'ignore',
          windowsHide: false,
        });
        child.unref();
        child.on('error', (e) => {
          this.logger.warn(`docker-manager: Docker Desktop spawn error: ${e.message}`);
        });

        launched = true;
        this.logger.info('docker-manager: Docker Desktop launch initiated');
        break;
      } catch {
        this.logger.info(`docker-manager: Docker Desktop not found at ${ddPath}`);
      }
    }

    if (!launched) {
      // Fallback: try via Windows start command (finds it via PATH/registry)
      this.logger.info('docker-manager: trying "start" command as fallback...');
      try {
        const child = spawn('cmd', ['/c', 'start', '', 'Docker Desktop'], {
          detached: true,
          stdio: 'ignore',
          windowsHide: true,
        });
        child.unref();
        child.on('error', () => {});
        this.logger.info('docker-manager: Docker Desktop fallback launch attempted');
      } catch (e) {
        this.logger.warn(`docker-manager: all Docker Desktop launch methods failed: ${e.message}`);
      }
    }
  }

  /**
   * Start all Fula services.
   * Waits for Docker daemon, purges ghost containers, pulls images, then starts.
   * Sends IPC 'launch-progress' events so the renderer can show phase updates.
   */
  async start() {
    // Ensure Docker daemon is responsive before proceeding
    this._sendToRenderer('launch-progress', { phase: 'waiting-docker' });
    const dockerReady = await this.waitForDocker();
    if (!dockerReady) {
      const err = new Error('Docker daemon is not responsive after multiple retries');
      this.logger.error(`docker-manager: ${err.message}`);
      this.emit('error', err);
      throw err;
    }

    try {
      this._sendToRenderer('launch-progress', { phase: 'purging-ghosts' });
      await this.purgeGhostContainers();
      // Pull latest images before starting (non-fatal — offline startup still works)
      this._sendToRenderer('launch-progress', { phase: 'pulling-updates' });
      try {
        await this._runCompose(['pull'], PULL_TIMEOUT);
        this.logger.info('docker-manager: pull complete before start');
      } catch (pullErr) {
        this.logger.warn(`docker-manager: pull before start failed (continuing): ${pullErr.message}`);
      }
      this._sendToRenderer('launch-progress', { phase: 'starting-containers' });
      const { stdout, stderr } = await this._runCompose(['up', '-d']);
      this.logger.info(`docker-manager: started\n${stdout}${stderr}`);
      this._sendToRenderer('launch-progress', { phase: 'waiting-healthy' });
      this.emit('status-change', 'started');
      this.emit('started');
    } catch (err) {
      this.logger.error(`docker-manager: start failed: ${err.message}`);
      this.emit('error', err);
      throw err;
    }
  }

  /**
   * Stop all Fula services and clean up ghost containers.
   */
  async stop() {
    try {
      const { stdout, stderr } = await this._runCompose(['down', '--remove-orphans']);
      this.logger.info(`docker-manager: stopped\n${stdout}${stderr}`);
      await this.purgeGhostContainers();
      this.emit('status-change', 'stopped');
      this.emit('stopped');
    } catch (err) {
      this.logger.error(`docker-manager: stop failed: ${err.message}`);
      this.emit('error', err);
      throw err;
    }
  }

  /**
   * Restart all services (stop then start).
   */
  async restart() {
    await this.stop();
    await this.start();
  }

  /**
   * Remove ghost / dead containers that carry the fula compose project label.
   *
   * Dead containers retain compose labels but are invisible to
   * `docker-compose ps`.  When `docker-compose up` runs with --no-recreate it
   * finds them via labels, refuses to create a replacement, but also cannot
   * start the dead container - so the service never comes up.
   *
   * This mirrors purgeGhostContainers() in fula.sh.
   */
  async purgeGhostContainers() {
    try {
      const { stdout } = await execFileAsync('docker', [
        'ps', '-a',
        '--filter', 'label=com.docker.compose.project=fula',
        '-q',
      ], { timeout: SHORT_TIMEOUT });

      const ids = stdout.trim();
      if (!ids) {
        this.logger.info('docker-manager: no ghost containers found');
        return;
      }

      const idList = ids.split(/\s+/);
      this.logger.info(`docker-manager: purging ${idList.length} ghost container(s): ${idList.join(', ')}`);
      await execFileAsync('docker', ['rm', '-f', ...idList], { timeout: SHORT_TIMEOUT });
      this.logger.info('docker-manager: ghost containers removed');
    } catch (err) {
      // Non-fatal; log and continue.
      this.logger.warn(`docker-manager: purgeGhostContainers failed (non-fatal): ${err.message}`);
    }
  }

  /**
   * Return the status of every container in the fula project.
   * @returns {Promise<Array<{name: string, status: string, state: string, image: string}>>}
   */
  async getContainerStatus() {
    try {
      const { stdout } = await execFileAsync('docker', [
        'ps', '-a',
        '--format', '{{json .}}',
        '--filter', 'label=com.docker.compose.project=fula',
      ], { timeout: SHORT_TIMEOUT });

      if (!stdout.trim()) return [];

      return stdout
        .trim()
        .split('\n')
        .map((line) => {
          const obj = JSON.parse(line);
          return {
            name: obj.Names,
            status: obj.Status,
            state: obj.State,
            image: obj.Image,
          };
        });
    } catch (err) {
      this.logger.error(`docker-manager: getContainerStatus failed: ${err.message}`);
      this.emit('error', err);
      throw err;
    }
  }

  /**
   * Fetch recent logs from a specific container.
   * @param {string} containerName - Container name (e.g. 'fula_go').
   * @param {number} [tail=100]    - Number of trailing lines to return.
   * @returns {Promise<string>}
   */
  async getContainerLogs(containerName, tail = 100) {
    try {
      const { stdout, stderr } = await execFileAsync('docker', [
        'logs', containerName,
        '--tail', String(tail),
      ], { maxBuffer: 5 * 1024 * 1024, timeout: SHORT_TIMEOUT });
      // Docker writes most log output to stderr; combine both streams.
      return `${stdout}${stderr}`;
    } catch (err) {
      this.logger.error(`docker-manager: getContainerLogs(${containerName}) failed: ${err.message}`);
      this.emit('error', err);
      throw err;
    }
  }

  /**
   * Restart a single compose service by name.
   * @param {string} serviceName - Service name as defined in compose file (e.g. 'go-fula').
   */
  async restartService(serviceName) {
    try {
      const { stdout, stderr } = await this._runCompose(['restart', serviceName]);
      this.logger.info(`docker-manager: restarted service ${serviceName}\n${stdout}${stderr}`);
      this.emit('status-change', `restarted:${serviceName}`);
    } catch (err) {
      this.logger.error(`docker-manager: restartService(${serviceName}) failed: ${err.message}`);
      this.emit('error', err);
      throw err;
    }
  }
}

module.exports = DockerManager;
