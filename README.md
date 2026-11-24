# homelab-security

A small blue-team kit for an Arch + Hyprland laptop running the
[serpantinum](https://github.com/ilyamiro) Quickshell desktop:

- **Rogue-AP detector** — a service that puts a USB Wi-Fi adapter into monitor
  mode and watches for evil twins, BSSID spoofing, deauth/disassoc attacks and
  karma/MANA access points aimed at *your* network.
- **Lab Security bar pill + panel** — a serpantinum bar module that shows the
  overall state (Secure / Check / Alert) and opens a dropdown with Wi-Fi,
  detector status, lab VMs, listening ports, ufw and recent alerts.
- **`homelab-status`** — one JSON snapshot that both of the above (and anything
  else, e.g. an MCP server) read.

```
             ┌──────────────── alerts.jsonl ◄──── detector.py (monitor mode, tshark)
             │                 detector.json ◄───┘
homelab-status ──► JSON ──► bar pill / panel (serpantinum QML)
             │
             └─ nmcli scan · VirtualBox + QEMU VMs · ss · ufw
```

## Detector

`detector/detector.py` — stdlib Python + `tshark`, no other dependencies.

| Rule | Fires when | Severity |
|---|---|---|
| evil_twin | a protected SSID is broadcast by a BSSID that isn't one of your router's | high |
| bssid_spoof | your router's BSSID advertised with different security (e.g. open) | high |
| deauth | ≥10 deauth/disassoc frames in 10 s at your router or its clients | high |
| karma | one BSSID answers probes for ≥5 different SSIDs in 60 s | high |
| channel_change | your router's BSSID advertises an unexpected channel | medium |
| deauth_other | ≥60 deauth frames in 10 s against someone else's network | medium |

- **Monitor mode** on the adapter named `wlalfa` (configurable), hopping 2.4 GHz
  1–11 and 5 GHz 36–48 / 149–165, with longer dwell on your router's channels.
  Uses the AP's advertised channel (`wlan.ds.current_channel`), since some
  drivers' radiotap channel is unreliable.
- **Fallback** when the adapter is unplugged: runs the evil-twin rules on
  NetworkManager scan results (deauth can't be seen in managed mode).
- **Learning** (`detector.py --learn`) trusts only BSSIDs from NetworkManager's
  scan that match the AP you're connected to (same first 4 MAC octets, same
  security) — never from the air, so a running twin can't whitelist itself.
  With no protected SSIDs configured, it protects the network you're connected to.
- Alerts → `~/.local/state/homelab/alerts.jsonl` (`{ts, severity, msg, source, kind, …}`),
  10-minute de-dup per (kind, BSSID); high severity also sends a critical
  `notify-send` notification (bypasses Do Not Disturb).
- Config `~/.config/rogue-ap-detector/config.json` is created on first run and
  live-reloaded on change.
- tshark is restarted every 30 min (`tshark_recycle`) so memory stays flat on an always-on service; detection state is kept across restarts.
- `detector.py --selftest` runs synthetic frames through the parser + rules.

### Service

```bash
sudo bash ~/.local/share/rogue-ap-detector/install.sh
```

Runs as **your user** (must be in the `wireshark` group for capture), with only
`CAP_NET_ADMIN`/`CAP_NET_RAW` granted by systemd for monitor mode and channel
hopping. On stop it returns the adapter to managed mode.

### Keep NetworkManager off the sensor adapter

Give the adapter a fixed name and tell NetworkManager to ignore it, so plugging
it in never steals your uplink (replace the MAC with your adapter's):

```ini
# /etc/systemd/network/10-alfa.link
[Match]
PermanentMACAddress=xx:xx:xx:xx:xx:xx
[Link]
Name=wlalfa
```
```ini
# /etc/NetworkManager/conf.d/10-unmanage-alfa.conf
[keyfile]
unmanaged-devices=interface-name:wlalfa
```

## serpantinum pill + panel

serpantinum hardcodes its widget, bar-module and popup registries, so
`bin/homelab-widget-install` copies the QML into its tree and injects a
`"security"` entry into `WidgetRegistry.qml`, `BarModuleRegistry.qml` and
`WindowRegistry.js`. It's idempotent; run it again after every serpantinum
update, or watch those three files with a systemd `--user` path unit that runs it.

The pill polls `homelab-status` every 10 s; the panel every 3 s while open and
has a Rescan button. A desktop-widget variant (`SecurityFace.qml`) is also
registered and can be added from the widget picker.

## Install

```bash
./install.sh            # user-level files + serpantinum QML
```

Then add `"security"` to `bar.modules` and install the detector service (above).

## Requirements

Arch/Hyprland, serpantinum 2.5.x, NetworkManager, `tshark` (wireshark-cli), `iw`,
a monitor-mode-capable USB Wi-Fi adapter (tested: RTL8812AU, `rtw_8812au`),
Python 3.12+.

## Scope

For defending networks you own or administer. The detector is passive — it
never transmits.
