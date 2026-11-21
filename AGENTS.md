# AGENTS.md — notes for AI agents working on this board/repo

This file is written for an AI coding/diagnostic agent (OpenCode, etc.) that is
asked to diagnose or modify an Orange Pi RV2 running Armbian. It documents the
exact failure that was found, the fix that was applied, the traps that were hit,
and the things that are **not** fixed. Read it before changing anything.

## 1. Context

- Board: Orange Pi RV2, SpacemiT K1 / Ky X1, 8 cores, 4 GiB RAM.
- Boot medium: 64 GB microSD (`SE64G`), single ext4 partition
  (`/dev/mmcblk0p1`, label `armbi_root`).
- Additional NVMe: 128 GB, used for application data, not for boot.
- OS: Armbian 26.11.0-trunk.74 trixie (Debian 13.7).
- Kernel: `6.18.55-current-spacemit` (built 2026-10-03).
- U-Boot: `2022.10_armbian-2022.10-Sd61c-P76af-H4e64-Vc38c-B5da4-R448a`.
- OpenSBI: 1.3 (`SBI implementation ID=0x1 Version=0x10003`).
- Serial: 3.3 V USB-TTL at 115200 8N1, `picocom`.
- Power: USB-C. Software `poweroff` cuts the rails; U-Boot `poweroff` does not.

The owner is not a kernel developer. Prefer minimal, reversible changes and
explain what you are doing. Do not test `reboot` on a remote board without a
way to power-cycle it physically.

## 2. The failure that was fixed (and why it looked like “No init found”)

The board reached the initramfs, fsck’d the root filesystem successfully, and
then dropped to `(initramfs)`:

```
run-init: opening console: No such file or directory
Target filesystem doesn't have requested /sbin/init.
No init found. Try passing init= bootarg.
```

The message is misleading. The root filesystem was healthy:
`chroot /root /sbin/init --version` ran systemd 257. The real problem:

1. `/usr/share/initramfs-tools/scripts/init-bottom/udev` has
   `#!/bin/sh -e` and starts with `udevadm settle --timeout=60`.
2. On this board udev’s queue does not empty for ~130 s (a stuck SD-partition
   event plus late `btrfs-control`; the btrfs module is loaded late).
3. `udevadm settle` therefore exits non-zero, and `set -e` aborts the hook
   **before** `mount -n -o move /dev "${rootmnt}/dev"`.
4. `/root/dev` is left empty, so `/root/dev/console` does not exist.
5. `run-init` tries to validate/exec `/sbin/init` and fails at the console open
   / path check. The root filesystem is fine; the hand-off is broken.

The decisive check is `ls /root/dev` at the `(initramfs)` prompt: it contains
only `.` and `..`.

## 3. The fix (current state of this board)

Three initramfs source scripts have been patched. Backups are outside the
scanned directories.

```diff
# /usr/share/initramfs-tools/scripts/functions
- udevadm settle ${1:+--timeout=$1}
+ udevadm settle --timeout=3 || true

# /usr/share/initramfs-tools/scripts/init-top/udev
- udevadm settle || true
+ udevadm settle --timeout=3 || true

# /usr/share/initramfs-tools/scripts/init-bottom/udev
- udevadm settle --timeout=60
+ udevadm settle --timeout=3 || true
```

The `|| true` on `init-bottom/udev` is the critical part because that script
runs with `set -e`. The 3-second value is tuning; the root device is registered
at ~3.2 s and the root UUID is resolved by `blkid`, not by udev symlinks.

After the edits:

```sh
update-initramfs -u -k "$(uname -r)"
```

Armbian’s `/etc/initramfs/post-update.d/99-uboot` hook rebuilds `uInitrd` with
`mkimage -A riscv -O linux -T ramdisk -C gzip`.

Verify with:

```sh
TMP=$(mktemp -d)
unmkinitramfs "/boot/initrd.img-$(uname -r)" "$TMP"
grep -rH 'udevadm settle' "$TMP"
find "$TMP" -name '*.pre-udevfix' -print
rm -rf "$TMP"
```

