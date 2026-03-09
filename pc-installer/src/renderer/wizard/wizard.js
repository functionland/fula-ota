(() => {
  const api = window.fulaNode;

  // State
  let currentStep = 0;
  const totalSteps = 5;
  let dockerOk = false;
  let storageOk = false;
  let portsOk = false;
  let pullOk = false;
  let selectedDataDir = '';

  const REQUIRED_PORTS = [4001, 5001, 5002, 8080, 8081, 40001, 3500, 3501, 4020, 4021, 9000, 9094, 9095, 9096];
  const MIN_FREE_GB = 20;

  // DOM references
  const steps = [
    document.getElementById('step-docker'),
    document.getElementById('step-storage'),
    document.getElementById('step-ports'),
    document.getElementById('step-pull'),
    document.getElementById('step-launch'),
  ];
  const dots = document.querySelectorAll('.step-dot');

  // ---- Navigation ----

  function goToStep(n) {
    if (n < 0 || n >= totalSteps) return;
    steps[currentStep].classList.remove('active');
    steps[n].classList.add('active');
    dots[currentStep].classList.remove('active');
    dots[n].classList.add('active');
    // Mark previous steps complete
    for (let i = 0; i < n; i++) {
      dots[i].classList.add('complete');
    }
    currentStep = n;
    onStepEnter(n);
  }

  function onStepEnter(n) {
    switch (n) {
      case 0: checkDocker(); break;
      case 1: loadDefaultDir(); break;
      case 2: checkPorts(); break;
      case 3: pullImages(); break;
      case 4: break; // manual launch
    }
  }

  // ---- Step 0: Docker Check ----

  async function checkDocker() {
    setStatusIcon('docker-status-icon', 'checking');
    setStatusText('docker-status-text', 'Checking for Docker...');
    hideError('docker-error');
    document.getElementById('btn-docker-next').disabled = true;

    try {
      const result = await api.checkDocker();
      if (result && result.installed && result.running) {
        setStatusIcon('docker-status-icon', 'success');
        setStatusText('docker-status-text',
          `Docker ${result.version || ''} is installed and running.`);
        dockerOk = true;
        document.getElementById('btn-docker-next').disabled = false;
      } else if (result && result.installed && !result.running) {
        setStatusIcon('docker-status-icon', 'error');
        setStatusText('docker-status-text',
          'Docker is installed but not running. Please start Docker Desktop and try again.');
        showError('docker-error', 'Start Docker Desktop, then click "Retry" below.');
        document.getElementById('btn-docker-next').textContent = 'Retry';
        document.getElementById('btn-docker-next').disabled = false;
        dockerOk = false;
      } else {
        setStatusIcon('docker-status-icon', 'error');
        setStatusText('docker-status-text',
          'Docker is not installed. <a href="https://www.docker.com/products/docker-desktop/" target="_blank">Download Docker Desktop</a>');
        showError('docker-error', 'Install Docker Desktop, restart it, then click "Retry".');
        document.getElementById('btn-docker-next').textContent = 'Retry';
        document.getElementById('btn-docker-next').disabled = false;
        dockerOk = false;
      }
    } catch (e) {
      setStatusIcon('docker-status-icon', 'error');
      setStatusText('docker-status-text', 'Failed to check Docker status.');
      showError('docker-error', e.message || 'Unknown error');
      document.getElementById('btn-docker-next').textContent = 'Retry';
      document.getElementById('btn-docker-next').disabled = false;
      dockerOk = false;
    }
  }

  document.getElementById('btn-docker-next').addEventListener('click', () => {
    if (dockerOk) {
      goToStep(1);
    } else {
      document.getElementById('btn-docker-next').textContent = 'Next';
      checkDocker();
    }
  });

  // ---- Step 1: Storage Selection ----

  async function loadDefaultDir() {
    if (selectedDataDir) return; // already picked
    try {
      const dir = await api.getDefaultDataDir();
      selectedDataDir = dir;
      document.getElementById('data-dir-input').value = dir;
      await checkDiskSpace(dir);
    } catch {}
  }

  async function checkDiskSpace(dir) {
    hideError('storage-error');
    document.getElementById('btn-storage-next').disabled = true;
    const diskInfo = document.getElementById('disk-info');

    if (!dir) {
      diskInfo.style.display = 'none';
      return;
    }

    try {
      const result = await api.checkDiskSpace(dir);
      diskInfo.style.display = 'block';
      const freeGB = result.freeGB != null ? result.freeGB : 0;
      document.getElementById('disk-free').textContent = `${freeGB.toFixed(1)} GB`;

      diskInfo.className = 'disk-info';
      if (freeGB < MIN_FREE_GB) {
        diskInfo.classList.add('warning');
        showError('storage-error',
          `At least ${MIN_FREE_GB} GB of free space is recommended. You have ${freeGB.toFixed(1)} GB.`);
        // Allow proceeding with a warning, not a hard block
        storageOk = true;
        document.getElementById('btn-storage-next').disabled = false;
      } else {
        storageOk = true;
        document.getElementById('btn-storage-next').disabled = false;
      }
    } catch (e) {
      diskInfo.style.display = 'none';
      showError('storage-error', e.message || 'Could not check disk space');
    }
  }

  document.getElementById('btn-browse').addEventListener('click', async () => {
    try {
      const result = await api.openFolderDialog();
      if (result) {
        selectedDataDir = result;
        document.getElementById('data-dir-input').value = result;
        await checkDiskSpace(result);
      }
    } catch {
      // Fallback: make input editable for manual entry
      const input = document.getElementById('data-dir-input');
      input.readOnly = false;
      input.focus();
      input.select();
    }
  });

  document.getElementById('data-dir-input').addEventListener('change', async () => {
    selectedDataDir = document.getElementById('data-dir-input').value.trim();
    if (selectedDataDir) {
      await checkDiskSpace(selectedDataDir);
    }
  });

  // Also trigger on blur or Enter key
  document.getElementById('data-dir-input').addEventListener('keydown', async (e) => {
    if (e.key === 'Enter') {
      selectedDataDir = document.getElementById('data-dir-input').value.trim();
      if (selectedDataDir) {
        await checkDiskSpace(selectedDataDir);
      }
    }
  });

  document.getElementById('btn-storage-back').addEventListener('click', () => goToStep(0));
  document.getElementById('btn-storage-next').addEventListener('click', async () => {
    if (!storageOk) return;
    // Initialize data directory
    hideError('storage-error');
    document.getElementById('btn-storage-next').disabled = true;
    document.getElementById('btn-storage-next').innerHTML = '<span class="spinner"></span>Setting up...';

    try {
      const result = await api.setupInitialize(selectedDataDir);
      if (result.success) {
        goToStep(2);
      } else {
        showError('storage-error', result.error || 'Failed to initialize data directory');
      }
    } catch (e) {
      showError('storage-error', e.message || 'Failed to initialize data directory');
    } finally {
      document.getElementById('btn-storage-next').innerHTML = 'Next';
      document.getElementById('btn-storage-next').disabled = false;
    }
  });

  // ---- Step 2: Port Check ----

  async function checkPorts() {
    hideError('ports-error');
    document.getElementById('btn-ports-next').disabled = true;

    // Set all to checking
    REQUIRED_PORTS.forEach(p => {
      const el = document.getElementById(`port-${p}`);
      if (el) {
        el.className = 'port-status checking';
        el.textContent = 'Checking...';
      }
    });

    try {
      const result = await api.checkPorts(REQUIRED_PORTS);
      let allAvailable = true;

      REQUIRED_PORTS.forEach(p => {
        const el = document.getElementById(`port-${p}`);
        if (!el) return;
        const portResult = result && result[p];
        if (portResult === true || (portResult && portResult.available)) {
          el.className = 'port-status available';
          el.textContent = 'Available';
        } else {
          el.className = 'port-status in-use';
          el.textContent = 'In Use';
          allAvailable = false;
        }
      });

      if (allAvailable) {
        portsOk = true;
        document.getElementById('btn-ports-next').disabled = false;
      } else {
        showError('ports-error',
          'Some ports are in use. Close the conflicting applications or change their ports, then click "Retry".');
        document.getElementById('btn-ports-next').textContent = 'Retry';
        document.getElementById('btn-ports-next').disabled = false;
        portsOk = false;
      }
    } catch (e) {
      showError('ports-error', e.message || 'Failed to check ports');
      document.getElementById('btn-ports-next').textContent = 'Retry';
      document.getElementById('btn-ports-next').disabled = false;
      portsOk = false;
    }
  }

  document.getElementById('btn-ports-back').addEventListener('click', () => goToStep(1));
  document.getElementById('btn-ports-next').addEventListener('click', () => {
    if (portsOk) {
      goToStep(3);
    } else {
      document.getElementById('btn-ports-next').textContent = 'Next';
      checkPorts();
    }
  });

  // ---- Step 3: Image Pull ----

  async function pullImages() {
    hideError('pull-error');
    document.getElementById('btn-pull-next').disabled = true;
    document.getElementById('btn-pull-back').disabled = true;

    const progressBar = document.getElementById('pull-progress-bar');
    const progressLabel = document.getElementById('pull-progress-label');
    const pullStatus = document.getElementById('pull-status');

    progressBar.style.width = '100%';
    progressBar.classList.add('indeterminate');
    progressLabel.textContent = 'Pulling Docker images...';
    pullStatus.style.display = 'none';

    try {
      progressLabel.textContent = 'Downloading images — this may take 10-15 minutes on first install...';
      const result = await api.setupPullImages();

      progressBar.classList.remove('indeterminate');

      if (result.success) {
        progressBar.style.width = '100%';
        progressLabel.textContent = 'All images downloaded successfully.';
        pullStatus.style.display = 'flex';
        setStatusIcon('pull-status-icon', 'success');
        document.getElementById('pull-status-text').textContent = 'Images are ready.';
        pullOk = true;
        document.getElementById('btn-pull-next').disabled = false;
      } else {
        progressBar.style.width = '0%';
        progressLabel.textContent = 'Image pull failed.';
        showError('pull-error', result.error || 'Failed to pull Docker images');
        pullStatus.style.display = 'flex';
        setStatusIcon('pull-status-icon', 'error');
        document.getElementById('pull-status-text').textContent = 'Pull failed. Check your internet connection.';
        document.getElementById('btn-pull-next').textContent = 'Retry';
        document.getElementById('btn-pull-next').disabled = false;
        pullOk = false;
      }
    } catch (e) {
      progressBar.classList.remove('indeterminate');
      progressBar.style.width = '0%';
      progressLabel.textContent = 'Image pull failed.';
      showError('pull-error', e.message || 'Failed to pull Docker images');
      document.getElementById('btn-pull-next').textContent = 'Retry';
      document.getElementById('btn-pull-next').disabled = false;
      pullOk = false;
    } finally {
      document.getElementById('btn-pull-back').disabled = false;
    }
  }

  document.getElementById('btn-pull-back').addEventListener('click', () => goToStep(2));
  document.getElementById('btn-pull-next').addEventListener('click', () => {
    if (pullOk) {
      goToStep(4);
    } else {
      document.getElementById('btn-pull-next').textContent = 'Next';
      pullImages();
    }
  });

  // ---- Step 4: Launch ----

  document.getElementById('btn-launch-back').addEventListener('click', () => goToStep(3));

  document.getElementById('btn-launch-start').addEventListener('click', async () => {
    hideError('launch-error');
    document.getElementById('btn-launch-start').disabled = true;
    document.getElementById('btn-launch-back').disabled = true;
    document.getElementById('btn-launch-start').innerHTML = '<span class="spinner"></span>Starting...';

    setStatusIcon('launch-status-icon', 'checking');
    document.getElementById('launch-status-text').textContent = 'Starting Fula Node services...';

    try {
      const result = await api.setupStart();

      if (result.success) {
        document.getElementById('launch-pending').style.display = 'none';
        document.getElementById('launch-done').style.display = 'block';
        document.getElementById('btn-launch-start').style.display = 'none';
        document.getElementById('btn-launch-back').style.display = 'none';
        document.getElementById('btn-launch-finish').style.display = 'inline-block';

        // Show LAN IP for mobile pairing
        try {
          const lanIp = await api.getLanIp();
          if (lanIp) {
            const ipEl = document.getElementById('lan-ip-info');
            if (ipEl) {
              ipEl.textContent = `Your device IP: ${lanIp} — enter this in FxFiles to pair.`;
              ipEl.style.display = 'block';
            }
          }
        } catch {}
      } else {
        setStatusIcon('launch-status-icon', 'error');
        document.getElementById('launch-status-text').textContent = 'Failed to start services.';
        showError('launch-error', result.error || 'Unknown error during launch');
        document.getElementById('btn-launch-start').innerHTML = 'Retry';
        document.getElementById('btn-launch-start').disabled = false;
        document.getElementById('btn-launch-back').disabled = false;
      }
    } catch (e) {
      setStatusIcon('launch-status-icon', 'error');
      document.getElementById('launch-status-text').textContent = 'Failed to start services.';
      showError('launch-error', e.message || 'Unknown error');
      document.getElementById('btn-launch-start').innerHTML = 'Retry';
      document.getElementById('btn-launch-start').disabled = false;
      document.getElementById('btn-launch-back').disabled = false;
    }
  });

  document.getElementById('btn-launch-finish').addEventListener('click', () => {
    window.close();
  });

  // ---- Helpers ----

  function setStatusIcon(id, state) {
    const el = document.getElementById(id);
    if (el) el.className = `status-icon ${state}`;
  }

  function setStatusText(id, html) {
    const el = document.getElementById(id);
    if (el) el.innerHTML = html;
  }

  function showError(id, message) {
    const el = document.getElementById(id);
    if (el) {
      el.textContent = message;
      el.classList.add('visible');
    }
  }

  function hideError(id) {
    const el = document.getElementById(id);
    if (el) {
      el.textContent = '';
      el.classList.remove('visible');
    }
  }

  // ---- Init ----
  onStepEnter(0);
})();
