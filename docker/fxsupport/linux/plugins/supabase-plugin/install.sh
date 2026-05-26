#!/bin/bash

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="/opt/supabase"
LOG_FILE="/var/log/supabase-install.log"
RETRY_COUNT=3
RETRY_DELAY=5

# Initialize logging
init_logging() {
    mkdir -p $(dirname $LOG_FILE)
    touch $LOG_FILE
    exec 2> >(tee -a $LOG_FILE >&2)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Supabase installation" | tee -a $LOG_FILE
}

# Print colored messages
print_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a $LOG_FILE; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a $LOG_FILE; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a $LOG_FILE; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE; }

# Detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        OS_LIKE=$ID_LIKE
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$(echo $DISTRIB_ID | tr '[:upper:]' '[:lower:]')
        VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        OS=debian
        VER=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        OS=rhel
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    
    # Normalize OS names
    case $OS in
        ubuntu|debian|raspbian) DISTRO_FAMILY="debian" ;;
        rhel|centos|fedora|rocky|almalinux|"red hat"*) DISTRO_FAMILY="rhel" ;;
        alpine) DISTRO_FAMILY="alpine" ;;
        arch|manjaro) DISTRO_FAMILY="arch" ;;
        opensuse*|suse*) DISTRO_FAMILY="suse" ;;
        *) DISTRO_FAMILY="unknown" ;;
    esac
    
    print_info "Detected OS: $OS (Family: $DISTRO_FAMILY)"
}

# Check if running as root or with sudo
check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then
            print_warning "Not running as root. Will use sudo for privileged operations."
            SUDO="sudo"
        else
            print_error "This script must be run as root or with sudo privileges"
            exit 1
        fi
    else
        SUDO=""
    fi
}

# Retry mechanism for commands
retry_command() {
    local cmd="$1"
    local attempt=1
    
    while [ $attempt -le $RETRY_COUNT ]; do
        if eval "$cmd"; then
            return 0
        else
            print_warning "Command failed (attempt $attempt/$RETRY_COUNT): $cmd"
            if [ $attempt -lt $RETRY_COUNT ]; then
                print_info "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    print_error "Command failed after $RETRY_COUNT attempts: $cmd"
    return 1
}

# Install package based on distribution
install_package() {
    local package=$1
    
    case $DISTRO_FAMILY in
        debian)
            retry_command "$SUDO apt-get update > /dev/null 2>&1"
            retry_command "$SUDO apt-get install -y $package"
            ;;
        rhel)
            retry_command "$SUDO yum install -y $package || $SUDO dnf install -y $package"
            ;;
        alpine)
            retry_command "$SUDO apk add --no-cache $package"
            ;;
        arch)
            retry_command "$SUDO pacman -Sy --noconfirm $package"
            ;;
        suse)
            retry_command "$SUDO zypper install -y $package"
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            return 1
            ;;
    esac
}

# Check and install curl
install_curl() {
    if ! command -v curl &> /dev/null; then
        print_info "Installing curl..."
        install_package "curl" || {
            print_error "Failed to install curl"
            exit 1
        }
        print_success "curl installed successfully"
    else
        print_info "curl is already installed"
    fi
}

# Check and install git
install_git() {
    if ! command -v git &> /dev/null; then
        print_info "Installing git..."
        install_package "git" || {
            print_error "Failed to install git"
            exit 1
        }
        print_success "git installed successfully"
    else
        print_info "git is already installed"
    fi
}

# Check and install other dependencies
install_dependencies() {
    local deps=""
    
    # Check for openssl
    if ! command -v openssl &> /dev/null; then
        deps="$deps openssl"
    fi
    
    # Check for sed
    if ! command -v sed &> /dev/null; then
        deps="$deps sed"
    fi
    
    # Check for awk
    if ! command -v awk &> /dev/null; then
        case $DISTRO_FAMILY in
            debian|rhel|suse) deps="$deps gawk" ;;
            alpine|arch) deps="$deps awk" ;;
        esac
    fi
    
    if [ -n "$deps" ]; then
        print_info "Installing additional dependencies: $deps"
        for dep in $deps; do
            install_package "$dep"
        done
    fi
}

