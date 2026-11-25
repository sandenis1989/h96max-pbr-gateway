#!/bin/bash
set -euo pipefail

# Installs Tailscale (if missing), enables tailscaled and makes this node an
# exit node. Authentication is manual unless TAILSCALE_AUTHKEY is set.

if ! command -v tailscale >/dev/null 2>&1; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if tailscale status 2>/dev/null | grep -q 'Logged out'; then
    echo "Tailscale is installed but NOT authenticated."
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        echo "Authenticating via TAILSCALE_AUTHKEY..."
        TS_AUTHKEY="$TAILSCALE_AUTHKEY" tailscale up --advertise-exit-node --accept-dns=false
    else
        echo "Run manually: tailscale up --advertise-exit-node --accept-dns=false"
        exit 0
    fi
fi

tailscale set --advertise-exit-node --accept-dns=false 2>/dev/null || true
tailscale status | head -5
