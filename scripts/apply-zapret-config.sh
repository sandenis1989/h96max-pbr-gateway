#!/bin/bash
set -euo pipefail

# Runs ON the target host. Makes stock /opt/zapret run nfqws only (qnum 200)
# and leaves all firewall/PBR rules to our nftables config.

CONF=/opt/zapret/config
BACKUP_DIR=/root/pbr-backup
BACKUP="$BACKUP_DIR/zapret-config.bak"

[ -f "$CONF" ] || { echo "ERROR: $CONF not found"; exit 1; }

mkdir -p "$BACKUP_DIR"
[ -f "$BACKUP" ] || cp -a "$CONF" "$BACKUP"

sed -i -E 's/^INIT_APPLY_FW=.*/INIT_APPLY_FW=0/' "$CONF"
grep -q '^INIT_APPLY_FW=' "$CONF" || echo 'INIT_APPLY_FW=0' >> "$CONF"
grep -q '^IFACE_LAN=' "$CONF" || echo 'IFACE_LAN=wlan0' >> "$CONF"
grep -q '^QNUM=' "$CONF" || echo 'QNUM=200' >> "$CONF"

# QUIC (UDP/443) desync. Stock nfqws has TCP-only profiles, so QUIC Initials
# from YouTube video hosts reach the ISP DPI untouched and are silently
# dropped: thumbnails (TCP/443, desynced) load fine while video buffers.
# The fake Initial is consumed by DPI first, the real one then passes.
# Using --dpi-desync-ttl=6 prevents fake packets from reaching remote GGC
# servers (avoiding 8-second QUIC handshake retries).
if ! grep -q 'pbr-gateway: quic desync' "$CONF"; then
    cat >> "$CONF" <<'EOF'

# >>> pbr-gateway: quic desync >>>
# Appended by apply-zapret-config.sh; idempotent.
case "$NFQWS_OPT" in
    *--filter-udp=443*) ;;
    *) NFQWS_OPT="$NFQWS_OPT --new --filter-udp=443 --dpi-desync=fake --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --dpi-desync-ttl=6" ;;
esac
# <<< pbr-gateway: quic desync <<<
EOF
fi

echo "zapret config patched:"
grep -E '^(INIT_APPLY_FW|IFACE_LAN|IFACE_WAN|QNUM|NFQWS_ENABLE|MODE_FILTER|FWTYPE)=' "$CONF"
grep -q 'pbr-gateway: quic desync' "$CONF" && echo 'QUIC_DESYNC=udp/443 (fake Initial)'
