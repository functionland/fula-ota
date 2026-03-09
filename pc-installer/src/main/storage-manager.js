/**
 * StorageManager - Initializes the on-disk directory layout and copies
 * template / config files for the Fula Node PC installer.
 *
 * The directory tree mirrors the Raspberry Pi layout defined in fula.sh,
 * but rooted under a user-chosen dataDir instead of fixed paths like
 * /home/pi/.internal and /media/pi.
 */

const fs = require('fs/promises');
const path = require('path');
const os = require('os');

class StorageManager {
  /**
   * @param {object} logger - Logger with info/warn/error methods.
   */
  constructor(logger) {
    this.logger = logger;
  }

  // ---------------------------------------------------------------------------
  // Directory initialization
  // ---------------------------------------------------------------------------

  /**
   * Create the full directory tree that the Docker services expect.
   *
   * Layout (all relative to dataDir):
   *   internal/                  - kubo identity, secrets, gateway state
   *   storage/                   - heavy data (IPFS blocks, chain, cluster)
   *   config/                    - compose files, kubo configs, init scripts
   *   home/                      - command exchange directory
   *   logs/                      - log files
   *
   * @param {string} dataDir - Root directory chosen by the user.
   */
  async initialize(dataDir, storageDir) {
    const effectiveStorageDir = storageDir || path.join(dataDir, 'storage');

    // Directories under dataDir (config, internal, home, logs)
    const dataDirs = [
      'internal',
      path.join('internal', 'ipfs_data'),
      path.join('internal', 'ipfs_data_local'),
      path.join('internal', 'fula-gateway'),
      path.join('internal', 'fula-pinning'),
      path.join('internal', '.secrets'),
      path.join('internal', 'plugins'),
      'config',
      path.join('config', 'kubo'),
      path.join('config', 'kubo-local'),
      path.join('config', 'ipfs-cluster'),
      'home',
      path.join('home', 'commands'),
      'logs',
    ];

    // Directories under storageDir (heavy data — IPFS blocks, chain, cluster)
    const storageDirs = [
      'ipfs_datastore',
      path.join('ipfs_datastore', 'blocks'),
      path.join('ipfs_datastore', 'datastore'),
      'ipfs_staging',
      'chain',
      'ipfs-cluster',
      'fxblox',
      'ipfs_datastore_local',
      path.join('ipfs_datastore_local', 'blocks'),
      path.join('ipfs_datastore_local', 'datastore'),
    ];

    for (const rel of dataDirs) {
      const abs = path.join(dataDir, rel);
      try {
        await fs.mkdir(abs, { recursive: true });
      } catch (err) {
        this.logger.error(`storage-manager: failed to create ${abs}: ${err.message}`);
        throw err;
      }
    }

    for (const rel of storageDirs) {
      const abs = path.join(effectiveStorageDir, rel);
      try {
        await fs.mkdir(abs, { recursive: true });
      } catch (err) {
        this.logger.error(`storage-manager: failed to create ${abs}: ${err.message}`);
        throw err;
      }
    }

    this.logger.info(`storage-manager: directory tree initialized under ${dataDir} (storage: ${effectiveStorageDir})`);
  }

  // ---------------------------------------------------------------------------
  // Template / config copying
  // ---------------------------------------------------------------------------

  /**
   * Copy template files from the bundled app resources into the appropriate
   * subdirectories of dataDir.
   *
   * Expected source layout inside resourcesDir:
   *   kubo/config                            -> config/kubo/config
   *   kubo/kubo-container-init.d.sh          -> config/kubo/kubo-container-init.d.sh
   *   kubo-local/config-local                -> config/kubo-local/config-local
   *   kubo-local/kubo-local-container-init.d.sh -> config/kubo-local/kubo-local-container-init.d.sh
   *   ipfs-cluster/ipfs-cluster-container-init.d.sh -> config/ipfs-cluster/ipfs-cluster-container-init.d.sh
   *   docker-compose.pc.yml                  -> config/docker-compose.pc.yml
   *   .env.pc                                -> config/.env.pc
   *   .env.cluster.pc                        -> config/.env.cluster.pc
   *   .env.gofula.pc                         -> config/.env.gofula.pc
   *
   * @param {string} dataDir      - User's chosen data directory.
   * @param {string} resourcesDir - Path to bundled resources
   *                                 (e.g. app.getPath('extraResources')).
   */
  async copyTemplates(dataDir, resourcesDir) {
    const mappings = [
      // kubo
      {
        src: path.join('kubo', 'config'),
        dest: path.join('config', 'kubo', 'config'),
      },
      {
        src: path.join('kubo', 'kubo-container-init.d.sh'),
        dest: path.join('config', 'kubo', 'kubo-container-init.d.sh'),
      },
      // kubo-local
      {
        src: path.join('kubo-local', 'config-local'),
        dest: path.join('config', 'kubo-local', 'config-local'),
      },
      {
        src: path.join('kubo-local', 'kubo-local-container-init.d.sh'),
        dest: path.join('config', 'kubo-local', 'kubo-local-container-init.d.sh'),
      },
      // ipfs-cluster
      {
        src: path.join('ipfs-cluster', 'ipfs-cluster-container-init.d.sh'),
        dest: path.join('config', 'ipfs-cluster', 'ipfs-cluster-container-init.d.sh'),
      },
      // compose & env files
      { src: 'docker-compose.pc.yml', dest: path.join('config', 'docker-compose.pc.yml') },
      { src: '.env.pc', dest: path.join('config', '.env.pc') },
      { src: '.env.cluster.pc', dest: path.join('config', '.env.cluster') },
      { src: '.env.gofula.pc', dest: path.join('config', '.env.gofula') },
    ];

    for (const { src, dest } of mappings) {
      const srcPath = path.join(resourcesDir, src);
      const destPath = path.join(dataDir, dest);

      try {
        // Ensure the destination directory exists
        await fs.mkdir(path.dirname(destPath), { recursive: true });
        await fs.copyFile(srcPath, destPath);
        this.logger.info(`storage-manager: copied ${src} -> ${destPath}`);
      } catch (err) {
        // If a source file does not exist in the resources bundle, warn but
        // do not abort -- not every deployment ships every template.
        if (err.code === 'ENOENT') {
          this.logger.warn(`storage-manager: template not found, skipping: ${srcPath}`);
        } else {
          this.logger.error(`storage-manager: failed to copy ${src}: ${err.message}`);
          throw err;
        }
      }
    }

    this.logger.info('storage-manager: template copying complete');
  }

