#!/bin/bash
set -euo pipefail

# Downloads the RU IPv4 CIDR list, persists it as an nftables fragment
# (/var/lib/pbr/ru_ips.nft) included by /etc/nftables.conf, and applies it live.
# The persisted fragment makes the set survive any `systemctl restart nftables`.

URLS="
https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt
https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone
"
STATE_DIR=/var/lib/pbr
STATE_FILE="$STATE_DIR/ru_ips.nft"
TMP=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$TMP" "$OUT"' EXIT

if ! nft list table inet pbr_fw >/dev/null 2>&1; then
    echo "ERROR: table inet pbr_fw is not loaded (start nftables.service first)" >&2
    exit 1
fi

COUNT=0
for URL in $URLS; do
    echo "Downloading RU CIDR list: $URL"
    if curl -fsSL --max-time 90 "$URL" -o "$TMP"; then
        COUNT=$(grep -cE '^[0-9]' "$TMP" || true)
        if [ "$COUNT" -gt 0 ]; then
            break
        fi
    fi
    echo "WARN: source failed or empty, trying next" >&2
done

if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: no usable RU list downloaded, keeping existing set" >&2
    exit 1
fi

{
    echo "flush set inet pbr_fw ru_ips"
    printf 'add element inet pbr_fw ru_ips { '
    grep -E '^[0-9]' "$TMP" | tr -d ' \r' | paste -sd, -
    echo ' }'
} > "$OUT"

mkdir -p "$STATE_DIR"
install -m 0644 "$OUT" "$STATE_FILE.tmp"
mv -f "$STATE_FILE.tmp" "$STATE_FILE"
nft -f "$STATE_FILE"
echo "ru_ips updated: $COUNT CIDRs (persisted to $STATE_FILE)"
