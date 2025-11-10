#!/bin/bash
#
# Fula OTA Ubuntu Installation Script
# Production-ready installer for Ubuntu systems
#
# Usage: sudo bash fula-ubuntu-installer.sh
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INSTALLATION_DIR="/home/pi"
FULA_PATH="/usr/bin/fula"
LOG_FILE="/var/log/fula-installation.log"
REPO_URL="https://github.com/functionland/fula-ota"
REPO_BRANCH="main"

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root (use sudo)${NC}" 
   exit 1
fi

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

# Error handler
error_exit() {
    log_error "$1"
    log_error "Installation failed. Check log file: $LOG_FILE"
    exit 1
}

# Check internet connectivity
check_internet() {
    log "Checking internet connectivity..."
    if wget -q --spider --timeout=10 https://github.com 2>/dev/null; then
        log "Internet connection verified"
        return 0
    else
        log_warning "No internet connection detected"
        return 1
    fi
}

# Detect architecture
detect_architecture() {
    log "Detecting system architecture..."
    
    if [ -d /sys/module/rockchipdrm ]; then
        ARCH="RK1"
        log "Detected: RK1/RK3588 architecture"
    else
        # Check if it's ARM-based (Raspberry Pi or similar)
        local machine_type=$(uname -m)
        case "$machine_type" in
            aarch64|armv7l|armv8l)
                ARCH="RPI4"
                log "Detected: ARM architecture (assuming RPI4 compatible)"
                ;;
            x86_64)
                log_warning "Detected x86_64 architecture - fula-ota is designed for ARM systems"
                log_warning "Installation will continue with RPI4 mode, but may not work correctly"
                ARCH="RPI4"
                ;;
            *)
                error_exit "Unsupported architecture: $machine_type"
                ;;
        esac
    fi
    
    export ARCH
}

# Check Ubuntu version
check_ubuntu_version() {
    log "Checking Ubuntu version..."
    
    if [ ! -f /etc/os-release ]; then
        error_exit "Cannot determine OS version - /etc/os-release not found"
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]]; then
        log_warning "This script is designed for Ubuntu, detected: $ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log "OS: $NAME $VERSION"
    
    # Check if version is supported (jammy/22.04 or newer recommended)
    case "$VERSION_CODENAME" in
        jammy|lunar|mantic|noble)
            log "Ubuntu version is supported"
            ;;
        focal|bionic)
            log_warning "Ubuntu $VERSION_CODENAME is older, some packages may need manual intervention"
            ;;
        *)
            log_warning "Ubuntu version $VERSION_CODENAME compatibility unknown"
            ;;
    esac
}

# Check system resources
check_system_resources() {
    log "Checking system resources..."
    
    # Check RAM (minimum 2GB recommended)
    local total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt 2048 ]; then
        log_warning "Low RAM detected: ${total_ram}MB (minimum 2GB recommended)"
    else
        log "RAM: ${total_ram}MB - OK"
    fi
    
    # Check disk space (minimum 10GB free recommended)
    local free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$free_space" -lt 10 ]; then
        log_warning "Low disk space: ${free_space}GB free (minimum 10GB recommended)"
    else
        log "Disk space: ${free_space}GB free - OK"
    fi
}

# Create required users
create_users() {
    log "Creating required users..."
    
    # Create pi user if it doesn't exist
    if ! id "pi" &>/dev/null; then
        log "Creating 'pi' user..."
        useradd -m -s /bin/bash pi || error_exit "Failed to create pi user"
        echo "pi:fxblox" | chpasswd || error_exit "Failed to set pi user password"
        log "User 'pi' created successfully"
    else
        log "User 'pi' already exists"
    fi
    
    # Add pi user to necessary groups
    usermod -aG sudo,docker pi 2>/dev/null || log_warning "Could not add pi to all groups (docker group may not exist yet)"
}