  // ---------------------------------------------------------------------------
  // Disk space helpers
  // ---------------------------------------------------------------------------

  /**
   * Check available and total disk space for the given directory.
   *
   * @param {string} dir - Any existing directory on the target filesystem.
   * @returns {Promise<{freeGB: number, totalGB: number, sufficient: boolean}>}
   *          sufficient is true when freeGB >= 20.
   */
  async checkDiskSpace(dir) {
    const GB = 1024 * 1024 * 1024;

    try {
      // fs.statfs is available in Node >= 18.15
      const stats = await fs.statfs(dir);
      const freeGB = (stats.bfree * stats.bsize) / GB;
      const totalGB = (stats.blocks * stats.bsize) / GB;
      return {
        freeGB: Math.round(freeGB * 100) / 100,
        totalGB: Math.round(totalGB * 100) / 100,
        sufficient: freeGB >= 20,
      };
    } catch (err) {
      // Fallback: use platform-specific CLI to get actual disk space
      this.logger.warn(
        `storage-manager: fs.statfs failed (${err.message}), falling back to CLI`
      );
      try {
        const { execFileSync } = require('child_process');
        let freeGB, totalGB;

        if (process.platform === 'win32') {
          // Extract drive letter from dir (e.g. "C:" from "C:\Users\...")
          const drive = dir.match(/^([A-Za-z]:)/)?.[1] || 'C:';
          const output = execFileSync(
            'powershell',
            ['-NoProfile', '-Command',
             `Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}'" | Select-Object -Property FreeSpace,Size | ConvertTo-Json`],
            { timeout: 10000, encoding: 'utf-8' }
          );
          const diskInfo = JSON.parse(output.trim());
          const freeBytes = diskInfo.FreeSpace;
          const totalBytes = diskInfo.Size;
          freeGB = freeBytes / GB;
          totalGB = totalBytes / GB;
        } else {
          const output = execFileSync('df', ['-B1', dir], {
            timeout: 10000,
            encoding: 'utf-8',
          });
          const lines = output.trim().split('\n');
          const parts = lines[lines.length - 1].split(/\s+/);
          // df -B1 columns: Filesystem 1B-blocks Used Available Use% Mounted
          totalGB = parseInt(parts[1], 10) / GB;
          freeGB = parseInt(parts[3], 10) / GB;
        }

        return {
          freeGB: Math.round(freeGB * 100) / 100,
          totalGB: Math.round(totalGB * 100) / 100,
          sufficient: freeGB >= 20,
        };
      } catch (fallbackErr) {
        this.logger.warn(
          `storage-manager: CLI fallback also failed (${fallbackErr.message}), returning unknown`
        );
        return { freeGB: 0, totalGB: 0, sufficient: false };
      }
    }
  }

  /**
   * Calculate the total size of all files under dataDir (recursive).
   *
   * @param {string} dataDir - Root directory to measure.
   * @returns {Promise<number>} Size in gigabytes.
   */
  async getDataDirSize(dataDir) {
    const GB = 1024 * 1024 * 1024;
    let totalBytes = 0;

    /**
     * Recursively walk a directory tree and sum regular-file sizes.
     * Symbolic links are not followed to avoid counting external data.
     */
    const walk = async (dir) => {
      let entries;
      try {
        entries = await fs.readdir(dir, { withFileTypes: true });
      } catch (err) {
        // Permission errors or vanished directories are non-fatal.
        this.logger.warn(`storage-manager: getDataDirSize skipping ${dir}: ${err.message}`);
        return;
      }

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          await walk(fullPath);
        } else if (entry.isFile()) {
          try {
            const stat = await fs.stat(fullPath);
            totalBytes += stat.size;
          } catch {
            // File may have been removed between readdir and stat.
          }
        }
        // Symlinks, sockets, etc. are intentionally skipped.
      }
    };

    await walk(dataDir);
    return Math.round((totalBytes / GB) * 100) / 100;
  }
}

module.exports = StorageManager;
