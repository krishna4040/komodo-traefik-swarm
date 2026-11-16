#!/bin/bash
set -e

# Docker VPS Installation Script
# Supports Ubuntu and Debian

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or using sudo."
    exit 1
fi

echo "=================================="
echo "     Docker VPS Installation"
echo "=================================="

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Unsupported Linux distribution."
    exit 1
fi

case "$ID" in
    ubuntu|debian)
        echo "Detected OS: $PRETTY_NAME"
        ;;
    *)
        echo "Unsupported OS: $ID"
        exit 1
        ;;
esac

# Remove conflicting packages
apt-get update
apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true

# Install dependencies
apt-get install -y ca-certificates curl

# Add Docker GPG key
install -m 0755 -d /etc/apt/keyrings

curl -fsSL "https://download.docker.com/linux/$ID/gpg" \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

echo \
"deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $CODENAME stable" \
> /etc/apt/sources.list.d/docker.list

# Install Docker
apt-get update

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Enable Docker
systemctl enable docker
systemctl start docker

# Add original sudo user to docker group
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "Added $SUDO_USER to docker group."
fi

echo ""
echo "=================================="
echo " Docker Installation Successful!"
echo "=================================="

docker --version
docker compose version

echo ""
echo "Run a test container:"
docker run hello-world

echo "Installation completed!"
