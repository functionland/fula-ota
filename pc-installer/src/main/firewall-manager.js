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
      results[port] = { available: !inUse };
    }
    return results;
  }
}

module.exports = FirewallManager;