Expected: the three `--timeout=3 || true` lines, no backup files inside
`scripts/init-top/` or `scripts/init-bottom/`.

## 4. Traps that were hit (do not repeat)

### 4.1 Backups inside the scanned script directories

`run_scripts` executes every executable file in `scripts/init-top/` and
`scripts/init-bottom/`. A backup named `udev.pre-udevfix` (mode 755) in those
directories is executed too. During this session that started a second
`systemd-udevd` and made one boot confusing. Keep backups in
`/var/backups/`, not in the scanned directories, or make them non-executable.

### 4.2 The initramfs is not a single gzip file

The board’s `initrd.img` is a concatenation of cpio archives (raw cpio magic
`070701`; `cpio -t` stops after the first archive at ~1.9 MB). Do not try to
`zcat` it. Use `unmkinitramfs` to inspect it, or let `update-initramfs`
regenerate it. A hand-repack with `find | cpio` is error-prone and unnecessary.

### 4.3 U-Boot `poweroff` is not a cold boot

At the U-Boot `=>` prompt, `poweroff` halts but does not cut the rails (the red
LED stays on). The SD card keeps its wedged state. Use Linux `poweroff` and the
physical button, or unplug power for ~5 minutes.

### 4.4 `reboot` wedges the SD card

A warm reset leaves the card unable to do data transfers. U-Boot reports
`mmc fail to set block count`, `fs_devread read error`, `No partition table -
mmc 0`; at the prompt `mmc info` works but `mmc read` returns `0 blocks read:
ERROR`. Only removing power restores it. Do not “fix” this by retrying
`reboot`; it will keep landing at `=>`. See section 6.

### 4.5 Do not disable the SD card rail while mounted

`dcdc4` powers `d4280000.sdh-vmmc` (the SD card), and `ldo1` powers its I/O.
Toggling them while the root filesystem is mounted will crash/corrupt the
system. Any future `dcdc4` shutdown hook must run only after unmounting the
root filesystem, ideally from `systemd-shutdown`.

### 4.6 Root filesystem is ~90% full

There is only ~6 GB free on the 58 GB root filesystem. Be careful with large
temporary extractions; clean up `/var/tmp` afterwards.

## 5. Diagnostic checklist

At the initramfs prompt (or via serial):

```sh
cat /proc/cmdline
mount
ls /root
readlink -f /root/sbin/init
chroot /root /sbin/init --version
ls /root/dev                 # the decisive check: empty means the /dev move failed
cat /scripts/init-bottom/udev
n=0; while read l; do n=$((n+1)); case "$l" in *run-init*|*rootmnt*|*console*|*panic*) echo "$n: $l";; esac; done < /init
```

From a running system:

```sh
systemd-analyze
systemd-analyze critical-chain
systemd-analyze blame
pgrep -a systemd-udevd
dmesg | grep -i -E 'mmc0|mmcblk0|I/O error|EXT4-fs'
ls -l /dev/watchdog*
cat /sys/class/regulator/regulator.*/name
mount | grep debugfs
cat /sys/kernel/debug/regulator/regulator_summary
```

The current expected state: one `systemd-udevd`, a kernel/initramfs phase of
about 15 s in the final build, `systemd-analyze` around 38.7 s, SSH available
~38 s after power-on.

## 6. Reboot: not fixed, and why

This is deliberate. Do not claim reboot is fixed.

Evidence:

- `sudo reboot` → kernel prints `reboot: Restarting system` → U-Boot starts →
  SD read errors → `=>`.
- At `=>`: `mmc info` identifies the card, `mmc part` shows a cached table, but
  every `mmc read` returns `0 blocks read: ERROR`, even with `mmc rescan`.
- Short button power cycles do not clear it; unplugging for minutes does.

Kernel/driver findings:

- Armbian 6.18.55 uses the vendor `drivers/watchdog/k1x_wdt.c` (symbols
  `spa_wdt_*`), not the mainline `spacemit,soc-wdt` driver.
- The driver declares `static spinlock_t reboot_lock;` and only initializes
  `info->wdt_lock`. `reboot_lock` is never initialized. This is the class of
  bug described by hydrogen18 (spinlock bad magic).
