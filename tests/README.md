# Fula-OTA Test Suite

This directory contains comprehensive unit tests for the Fula-OTA system, specifically designed for Armbian/Rockchip3588 deployment after sugarfunge-node removal.

## Test Structure

### Validation Tests (Post-Removal)
- **`test-config-validation.sh`** - Validates configuration files for remaining node references
- **`test-docker-setup.sh`** - Tests Docker Compose setup and syntax validation
- **`test-container-dependencies.sh`** - Analyzes container dependencies and startup order

### Core Component Tests
- **`test-fula-sh-functions.sh`** - Comprehensive testing of fula.sh functions (install, update, run)
- **`test-docker-services.sh`** - Tests Docker services (go-fula, kubo, ipfs-cluster, watchtower)
- **`test-uniondrive-readiness.sh`** - Tests uniondrive service and readiness-check.py script

### System Integration Tests
- **`test-go-fula-system-integration.sh`** - Enhanced system integration testing for go-fula with WiFi, hotspot, storage, and network connectivity features

## Running Tests

### Run All Tests
From the project root directory:
```bash
./test-fula-system-complete.sh
```

### Run Individual Tests
From the project root directory:
```bash
./tests/test-config-validation.sh
./tests/test-docker-setup.sh
# ... etc
```

## Test Features

- **Safe Testing**: All tests use mock commands and temporary directories to avoid modifying the real system
- **Comprehensive Coverage**: Tests cover Docker services, system scripts, configuration validation, and hardware interactions
- **Armbian/Rockchip3588 Specific**: Tests include platform-specific features and requirements
- **Detailed Reporting**: Each test generates detailed logs and reports in `/tmp/fula-test-results/`

## Test Results

Test results are stored in:
- **Master Log**: `/tmp/fula-system-complete-test.log`
- **Individual Logs**: `/tmp/fula-test-results/`
- **Comprehensive Report**: `/tmp/fula-test-results/fula-system-test-report.txt`

## Testing Environment Requirements

### Recommended Platform
**🎯 Primary: Armbian/Rockchip3588**
- Full validation of all features
- Hardware-specific testing (GPIO, LED control, WiFi management)
- Real system integration testing
- Production-ready validation

**✅ Alternative: Any Linux System (Ubuntu, Debian, etc.)**
- Most tests will pass and provide valuable validation
- Docker services testing works fully
- Configuration validation works completely
- System integration tests use mocks for hardware-specific features

**⚠️ Limited: Windows System**
- Basic syntax validation only
- Docker Compose validation may work but with different behavior
- System integration tests will fail due to Linux-specific commands
- **Not recommended** for production validation

### What Works on Each Platform

| Test Suite | Armbian/RK3588 | Linux | Windows |
|------------|----------------|-------|----------|
| Config Validation | ✅ Full | ✅ Full | ⚠️ Limited |
| Docker Setup | ✅ Full | ✅ Full | ⚠️ Different |
| Container Dependencies | ✅ Full | ✅ Full | ⚠️ Different |
| Fula.sh Functions | ✅ Full | ✅ Mocked | ❌ Fails |
| Docker Services | ✅ Full | ✅ Full | ⚠️ Different |
| Uniondrive/Readiness | ✅ Full | ✅ Mocked | ❌ Fails |
| System Integration | ✅ Full | ✅ Mocked | ❌ Fails |

## Prerequisites

Required tools:
- `bash` (Linux shell)
- `docker`
- `python3`

Optional tools (some tests may show warnings if missing):
- `docker-compose`
- `systemctl` (Linux service management)
- `nmcli` (NetworkManager CLI)

## Post-Sugarfunge-Node Removal

These tests specifically validate that:
1. No critical dependencies on sugarfunge-node remain
2. All Linux services continue to function properly
3. Docker containers start and operate correctly
4. System integration features work as expected
5. Configuration files are clean of node references

The test suite ensures the Fula-OTA system is ready for deployment on Armbian/Rockchip3588 after the complete removal of sugarfunge-node components.


## Full test 
Usage on device

### Full test (build + deploy + verify):

Remove Locks from hosts if any:

```
sudo sed -i '/hardening-test-pull-guard/d' /etc/hosts
```

```
  sudo bash ./tests/test-device-hardening.sh

  sudo bash ./tests/test-device-hardening.sh --reboot-prep
```

### After reboot (Step 12), verify everything survived:

```
  sudo bash ./tests/test-device-hardening.sh --verify
```

### tet OTA

```
sudo bash ./tests/test-device-hardening.sh --build --ota-sim --verify
```

### If something breaks or you want to restore normal operation:

```
  sudo bash ./tests/test-device-hardening.sh --finish
```

The script is also registered in test-fula-system-complete.sh as a test suite.

---

## Python unit tests — readiness-check discovery integration

In addition to the shell integration tests above, this directory also holds Python pytest unit tests for the Cloudflare-Workers discovery-API integration that lives inside `readiness-check.py`.

### Setup

```bash
cd E:\GitHub\fula-ota
python -m venv .venv
source .venv/bin/activate    # or .venv\Scripts\Activate.ps1 on Windows
pip install -r tests/requirements-test.txt
```

### Run

```bash
pytest tests/test_canonical_json.py tests/test_kubo_key_loader.py tests/test_relay_drift.py -v
```

### What's covered

- **`test_canonical_json.py`** — the Python `_canonical_json` in `readiness-check.py` produces byte-identical output to the TypeScript `canonicalJSON` in `cloudflare/src/verify.ts`. Cross-language gate; if it fails, every heartbeat signature mismatches.

- **`test_kubo_key_loader.py`** — `_load_kubo_ed25519_key` parses a synthetic kubo config with a real libp2p-wrapped ed25519 PrivKey and produces an `Ed25519PrivateKey` whose public key matches the claimed peer ID. Also tests missing-file and malformed-wire-format failure paths.

- **`test_relay_drift.py`** — `maybe_refresh_relays` correctly: skips kubo restart when Workers' list matches on-disk, triggers `docker restart ipfs_host` when they differ, silently no-ops when Workers is unreachable, rate-limits within `RELAY_DRIFT_CHECK_INTERVAL_SEC`.
