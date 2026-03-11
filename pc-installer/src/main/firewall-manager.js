/**
 * PortChecker — checks whether local TCP ports are available.
 *
 * Originally named "firewall-manager" but firewall rule manipulation was
 * removed: on Windows, Docker Desktop manages its own port forwarding via
 * Hyper-V/WSL2 and adding netsh rules requires admin elevation that an
 * Electron app shouldn't assume.  On Armbian the firewall is managed by
 * fula.sh on the bare-metal host, not by the installer.
 *
 * The module name is kept as firewall-manager.js for backward compatibility
 * with existing require() paths.
 */

const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileAsync = promisify(execFile);

class FirewallManager {
  constructor(logger) {
    this.logger = logger;
  }

  async checkPortAvailability(ports) {
    const net = require('net');
    const results = {};
    for (const port of ports) {
      const inUse = await new Promise((resolve) => {
        const server = net.createServer();
        server.once('error', () => resolve(true));
        server.once('listening', () => { server.close(); resolve(false); });
        server.listen(port, '127.0.0.1');
      });
      if (inUse) {
        const processInfo = await this._identifyProcess(port);
        results[port] = { available: false, ...processInfo };
      } else {
        results[port] = { available: true };
      }
    }
    return results;
  }

  /**
   * Try to identify which process is using a given port.
   * @param {number} port
   * @returns {Promise<{process?: string, pid?: number}>}
   */
  async _identifyProcess(port) {
    try {
      if (process.platform === 'win32') {
        // netstat -ano finds the PID, then tasklist gets the process name
        const { stdout } = await execFileAsync('netstat', ['-ano', '-p', 'TCP'], { timeout: 10000 });
        const lines = stdout.split('\n');
        for (const line of lines) {
          // Match lines like "  TCP    0.0.0.0:4001    0.0.0.0:0    LISTENING    1234"
          const match = line.match(new RegExp(`:\\s*${port}\\s+.*LISTENING\\s+(\\d+)`));
          if (match) {
            const pid = parseInt(match[1], 10);
            try {
              const { stdout: taskOut } = await execFileAsync(
                'tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'],
                { timeout: 5000 }
              );
              const nameMatch = taskOut.match(/"([^"]+)"/);
              return { process: nameMatch ? nameMatch[1] : undefined, pid };
            } catch {
              return { pid };
            }
          }
        }
      } else {
        // Linux/macOS: lsof
        const { stdout } = await execFileAsync('lsof', ['-i', `:${port}`, '-sTCP:LISTEN', '-t'], { timeout: 5000 });
        const pid = parseInt(stdout.trim().split('\n')[0], 10);
        if (!isNaN(pid)) {
          try {
            const { stdout: psOut } = await execFileAsync('ps', ['-p', String(pid), '-o', 'comm='], { timeout: 5000 });
            return { process: psOut.trim() || undefined, pid };
          } catch {
            return { pid };
          }
        }
      }
    } catch {
      // Non-fatal — just return no info
    }
    return {};
  }
}

module.exports = FirewallManager;
