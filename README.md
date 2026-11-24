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

## Hardware: you need a second Wi-Fi card

The detector needs a **dedicated Wi-Fi adapter that supports monitor mode**, in
addition to the card you use for internet:

- **Why a second card:** in monitor mode the adapter stops being a normal
  network connection — it listens to every frame on a channel and hops between
  channels. A single card can't stay connected to your network and do that at
  the same time, so your laptop's built-in Wi-Fi keeps the internet and the
  second card is the sensor.
- **Which card:** a USB adapter whose Linux driver supports monitor mode.
  Tested with an ALFA AWUS036ACH (Realtek RTL8812AU, in-kernel `rtw_8812au`,
  2.4 + 5 GHz). Check yours with `iw phy` → "Supported interface modes" must
  list `monitor`. Most built-in laptop cards (e.g. Intel `iwlwifi`) can do
  monitor mode too, but then you'd lose your internet connection while it runs.
- **Without the second card** the detector still runs, in a reduced
  *scan* mode on your normal Wi-Fi: it can spot evil twins from scan results but
  **cannot see deauth attacks or karma probe responses**.
- **Testing deauth detection live** needs a third, injection-capable radio to
  play the attacker (the sensor can't attack and listen at once). Evil-twin
  detection can be tested with just a phone hotspot named like your network.

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

### Known ports

Exposed listening ports other than 22/80 turn the pill to **Check**. List ports you
expect (e.g. AirPlay/UxPlay `7000 7001 7100`) in `~/.config/homelab/known-ports`
(comma/space/newline separated, `#` comments) or `$HOMELAB_KNOWN_PORTS`.

## serpantinum pill + panel

serpantinum hardcodes its widget, bar-module and popup registries, so
`bin/homelab-widget-install` copies the QML into its tree and injects a
`"security"` entry into `WidgetRegistry.qml`, `BarModuleRegistry.qml` and
`WindowRegistry.js`, plus the settings card into `guide/bar/modules/`. It's idempotent; run it again after every serpantinum
update, or watch those three files with a systemd `--user` path unit that runs it.

It also adds a **Lab Security** card to Settings → Bar → Modules with a
Button / Text style (stored as `bar.securityStyle`), like the built-in modules.

The pill polls `homelab-status` every 10 s; the panel every 3 s while open and
has a Rescan button. A desktop-widget variant (`SecurityFace.qml`) is also
registered and can be added from the widget picker.

## Demo mode (screen recordings)

```bash
homelab-demo on    # mask SSIDs + MACs everywhere on screen
homelab-demo off
```

While on (`~/.config/homelab/demo-mode` exists): `homelab-status` (so the pill,
panel and MCP server) shows your network as **Home-WiFi**, other networks as
`WiFi-xxxx`, and MAC addresses as `xx:xx:xx:xx:xx:74`; the detector's
notifications are masked the same way; and serpantinum's Wi-Fi module hides the
network name. `alerts.jsonl` always keeps the real values. Things outside this
kit (terminal output, other apps) still show real names — keep them off-screen.

## Install

```bash
./install.sh            # user-level files + serpantinum QML
```

Then add `"security"` to `bar.modules` and install the detector service (above).

## Requirements

Arch/Hyprland, serpantinum 2.5.x, NetworkManager, `tshark` (wireshark-cli), `iw`,
a **second**, monitor-mode-capable USB Wi-Fi adapter (see Hardware above; tested: RTL8812AU, `rtw_8812au`),
Python 3.12+.

## Scope

For defending networks you own or administer. The detector is passive — it
never transmits.
