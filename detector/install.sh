#!/usr/bin/env bash
# Install + start the rogue-AP detector as a system service that runs as YOUR user
# (needs the wireshark group for capture; systemd grants only CAP_NET_ADMIN/NET_RAW).
#   sudo bash install.sh            # installs for $SUDO_USER
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U="${SUDO_USER:?run via sudo from your user account}"
H="$(getent passwd "$U" | cut -d: -f6)"
G="$(id -gn "$U")"
ID="$(id -u "$U")"
SRC="$(cd "$(dirname "$0")" && pwd)"
id -nG "$U" | grep -qw wireshark || echo "WARNING: $U is not in the 'wireshark' group (sudo usermod -aG wireshark $U, then re-login)"
sed -e "s|@USER@|$U|g" -e "s|@GROUP@|$G|g" -e "s|@HOME@|$H|g" -e "s|@UID@|$ID|g" \
    "$SRC/rogue-ap-detector.service.in" > /etc/systemd/system/rogue-ap-detector.service
systemctl daemon-reload
systemctl enable --now rogue-ap-detector.service
sleep 4
systemctl --no-pager --lines=8 status rogue-ap-detector.service || true
