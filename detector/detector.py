#!/usr/bin/env python3
"""rogue-ap-detector — watch for evil twins, deauth floods and karma APs.

Modes (chosen automatically, re-checked every 30s):
  monitor  — the ALFA (iface "wlalfa") in monitor mode, channel hopping, frames
             decoded by tshark. Detects: evil twins, deauth/disassoc floods,
             karma/MANA probe responders, BSSID spoofing with wrong security.
  scan     — no ALFA: NetworkManager's wifi scan on the Intel card. Detects
             evil twins only (deauth frames aren't visible in managed mode).

Alerts are appended to ~/.local/state/homelab/alerts.jsonl (shared with the
Lab Security bar pill and the homelab MCP server); high severity also raises a
critical desktop notification. Live status: ~/.local/state/homelab/detector.json.

Usage:
  detector.py              run (the systemd service does this)
  detector.py --learn      (re)learn your router's real BSSIDs from the current scan
  detector.py --selftest   feed synthetic frames through the rules, print alerts
Needs CAP_NET_ADMIN (monitor mode / channel hopping) + capture rights (wireshark group).
"""
from __future__ import annotations

import collections
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HOME = Path.home()
CONF_FILE = HOME / ".config/rogue-ap-detector/config.json"
STATE_DIR = HOME / ".local/state/homelab"
ALERTS_FILE = STATE_DIR / "alerts.jsonl"
STATUS_FILE = STATE_DIR / "detector.json"

DEFAULT_CONF = {
    "iface": "wlalfa",
    "protected_ssids": [],          # empty = protect the network you are connected to (set on first run)
    # ssid -> {bssid: {"chan": int, "security": "WPA2"}}; learned via --learn / first start
    "known": {},
    "channels_24": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    "channels_5": [36, 40, 44, 48, 149, 153, 157, 161, 165],
    "dwell": 0.35,                 # seconds per channel
    "protected_dwell": 1.5,        # extra time on your router's channels
    "deauth_window": 10,           # seconds
    "deauth_threshold": 10,        # frames per window aimed at a protected BSSID / its clients
    "deauth_flood_threshold": 60,  # frames per window, any BSSID (someone else being attacked)
    "karma_window": 60,
    "karma_ssids": 5,              # distinct SSIDs answered by one BSSID = karma/MANA
    "cooldown": 600,               # seconds before repeating the same alert
    "notify": True,
}

SUBTYPE = {0x0008: "beacon", 0x0005: "probe_resp", 0x000c: "deauth", 0x000a: "disassoc"}
FIELDS = ["frame.time_epoch", "wlan.fc.type_subtype", "wlan.bssid", "wlan.ta", "wlan.ra",
          "wlan.ssid", "wlan.ds.current_channel", "wlan_radio.channel", "radiotap.dbm_antsignal",
          "wlan.fixed.capabilities.privacy", "wlan.rsn.akms.type", "wlan.fixed.reason_code"]
BPF = ("type mgt subtype beacon or type mgt subtype probe-resp or "
       "type mgt subtype deauth or type mgt subtype disassoc")

