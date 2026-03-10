const { EventEmitter } = require('events');
const os = require('os');

class MdnsAdvertiser extends EventEmitter {
  constructor(logger) {
    super();
    this.logger = logger;
    this.bonjour = null;
    this.service = null;
    this.wapPort = 3500;
    this.lastTxt = null;
  }

  /**
   * Find the best LAN IP for mDNS multicast.
   * Skips Docker, WSL, and Hyper-V virtual adapters.
   */
  _getLanIp() {
    const interfaces = os.networkInterfaces();
    const skipPatterns = ['docker', 'vethernet', 'wsl', 'hyper-v', 'vmware', 'virtualbox', 'vbox'];

    // First pass: physical adapters only, skip link-local 169.254.x.x
    for (const [name, addrs] of Object.entries(interfaces)) {
      const lowerName = name.toLowerCase();
      if (skipPatterns.some(p => lowerName.includes(p))) continue;
      for (const iface of addrs) {
        if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.')) {
          return { ip: iface.address, adapter: name };
        }
      }
    }
    // Fallback: any non-internal, non-link-local IPv4
    for (const [name, addrs] of Object.entries(interfaces)) {
      for (const iface of addrs) {
        if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.')) {
          return { ip: iface.address, adapter: name };
        }
      }
    }
    return null;
  }

  /**
   * Start mDNS advertisement with full device properties.
   * @param {object} props
   * @param {string} props.bloxPeerIdString  - kubo peer ID
   * @param {string} [props.authorizer]      - authorizer peer ID (empty = unpaired)
   * @param {string} [props.hardwareID]      - stable device identifier
   * @param {string} [props.poolName]        - pool name (empty initially)
   * @param {string} [props.ipfsClusterID]   - ipfs-cluster peer ID
   * @param {number} [props.wapPort]         - go-fula WAP port (default 3500)
   */
  async start(props) {
    try {
      const Bonjour = require('bonjour-service');

      // Log all network interfaces for diagnostics
      const interfaces = os.networkInterfaces();
      const ifaceList = [];
      for (const [name, addrs] of Object.entries(interfaces)) {
        for (const a of addrs) {
          if (a.family === 'IPv4') {
            ifaceList.push(`${name}: ${a.address}${a.internal ? ' (internal)' : ''}`);
          }
        }
      }
      this.logger.info(`mDNS: network interfaces: ${ifaceList.join(', ')}`);

      const lanInfo = this._getLanIp();
      this.logger.info(`mDNS: selected interface: ${lanInfo ? `${lanInfo.adapter} (${lanInfo.ip})` : '(none — using default)'}`);

      if (!this.bonjour) {
        const opts = {};
        if (lanInfo) {
          opts.interface = lanInfo.ip;
        }
        this.bonjour = new Bonjour.default(opts, (err) => {
          this.logger.error(`mDNS Bonjour error callback: ${err.message}`);
        });

        // Hook into the underlying multicast-dns server for diagnostics
        const server = this.bonjour._server || this.bonjour.mdnsServer;
        if (server) {
          server.on('error', (err) => {
            this.logger.error(`mDNS multicast-dns error: ${err.message}`);
          });
          server.on('ready', () => {
            this.logger.info('mDNS multicast-dns socket is ready and bound');
          });
          server.on('query', (query) => {
            const questions = (query.questions || []).map(q => `${q.name} ${q.type}`).join(', ');
            if (questions.includes('fulatower')) {
              this.logger.info(`mDNS: received query for: ${questions}`);
            }
          });
        } else {
          this.logger.warn('mDNS: could not access underlying multicast-dns server for diagnostics');
        }
      }

      const bloxPeerId = props.bloxPeerIdString || '';
      this.wapPort = props.wapPort || 3500;

      const txt = {
        bloxPeerIdString: bloxPeerId,
        authorizer: props.authorizer || '',
        hardwareID: props.hardwareID || '',
        poolName: props.poolName || '',
        ipfsClusterID: props.ipfsClusterID || '',
        ipAddress: lanInfo?.ip || '',
      };
      this.lastTxt = txt;

      const peerSuffix = bloxPeerId.slice(-5) || 'pc';
      const serviceName = `fulatower_${peerSuffix}`;

      // Stop existing service before re-publishing
      if (this.service) {
        this.service.stop();
        this.service = null;
      }

      this.service = this.bonjour.publish({
        name: serviceName,
        type: 'fulatower',
        port: this.wapPort,
        txt,
      });

      // Listen for service events
      if (this.service) {
        this.service.on('up', () => {
          this.logger.info(`mDNS service '${serviceName}' is UP and responding to queries`);
        });
        this.service.on('error', (err) => {
          this.logger.error(`mDNS service error: ${err.message}`);
        });
      }

      this.logger.info(`mDNS: published ${serviceName} (_fulatower._tcp) on port ${this.wapPort}, txt=${JSON.stringify(txt)}`);
    } catch (e) {
      this.logger.error(`mDNS advertising failed: ${e.message}\n${e.stack}`);
    }
  }

  /**
   * Re-advertise with updated properties (e.g. after authorizer changes).
   * Merges new props with last-known TXT record values.
   * @param {object} props - partial props to update
   */
  async updateAdvertisement(props) {
    const merged = { ...this.lastTxt, wapPort: this.wapPort, ...props };
    await this.start(merged);
  }

  stop() {
    try {
      if (this.service) {
        this.service.stop();
        this.service = null;
      }
      if (this.bonjour) {
        this.bonjour.destroy();
        this.bonjour = null;
      }
      this.logger.info('mDNS advertising stopped');
    } catch (e) {
      // Ignore cleanup errors
    }
  }
}

module.exports = MdnsAdvertiser;
