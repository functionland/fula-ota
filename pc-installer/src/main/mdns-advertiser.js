const { EventEmitter } = require('events');

class MdnsAdvertiser extends EventEmitter {
  constructor(logger) {
    super();
    this.logger = logger;
    this.bonjour = null;
    this.service = null;
  }

  async start(peerId, s3Port = 9000, wapPort = 3500) {
    try {
      const Bonjour = require('bonjour-service');
      this.bonjour = new Bonjour.default();
      const peerSuffix = peerId.slice(-5);
      this.service = this.bonjour.publish({
        name: `fulatower_${peerSuffix}`,
        type: 'fxblox',
        port: wapPort,
        txt: {
          s3Port: String(s3Port),
          peerId: peerId,
          platform: 'pc',
          wapPort: String(wapPort)
        }
      });
      this.logger.info(`mDNS advertising started: fulatower_${peerSuffix} on port ${wapPort}`);
    } catch (e) {
      this.logger.error(`mDNS advertising failed: ${e.message}`);
    }
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
