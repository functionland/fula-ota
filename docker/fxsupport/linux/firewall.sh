#!/bin/bash

# Check and install iptables-persistent
dpkg -s iptables-persistent >/dev/null 2>&1 || {
    echo >&2 "iptables-persistent not found, installing..."
    sudo apt-get install -y iptables-persistent || {
        echo "Could not install iptables-persistent"
        exit 1
    }
}

# Check and install dnsutils
dpkg -s dnsutils >/dev/null 2>&1 || {
    echo >&2 "dnsutils not found, installing..."
    sudo apt-get install -y dnsutils || {
        echo "Could not install dnsutils"
        exit 1
    }
}

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
    dig +short "$1" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"
}

get_domain_ips6() {
    dig +short AAAA "$1" | grep -oE "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"
}

# Docker Hub resolution with timeout and fallback
resolve_docker_domains() {
    local domain="$1"
    # Set a timeout of 2 seconds for dig
    local ips=$(dig +short +time=2 +tries=1 "$domain" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
    
    # If dig fails, use hardcoded IPs as fallback
    if [ -z "$ips" ]; then
        case "$domain" in
            "index.docker.io")
                ips="54.198.86.24 54.236.113.205 54.227.20.253"
                ;;
            "hub.docker.com")
                ips="34.195.82.38 52.203.198.227 52.55.168.20"
                ;;
        esac
    fi
    echo "$ips"
}

# Clear existing rules and set default policies
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

ip6tables -F
ip6tables -X
ip6tables -t nat -F
ip6tables -t nat -X
ip6tables -t mangle -F
ip6tables -t mangle -X

# Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Port 40001 and 4001 - all traffic
for port in 40001 4001 9096 32200 9094 9095 3500 30335 9945; do
    iptables -A INPUT -p tcp --dport $port -j ACCEPT
    iptables -A OUTPUT -p tcp --dport $port -j ACCEPT
    iptables -A INPUT -p udp --dport $port -j ACCEPT
    iptables -A OUTPUT -p udp --dport $port -j ACCEPT
done

# Allow DNS resolution
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -j ACCEPT


# Port 80, 443, ping - specific IPs
for ip in 8.8.8.8 4.4.4.4 8.8.4.4; do
    iptables -A OUTPUT -p tcp --dport 80 -d $ip -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 443 -d $ip -j ACCEPT
    iptables -A INPUT -s $ip -p icmp -j ACCEPT
	iptables -A OUTPUT -d $ip -p icmp -j ACCEPT
done

# Whitelist specific IPs for all ports
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
    iptables -A INPUT -s $ip -j ACCEPT
    iptables -A OUTPUT -d $ip -j ACCEPT

    # Ping protocol
    iptables -A INPUT -s $ip -p icmp --icmp-type echo-reply -j ACCEPT
    iptables -A OUTPUT -d $ip -p icmp --icmp-type echo-request -j ACCEPT
done


# IPv6 addresses
declare -a IPS6=(
    "2a10:1fc0:c::954a:2386"
    "2a10:1fc0:c::fc0b:1ac3"
    "2a10:1fc0:c::6548:cfcf"
    "2a10:1fc0:c::918c:b2a8"
)

for ip in "${IPS6[@]}"; do
    ip6tables -A INPUT -s $ip -j ACCEPT
    ip6tables -A OUTPUT -d $ip -j ACCEPT
done

# Define local network ranges
declare -a LOCAL_NETS=(
    "192.168.0.0/16"
    "172.16.0.0/12"
    "10.0.0.0/8"
)

# Allow ping and SSH for local networks
for net in "${LOCAL_NETS[@]}"; do
    # Allow incoming pings
    iptables -A INPUT -s $net -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A OUTPUT -d $net -p icmp --icmp-type echo-reply -j ACCEPT
    
    # Allow outgoing pings
    iptables -A OUTPUT -d $net -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A INPUT -s $net -p icmp --icmp-type echo-reply -j ACCEPT

    iptables -A INPUT -p tcp --dport 22 -s $net -j ACCEPT
    iptables -A OUTPUT -p tcp --sport 22 -d $net -j ACCEPT
done


# Docker Hub dynamic IP resolution
for domain in "index.docker.io" "hub.docker.com" "registry-1.docker.io"; do
    echo "Resolving $domain..."
    
    # IPv4 rules
    for ip in $(resolve_docker_domains "$domain"); do
        if [ -n "$ip" ]; then
            iptables -A INPUT -s "$ip" -j ACCEPT
            iptables -A OUTPUT -d "$ip" -j ACCEPT
	    iptables -A INPUT -d $ip -p tcp --dport 443 -j ACCEPT
	    iptables -A OUTPUT -d $ip -p tcp --dport 443 -j ACCEPT
        fi
    done
    
    # Only attempt IPv6 if IPv6 is enabled
    if [ -f /proc/net/if_inet6 ]; then
        for ip in $(dig +short +time=2 +tries=1 AAAA "$domain" | grep -v "^;;"); do
            if [ -n "$ip" ]; then
                ip6tables -A INPUT -s "$ip" -j ACCEPT
                ip6tables -A OUTPUT -d "$ip" -j ACCEPT
            fi
        done
    fi
done

# GitHub dynamic IP resolution
for domain in "github.com" "raw.githubusercontent.com"; do
    for ip in $(get_domain_ips "$domain"); do
        iptables -A INPUT -s $ip -j ACCEPT
        iptables -A OUTPUT -d $ip -j ACCEPT
	iptables -A INPUT -d $ip -p tcp --dport 443 -j ACCEPT
	iptables -A OUTPUT -d $ip -p tcp --dport 443 -j ACCEPT
    done
    for ip in $(get_domain_ips6 "$domain"); do
        ip6tables -A INPUT -s $ip -j ACCEPT
        ip6tables -A OUTPUT -d $ip -j ACCEPT
    done
done

# Allow APT repositories
# Common APT repository domains
apt_domains=(
    "deb.debian.org"
    "security.debian.org"
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "ports.ubuntu.com"
)

for domain in "${apt_domains[@]}"; do
    for ip in $(get_domain_ips "$domain"); do
        iptables -A OUTPUT -p tcp --dport 80 -d $ip -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 443 -d $ip -j ACCEPT
    done
done

# Save rules
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

disable_root_ssh
