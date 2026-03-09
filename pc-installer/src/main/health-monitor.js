const { EventEmitter } = require('events');
const http = require('http');
const net = require('net');
const fs = require('fs/promises');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const YAML = require('yaml');

const execFileAsync = promisify(execFile);

const {
  PORTS,
  CONTAINERS,
  RELAY_PEER_ID,
  MIN_DISK_SPACE_GB,
} = require('./constants');

// YAML invalid control characters (all control chars except tab 0x09, newline 0x0A, carriage return 0x0D)
const YAML_INVALID_CHARS = new Set([
  ...range(0x00, 0x09),
  0x0b, 0x0c,
  ...range(0x0e, 0x20),
]);

/** Generate an array of integers from start (inclusive) to end (exclusive). */
function range(start, end) {
  const result = [];
  for (let i = start; i < end; i++) result.push(i);
  return result;
}

/**
 * Perform an HTTP POST request using the built-in http module.
 * Returns { status, data } on success.
 */
function httpPost(url, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const req = http.request(
      {
        hostname: urlObj.hostname,
        port: urlObj.port,
        path: urlObj.pathname + urlObj.search,
        method: 'POST',
        timeout,
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => resolve({ status: res.statusCode, data }));
      }
    );
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('timeout'));
    });
    req.end();
  });
}

/**
 * Attempt a TCP connection to host:port with a timeout.
 * Resolves true if the connection succeeds, false otherwise.
 */
function tcpProbe(host, port, timeout = 3000) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;

    const finish = (ok) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(ok);
    };

    socket.setTimeout(timeout);
    socket.on('connect', () => finish(true));
    socket.on('error', () => finish(false));
    socket.on('timeout', () => finish(false));
    socket.connect(port, host);
  });
}

/**
 * HealthMonitor — periodically checks all Fula node services and emits status events.
 *
 * Ported from the Armbian readiness-check.py to Node.js for the PC installer.
 *
 * Events emitted:
 *   'status'          — { color, checks, issues }
 *   'needs-restart'   — after consecutive relay+swarm failures
 *   'container-down'  — { service } when a container is not running
 *   'cluster-corrupt' — when pebble/lock errors are detected in cluster logs
 */