# Check system requirements
check_system() {
    print_info "Checking system requirements..."
    
    # Check OS
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        print_error "This plugin requires Linux OS"
        exit 1
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) DOCKER_ARCH="amd64" ;;
        aarch64|arm64) DOCKER_ARCH="arm64" ;;
        armv7l|armhf) DOCKER_ARCH="armhf" ;;
        *)
            print_warning "Architecture $ARCH may not be fully supported"
            DOCKER_ARCH=$ARCH
            ;;
    esac
    print_info "System architecture: $ARCH (Docker arch: $DOCKER_ARCH)"
    
    # Check available memory
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$((MEM_TOTAL / 1024 / 1024))
    if [ $MEM_TOTAL -lt 2097152 ]; then
        print_warning "System has ${MEM_GB}GB RAM. Minimum 2GB recommended for Supabase."
        read -p "Do you want to continue? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_info "System memory: ${MEM_GB}GB RAM (OK)"
    fi
    
    # Check disk space
    DISK_AVAILABLE=$(df /opt 2>/dev/null | awk 'NR==2 {print $4}' || df / | awk 'NR==2 {print $4}')
    DISK_GB=$((DISK_AVAILABLE / 1024 / 1024))
    if [ $DISK_AVAILABLE -lt 10485760 ]; then
        print_warning "Only ${DISK_GB}GB disk space available. Minimum 10GB recommended."
        read -p "Do you want to continue? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_info "Available disk space: ${DISK_GB}GB (OK)"
    fi
}

# Check if ports are available
check_ports() {
    print_info "Checking port availability..."
    local ports=(8000 8443 5432 3000)
    local used_ports=""
    
    for port in "${ports[@]}"; do
        if command -v ss &> /dev/null; then
            if ss -tuln | grep -q ":$port "; then
                used_ports="$used_ports $port"
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -tuln | grep -q ":$port "; then
                used_ports="$used_ports $port"
            fi
        elif command -v lsof &> /dev/null; then
            if $SUDO lsof -i :$port &> /dev/null; then
                used_ports="$used_ports $port"
            fi
        fi
    done
    
    if [ -n "$used_ports" ]; then
        print_warning "The following ports are already in use:$used_ports"
        print_warning "Supabase may conflict with existing services."
        read -p "Do you want to continue? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_info "All required ports are available"
    fi
}