# Install system dependencies
install_dependencies() {
    log "Installing system dependencies..."
    
    # Update package lists
    log "Updating package lists..."
    apt-get update || error_exit "Failed to update package lists"
    
    # Install basic dependencies
    log "Installing basic packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        wget \
        git \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https || error_exit "Failed to install basic packages"
    
    # Install Python and related packages
    log "Installing Python packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 \
        python3-pip \
        python3-dbus \
        python3-pexpect \
        python3-requests \
        python3-psutil || error_exit "Failed to install Python packages"
    
    # Install system utilities
    log "Installing system utilities..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mergerfs \
        inotify-tools \
        logrotate || error_exit "Failed to install system utilities"
    
    log "System dependencies installed successfully"
}

# Install Docker
install_docker() {
    log "Installing Docker..."
    
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        log "Docker is already installed: $(docker --version)"
        return 0
    fi
    
    # Remove old Docker packages
    log "Removing old Docker packages if present..."
    apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true
    
    # Add Docker's official GPG key
    log "Adding Docker GPG key..."
    install -m 0755 -d /etc/apt/keyrings || error_exit "Failed to create keyrings directory"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || error_exit "Failed to download Docker GPG key"
    chmod a+r /etc/apt/keyrings/docker.asc || error_exit "Failed to set permissions on Docker GPG key"
    
    # Add Docker repository
    log "Adding Docker repository..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null || error_exit "Failed to add Docker repository"
    
    # Update package lists
    apt-get update || error_exit "Failed to update package lists after adding Docker repo"
    
    # Install Docker
    log "Installing Docker packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin || error_exit "Failed to install Docker packages"
    
    # Install Docker Compose standalone
    log "Installing Docker Compose standalone..."
    curl -SL https://github.com/docker/compose/releases/download/v2.29.6/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose || error_exit "Failed to download Docker Compose"
    chmod +x /usr/local/bin/docker-compose || error_exit "Failed to make Docker Compose executable"
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    
    # Start and enable Docker
    systemctl enable docker || error_exit "Failed to enable Docker service"
    systemctl start docker || error_exit "Failed to start Docker service"
    
    # Add pi user to docker group
    usermod -aG docker pi || log_warning "Failed to add pi user to docker group"
    
    log "Docker installed successfully: $(docker --version)"
}

# Clone fula-ota repository
clone_repository() {
    log "Cloning fula-ota repository..."
    
    # Remove existing directory if present
    if [ -d "$INSTALLATION_DIR/fula-ota" ]; then
        log_warning "Existing fula-ota directory found, backing up..."
        mv "$INSTALLATION_DIR/fula-ota" "$INSTALLATION_DIR/fula-ota.backup.$(date +%s)" || log_warning "Failed to backup existing directory"
    fi
    
    # Clone repository
    if ! check_internet; then
        error_exit "Internet connection required to clone repository"
    fi
    
    git clone --depth=1 -b "$REPO_BRANCH" "$REPO_URL" "$INSTALLATION_DIR/fula-ota" || error_exit "Failed to clone repository"
    
    log "Repository cloned successfully"
}

# Verify installation prerequisites
verify_prerequisites() {
    log "Verifying installation prerequisites..."
    
    local missing_deps=()
    
    # Check for required commands
    local required_commands=("python3" "docker" "docker-compose" "mergerfs" "inotifywait" "git")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Check for required Python modules
    local required_modules=("dbus" "pexpect" "requests" "psutil")
    for module in "${required_modules[@]}"; do
        if ! python3 -c "import $module" 2>/dev/null; then
            missing_deps+=("python3-$module")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    log "All prerequisites verified"
    return 0
}

# Run fula.sh installation
run_fula_installation() {
    log "Running fula.sh installation..."
    
    local fula_script="$INSTALLATION_DIR/fula-ota/docker/fxsupport/linux/fula.sh"
    
    if [ ! -f "$fula_script" ]; then
        error_exit "fula.sh not found at: $fula_script"
    fi
    
    # Make script executable
    chmod +x "$fula_script" || error_exit "Failed to make fula.sh executable"
    
    # Run installation
    log "Executing: bash $fula_script install $ARCH"
    if ! bash "$fula_script" install "$ARCH" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "fula.sh installation failed"
    fi
    
    log "fula.sh installation completed"
}

