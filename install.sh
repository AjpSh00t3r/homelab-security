#!/usr/bin/env bash
# User-level install of the Lab Security pieces (no sudo):
#   ~/.local/bin/homelab-status            shared JSON status backend
#   ~/.local/bin/homelab-widget-install    injects the widget/pill/popup into serpantinum
#   ~/.local/share/homelab-widget/         durable QML sources (survive serpantinum updates)
#   ~/.local/share/rogue-ap-detector/      detector + service template
# Then installs the QML into serpantinum. The detector service needs sudo (see README).
set -euo pipefail
cd "$(dirname "$0")"

install -Dm755 bin/homelab-status          ~/.local/bin/homelab-status
install -Dm755 bin/homelab-widget-install  ~/.local/bin/homelab-widget-install
install -Dm644 serpantinum/SecurityFace.qml          ~/.local/share/homelab-widget/SecurityFace.qml
install -Dm644 serpantinum/bar/SecurityBarFace.qml   ~/.local/share/homelab-widget/bar/SecurityBarFace.qml
install -Dm644 serpantinum/popup/SecurityPopup.qml   ~/.local/share/homelab-widget/popup/SecurityPopup.qml
install -Dm644 serpantinum/settings/BarSecurityCard.qml ~/.local/share/homelab-widget/settings/BarSecurityCard.qml
install -Dm755 detector/detector.py                  ~/.local/share/rogue-ap-detector/detector.py
install -Dm644 detector/rogue-ap-detector.service.in ~/.local/share/rogue-ap-detector/rogue-ap-detector.service.in
install -Dm755 detector/install.sh                   ~/.local/share/rogue-ap-detector/install.sh

~/.local/bin/homelab-widget-install >/dev/null || true
command -v serpantinum >/dev/null && serpantinum reload >/dev/null 2>&1 || true

cat <<'EOF'
Installed. Next steps:
  1. Add the bar pill:   put "security" in bar.modules (e.g. after "wifi") via
                         serpantinum config set bar.modules '<json>'
  2. Detector service:   sudo bash ~/.local/share/rogue-ap-detector/install.sh
  3. Optional VM SSH user for the panel's SSH buttons:
                         echo <user> > ~/.config/homelab/ssh-user
Re-run ~/.local/bin/homelab-widget-install after a serpantinum update
(or hook it into a systemd path unit — see README).
EOF