# Install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        print_info "Docker not found. Installing Docker..."
        
        # Try official Docker installation script
        if ! retry_command "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"; then
            print_error "Failed to download Docker installation script"
            
            # Fallback to package manager
            print_info "Trying to install Docker via package manager..."
            case $DISTRO_FAMILY in
                debian)
                    install_package "docker.io"
                    ;;
                rhel)
                    install_package "docker"
                    ;;
                *)
                    print_error "Please install Docker manually"
                    exit 1
                    ;;
            esac
        else
            # Run Docker installation script
            print_info "Running Docker installation script..."
            $SUDO sh /tmp/get-docker.sh 2>&1 | while IFS= read -r line; do
                # Filter out rootless mode messages
                if [[ ! "$line" =~ "rootless mode" ]] && [[ ! "$line" =~ "dockerd-rootless" ]]; then
                    echo "$line"
                fi
            done
            rm -f /tmp/get-docker.sh
        fi
        
        # Configure Docker user permissions
        if [ -n "${SUDO_USER:-}" ]; then
            $SUDO usermod -aG docker $SUDO_USER 2>/dev/null || true
            print_info "Added $SUDO_USER to docker group"
        elif [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
            $SUDO usermod -aG docker $USER 2>/dev/null || true
            print_info "Added $USER to docker group"
        fi
        
        # Start Docker service
        if command -v systemctl &> /dev/null; then
            $SUDO systemctl enable docker 2>/dev/null || true
            $SUDO systemctl start docker 2>/dev/null || true
        elif command -v service &> /dev/null; then
            $SUDO service docker start 2>/dev/null || true
        fi
        
        # Wait for Docker to start
        sleep 5
        
        # Verify Docker is running
        if ! $SUDO docker info &> /dev/null 2>&1; then
            print_error "Docker installed but not running properly"
            print_info "Trying to fix Docker daemon..."
            
            # Common fixes
            $SUDO mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2"}' | $SUDO tee /etc/docker/daemon.json > /dev/null
            
            if command -v systemctl &> /dev/null; then
                $SUDO systemctl restart docker 2>/dev/null || true
            elif command -v service &> /dev/null; then
                $SUDO service docker restart 2>/dev/null || true
            fi
            
            sleep 5
            
            if ! $SUDO docker info &> /dev/null 2>&1; then
                print_error "Failed to start Docker. Please check logs: journalctl -u docker"
                exit 1
            fi
        fi
        
        print_success "Docker installed successfully"
    else
        print_info "Docker is already installed ($(docker --version 2>/dev/null || echo 'version unknown'))"
        
        # Verify Docker is running
        if ! $SUDO docker info &> /dev/null 2>&1; then
            print_warning "Docker is installed but not running. Starting Docker..."
            if command -v systemctl &> /dev/null; then
                $SUDO systemctl start docker 2>/dev/null || true
            elif command -v service &> /dev/null; then
                $SUDO service docker start 2>/dev/null || true
            fi
            sleep 5
        fi
    fi
    
    # Check Docker Compose
    if ! $SUDO docker compose version &> /dev/null 2>&1; then
        if ! $SUDO docker-compose version &> /dev/null 2>&1; then
            print_info "Installing Docker Compose..."
            
            case $DISTRO_FAMILY in
                debian)
                    install_package "docker-compose-plugin"
                    ;;
                rhel)
                    install_package "docker-compose-plugin"
                    ;;
                alpine)
                    install_package "docker-compose"
                    ;;
                *)
                    # Install standalone docker-compose
                    COMPOSE_VERSION="v2.24.1"
                    retry_command "$SUDO curl -L \"https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose"
                    $SUDO chmod +x /usr/local/bin/docker-compose
                    ;;
            esac
            
            print_success "Docker Compose installed successfully"
        fi
    else
        print_info "Docker Compose is already installed"
    fi
}

