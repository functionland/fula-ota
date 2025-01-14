#!/bin/bash
set -e
set -o pipefail
package_installed=true

install_and_setup_firewalld() {
    # Check if firewalld is already installed
    if ! dpkg -l | grep -q firewalld; then
        # Ensure non-interactive installation
        export DEBIAN_FRONTEND=noninteractive
        
        # Update package list
        apt-get update -qq
        
        # Disable UFW if it exists and is active
        if command -v ufw >/dev/null 2>&1; then
            systemctl disable --now ufw >/dev/null 2>&1
        fi
        
        # Install firewalld
        apt-get install -y firewalld >/dev/null 2>&1
        package_installed=false
    fi
    
    # Check if firewalld is enabled, if not enable it
    if ! systemctl is-enabled --quiet firewalld; then
        systemctl enable firewalld >/dev/null 2>&1
    fi
    
    # Check if firewalld is running, if not start it
    if ! systemctl is-active --quiet firewalld; then
        systemctl start firewalld >/dev/null 2>&1
    fi
    
    # Verify firewalld is running
    if firewall-cmd --state >/dev/null 2>&1; then
        echo "Firewalld is installed, enabled, and running"
        return 0
    else
        echo "Failed to setup firewalld"
        return 1
    fi
}


# Check and install dnsutils
if ! dpkg -l | grep -q "^ii.*dnsutils"; then
    echo >&2 "dnsutils not found, installing..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils; then
        echo "Could not install dnsutils"
        exit 1
    fi
    package_installed=false
fi

if ! ${package_installed}; then
    sudo dpkg --configure -a
fi

disable_root_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.bak"
    
    # Check if file exists
    if [ ! -f "$sshd_config" ]; then
        echo "SSH config file not found at $sshd_config"
        return 1
    fi

    # Create backup
    sudo cp "$sshd_config" "$backup_file"
    
    # Check current setting
    if grep -q "^PermitRootLogin" "$sshd_config"; then
        # Replace existing setting
        sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
        echo "Updated existing PermitRootLogin setting to 'no'"
    else
        # Add setting if it doesn't exist
        echo "PermitRootLogin no" | sudo tee -a "$sshd_config" > /dev/null
        echo "Added PermitRootLogin no to config"
    fi

    # Verify the change
    if grep -q "^PermitRootLogin no" "$sshd_config"; then
        echo "Successfully disabled root SSH login"
        
        # Test configuration
        if sudo sshd -t; then
            echo "SSH configuration test passed"
            # Restart SSH service
            sudo systemctl restart sshd
            echo "SSH service restarted"
            return 0
        else
            echo "SSH configuration test failed, restoring backup"
            sudo cp "$backup_file" "$sshd_config"
            return 1
        fi
    else
        echo "Failed to disable root SSH login"
        return 1
    fi
}

# Function to resolve domain to IPs
get_domain_ips() {
    sudo ufw disable || true
    dig +short "$1" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"
}

get_domain_ips6() {
    sudo ufw disable || true
    dig +short AAAA "$1" | grep -oE "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"
}

# Docker Hub resolution with timeout and fallback
resolve_docker_domains() {
    local domain="$1"
    sudo ufw disable || true
    # Set a timeout of 2 seconds for dig
    local ips
    ips=$(dig +short +time=2 +tries=1 "$domain" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
    
    # If dig fails, use hardcoded IPs as fallback
    if [ -z "$ips" ]; then
        case "$domain" in
            "index.docker.io")
                ips="54.198.86.24 54.236.113.205 54.227.20.253"
                ;;
            "hub.docker.com")
                ips="34.195.82.38 52.203.198.227 52.55.168.20"
                ;;
            "registry-1.docker.io")
                ips="54.236.113.205 54.198.86.24 54.227.20.253"
                ;;
        esac
    fi
    echo "$ips"
}

detect_interfaces() {
    ip -br link show | grep -v '^lo' | grep 'UP' | awk '{print $1}'
}

is_valid_ipv6() {
    local ip="$1"
    dot_count=$(echo "$ip" | tr -cd ':' | wc -c)
    if [ -n "$ip" ] && [ "$dot_count" -gt 2 ]; then
        return 0
    else 
        return 1
    fi
}

systemctl stop iptables
systemctl stop ip6tables
systemctl disable iptables
systemctl disable ip6tables

# Stop and disable ufw if it exists
systemctl stop ufw || true
systemctl disable ufw || true

# Enable and start firewalld
install_and_setup_firewalld

# Check if zone exists before creating it
if ! firewall-cmd --get-zones | grep -q "docker-custom"; then
    firewall-cmd --permanent --new-zone=docker-custom
    firewall-cmd --reload
else
    echo "Zone docker-custom already exists"
fi


# Set default zone
firewall-cmd --set-default-zone=docker-custom
firewall-cmd --runtime-to-permanent


# Allow loopback interface
firewall-cmd --permanent --zone=docker-custom --add-interface=lo

