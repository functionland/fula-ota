(() => {
  const api = window.fulaNode;

  // Refresh interval (10 seconds)
  const REFRESH_INTERVAL = 10000;
  let refreshTimer = null;
  let containerNames = [];

  // Human-readable health check name mapping
  const HEALTH_CHECK_LABELS = {
    kuboApi: 'Kubo API',
    kuboSwarm: 'Kubo Swarm',
    clusterApi: 'Cluster API',
    clusterPeers: 'Cluster Peers',
    goFulaProcess: 'Go-Fula Process',
    goFulaApi: 'Go-Fula API',
    bootstrap: 'Bootstrap Connection',
    diskSpace: 'Disk Space',
    dockerHealth: 'Docker Health',
    portAvailability: 'Port Availability',
    dnsResolution: 'DNS Resolution',
    timeSync: 'Time Sync',
  };

  // ---- Initialization ----

  async function init() {
    await Promise.all([
      refreshContainers(),
      refreshHealth(),
      refreshPlugins(),
      refreshSystemInfo(),
    ]);
    startAutoRefresh();
  }

  function startAutoRefresh() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(async () => {
      await refreshContainers();
      await refreshHealth();
    }, REFRESH_INTERVAL);
  }

  // Listen for real-time health status from main process
  const colorLabels = {
    green: 'Healthy', blue: 'Connecting...', yellow: 'Degraded',
    red: 'Error', cyan: 'Setup Required', grey: 'Stopped',
  };
  api.onHealthStatus((status) => {
    updateOverallStatus(status.color, status.label || colorLabels[status.color] || '');
    // Hide instruction box when node is fully healthy
    const instructionBox = document.getElementById('instruction-box');
    if (instructionBox && status.checks) {
      const allHealthy = status.checks.every(c => c.status === 'ok');
      instructionBox.style.display = allHealthy ? 'none' : '';
    }
  });

  // ---- Containers ----

  async function refreshContainers() {
    const listEl = document.getElementById('container-list');
    try {
      const containers = await api.getContainerStatus();
      if (!containers || containers.length === 0) {
        listEl.innerHTML = '<span class="loading-text">No containers found.</span>';
        document.getElementById('container-count').textContent = '0 containers';
        containerNames = [];
        updateLogSelect([]);
        return;
      }

      containerNames = containers.map(c => c.name);
      document.getElementById('container-count').textContent = `${containers.length} container${containers.length !== 1 ? 's' : ''}`;

      listEl.innerHTML = '';
      containers.forEach(c => {
        const row = document.createElement('div');
        row.className = 'container-row';

        const statusClass = c.state === 'running' ? 'running'
          : c.state === 'restarting' ? 'restarting'
          : 'stopped';

        row.innerHTML = `
          <span class="container-name">${escapeHtml(c.name)}</span>
          <span class="container-status ${statusClass}">${escapeHtml(c.state || 'unknown')}</span>
          <button class="btn-sm logs-btn" data-name="${escapeHtml(c.name)}" title="View Logs">Logs</button>
          <button class="btn-sm restart-btn" data-name="${escapeHtml(c.name)}" title="Restart">Restart</button>
        `;

        listEl.appendChild(row);
      });

      // Bind buttons
      listEl.querySelectorAll('.logs-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const name = btn.getAttribute('data-name');
          document.getElementById('log-select').value = name;
          fetchLogs(name);
        });
      });

      listEl.querySelectorAll('.restart-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
          const name = btn.getAttribute('data-name');
          btn.disabled = true;
          btn.textContent = 'Restarting...';
          const origBg = btn.style.background;
          try {
            await api.restartService(name);
            btn.textContent = 'Restarted';
            btn.style.background = '#2ecc71';
          } catch (e) {
            console.error('Restart failed:', e);
            btn.textContent = 'Failed';
            btn.style.background = '#e94560';
          }
          setTimeout(() => {
            btn.textContent = 'Restart';
            btn.style.background = origBg;
            btn.disabled = false;
            refreshContainers();
          }, 3000);
        });
      });

      updateLogSelect(containerNames);
    } catch (e) {
      listEl.innerHTML = `<span class="loading-text">Error loading containers: ${escapeHtml(e.message)}</span>`;
    }
  }

  function updateLogSelect(names) {
    const select = document.getElementById('log-select');
    const currentValue = select.value;
    // Keep the placeholder
    select.innerHTML = '<option value="">Select a service...</option>';
    names.forEach(name => {
      const opt = document.createElement('option');
      opt.value = name;
      opt.textContent = name;
      select.appendChild(opt);
    });
    // Restore selection if still valid
    if (names.includes(currentValue)) {
      select.value = currentValue;
    }
  }

  // ---- Logs ----

  let logRefreshInterval = null;
  let logUserScrolled = false;
  let lastLogContent = '';
  let logFilterText = '';

  async function fetchLogs(name) {
    const outputEl = document.getElementById('log-output');
    if (!name) {
      outputEl.textContent = 'Select a service and click "Load Logs" to view recent output.';
      return;
    }

    try {
      const logs = await api.getContainerLogs(name, 200);
      if (logs && logs.trim()) {
        lastLogContent = logs;
        applyLogFilter();
        // Auto-scroll to bottom unless user has scrolled up
        if (!logUserScrolled) {
          outputEl.scrollTop = outputEl.scrollHeight;
        }
      } else {
        outputEl.textContent = '(no log output)';
        lastLogContent = '';
      }
    } catch (e) {
      outputEl.textContent = `Error: ${e.message}`;
      lastLogContent = '';
    }
  }

  function applyLogFilter() {
    const outputEl = document.getElementById('log-output');
    if (!lastLogContent) return;
    if (logFilterText) {
      const lines = lastLogContent.split('\n');
      const filtered = lines.filter(l => l.toLowerCase().includes(logFilterText.toLowerCase()));
      outputEl.textContent = filtered.join('\n') || '(no matching lines)';
    } else {
      outputEl.textContent = lastLogContent;
    }
  }

  function startLogRefresh() {
    stopLogRefresh();
    const name = document.getElementById('log-select').value;
    if (name) {
      fetchLogs(name);
      logRefreshInterval = setInterval(() => {
        const currentName = document.getElementById('log-select').value;
        if (currentName) fetchLogs(currentName);
      }, 5000);
    }
  }

  function stopLogRefresh() {
    if (logRefreshInterval) {
      clearInterval(logRefreshInterval);
      logRefreshInterval = null;
    }
  }

  // Detect user scroll to prevent auto-scroll interference
  document.getElementById('log-output').addEventListener('scroll', () => {
    const el = document.getElementById('log-output');
    // If scrolled near bottom (within 30px), re-enable auto-scroll
    logUserScrolled = (el.scrollHeight - el.scrollTop - el.clientHeight) > 30;
  });

  document.getElementById('btn-fetch-logs').addEventListener('click', () => {
    const name = document.getElementById('log-select').value;
    fetchLogs(name);
    startLogRefresh();
  });

  // Start auto-refresh when a service is selected from the dropdown
  document.getElementById('log-select').addEventListener('change', () => {
    const name = document.getElementById('log-select').value;
    if (name) {
      fetchLogs(name);
      startLogRefresh();
    } else {
      stopLogRefresh();
    }
  });

  // Log filter input
  document.getElementById('log-filter').addEventListener('input', (e) => {
    logFilterText = e.target.value;
    applyLogFilter();
  });

  // ---- Health Checks ----

  async function refreshHealth() {
    const listEl = document.getElementById('health-list');
    try {
      const health = await api.getHealthStatus();
      if (!health || !health.checks || health.checks.length === 0) {
        listEl.innerHTML = '<span class="loading-text">No health data available.</span>';
        return;
      }

      listEl.innerHTML = '';
      health.checks.forEach(check => {
        const item = document.createElement('div');
        item.className = 'health-item';

        const dotClass = check.status === 'ok' ? 'ok'
          : check.status === 'warn' ? 'warn'
          : 'fail';

        const displayName = HEALTH_CHECK_LABELS[check.name] || check.name;
        item.innerHTML = `
          <div class="health-dot ${dotClass}"></div>
          <span class="health-label">${escapeHtml(displayName)}</span>
          <span class="health-detail">${escapeHtml(check.detail || '')}</span>
        `;
        listEl.appendChild(item);
      });

      // Hide instruction box when all health checks pass
      const instructionBox = document.getElementById('instruction-box');
      if (instructionBox) {
        const allHealthy = health.checks.every(c => c.status === 'ok');
        instructionBox.style.display = allHealthy ? 'none' : '';
      }

      // Update overall from health if provided
      if (health.color) {
        const colorLabels = {
          green: 'Healthy', blue: 'Connecting...', yellow: 'Degraded',
          red: 'Error', cyan: 'Setup Required', grey: 'Stopped',
        };
        updateOverallStatus(health.color, health.label || colorLabels[health.color] || '');
      }
    } catch (e) {
      listEl.innerHTML = `<span class="loading-text">Error: ${escapeHtml(e.message)}</span>`;
    }
  }

  // ---- Plugins ----

  async function refreshPlugins() {
    const listEl = document.getElementById('plugin-list');
    try {
      const [available, active] = await Promise.all([
        api.getPlugins(),
        api.getActivePlugins(),
      ]);

      const activeNames = new Set((active || []).map(p => p.name || p));

      const allPlugins = available || [];
      if (allPlugins.length === 0) {
        listEl.innerHTML = '<span class="loading-text">No plugins available.</span>';
        return;
      }

      listEl.innerHTML = '';
      allPlugins.forEach(plugin => {
        const isInstalled = activeNames.has(plugin.name);
        const row = document.createElement('div');
        row.className = 'plugin-row';

        row.innerHTML = `
          <div class="plugin-info">
            <div class="plugin-name">${escapeHtml(plugin.name)}</div>
            <div class="plugin-desc">${escapeHtml(plugin.description || '')}</div>
          </div>
          <span class="plugin-status ${isInstalled ? 'installed' : 'available'}">${isInstalled ? 'Installed' : 'Available'}</span>
          <button class="btn-sm plugin-action-btn" data-name="${escapeHtml(plugin.name)}" data-installed="${isInstalled}">
            ${isInstalled ? 'Uninstall' : 'Install'}
          </button>
        `;

        listEl.appendChild(row);
      });

      // Bind plugin action buttons
      listEl.querySelectorAll('.plugin-action-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
          const name = btn.getAttribute('data-name');
          const isInstalled = btn.getAttribute('data-installed') === 'true';
          btn.disabled = true;
          btn.textContent = '...';
          try {
            if (isInstalled) {
              await api.uninstallPlugin(name);
            } else {
              await api.installPlugin(name);
            }
          } catch (e) {
            console.error('Plugin action failed:', e);
          }
          await refreshPlugins();
        });
      });
    } catch (e) {
      listEl.innerHTML = `<span class="loading-text">Error: ${escapeHtml(e.message)}</span>`;
    }
  }

  // ---- System Info ----

  async function refreshSystemInfo() {
    try {
      const dataDir = await api.getDataDir();
      document.getElementById('info-datadir').textContent = dataDir || '--';
      document.getElementById('info-platform').textContent = navigator.platform || '--';

      if (dataDir) {
        try {
          const disk = await api.checkDiskSpace(dataDir);
          if (disk && disk.freeGB != null) {
            document.getElementById('info-disk').textContent = `${disk.freeGB.toFixed(1)} GB free`;
          }
        } catch {}
      }

      const isSetup = await api.isSetupComplete();
      document.getElementById('info-status').textContent = isSetup ? 'Setup Complete' : 'Needs Setup';

      // Show LAN IP in header
      try {
        const lanIp = await api.getLanIp();
        if (lanIp) {
          document.getElementById('lan-ip').textContent = `(${lanIp})`;
        }
      } catch {}
    } catch (e) {
      console.error('System info error:', e);
    }
  }

  // ---- Overall Status ----

  function updateOverallStatus(color, label) {
    const dot = document.getElementById('overall-dot');
    const labelEl = document.getElementById('overall-label');
    dot.className = `status-dot ${color}`;
    if (label) labelEl.textContent = label;
  }

  // ---- Refresh Button ----

  document.getElementById('btn-refresh').addEventListener('click', async () => {
    const btn = document.getElementById('btn-refresh');
    btn.disabled = true;
    btn.textContent = 'Refreshing...';
    await Promise.all([
      refreshContainers(),
      refreshHealth(),
      refreshPlugins(),
      refreshSystemInfo(),
    ]);
    btn.disabled = false;
    btn.textContent = 'Refresh';
  });

  // ---- Helpers ----

  function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  // ---- Start ----
  init();
})();
