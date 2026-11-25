#!/bin/bash
set -euo pipefail

# Download Russian IPv4 ranges and generate nftables set format
RU_IPS_FILE="/etc/nftables/ru_ips.nft"

echo "Downloading RU IP list..."
TMP_FILE=$(mktemp)
curl -sSL "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr" > "$TMP_FILE" || {
    echo "Failed to fetch RU CIDR list, keeping existing file."
    rm -f "$TMP_FILE"
    exit 1
}

echo "Generating $RU_IPS_FILE..."
cat <<EOF > "$RU_IPS_FILE"
# Auto-generated RU IP ranges for bypass
table inet pbr_fw {
    set ru_ips {
        type ipv4_addr
        flags interval
        auto-merge
        elements = {
EOF

sed -e 's/#.*//' -e '/^$/d' "$TMP_FILE" | sed 's/$/\,/' >> "$RU_IPS_FILE"

cat <<EOF >> "$RU_IPS_FILE"
        }
    }
}
EOF

rm -f "$TMP_FILE"
echo "RU IP list updated successfully."
nft -f "$RU_IPS_FILE" 2>/dev/null || echo "nft reload required."