# Add specific ports
echo "Whitelisting needed ports on tcp/udp"
PORTS=(40001 4001 9096 32200 9094 9095 3500 30335 9945 5001)
for port in "${PORTS[@]}"; do
    firewall-cmd --permanent --zone=docker-custom --add-port=${port}/tcp
    firewall-cmd --permanent --zone=docker-custom --add-port=${port}/udp
done

# Add localhost specific ports
echo "Whitelisting needed ports from localhost on tcp"
LOCALHOST_PORTS=(40001 4001 30335 32200 9094 5001)
for port in "${LOCALHOST_PORTS[@]}"; do
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=127.0.0.1 port port=${port} protocol=tcp accept"
done

# Allow DNS resolution
echo "allow dns"
firewall-cmd --permanent --zone=docker-custom --add-service=dns

# Add specific IPs for HTTP/HTTPS
echo "Whitelisting 8.8.8.8"
SPECIFIC_IPS=(8.8.8.8 4.4.4.4 8.8.4.4)
for ip in "${SPECIFIC_IPS[@]}"; do
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 destination address=${ip} port port=80 protocol=tcp accept"
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 destination address=${ip} port port=443 protocol=tcp accept"
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=${ip} protocol value=icmp accept"
done

# Whitelist specific IPs
echo "Whitelisting known IPs"
declare -a IPS=(
    "209.126.1.139"
    "209.145.51.240"
    "95.216.26.170"
    "46.249.38.183"
    "5.252.53.186"
    "217.76.60.60"
    "217.76.51.113"
    "66.94.112.13"
)

for ip in "${IPS[@]}"; do
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=${ip} accept"
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 destination address=${ip} accept"
done

echo "Whitelisting known IP6s"
# IPv6 addresses
if [ -f /proc/net/if_inet6 ]; then
    declare -a IPS6=(
        "2a10:1fc0:c::954a:2386"
        "2a10:1fc0:c::fc0b:1ac3"
        "2a10:1fc0:c::6548:cfcf"
        "2a10:1fc0:c::918c:b2a8"
    )
    
    for ip in "${IPS6[@]}"; do
        firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv6 source address=${ip} accept"
        firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv6 destination address=${ip} accept"
    done
fi

# Local networks
echo "Whitelisting local network"
declare -a LOCAL_NETS=(
    "192.168.0.0/16"
    "172.16.0.0/12"
    "10.0.0.0/8"
)

for net in "${LOCAL_NETS[@]}"; do
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=${net} protocol value=icmp accept"
    firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=${net} service name=ssh accept"
done

# Docker domains resolution function
resolve_docker_domains() {
    dig +short "$1" | grep -v "^;"
}

# Add Docker related domains
echo "Whitelisting known domains"
valid_domains=(
    "index.docker.io" 
    "docker.io"
    "docker.com"
    "hub.docker.com"
    "docs.docker.com"
    "registry-1.docker.io"
    "production.cloudflare.docker.com"
    "download.docker.com"
    "github.com" 
    "raw.githubusercontent.com"
    "deb.debian.org"
    "security.debian.org"
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "ports.ubuntu.com"
    "apt.armbian.com"
    "github.armbian.com"
    "armbian.chi.auroradev.org"
    "armbian.tnahosting.net"
    "mirrors.jevincanders.net"
    "google.com"
    "relay.dev.fx.land"
    "node.functionyard.fx.land"
    "node3.functionyard.fx.land"
    "api.node3.functionyard.fx.land"
)

for domain in "${valid_domains[@]}"; do
    echo "Resolving $domain..."
    for ip in $(resolve_docker_domains "$domain"); do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
            firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 destination address=${ip} port port=80 protocol=tcp accept"
            firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 destination address=${ip} port port=443 protocol=tcp accept"
        fi
    done
done

firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=10.42.0.0/24 accept"
firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=10.42.0.0/24 port port=3500 protocol=tcp accept"

# Docker daemon ports
firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=127.0.0.1 port port=2375 protocol=tcp accept"
firewall-cmd --permanent --zone=docker-custom --add-rich-rule="rule family=ipv4 source address=127.0.0.1 port port=2376 protocol=tcp accept"

# Reload firewall to apply all changes
firewall-cmd --reload


disable_root_ssh

# Check if resolvconf is installed
# Function to check if resolv.conf is valid
check_resolv_conf() {
    if [ ! -f /etc/resolv.conf ] || ! grep -q "^nameserver" /etc/resolv.conf; then
        echo "Invalid or missing resolv.conf, recreating..."
        sudo rm -f /etc/resolv.conf
        sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
        sudo chmod 644 /etc/resolv.conf
    fi

    # Verify DNS resolution works
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "DNS resolution failed, recreating resolv.conf..."
        sudo rm -f /etc/resolv.conf
        sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
        sudo chmod 644 /etc/resolv.conf
    fi
}
check_resolv_conf

if ! dpkg -l | grep -q "^ii.*resolvconf"; then
    # Install and configure resolvconf
    sudo DEBIAN_FRONTEND=noninteractive apt install resolvconf
    sudo systemctl enable resolvconf.service
    sudo systemctl start resolvconf.service
    sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolvconf/resolv.conf.d/head'
    sudo resolvconf -u
else
    echo "resolvconf is already installed"
fi