- The DTB has `spa,wdt-disabled` but not `spa,wdt-enable-restart-handler`, so
  the watchdog restart handler is not registered. `reboot` uses the PMIC/SoC
  restart path, which hangs on this firmware.
- OpenSBI 1.3 has no SBI SRST reboot support for K1.
- The hardware watchdog can reset the SoC, but that is still a warm reset; the
  SD card remains wedged. `RebootWatchdogSec` therefore lands in U-Boot, not
  Linux.
- The 2026 Linux RISC-V patch “disable local interrupts and stop other CPUs
  before restart” is not in this kernel. The 2026 OpenSBI K1 reboot patches are
  not in this firmware.

Safe workarounds:

1. `poweroff` + physical button (used for the 9/9 cold-boot tests).
2. Smart plug / USB relay for remote power cycling.
3. Future: `dcdc4`/`ldo1` shutdown hook (after unmount) to power-cycle the SD
   card; kexec; newer OpenSBI/U-Boot. None of these are implemented here.

## 7. Verification done

- 9/9 clean cold boots (7 in the requested series + the 10 s and 3 s
  validation boots); Linux `poweroff`, red LED off, button. The first post-fix
  boot also succeeded but had the duplicate-hook mistake; it is counted
  separately.
- Final build: `systemd-analyze` 38.677 s (kernel 14.740 s + userspace
  23.937 s); SSH in ~38 s; single `systemd-udevd`.
- Boot-time progression: ~3:38 (first fix) → 1:19.7 (20 s caps) → 59.7 s
  (10 s caps) → 38.7 s (3 s caps).
- The `Timed out while waiting for udev queue to empty` lines still appear;
  they are expected and non-fatal.

## 8. Non-issues / noise

These are present but unrelated to the boot failure. Do not chase them unless
the user asks:

- `HDMI cannot get HPD signal` / display probe errors on a headless board.
- `v4l2_open` warnings from the camera/video subsystem.
- `dhd` / `btsdio` / `bcmsdh_sdmmc` warnings for the Wi-Fi/Bluetooth module.
- U-Boot `bad CRC, using default environment` and
  `MAC mapping file path not set in environment`.
- `dnscrypt-proxy-resolvconf.service` failing (pre-existing service config).
- Root filesystem 90% full (maintenance issue).

## 9. Files and evidence

- `README.md` — the human write-up.
- `logs/01-original-stuck-boot.txt` — original failure.
- `logs/02-initramfs-dmesg.txt` — kernel log from the stuck initramfs.
- `logs/03-first-successful-boot.log` — first post-fix boot (includes the
  duplicate-udevd mistake).
- `logs/04-failed-warm-reboot-sd-wedge.log` — reboot → U-Boot → SD wedge.
- `logs/05-button-poweron-still-wedged.log` — short power cycle does not reset
  the card.
- `logs/06-uboot-retry-fail.log` — `mmc read` ERROR at the U-Boot prompt.
- `logs/07-cold-boot-series.log` — cold-boot series #1–#7.
- `logs/08-final-38s-boot.log` — final 3 s build.
- `logs/09-onboard-changes.log` — the session change log.
- `logs/10-onboard-initramfs-build.log` — initramfs build attempts.
- `logs/11-key-diagnosis-evidence.txt` — curated decisive outputs.
- `scripts/fix-initrd.sh` — the helper used from the initramfs shell.

All logs are sanitized (UUIDs, MACs, LAN IPs, username replaced).

## 10. Safety and consent

- Ask before flashing firmware, changing the bootloader environment, or
  modifying the DTB.
- Do not test `reboot` without physical power access.
- Do not disable `dcdc4`/`ldo1` while the root filesystem is mounted.
- Keep backups of `/boot/initrd.img-*`, `/boot/uInitrd-*`, and
  `/boot/extlinux/extlinux.conf` before rebuilding.
- If the board ends at U-Boot `=>`, do not panic: the card is wedged. Power it
  off completely (unplug ~5 min), then boot.
- If you are an AI and the evidence does not fit one of the patterns above,
  stop and collect serial logs instead of guessing.