running = True


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def sh(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


# ------------------------------------------------------------------ config
def load_conf() -> dict:
    conf = dict(DEFAULT_CONF)
    if CONF_FILE.exists():
        conf.update(json.loads(CONF_FILE.read_text()))
    else:
        save_conf(conf)
    return conf


def save_conf(conf: dict):
    CONF_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONF_FILE.write_text(json.dumps(conf, indent=2) + "\n")


def split_nm(line):
    return [f.replace("\\:", ":") for f in re.split(r"(?<!\\):", line)]


def nm_scan(rescan=False) -> list[dict]:
    base = ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan"]
    out = sh(base + ["yes" if rescan else "no"], timeout=20).stdout
    if rescan and not out.strip():
        # NM may refuse a rescan from a non-session (system service) caller; use the cache
        out = sh(base + ["no"], timeout=10).stdout
    aps = []
    for line in out.splitlines():
        f = split_nm(line)
        if len(f) >= 6:
            aps.append({"in_use": f[0] == "*", "ssid": f[1], "bssid": f[2].lower(),
                        "chan": int(f[3] or 0), "signal": int(f[4] or 0),
                        "security": norm_sec(f[5])})
    return aps


def norm_sec(s: str) -> str:
    s = (s or "").upper()
    if not s or s in ("--", "OPEN"):
        return "OPEN"
    if "WPA3" in s or "SAE" in s:
        return "WPA3" if "WPA2" not in s else "WPA2/WPA3"
    if "802.1X" in s or "EAP" in s:
        return "ENTERPRISE"
    if "WPA" in s:
        return "WPA2"
    if "WEP" in s:
        return "WEP"
    return s


def oui4(bssid: str) -> str:
    return ":".join(bssid.split(":")[:4])


def learn(conf: dict, rescan=True) -> dict:
    """Learn each protected SSID's real BSSIDs from NetworkManager's scan: the AP
    we're connected to, plus same-SSID BSSIDs from the same router (matching first
    4 MAC octets and the same security). Never learns from the monitor feed, so a
    twin that's already running can't get itself whitelisted."""
    aps = nm_scan(rescan=rescan)
    if not conf["protected_ssids"]:
        cur = next((a for a in aps if a["in_use"] and a["ssid"]), None)
        if cur:
            conf["protected_ssids"] = [cur["ssid"]]
            log(f"learn: no protected networks configured; protecting the connected one ({cur['ssid']})")
    for ssid in conf["protected_ssids"]:
        anchor = next((a for a in aps if a["in_use"] and a["ssid"] == ssid), None)
        known = conf["known"].setdefault(ssid, {})
        if not anchor:
            log(f"learn: not connected to {ssid!r}; keeping {len(known)} known BSSIDs")
            continue
        for a in aps:
            if a["ssid"] == ssid and oui4(a["bssid"]) == oui4(anchor["bssid"]) and a["security"] == anchor["security"]:
                known[a["bssid"]] = {"chan": a["chan"], "security": a["security"]}
        log(f"learn: {ssid} -> {', '.join(f'{b} ch{v['chan']}' for b, v in known.items())}")
    save_conf(conf)
    return conf


# ------------------------------------------------------------------ alerts
class Alerter:
    def __init__(self, conf, path=ALERTS_FILE, dry=False):
        self.conf, self.path, self.dry = conf, path, dry
        self.last = {}
        self.emitted = []

    def __call__(self, kind, key, severity, msg, **extra):
        now = time.time()
        k = (kind, key)
        if now - self.last.get(k, 0) < self.conf["cooldown"]:
            return
        self.last[k] = now
        rec = {"ts": int(now), "severity": severity, "msg": msg, "source": "rogue-ap", "kind": kind, **extra}
        self.emitted.append(rec)
        log(f"ALERT [{severity}] {msg}")
        if self.dry:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
        if severity == "high" and self.conf.get("notify"):
            sh(["notify-send", "-u", "critical", "-a", "Rogue AP detector", "-i", "security-high",
                "Rogue AP detector", msg], timeout=5)


# ------------------------------------------------------------------ rules
class Rules:
    def __init__(self, conf, alert):
        self.conf, self.alert = conf, alert
        self.protected = set(conf["protected_ssids"])
        self.known = {s: {b.lower(): v for b, v in d.items()} for s, d in conf["known"].items()}
        self.known_bssids = {b for d in self.known.values() for b in d}
        self.deauth = collections.defaultdict(collections.deque)   # key -> timestamps
        self.karma = collections.defaultdict(dict)                 # bssid -> {ssid: ts}
        self.seen_bssids = set()
        self.frames = 0

    def _sec(self, privacy: str, akm: str) -> str:
        if privacy not in ("1", "True", "true"):
            return "OPEN"
        if not akm:
            return "WEP"
        akm = int(akm, 0)
        return {1: "ENTERPRISE", 2: "WPA2", 8: "WPA3", 6: "WPA2"}.get(akm, "WPA2")

    def frame(self, f: dict):
        self.frames += 1
        kind = f["kind"]
        if kind in ("beacon", "probe_resp"):
            self._ap_frame(f)
        elif kind in ("deauth", "disassoc"):
            self._deauth(f)

    def _ap_frame(self, f):
        bssid, ssid = f["bssid"], f["ssid"]
        if not bssid:
            return
        self.seen_bssids.add(bssid)
        sec = self._sec(f["privacy"], f["akm"])
        chan = f["ds_chan"] or f["radio_chan"]

        if ssid in self.protected:
            known = self.known.get(ssid, {})
            if bssid not in known:
                why = []
                exp = {v["security"] for v in known.values()}
                if exp and sec not in exp and not (sec.startswith("WPA") and any(e.startswith("WPA") for e in exp)):
                    why.append(f"{sec} instead of {'/'.join(sorted(exp))}")
                if known and oui4(bssid) != oui4(next(iter(known))):
                    why.append("different vendor/router MAC")
                self.alert("evil_twin", bssid, "high",
                           f"Evil twin of {ssid}: {bssid} on ch{chan} ({f['signal']} dBm)"
                           + (f" — {', '.join(why)}" if why else " — unknown BSSID"),
                           ssid=ssid, bssid=bssid, chan=chan, security=sec, signal=f["signal"])
            else:
                k = known[bssid]
                if sec != k["security"] and not (sec.startswith("WPA") and k["security"].startswith("WPA")):
                    self.alert("bssid_spoof", bssid, "high",
                               f"Spoofed BSSID: {bssid} is advertising {ssid} as {sec} (real AP is {k['security']}) on ch{chan}",
                               ssid=ssid, bssid=bssid, chan=chan, security=sec)
                elif f["ds_chan"] and k.get("chan") and int(f["ds_chan"]) != int(k["chan"]):
                    self.alert("channel_change", bssid, "medium",
                               f"{ssid} ({bssid}) now advertises ch{f['ds_chan']} (learned ch{k['chan']}) — "
                               "router changed channel, or a cloned BSSID on another channel",
                               ssid=ssid, bssid=bssid, chan=f["ds_chan"])

        if f["kind"] == "probe_resp" and ssid:
            now = f["ts"]
            seen = self.karma[bssid]
            seen[ssid] = now
            for s, t in list(seen.items()):
                if now - t > self.conf["karma_window"]:
                    del seen[s]
            if len(seen) >= self.conf["karma_ssids"]:
                self.alert("karma", bssid, "high",
                           f"Karma/MANA AP: {bssid} answered probes for {len(seen)} different networks "
                           f"({', '.join(list(seen)[:5])}…) in {self.conf['karma_window']}s",
                           bssid=bssid, ssids=list(seen))

    def _deauth(self, f):
        now, win = f["ts"], self.conf["deauth_window"]
        parties = {f["bssid"], f["ta"], f["ra"]} - {"", None}
        targeted = parties & self.known_bssids
        key = next(iter(targeted)) if targeted else (f["bssid"] or f["ta"])
        if not key:
            return
        q = self.deauth[key]
        q.append(now)
        while q and now - q[0] > win:
            q.popleft()
        what = "Deauth" if f["kind"] == "deauth" else "Disassoc"
        if targeted and len(q) >= self.conf["deauth_threshold"]:
            ssid = next((s for s, d in self.known.items() if key in d), "your network")
            victim = f["ra"] if f["ra"] and f["ra"] != "ff:ff:ff:ff:ff:ff" else "all clients (broadcast)"
            self.alert("deauth", key, "high",
                       f"{what} attack on {ssid}: {len(q)} frames in {win}s, target {victim}, reason {f['reason'] or '?'}",
                       bssid=key, count=len(q), target=victim, reason=f["reason"])
        elif not targeted and len(q) >= self.conf["deauth_flood_threshold"]:
            self.alert("deauth_other", key, "medium",
                       f"{what} flood nearby against {key}: {len(q)} frames in {win}s (not your network)",
                       bssid=key, count=len(q))


# ------------------------------------------------------------------ tshark feed
def parse_line(line: str) -> dict | None:
    p = line.rstrip("\n").split("\t")
    if len(p) < len(FIELDS):
        p += [""] * (len(FIELDS) - len(p))
    try:
        st = int(p[1], 0)
    except ValueError:
        return None
    kind = SUBTYPE.get(st)
    if not kind:
        return None
    ssid = p[5]
    if ssid and re.fullmatch(r"(?:[0-9a-fA-F]{2})+", ssid):     # FT_BYTES comes out as hex
        try:
            ssid = bytes.fromhex(ssid).decode("utf-8", "replace")
        except ValueError:
            pass
    if ssid.startswith("<MISSING>") or ssid == "\\x00" * len(ssid):
        ssid = ""
    return {"ts": float(p[0] or time.time()), "kind": kind, "bssid": p[2].lower(), "ta": p[3].lower(),
            "ra": p[4].lower(), "ssid": ssid, "ds_chan": p[6], "radio_chan": p[7],
            "signal": p[8], "privacy": p[9], "akm": p[10], "reason": p[11]}


class Monitor:
    def __init__(self, conf, rules):
        self.conf, self.rules, self.iface = conf, rules, conf["iface"]
        self.channel = None
        self.proc = None
        self.channels = list(conf["channels_24"]) + list(conf["channels_5"])
        self.priority = {int(v["chan"]) for d in conf["known"].values() for v in d.values() if v.get("chan")}

    def available(self) -> bool:
        return Path(f"/sys/class/net/{self.iface}").exists()

    def set_mode(self, mode) -> bool:
        cmds = [["ip", "link", "set", self.iface, "down"],
                ["iw", "dev", self.iface, "set", "type", mode],
                ["ip", "link", "set", self.iface, "up"]]
        for c in cmds:
            r = sh(c)
            if r.returncode != 0:
                log(f"{' '.join(c)} failed: {r.stderr.strip()}")
                return False
        return True

    def hopper(self):
        bad = set()
        while running and self.proc and self.proc.poll() is None:
            for ch in self.channels:
                if not running or not self.proc or self.proc.poll() is not None:
                    return
                if ch in bad:
                    continue
                if sh(["iw", "dev", self.iface, "set", "channel", str(ch)], timeout=5).returncode != 0:
                    bad.add(ch)
                    continue
                self.channel = ch
                time.sleep(self.conf["protected_dwell"] if ch in self.priority else self.conf["dwell"])

    def run(self, status):
        if not self.set_mode("monitor"):
            return False
        log(f"monitor mode on {self.iface}; hopping {len(self.channels)} channels (priority {sorted(self.priority)})")
        cmd = ["tshark", "-i", self.iface, "-l", "-n", "-Q", "-f", BPF, "-T", "fields",
               "-E", "separator=\t", "-E", "occurrence=f"]
        for fld in FIELDS:
            cmd += ["-e", fld]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self.hopper, daemon=True).start()
        status.update(mode="monitor", iface=self.iface)
        try:
            for line in self.proc.stdout:
                if not running:
                    break
                f = parse_line(line)
                if f:
                    self.rules.frame(f)
                status.update(channel=self.channel)
        finally:
            if self.proc.poll() is None:
                self.proc.terminate()
            err = self.proc.stderr.read().strip() if self.proc.stderr else ""
            if err:
                log(f"tshark: {err[-400:]}")
            self.proc = None
            if self.available():
                self.set_mode("managed")
        return True


