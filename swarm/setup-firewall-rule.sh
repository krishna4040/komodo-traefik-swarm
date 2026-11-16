#!/usr/bin/env bash
set -euo pipefail

# Docker Swarm Firewall Configuration
# Usage:
# sudo ./swarm-firewall.sh --role manager --manager-ip IP --worker-ip IP ...
# sudo ./swarm-firewall.sh --role worker --manager-ip IP --worker-ip IP ...

ROLE=""
MANAGER_IP=""
WORKER_IPS=()

# Docker Swarm ports
MANAGEMENT_PORT=2377
COMMUNICATION_PORT=7946
OVERLAY_PORT=4789

# ------------------------------------------
# Parse arguments
# ------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            ROLE="${2:?Missing role}"
            shift 2
            ;;
        --manager-ip)
            MANAGER_IP="${2:?Missing manager IP}"
            shift 2
            ;;
        --worker-ip)
            WORKER_IPS+=("${2:?Missing worker IP}")
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --role manager|worker --manager-ip IP --worker-ip IP ..."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ------------------------------------------
# Validation
# ------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo."
    exit 1
fi

if [[ "$ROLE" != "manager" && "$ROLE" != "worker" ]]; then
    echo "ERROR: --role must be manager or worker"
    exit 1
fi

if [[ -z "$MANAGER_IP" ]]; then
    echo "ERROR: --manager-ip is required"
    exit 1
fi

# Validate IPv4
validate_ip() {
    local ip="$1"
    local IFS=.
    local -a octets

    read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

validate_ip "$MANAGER_IP" || {
    echo "Invalid manager IP: $MANAGER_IP"
    exit 1
}

for ip in "${WORKER_IPS[@]}"; do
    validate_ip "$ip" || {
        echo "Invalid worker IP: $ip"
        exit 1
    }
done

# ------------------------------------------
# Add firewall rule without duplicates
# ------------------------------------------

allow_rule() {
    local ip="$1"
    local protocol="$2"
    local port="$3"

    if ! iptables -C INPUT \
        -s "$ip" -p "$protocol" --dport "$port" \
        -j ACCEPT 2>/dev/null; then

        iptables -I INPUT 1 \
            -s "$ip" -p "$protocol" --dport "$port" \
            -j ACCEPT

        echo "ADDED: $ip -> $protocol/$port"
    else
        echo "EXISTS: $ip -> $protocol/$port"
    fi
}

allow_node_communication() {
    local ip="$1"

    allow_rule "$ip" tcp "$COMMUNICATION_PORT"
    allow_rule "$ip" udp "$COMMUNICATION_PORT"
    allow_rule "$ip" udp "$OVERLAY_PORT"
}

# ------------------------------------------
# Configure manager
# ------------------------------------------

if [[ "$ROLE" == "manager" ]]; then

    if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
        echo "ERROR: Provide at least one --worker-ip"
        exit 1
    fi

    echo "Configuring MANAGER firewall..."

    for ip in "${WORKER_IPS[@]}"; do

        # Worker -> Manager: management
        allow_rule "$ip" tcp "$MANAGEMENT_PORT"

        # Worker <-> Manager: node and overlay communication
        allow_node_communication "$ip"
    done
fi

# ------------------------------------------
# Configure worker
# ------------------------------------------

if [[ "$ROLE" == "worker" ]]; then

    echo "Configuring WORKER firewall..."

    # Manager <-> Worker
    allow_node_communication "$MANAGER_IP"

    # Other workers <-> This worker
    for ip in "${WORKER_IPS[@]}"; do
        allow_node_communication "$ip"
    done
fi

echo
echo "Firewall configuration completed."
iptables -L INPUT -n -v --line-numbers