class HealthMonitor extends EventEmitter {
  /**
   * @param {object} dockerManager - Must expose getContainerStatus() and getContainerLogs(name, tail)
   * @param {object} configStore   - Must expose getDataDir()
   * @param {object} logger        - Winston-compatible logger
   */
  constructor(dockerManager, configStore, logger) {
    super();
    this.dockerManager = dockerManager;
    this.configStore = configStore;
    this.logger = logger;

    this._interval = null;
    this._running = false;

    // Auto-recovery state
    this.consecutiveRelayFailures = 0;
    this.consecutiveSwarmFailures = 0;

    // Expected container names (values from CONTAINERS constant)
    this.expectedContainers = Object.values(CONTAINERS);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /**
   * Start periodic health checks.
   * @param {number} intervalMs - Milliseconds between check cycles (default 60 000).
   */
  start(intervalMs = 60000) {
    if (this._running) return;
    this._running = true;
    this.logger.info(`HealthMonitor starting (interval=${intervalMs}ms)`);

    // Run immediately, then on interval
    this.runAllChecks().catch((err) =>
      this.logger.error(`HealthMonitor initial check failed: ${err.message}`)
    );

    this._interval = setInterval(() => {
      this.runAllChecks().catch((err) =>
        this.logger.error(`HealthMonitor check failed: ${err.message}`)
      );
    }, intervalMs);
  }

  /** Stop periodic health checks. */
  stop() {
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
    this._running = false;
    this.logger.info('HealthMonitor stopped');
  }

  // ---------------------------------------------------------------------------
  // Orchestrator
  // ---------------------------------------------------------------------------

  /**
   * Run every individual check, compute overall color, and emit the 'status' event.
   * @returns {{ color: string, checks: object, issues: string[] }}
   */
  async runAllChecks() {
    const checks = {};
    const issues = [];

    // Run all checks concurrently where possible.
    const [
      kuboApi,
      kuboLocalApi,
      relay,
      bootstrap,
      containers,
      clusterErrors,
      kuboHostErrors,
      kuboLocalErrors,
      configValidity,
      diskSpace,
      proxyPorts,
      peerIdCollision,
    ] = await Promise.allSettled([
      this.checkKuboApi(),
      this.checkKuboLocalApi(),
      this.checkRelayConnection(),
      this.checkBootstrapPeers(),
      this.checkContainerHealth(),
      this.checkClusterErrors(),
      this.checkKuboHostErrors(),
      this.checkKuboLocalErrors(),
      this.checkConfigValidity(),
      this.checkDiskSpace(),
      this.checkProxyPorts(),
      this.checkPeerIdCollision(),
    ]);

    const settle = (result, name) => {
      if (result.status === 'fulfilled') {
        checks[name] = result.value;
      } else {
        checks[name] = {
          ok: false,
          detail: `check threw: ${result.reason?.message || result.reason}`,
        };
      }
      if (!checks[name].ok) {
        issues.push(`${name}: ${checks[name].detail}`);
      }
    };

    settle(kuboApi, 'kuboApi');
    settle(kuboLocalApi, 'kuboLocalApi');
    settle(relay, 'relay');
    settle(bootstrap, 'bootstrap');
    settle(containers, 'containers');
    settle(clusterErrors, 'clusterErrors');
    settle(kuboHostErrors, 'kuboHostErrors');
    settle(kuboLocalErrors, 'kuboLocalErrors');
    settle(configValidity, 'configValidity');
    settle(diskSpace, 'diskSpace');
    settle(proxyPorts, 'proxyPorts');
    settle(peerIdCollision, 'peerIdCollision');

    // --- Auto-recovery logic ---
    this._evaluateAutoRecovery(checks);

    const color = this.determineColor(checks);

    const result = { color, checks, issues };
    this.emit('status', result);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Individual checks — each returns { ok: boolean, detail: string }
  // ---------------------------------------------------------------------------

  /** Check kubo API at 127.0.0.1:5001 */
  async checkKuboApi() {
    try {
      const resp = await httpPost(
        `http://127.0.0.1:${PORTS.kuboApi}/api/v0/id`,
        5000
      );
      if (resp.status === 200) {
        const body = JSON.parse(resp.data);
        return { ok: true, detail: `PeerID=${body.ID || 'unknown'}` };
      }
      return { ok: false, detail: `HTTP ${resp.status}` };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  /** Check kubo-local API at 127.0.0.1:5002 */
  async checkKuboLocalApi() {
    try {
      const resp = await httpPost(
        `http://127.0.0.1:${PORTS.kuboLocalApi}/api/v0/id`,
        5000
      );
      if (resp.status === 200) {
        const body = JSON.parse(resp.data);
        return { ok: true, detail: `PeerID=${body.ID || 'unknown'}` };
      }
      return { ok: false, detail: `HTTP ${resp.status}` };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  /** Check if the relay peer is among connected swarm peers. */
  async checkRelayConnection() {
    try {
      const resp = await httpPost(
        `http://127.0.0.1:${PORTS.kuboApi}/api/v0/swarm/peers`,
        5000
      );
      if (resp.status !== 200) {
        return { ok: false, detail: `HTTP ${resp.status}` };
      }
      const body = JSON.parse(resp.data);
      const peers = body.Peers || [];
      const relayConnected = peers.some(
        (p) => p.Peer === RELAY_PEER_ID
      );
      if (relayConnected) {
        return { ok: true, detail: 'relay peer connected' };
      }
      return {
        ok: false,
        detail: `relay peer ${RELAY_PEER_ID} not in ${peers.length} connected peers`,
      };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  /** Check that kubo has at least one bootstrap/swarm peer connected. */
  async checkBootstrapPeers() {
    try {
      const resp = await httpPost(
        `http://127.0.0.1:${PORTS.kuboApi}/api/v0/swarm/peers`,
        5000
      );
      if (resp.status !== 200) {
        return { ok: false, detail: `HTTP ${resp.status}` };
      }
      const body = JSON.parse(resp.data);
      const peers = body.Peers || [];
      if (peers.length > 0) {
        return { ok: true, detail: `${peers.length} peers connected` };
      }
      return { ok: false, detail: 'no swarm peers connected' };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  /** Verify all expected containers are running. */
  async checkContainerHealth() {
    try {
      const statuses = await this.dockerManager.getContainerStatus();
      const running = [];
      const notRunning = [];

      for (const name of this.expectedContainers) {
        const entry = statuses.find(
          (s) => s.name === name || s.Names === name
        );
        if (entry && /running|up/i.test(entry.status || entry.State || '')) {
          running.push(name);
        } else {
          notRunning.push(name);
        }
      }

      if (notRunning.length === 0) {
        return {
          ok: true,
          detail: `all ${this.expectedContainers.length} containers running`,
        };
      }

      // Emit per-container events for auto-recovery
      for (const svc of notRunning) {
        this.emit('container-down', { service: svc });
      }

      return {
        ok: false,
        detail: `not running: ${notRunning.join(', ')} (${running.length}/${this.expectedContainers.length})`,
      };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  /** Check ipfs_cluster logs for pebble/lock/FATAL errors. */
  async checkClusterErrors() {
    try {
      const logs = await this.dockerManager.getContainerLogs(
        CONTAINERS.cluster,
        15
      );
      const keywords = ['pebble', 'lock', 'FATAL', 'failed to open pebble database'];
      const found = keywords.filter((kw) =>
        logs.toLowerCase().includes(kw.toLowerCase())
      );

      if (found.length > 0) {
        this.emit('cluster-corrupt');
        return {
          ok: false,
          detail: `cluster log errors: ${found.join(', ')}`,
        };
      }
      return { ok: true, detail: 'no cluster errors in recent logs' };
    } catch (err) {
      // If container doesn't exist yet, don't treat as error
      return { ok: true, detail: `could not read logs: ${err.message}` };
    }
  }

  /** Check kubo (ipfs_host) logs for plugin/config errors. */
  async checkKuboHostErrors() {
    try {
      const { stdout } = await execFileAsync(
        'docker', ['logs', CONTAINERS.kubo, '--tail', '17'],
        { timeout: 10000 }
      );
      const patterns = [
        'could not load plugin',
        'fatal',
        'Provider has been removed',
      ];
      const found = patterns.filter((p) =>
        stdout.toLowerCase().includes(p.toLowerCase())
      );

      if (found.length > 0) {
        return {
          ok: false,
          detail: `kubo host log errors: ${found.join(', ')}`,
        };
      }
      return { ok: true, detail: 'no kubo host errors in recent logs' };
    } catch (err) {
      return { ok: true, detail: `could not read logs: ${err.message}` };
    }
  }

  /** Check kubo-local (ipfs_local) logs for fatal/error patterns. */
  async checkKuboLocalErrors() {
    try {
      const { stdout } = await execFileAsync(
        'docker', ['logs', CONTAINERS.kuboLocal, '--tail', '20'],
        { timeout: 10000 }
      );
      const patterns = [
        'fatal',
        'could not load plugin',
        'Provider has been removed',
      ];
      const found = patterns.filter((p) =>
        stdout.toLowerCase().includes(p.toLowerCase())
      );

      if (found.length > 0) {
        return {
          ok: false,
          detail: `kubo local log errors: ${found.join(', ')}`,
        };
      }
      return { ok: true, detail: 'no kubo local errors in recent logs' };
    } catch (err) {
      return { ok: true, detail: `could not read logs: ${err.message}` };
    }
  }

  /**
   * Validate config.yaml:
   *   1. File exists
   *   2. No YAML-invalid control characters
   *   3. Parses as valid YAML
   */
  async checkConfigValidity() {
    try {
      const dataDir = this.configStore.getDataDir();
      const configPath = path.join(dataDir, 'internal', 'config.yaml');

      let raw;
      try {
        raw = await fs.readFile(configPath);
      } catch (err) {
        if (err.code === 'ENOENT') {
          return { ok: false, detail: 'config.yaml missing' };
        }
        throw err;
      }

      // Check for invalid control characters
      const invalidChars = [];
      for (let i = 0; i < raw.length; i++) {
        if (YAML_INVALID_CHARS.has(raw[i])) {
          invalidChars.push({ byte: raw[i], position: i });
        }
      }
      if (invalidChars.length > 0) {
        const sample = invalidChars
          .slice(0, 3)
          .map((c) => `0x${c.byte.toString(16).padStart(2, '0')} @${c.position}`)
          .join(', ');
        return {
          ok: false,
          detail: `config.yaml contains ${invalidChars.length} invalid control char(s): ${sample}`,
        };
      }

      // Try parsing
      const text = raw.toString('utf-8');
      YAML.parse(text);

      return { ok: true, detail: 'config.yaml valid' };
    } catch (err) {
      return { ok: false, detail: `config.yaml error: ${err.message}` };
    }
  }

  /** Check available disk space on the data directory. */
  async checkDiskSpace() {
    try {
      const dataDir = this.configStore.getDataDir();
      const stats = await fs.statfs(dataDir);

      const freeBytes = stats.bfree * stats.bsize;
      const freeGb = freeBytes / (1024 ** 3);

      if (freeGb < MIN_DISK_SPACE_GB) {
        return {
          ok: false,
          detail: `low disk space: ${freeGb.toFixed(2)} GB free (min ${MIN_DISK_SPACE_GB} GB)`,
        };
      }
      return { ok: true, detail: `${freeGb.toFixed(2)} GB free` };
    } catch (err) {
      // Don't block on missing/unmounted path
      return { ok: true, detail: `disk check skipped: ${err.message}` };
    }
  }

  /** Check that go-fula proxy ports 4020 and 4021 are reachable. */
  async checkProxyPorts() {
    const port4020 = await tcpProbe('127.0.0.1', PORTS.blockchainProxy, 3000);
    const port4021 = await tcpProbe(
      '127.0.0.1',
      PORTS.blockchainProxyAlt,
      3000
    );

    if (port4020 && port4021) {
      return { ok: true, detail: 'proxy ports 4020 and 4021 reachable' };
    }

    const down = [];
    if (!port4020) down.push('4020');
    if (!port4021) down.push('4021');
    return {
      ok: false,
      detail: `proxy port(s) unreachable: ${down.join(', ')}`,
    };
  }

  /**
   * Detect if kubo and ipfs-cluster share the same PeerID (known failure mode).
   * Compares kubo /api/v0/id against the cluster identity.json file.
   */
  async checkPeerIdCollision() {
    try {
      // Get kubo PeerID
      const kuboResp = await httpPost(
        `http://127.0.0.1:${PORTS.kuboApi}/api/v0/id`,
        5000
      );
      if (kuboResp.status !== 200) {
        return { ok: true, detail: 'kubo not reachable, skipping collision check' };
      }
      const kuboId = JSON.parse(kuboResp.data).ID;

      // Get cluster PeerID from identity.json
      let clusterId;
      try {
        const dataDir = this.configStore.getDataDir();
        const identityPath = path.join(dataDir, 'ipfs-cluster', 'identity.json');
        const identityRaw = await fs.readFile(identityPath, 'utf-8');
        const identity = JSON.parse(identityRaw);
        clusterId = identity.id;
      } catch {
        // Fall back to cluster HTTP API
        try {
          const clusterResp = await httpPost(
            `http://127.0.0.1:${PORTS.clusterApi}/id`,
            5000
          );
          if (clusterResp.status === 200) {
            clusterId = JSON.parse(clusterResp.data).id;
          }
        } catch {
          return { ok: true, detail: 'cluster not reachable, skipping collision check' };
        }
      }

      if (!kuboId || !clusterId) {
        return { ok: true, detail: 'could not retrieve both peer IDs' };
      }

      if (kuboId === clusterId) {
        return {
          ok: false,
          detail: `PeerID COLLISION: kubo and cluster share ${kuboId}`,
        };
      }

      return { ok: true, detail: 'no PeerID collision' };
    } catch (err) {
      return { ok: true, detail: `collision check skipped: ${err.message}` };
    }
  }

  // ---------------------------------------------------------------------------
  // Color determination
  // ---------------------------------------------------------------------------

  /**
   * Determine the overall tray color from the individual check results.
   *
   * Priority:
   *   red    — no containers running, or critical errors (peerID collision, corrupt cluster)
   *   cyan   — config.yaml missing (setup required)
   *   yellow — some containers down or non-critical warnings
   *   blue   — kubo OK but relay/bootstrap not yet connected (still joining swarm)
   *   green  — everything healthy
   */
  determineColor(checks) {
    const c = (name) => checks[name] || { ok: true };

    // Count running containers from the detail string
    const containerCheck = c('containers');
    const allContainersDown =
      !containerCheck.ok &&
      containerCheck.detail &&
      /0\/\d+/.test(containerCheck.detail);

    // Red: no containers at all
    if (allContainersDown) {
      return 'red';
    }

    // Cyan: config.yaml missing → setup required
    if (
      !c('configValidity').ok &&
      c('configValidity').detail === 'config.yaml missing'
    ) {
      return 'cyan';
    }

    // Red: critical errors
    if (!c('peerIdCollision').ok) return 'red';
    if (!c('clusterErrors').ok) return 'red';
    if (!c('diskSpace').ok) return 'red';

    // Yellow: some containers down
    if (!containerCheck.ok) return 'yellow';

    // Yellow: kubo host or local errors
    if (!c('kuboHostErrors').ok || !c('kuboLocalErrors').ok) return 'yellow';

    // Yellow: config invalid (but exists)
    if (!c('configValidity').ok) return 'yellow';

    // Blue: kubo API responding but relay or bootstrap not connected yet
    if (c('kuboApi').ok && (!c('relay').ok || !c('bootstrap').ok)) {
      return 'blue';
    }

    // Yellow: proxy ports down
    if (!c('proxyPorts').ok) return 'yellow';

    // Yellow: kubo APIs down but containers are running
    if (!c('kuboApi').ok || !c('kuboLocalApi').ok) return 'yellow';

    // Green: all good
    return 'green';
  }

  // ---------------------------------------------------------------------------
  // Auto-recovery evaluation
  // ---------------------------------------------------------------------------

  /** @private */
  _evaluateAutoRecovery(checks) {
    const c = (name) => checks[name] || { ok: true };

    // Track consecutive relay failures
    if (!c('relay').ok) {
      this.consecutiveRelayFailures++;
    } else {
      this.consecutiveRelayFailures = 0;
    }

    // Track consecutive swarm/bootstrap failures
    if (!c('bootstrap').ok) {
      this.consecutiveSwarmFailures++;
    } else {
      this.consecutiveSwarmFailures = 0;
    }

    // After 5 consecutive relay+swarm failures → suggest restart
    if (
      this.consecutiveRelayFailures >= 5 &&
      this.consecutiveSwarmFailures >= 5
    ) {
      this.logger.warn(
        `HealthMonitor: ${this.consecutiveRelayFailures} consecutive relay+swarm failures, emitting needs-restart`
      );
      this.emit('needs-restart');
      // Reset counters so we don't spam the event every cycle
      this.consecutiveRelayFailures = 0;
      this.consecutiveSwarmFailures = 0;
    }
  }
}

module.exports = { HealthMonitor };