def scan_mode(conf, rules, status):
    """Fallback without the ALFA: run the evil-twin rules on NM scan results."""
    status.update(mode="scan", iface="wlan0 (NetworkManager)", channel=None)
    for ap in nm_scan(rescan=True):
        rules.frame({"ts": time.time(), "kind": "beacon", "bssid": ap["bssid"], "ta": "", "ra": "",
                     "ssid": ap["ssid"], "ds_chan": str(ap["chan"]), "radio_chan": str(ap["chan"]),
                     "signal": f"{ap['signal']}%", "privacy": "0" if ap["security"] == "OPEN" else "1",
                     "akm": "" if ap["security"] in ("OPEN", "WEP") else
                            {"WPA3": "8", "ENTERPRISE": "1"}.get(ap["security"], "2"),
                     "reason": ""})


# ------------------------------------------------------------------ status
class Status:
    def __init__(self, rules):
        self.rules = rules
        self.data = {"started": int(time.time()), "mode": "starting", "iface": None, "channel": None}
        self._last = 0

    def update(self, **kw):
        self.data.update(kw)
        now = time.time()
        if now - self._last < 3:
            return
        self._last = now
        self._maybe_reload()
        self.data.update(ts=int(now), frames=self.rules.frames, bssids_seen=len(self.rules.seen_bssids),
                         protected=sorted(self.rules.protected),
                         known_bssids=sorted(self.rules.known_bssids))
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = STATUS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data))
        tmp.replace(STATUS_FILE)

    def _maybe_reload(self):
        """Pick up config edits (e.g. `detector.py --learn`) without a restart."""
        try:
            m = CONF_FILE.stat().st_mtime
        except OSError:
            return
        if getattr(self, "_conf_mtime", None) is None:
            self._conf_mtime = m
        elif m != self._conf_mtime:
            self._conf_mtime = m
            conf = load_conf()
            self.rules.alert.conf = conf
            self.rules.__init__(conf, self.rules.alert)
            log(f"config reloaded; protecting {conf['protected_ssids']}, known {sorted(self.rules.known_bssids)}")