# Setup automount
setup_automount() {
    log "Setting up automount..."
    
    local automount_script="$INSTALLATION_DIR/fula-ota/docker/fxsupport/linux/automount.sh"
    local automount_rules="$INSTALLATION_DIR/fula-ota/docker/fxsupport/linux/99-automount.rules"
    local automount_service="$INSTALLATION_DIR/fula-ota/docker/fxsupport/linux/automount@.service"
    
    # Copy automount script
    if [ -f "$automount_script" ]; then
        cp "$automount_script" /usr/local/bin/automount.sh || log_warning "Failed to copy automount.sh"
        chmod +x /usr/local/bin/automount.sh || log_warning "Failed to make automount.sh executable"
    fi
    
    # Copy udev rules
    if [ -f "$automount_rules" ]; then
        cp "$automount_rules" /etc/udev/rules.d/99-automount.rules || log_warning "Failed to copy automount rules"
        udevadm control --reload-rules 2>/dev/null || true
    fi
    
    # Copy systemd service
    if [ -f "$automount_service" ]; then
        cp "$automount_service" /etc/systemd/system/automount@.service || log_warning "Failed to copy automount service"
        systemctl daemon-reload || log_warning "Failed to reload systemd"
    fi
    
    log "Automount setup completed"
}

# Create version marker
create_version_marker() {
    log "Creating version marker..."
    
    # Mark installation as completed
    touch "$INSTALLATION_DIR/V6.info" || log_warning "Failed to create version marker"
    
    log "Version marker created"
}

# Final verification
final_verification() {
    log "Performing final verification..."
    
    # Check if services are enabled
    local services=("uniondrive.service" "fula.service" "commands.service" "fula-readiness-check.service")
    local failed_services=()
    
    for service in "${services[@]}"; do
        if ! systemctl is-enabled "$service" &>/dev/null; then
            failed_services+=("$service")
        fi
    done
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        log_warning "Some services are not enabled: ${failed_services[*]}"
    else
        log "All services are enabled"
    fi
    
    # Check if Docker is running
    if ! systemctl is-active docker &>/dev/null; then
        log_warning "Docker service is not running"
    else
        log "Docker service is running"
    fi
    
    log "Final verification completed"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}  Fula OTA Installation Complete!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    log "Installation summary:"
    log "  Architecture: $ARCH"
    log "  Installation directory: $INSTALLATION_DIR/fula-ota"
    log "  Fula path: $FULA_PATH"
    log "  Log file: $LOG_FILE"
    echo ""
    log "Next steps:"
    log "  1. Reboot the system to complete setup"
    log "  2. Check service status: systemctl status fula.service"
    log "  3. View logs: journalctl -u fula.service -f"
    echo ""
    log "To start services manually:"
    log "  sudo systemctl start uniondrive.service"
    log "  sudo systemctl start fula.service"
    echo ""
    read -p "Reboot now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Rebooting system..."
        reboot
    fi
}

# Main installation flow
main() {
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}  Fula OTA Ubuntu Installer${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    
    # Create log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    log "Starting Fula OTA installation..."
    log "Log file: $LOG_FILE"
    
    # Run installation steps
    check_ubuntu_version
    detect_architecture
    check_system_resources
    
    if ! check_internet; then
        error_exit "Internet connection is required for installation"
    fi
    
    create_users
    install_dependencies
    install_docker
    clone_repository
    
    if ! verify_prerequisites; then
        error_exit "Prerequisites verification failed"
    fi
    
    run_fula_installation
    setup_automount
    create_version_marker
    final_verification
    
    log "Installation completed successfully!"
    print_summary
}

# Run main function
main "$@"
