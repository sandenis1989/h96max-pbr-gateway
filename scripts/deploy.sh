#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and configure it."
    exit 1
fi

source "$ENV_FILE"

TARGET="${TARGET_HOST:-root@192.168.0.102}"

echo "=== Deploying PBR Gateway to $TARGET ==="

# 1. Enable IP Forwarding on target (persistent via sysctl.d)
ssh "$TARGET" "printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-ipforward.conf && sysctl --system >/dev/null"

# 2. Remote directories creation
ssh "$TARGET" "mkdir -p /etc/hysteria /etc/dnsmasq.d /etc/nftables /etc/hostapd /etc/NetworkManager/conf.d /usr/local/bin /var/log/hysteria"

# 3. Process hostapd config
sed "s/PBR-Gateway-WiFi/${WLAN_SSID}/g; s/ChangeMeSecurePassword123!/${WLAN_PASSPHRASE}/g" \
    "${SCRIPT_DIR}/config/hostapd.conf.template" > "${SCRIPT_DIR}/config/hostapd.conf"

# 4. Process hysteria config
sed "s|\${HYSTERIA_SERVER}|${HYSTERIA_SERVER}|g; \
     s|\${HYSTERIA_AUTH_SECRET}|${HYSTERIA_AUTH_SECRET}|g; \
     s|\${HYSTERIA_SNI}|${HYSTERIA_SNI}|g" \
    "${SCRIPT_DIR}/config/hysteria.yaml.template" > "${SCRIPT_DIR}/config/hysteria.yaml"

# 5. Upload configuration files
echo "Uploading configs..."
scp "${SCRIPT_DIR}/config/hostapd.conf" "$TARGET:/etc/hostapd/hostapd.conf"
scp "${SCRIPT_DIR}/config/dnsmasq.conf" "$TARGET:/etc/dnsmasq.conf"
scp "${SCRIPT_DIR}/config/zapret-domains.conf" "$TARGET:/etc/dnsmasq.d/zapret-domains.conf"
scp "${SCRIPT_DIR}/config/hysteria.yaml" "$TARGET:/etc/hysteria/config.yaml"
scp "${SCRIPT_DIR}/config/nftables.conf" "$TARGET:/etc/nftables.conf"
scp "${SCRIPT_DIR}/config/NetworkManager-99-unmanaged-wlan0.conf" "$TARGET:/etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf"

# 6. Upload systemd units & scripts
echo "Uploading systemd units & helper scripts..."
scp "${SCRIPT_DIR}/systemd/"*.service "$TARGET:/etc/systemd/system/"
scp "${SCRIPT_DIR}/scripts/update-lists.sh" "$TARGET:/usr/local/bin/update-lists.sh"
scp "${SCRIPT_DIR}/scripts/apply-zapret-config.sh" "$TARGET:/usr/local/bin/apply-zapret-config.sh"
scp "${SCRIPT_DIR}/scripts/install-hysteria.sh" "$TARGET:/usr/local/bin/install-hysteria.sh"
ssh "$TARGET" "chmod +x /usr/local/bin/update-lists.sh /usr/local/bin/apply-zapret-config.sh /usr/local/bin/install-hysteria.sh"

# 7. Zapret: nfqws only (qnum 200), firewall ruled by our nftables
echo "Configuring zapret (nfqws only)..."
ssh "$TARGET" "/usr/local/bin/apply-zapret-config.sh && systemctl daemon-reload && systemctl enable --now zapret.service"

# 8. Hysteria 2 binary
echo "Installing Hysteria 2..."
ssh "$TARGET" "/usr/local/bin/install-hysteria.sh"

echo "=== Deployment complete ==="
