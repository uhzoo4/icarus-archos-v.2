# Icarus-ArchOS Burn-In Checklist

Post-install validation plan — 18 steps covering boot reliability, suspend/resume, thermals, Wine Wayland, networking, and Btrfs health.

> **Instructions:** Run each step sequentially on the target hardware after a fresh Icarus-ArchOS install. Mark each step **PASS** or **FAIL** before continuing. Any **FAIL** should be investigated and resolved before the system is considered production-ready.

> **Prerequisite tools:** `stress-ng`, `lm_sensors` (for `sensors`), and `power-profiles-daemon` (for `powerprofilesctl`) are installed and enabled by `layers/04-graphics.sh`. Run `sudo sensors-detect` once before step 9 if `sensors` reports no chips found — that step is interactive and can't be scripted into the installer.

---

## Boot Reliability

### 1. Cold boot #1

```bash
systemd-analyze
systemd-analyze blame
```

- **PASS** if boot completes to Hyprland login under 45s and `systemd-analyze blame` shows no service >10s.
- **FAIL** if any service fails or boot hangs.

### 2. Cold boot #2 (immediate reboot)

```bash
reboot
# After reboot:
systemd-analyze
journalctl -b -1 -p err
```

- **PASS** if identical boot time ±5s and no new errors in `journalctl -b -1 -p err`.
- **FAIL** on regression or new failures.

### 3. Cold boot #3 (power-off 30s, cold start)

Power off → wait 30s → power on.

```bash
dmesg -T | grep -iE 'error|fail|warn'
```

- **PASS** if POST + boot succeeds and `dmesg` shows only expected firmware warnings.
- **FAIL** on new hardware errors or boot failure.

### 4. Stock kernel fallback verification

```bash
bootctl list
# Select icarus-fallback entry, then reboot
```

- **PASS** if stock kernel entry boots to Hyprland without manual intervention.
- **FAIL** if fallback entry missing, kernel panic, or graphics fail.

---

## Suspend / Resume

### 5. Suspend/resume cycle #1

```bash
systemctl suspend
# Wake via lid/power button
dmesg -T | tail -20
```

- **PASS** if resume <5s, Hyprland responsive, `dmesg` shows no `xe`/`i915` GPU reset/hang messages.
- **FAIL** on black screen, frozen input, or GPU reset logs.

### 6. Suspend/resume cycle #2 (immediate repeat)

```bash
systemctl suspend
# Wake immediately
```

- **PASS** if same as #5 with no accumulated latency.
- **FAIL** on degradation or new errors.

### 7. Suspend/resume cycle #3 (lid close 5min)

Close lid → wait 5min → open.

- **PASS** if instant resume, network reconnected (see #13), no `dmesg` GPU complaints.
- **FAIL** on delayed wake or network down.

---

## Power & Thermals

### 8. Battery idle drain (unplugged, 30min)

```bash
# Before:
upower -i /org/freedesktop/UPower/devices/battery_BAT0
# Wait 30min idle (Hyprland, no apps)
# After:
upower -i /org/freedesktop/UPower/devices/battery_BAT0
powerprofilesctl get
```

- **PASS** if drain ≤2%/hr and `powerprofilesctl get` shows `balanced` or `power-saver`.
- **FAIL** if >3%/hr or profile stuck on `performance`.

### 9. CPU stress test (custom kernel if built, else stock)

```bash
stress-ng --cpu $(nproc) --timeout 300s --metrics-brief
sensors
dmesg -T | grep -iE 'mce|thermald|throttl'
```

- **PASS** if all cores sustain ≥95% load, temps <90°C, no `mce`/`thermald` throttling in `dmesg`.
- **FAIL** on crash, throttle >20% freq drop, or kernel oops.

### 10. Custom kernel vs stock comparison (if custom built)

Reboot into custom kernel → repeat #9 → reboot into stock kernel → repeat #9.

- **PASS** if both kernels pass #9 with comparable thermals/stability.
- **FAIL** if custom kernel shows instability stock does not.

---

## Wine Wayland

### 11. Wine native Wayland verification

```bash
WINEPREFIX=~/.wine wine reg query "HKCU\Software\Wine\Drivers" /v Graphics
```

- **PASS** if output shows `Graphics    REG_SZ    wayland,x11`.
- **FAIL** if `x11` only or key missing.

### 12. Wine Wayland runtime confirmation

```bash
WINEPREFIX=~/.wine wine winecfg
# Check "Graphics" tab shows "Wayland Driver" enabled
```

- **PASS** if Wayland driver listed and selected.
- **FAIL** if only X11 driver present.

---

## Networking

### 13. NetworkManager reconnect after suspend

```bash
systemctl suspend
# Wake
nmcli device status
ping -c3 9.9.9.9
```

- **PASS** if Wi-Fi shows `connected` and ping succeeds within 10s.
- **FAIL** if `disconnected` or ping fails >30s.

### 14. systemd-resolved DNS sanity

```bash
resolvectl status
dig @127.0.0.53 archlinux.org
```

- **PASS** if `resolvectl` shows valid DNS servers per interface and `dig` resolves in <200ms.
- **FAIL** on `SERVFAIL`, timeout, or no DNS servers listed.

---

## Btrfs Health

### 15. Btrfs scrub (full)

```bash
btrfs scrub start -B /
btrfs scrub status /
```

- **PASS** if `btrfs scrub status /` reports `Error summary: no errors found`.
- **FAIL** on any uncorrectable errors or scrub abort.

### 16. Btrfs subvolume sanity

```bash
btrfs subvolume list /
```

- **PASS** if `@`, `@home`, `@cache`, `@log` present with correct paths.
- **FAIL** if any missing, misnamed, or unexpected subvolumes exist.

### 17. Btrfs space/usage health

```bash
btrfs filesystem usage /
```

- **PASS** if `Data,single`/`Metadata,single` profiles match install choice, `Unallocated` >5GB, no `Missing devices`.
- **FAIL** on profile mismatch, <3GB free, or missing device.

---

## Final Validation

### 18. Final cold boot (post-stress validation)

Power off 10s → cold boot.

```bash
journalctl -b -p err
```

- **PASS** if zero new errors since pre-stress baseline.
- **FAIL** on any new error entries.

---

## Results Summary

| Step | Description                          | Result | Notes |
|-----:|--------------------------------------|--------|-------|
|    1 | Cold boot #1                         |        |       |
|    2 | Cold boot #2 (immediate reboot)      |        |       |
|    3 | Cold boot #3 (30s power-off)         |        |       |
|    4 | Stock kernel fallback                |        |       |
|    5 | Suspend/resume #1                    |        |       |
|    6 | Suspend/resume #2 (immediate)        |        |       |
|    7 | Suspend/resume #3 (lid 5min)         |        |       |
|    8 | Battery idle drain (30min)           |        |       |
|    9 | CPU stress test                      |        |       |
|   10 | Custom vs stock kernel               |        |       |
|   11 | Wine Wayland registry                |        |       |
|   12 | Wine Wayland runtime                 |        |       |
|   13 | NetworkManager post-suspend          |        |       |
|   14 | systemd-resolved DNS                 |        |       |
|   15 | Btrfs scrub                          |        |       |
|   16 | Btrfs subvolume sanity               |        |       |
|   17 | Btrfs space/usage health             |        |       |
|   18 | Final cold boot (post-stress)        |        |       |
