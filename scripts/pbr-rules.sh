#!/bin/bash
set -euo pipefail

# Idempotent PBR setup for Hysteria 2 TPROXY:
# fwmark 0x1 -> table 100, table 100 has a local default route.

RULE_MATCH="fwmark 0x1 lookup 100"

if ! ip rule show | grep -qF "$RULE_MATCH"; then
    ip rule add fwmark 0x1 table 100
    echo "added: ip rule fwmark 0x1 table 100"
else
    echo "present: ip rule fwmark 0x1 table 100"
fi

ip route replace local default dev lo table 100
echo "present: ip route local default dev lo table 100"
