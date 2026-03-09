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
const { execFile } = require('child_process');
const { promisify } = require('util');
const path = require('path');
const fs = require('fs/promises');

const execFileAsync = promisify(execFile);

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
  async _runCompose(args) {
    const cmd = await this.getDockerComposePath();
    const prefixArgs = await this._composeArgs();

    // cmd may be 'docker compose' (two tokens) or 'docker-compose' (one token)
    const tokens = cmd.split(/\s+/);
    const binary = tokens[0];
    const extraTokens = tokens.slice(1); // e.g. ['compose'] for plugin form
    const fullArgs = [...extraTokens, ...prefixArgs, ...args];

    this.logger.info(`docker-manager: ${binary} ${fullArgs.join(' ')}`);
    return execFileAsync(binary, fullArgs, { maxBuffer: 10 * 1024 * 1024 });
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
   */
  async pullImages() {
    const cmd = await this.getDockerComposePath();
    const prefixArgs = await this._composeArgs();

    const tokens = cmd.split(/\s+/);
    const binary = tokens[0];
    const extraTokens = tokens.slice(1);
    const fullArgs = [...extraTokens, ...prefixArgs, 'pull'];

    this.logger.info(`docker-manager: pulling images...`);

    return new Promise((resolve, reject) => {
      const child = execFile(binary, fullArgs, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
        if (err) {
          this.logger.error(`docker-manager: pull failed: ${err.message}`);
          return reject(err);
        }
        this.logger.info('docker-manager: pull complete');
        resolve({ stdout, stderr });
      });

      // Stream progress from both stdout and stderr (Docker often writes
      // progress to stderr).
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
   * Start all Fula services.
   * Purges ghost containers first to avoid the --no-recreate dead-container
   * problem documented in MEMORY.md.
   */
  async start() {
    try {
      await this.purgeGhostContainers();
      const { stdout, stderr } = await this._runCompose(['up', '-d']);
      this.logger.info(`docker-manager: started\n${stdout}${stderr}`);
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
      ]);

      const ids = stdout.trim();
      if (!ids) {
        this.logger.info('docker-manager: no ghost containers found');
        return;
      }

      const idList = ids.split(/\s+/);
      this.logger.info(`docker-manager: purging ${idList.length} ghost container(s): ${idList.join(', ')}`);
      await execFileAsync('docker', ['rm', '-f', ...idList]);
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
      ]);

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
      ], { maxBuffer: 5 * 1024 * 1024 });
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