# Setup Supabase
setup_supabase() {
    print_info "Setting up Supabase..."
    
    # Create directory with proper permissions
    $SUDO mkdir -p $SUPABASE_DIR
    $SUDO chmod 755 $SUPABASE_DIR
    
    cd $SUPABASE_DIR
    
    # Clone Supabase repository with retry
    if [ ! -d "supabase" ]; then
        print_info "Cloning Supabase repository..."
        if ! retry_command "git clone --depth 1 https://github.com/supabase/supabase 2>&1"; then
            print_error "Failed to clone Supabase repository"
            exit 1
        fi
    fi
    
    # Copy Docker files
    print_info "Copying Docker configuration files..."
    $SUDO cp -rf supabase/docker/* .
    
    # Copy and configure environment variables
    if [ ! -f ".env" ]; then
        $SUDO cp supabase/docker/.env.example .env
        
        print_info "Generating secure passwords..."
        
        # Generate secure passwords
        POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        JWT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
        ANON_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
        SERVICE_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
        
        # Backup original .env
        $SUDO cp .env .env.backup
        
        # Update .env file with generated values
        $SUDO sed -i "s|your-super-secret-jwt-token-with-at-least-32-characters-long|$JWT_SECRET|g" .env
        $SUDO sed -i "s|your-anon-key|$ANON_KEY|g" .env
        $SUDO sed -i "s|your-service-key|$SERVICE_KEY|g" .env
        $SUDO sed -i "s|your-super-secret-and-long-postgres-password|$POSTGRES_PASSWORD|g" .env
        
        # Get public IP with multiple fallback methods
        print_info "Detecting public IP address..."
        PUBLIC_IP=""
        
        # Try multiple services
        for service in "ifconfig.me" "icanhazip.com" "ipinfo.io/ip" "api.ipify.org"; do
            PUBLIC_IP=$(curl -s --max-time 5 $service 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
            if [ -n "$PUBLIC_IP" ]; then
                break
            fi
        done
        
        # Fallback to local IP if public IP not found
        if [ -z "$PUBLIC_IP" ]; then
            print_warning "Could not detect public IP. Using local IP..."
            PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
        fi
        
        if [ -z "$PUBLIC_IP" ]; then
            PUBLIC_IP="localhost"
            print_warning "Could not detect any IP. Using localhost"
        fi
        
        print_info "Configuring Supabase with IP: $PUBLIC_IP"
        
        # Update API URLs to use public IP
        $SUDO sed -i "s|API_EXTERNAL_URL=http://localhost:8000|API_EXTERNAL_URL=http://$PUBLIC_IP:8000|g" .env
        $SUDO sed -i "s|SUPABASE_PUBLIC_URL=http://localhost:8000|SUPABASE_PUBLIC_URL=http://$PUBLIC_IP:8000|g" .env
        
        # Save public IP to .env (make sure it's a valid line)
        echo "" | $SUDO tee -a .env > /dev/null
        echo "# Public IP Configuration" | $SUDO tee -a .env > /dev/null
        echo "PUBLIC_IP=$PUBLIC_IP" | $SUDO tee -a .env > /dev/null
        
        # Save credentials to a separate file for security
        $SUDO tee credentials.txt > /dev/null <<EOF
========================================
Supabase Credentials (KEEP THIS SECURE!)
========================================
Public IP: $PUBLIC_IP
PostgreSQL Password: $POSTGRES_PASSWORD
JWT Secret: $JWT_SECRET
Anon Key: $ANON_KEY
Service Key: $SERVICE_KEY
========================================
EOF
        $SUDO chmod 600 credentials.txt
        
        print_success "Environment configured successfully"
    else
        print_info "Environment file already exists. Skipping configuration."
    fi
    
    # Pull Docker images with retry
    print_info "Pulling Docker images (this may take several minutes)..."
    if ! retry_command "$SUDO docker compose pull 2>&1"; then
        print_warning "Failed to pull some images. They will be downloaded on first start."
    fi
    
    # Clean up
    $SUDO rm -rf supabase
    
    # Set proper permissions
    if [ -n "${SUDO_USER:-}" ]; then
        $SUDO chown -R $SUDO_USER:$SUDO_USER $SUPABASE_DIR 2>/dev/null || true
    elif [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
        $SUDO chown -R $USER:$USER $SUPABASE_DIR 2>/dev/null || true
    fi
    
    print_success "Supabase setup completed"
}

# Configure firewall
configure_firewall() {
    print_info "Configuring firewall..."
    
    # Detect and configure firewall
    if command -v ufw &> /dev/null; then
        print_info "Configuring UFW firewall..."
        $SUDO ufw allow 8000/tcp comment 'Supabase API Gateway'
        $SUDO ufw allow 8443/tcp comment 'Supabase API Gateway HTTPS'
        $SUDO ufw allow 5432/tcp comment 'PostgreSQL'
        $SUDO ufw allow 3000/tcp comment 'Supabase Studio'
        print_success "UFW firewall rules added"
    elif command -v firewall-cmd &> /dev/null; then
        print_info "Configuring firewalld..."
        $SUDO firewall-cmd --permanent --add-port=8000/tcp
        $SUDO firewall-cmd --permanent --add-port=8443/tcp
        $SUDO firewall-cmd --permanent --add-port=5432/tcp
        $SUDO firewall-cmd --permanent --add-port=3000/tcp
        $SUDO firewall-cmd --reload
        print_success "firewalld rules added"
    elif command -v iptables &> /dev/null; then
        print_info "Configuring iptables..."
        $SUDO iptables -A INPUT -p tcp --dport 8000 -j ACCEPT
        $SUDO iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
        $SUDO iptables -A INPUT -p tcp --dport 5432 -j ACCEPT
        $SUDO iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
        
        # Try to save iptables rules
        if command -v iptables-save &> /dev/null; then
            $SUDO iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            $SUDO iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
            print_warning "Could not save iptables rules. Rules may be lost on reboot."
        fi
        print_success "iptables rules added"
    else
        print_warning "No firewall detected. Please manually configure your firewall to allow ports: 8000, 8443, 5432, 3000"
    fi
}

# Create systemd service (optional)
create_systemd_service() {
    if command -v systemctl &> /dev/null; then
        print_info "Creating systemd service for Supabase..."
        
        $SUDO tee /etc/systemd/system/supabase.service > /dev/null <<EOF
[Unit]
Description=Supabase
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$SUPABASE_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
        
        $SUDO systemctl daemon-reload
        $SUDO systemctl enable supabase.service
        print_success "Systemd service created. Supabase will start on boot."
    fi
}

# Post-installation check
post_install_check() {
    print_info "Running post-installation checks..."
    
    # Check if all required files exist
    if [ ! -f "$SUPABASE_DIR/.env" ]; then
        print_error "Environment file not found!"
        return 1
    fi
    
    if [ ! -f "$SUPABASE_DIR/docker-compose.yml" ]; then
        print_error "Docker Compose file not found!"
        return 1
    fi
    
    # Test Docker connectivity
    if ! $SUDO docker info &> /dev/null; then
        print_error "Docker is not running properly!"
        return 1
    fi
    
    print_success "All post-installation checks passed"
    return 0
}

# Cleanup on error
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Installation failed with exit code: $exit_code"
        
        # Stop any running containers
        if [ -d "$SUPABASE_DIR" ]; then
            cd $SUPABASE_DIR 2>/dev/null && $SUDO docker compose down 2>/dev/null || true
        fi
        
        # Remove incomplete installation
        if [ -d "$SUPABASE_DIR" ] && [ ! -f "$SUPABASE_DIR/.env" ]; then
            $SUDO rm -rf $SUPABASE_DIR 2>/dev/null || true
        fi
        
        print_info "Cleanup completed"
    fi
}

# Trap errors and exit
trap cleanup_on_error EXIT

# Main installation
main() {
    echo "==========================================="
    echo "     Supabase Plugin Installation"
    echo "==========================================="
    
    init_logging
    detect_distro
    check_privileges
    check_system
    check_ports
    
    # Install dependencies
    install_curl
    install_git
    install_dependencies
    
    # Install and configure Docker
    install_docker
    
    # Setup Supabase
    setup_supabase
    
    # Configure firewall
    configure_firewall
    
    # Optional: Create systemd service
    create_systemd_service
    
    # Run post-installation checks
    if ! post_install_check; then
        print_error "Post-installation checks failed!"
        exit 1
    fi
    
    # Display success message and next steps
    echo ""
    echo "==========================================="
    print_success "Supabase Plugin installed successfully!"
    echo "==========================================="
    echo ""
    
    # Get credentials for display
    if [ -f "$SUPABASE_DIR/.env" ]; then
        # Extract PUBLIC_IP safely without sourcing
        PUBLIC_IP=$(grep "^PUBLIC_IP=" $SUPABASE_DIR/.env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        
        # Use default if PUBLIC_IP is not found
        if [ -z "$PUBLIC_IP" ]; then
            PUBLIC_IP="localhost"
        fi
        
        echo -e "${GREEN}📋 Quick Start Guide:${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo -e "${BLUE}1. Start Supabase:${NC}"
        echo "   ./start.sh"
        echo ""
        echo -e "${BLUE}2. Access Points:${NC}"
        echo "   • API: http://$PUBLIC_IP:8000"
        echo "   • Database: $PUBLIC_IP:5432"
        echo ""
        echo -e "${BLUE}3. View full credentials:${NC}"
        echo "   cat $SUPABASE_DIR/credentials.txt"
        echo ""
        echo -e "${BLUE}4. Check status:${NC}"
        echo "   ./status.sh"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    
    print_info "Installation log saved to: $LOG_FILE"
    print_info "Credentials saved to: $SUPABASE_DIR/credentials.txt"
    
    if command -v systemctl &> /dev/null; then
        print_info "Supabase service configured to start on boot"
    fi
    
    echo ""
    echo "==========================================="
}

# Run main function
main "$@"