# ------------------------------------------------------------------ main
def selftest():
    conf = dict(DEFAULT_CONF)
    conf["protected_ssids"] = ["HomeNet-Test"]
    conf["known"] = {"HomeNet-Test": {"02:aa:bb:cc:dd:01": {"chan": 44, "security": "WPA2"},
                                          "02:aa:bb:cc:dd:02": {"chan": 1, "security": "WPA2"}}}
    conf["notify"] = False
    alert = Alerter(conf, dry=True)
    rules = Rules(conf, alert)
    t = time.time()
    hexs = lambda s: s.encode().hex()
    L = lambda *a: "\t".join(str(x) for x in a)
    lines = [
        # real router, both bands: no alert
        L(t, "0x0008", "02:aa:bb:cc:dd:01", "02:aa:bb:cc:dd:01", "ff:ff:ff:ff:ff:ff", hexs("HomeNet-Test"), 44, 44, -55, 1, 2, ""),
        L(t, "0x0008", "02:aa:bb:cc:dd:02", "02:aa:bb:cc:dd:02", "ff:ff:ff:ff:ff:ff", hexs("HomeNet-Test"), 1, 1, -60, 1, 2, ""),
        # open twin from the ALFA (lab)
        L(t, "0x0008", "0a:66:77:88:99:aa", "0a:66:77:88:99:aa", "ff:ff:ff:ff:ff:ff", hexs("HomeNet-Test"), 6, 6, -30, 0, "", ""),
        # cloned BSSID but open
        L(t, "0x0008", "02:aa:bb:cc:dd:01", "02:aa:bb:cc:dd:01", "ff:ff:ff:ff:ff:ff", hexs("HomeNet-Test"), 44, 44, -40, 0, "", ""),
        # unrelated network: no alert
        L(t, "0x0008", "0e:11:22:33:44:66", "0e:11:22:33:44:66", "ff:ff:ff:ff:ff:ff", hexs("Neighbor-WiFi"), 1, 1, -70, 1, 2, ""),
    ]
    # deauth burst against the router (aireplay-style, reason 7)
    lines += [L(t + i * 0.1, "0x000c", "02:aa:bb:cc:dd:01", "02:aa:bb:cc:dd:01", "ff:ff:ff:ff:ff:ff", "", 44, 44, -40, "", "", 7) for i in range(12)]
    # karma: one BSSID answering 6 different SSIDs
    lines += [L(t + i, "0x0005", "02:11:22:33:44:55", "02:11:22:33:44:55", "aa:bb:cc:dd:ee:ff", hexs(s), 6, 6, -45, 0, "", "")
              for i, s in enumerate(["Starbucks", "attwifi", "xfinitywifi", "HomeNet", "Airport_Free", "Hilton"])]
    # a few stray deauths elsewhere: no alert
    lines += [L(t, "0x000c", "0e:11:22:33:44:66", "0e:11:22:33:44:66", "12:34:56:78:9a:bc", "", 1, 1, -70, "", "", 3)] * 3
    for ln in lines:
        f = parse_line(ln)
        if f:
            rules.frame(f)
    kinds = [a["kind"] for a in alert.emitted]
    expect = ["evil_twin", "bssid_spoof", "deauth", "karma"]
    ok = kinds == expect
    print(f"\nselftest: {'PASS' if ok else 'FAIL'} — got {kinds}, expected {expect}")
    return 0 if ok else 1


def main():
    global running
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    conf = load_conf()
    if "--learn" in sys.argv:
        learn(conf)
        return
    if not any(conf["known"].get(s) for s in conf["protected_ssids"]):
        conf = learn(conf)

    def stop(*_):
        global running
        running = False
        if mon.proc and mon.proc.poll() is None:
            mon.proc.terminate()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    alert = Alerter(conf)
    rules = Rules(conf, alert)
    status = Status(rules)
    mon = Monitor(conf, rules)
    log(f"protecting {conf['protected_ssids']}; known BSSIDs {sorted(rules.known_bssids)}")
    while running:
        if mon.available():
            if not mon.run(status):
                log("monitor mode unavailable; falling back to scan mode for 60s")
                scan_mode(conf, rules, status)
                _sleep(60, status)
        else:
            scan_mode(conf, rules, status)
            _sleep(30, status)
    status.update(mode="stopped")
    status._last = 0
    status.update(mode="stopped")


def _sleep(sec, status):
    end = time.time() + sec
    while running and time.time() < end:
        status.update()
        time.sleep(1)


if __name__ == "__main__":
    main()
