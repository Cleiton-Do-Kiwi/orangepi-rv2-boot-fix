# How to fix boot problems on the Orange Pi RV2 (Armbian)

**From “No init found” and random cold boots to a reliable 38-second boot.**

This is a field report, not official documentation. It describes one specific
Orange Pi RV2 / Armbian setup, the failure I hit, how I diagnosed it, and the
small fix that made cold boots reliable. The reboot limitation is documented
separately and honestly: it is **not** fixed.

---

## Disclaimer

I do not know much about this board, its hardware, or its software bugs. I am
not a kernel developer and I do not work for Orange Pi, SpacemiT or Armbian.
Everything here is the result of one long debugging session on one board.

I spent about **US$0.35** in API usage on **DeepSeek V4.1 Flash 1017** (the
model running inside **OpenCode**) to diagnose and fix the boot problems
described below. The AI did the digging, I did the physical work (serial cable,
power cycles, pressing the button) and made the decisions.

If you have a different problem, or if this fix does not work for you, I
strongly recommend doing the same: use **OpenCode** with a capable AI model,
connect a **serial console**, and let it diagnose your board. It is much more
effective than guessing, and the serial log gives the model the evidence it
needs. You should also be ready to stop and ask a human if the AI starts
guessing.

This write-up is provided as-is. There is no license file in this repository;
ask the author before reusing large parts of it.

---

## Symptoms I had

- Booting with an HDMI monitor connected, the board would hang on
  **“initializing bootloader”** forever. Nothing useful appeared on the screen.
- Occasionally it would boot **completely at random**, with no change on my side.
- Most of the time a cold boot required **multiple attempts**. Often I had to
  unplug the power for several minutes to let the capacitors discharge, and
  then it would “magically” boot.
- `reboot` **never worked**. It would appear to restart and then stop, usually
  at the bootloader or with a black screen.
- `poweroff` did work: the red LED turned off, and pressing the power button
  afterwards was the only reliable way to start the board again.

On the serial console, the “random” failures were not random at all: the board
was reaching the initramfs and then failing there with:

```
run-init: opening console: No such file or directory
Target filesystem doesn't have requested /sbin/init.
No init found. Try passing init= bootarg.
(initramfs)
```

The HDMI symptom was misleading. The board was not stuck in the bootloader; it
was getting much further and then dropping to an initramfs rescue shell that
was invisible on HDMI.

---

## My environment

| Item | Value |
|---|---|
| Board | Orange Pi RV2 |
| SoC | SpacemiT K1 / Ky X1, 8 cores |
| RAM | 4 GiB |
| Boot storage | 64 GB microSD (`SE64G`, 59.5 GiB), one ext4 partition |
| Other storage | 128 GB NVMe (used for app data, not for boot) |
| OS | Armbian 26.11.0-trunk.74 trixie (Debian 13.7) |
| Kernel | `6.18.55-current-spacemit` |
| U-Boot | `2022.10_armbian-2022.10-Sd61c-P76af-H4e64-Vc38c-B5da4-R448a` |
| OpenSBI | 1.3 (SBI implementation version `0x10003`) |
| Power | USB-C phone charger (5 V), works but not a lab supply |
| Cooling | Small heatsink, no fan |
| Serial | 3.3 V USB-TTL adapter (CP2102), 115200 8N1 |
| Host | NixOS laptop, `picocom` |

The serial connection is what made the diagnosis possible. If you are debugging
an RV2, get a 3.3 V USB-TTL adapter and connect **GND, TX and RX** (adapter TX
to board RX, adapter RX to board TX). Do not use a 5 V adapter.

A blog post by Eric Urban (hydrogen18) was extremely useful for understanding
the watchdog and reboot side of this board:

<https://www.hydrogen18.com/blog/orange-pi-rv2-first-look-kernel-watchdog-bug.html>

That post documents a kernel watchdog bug and the board’s power-state issues.
The fix in this repository is different: it is about the **initramfs**, not the
watchdog driver.

---

## TL;DR

The root filesystem was completely healthy. The boot was failing because the
initramfs hook `init-bottom/udev` runs with `set -e` and starts with:

```sh
udevadm settle --timeout=60
```

On this board udev’s event queue does not empty for about 130 seconds. The
`settle` call therefore fails, `set -e` aborts the hook **before** it moves the
`/dev` tmpfs into the root filesystem, and `run-init` then cannot find
`/dev/console` or `/sbin/init`.

The fix is three small changes in the initramfs scripts:

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

then:

```sh
sudo update-initramfs -u -k "$(uname -r)"
```

The important part is `|| true` on the `init-bottom/udev` line. Without it the
hook can abort and the board will drop to the initramfs shell again. The 3-second
timeout is a tuning choice: the root device is ready after ~3 seconds and the
root UUID is resolved with `blkid`, not through udev symlinks, so the initramfs
does not need to wait for the 130-second udev stall.

`reboot` is still broken; see [Why reboot still does not
work](#6-why-reboot-still-does-not-work). Use `poweroff` and the power button.

---

## Index

- [Quick steps](#quick-steps-the-short-version)

1. [How the board boots](#1-how-the-board-boots)
2. [Diagnosis, step by step](#2-diagnosis-step-by-step)
3. [The fix, step by step](#3-the-fix-step-by-step)
4. [The exact commands and changes](#4-the-exact-commands-and-changes)
5. [Boot-time tuning](#5-boot-time-tuning)
6. [Why reboot still does not work](#6-why-reboot-still-does-not-work)
7. [All issues diagnosed](#7-all-issues-diagnosed)
8. [Verification](#8-verification)
9. [What you need](#9-what-you-need)
10. [Reproducing from scratch](#10-reproducing-from-scratch)
11. [Logs in this repository](#11-logs-in-this-repository)
12. [References](#12-references)
13. [Credits](#13-credits)

---

## Quick steps (the short version)

1. Connect a **3.3 V USB-TTL** adapter to GND, TX and RX and open
   `picocom -b 115200 /dev/ttyUSB0`.
2. Reproduce the failure and check that the root filesystem is healthy:
   `chroot /root /sbin/init --version` should work at the `(initramfs)` prompt.
   `ls /root/dev` should be empty.
3. Patch the three initramfs scripts so the udev waits are non-fatal and short
   (the exact `sed` commands are in
   [section 4](#4-the-exact-commands-and-changes)).
4. Rebuild: `sudo update-initramfs -u -k "$(uname -r)"`.
5. `sudo poweroff`, wait for the red LED to turn off, then press the power
   button. Do not use `reboot`.

---

## 1. How the board boots

A very short version, enough to follow the rest:

1. **BootROM → SPL**: the SoC loads the first-stage bootloader.
2. **U-Boot**: loads the kernel, the device tree and the initramfs (`uInitrd`)
   from the SD card.
3. **Linux kernel**: starts, mounts a temporary in-memory filesystem
   (the *initramfs*), and runs `/init` from it.
4. **initramfs-tools `/init`**: finds the real root filesystem, runs `fsck`,
   mounts it at `/root`, moves virtual filesystems such as `/dev`, `/proc` and
   `/sys` into it, and calls `run-init`.
5. **`run-init`**: switches to the real root filesystem and executes
   `/sbin/init` (systemd).
6. **systemd**: starts the services.

The failure was between steps 4 and 5.

---

## 2. Diagnosis, step by step

### 2.1 Get a serial console

Connect a 3.3 V USB-TTL adapter to the board’s debug UART and open it at
115200 8N1:

```sh
picocom -b 115200 /dev/ttyUSB0
```

On NixOS the device may need a one-time permission change:

```sh
sudo chown "$USER" /dev/ttyUSB0
```

A logging session is useful:

```sh
picocom -b 115200 --logfile boot.log /dev/ttyUSB0
```

If the board is already stuck, press Enter. You should see `(initramfs)`.

### 2.2 Confirm the failure

The serial log showed the board reaching the initramfs, fsck’ing the root
partition successfully, and then failing:

```
armbi_root: clean, ...
Begin: Running /scripts/init-bottom ... Timed out while waiting for udev queue to empty.
run-init: opening console: No such file or directory
Target filesystem doesn't have requested /sbin/init.
No init found. Try passing init= bootarg.
```

That message is misleading. It says the target filesystem has no
`/sbin/init`, but the root filesystem was fine. The next step proves it.

### 2.3 Prove the root filesystem is healthy

At the `(initramfs)` prompt:

```sh
cat /proc/cmdline
mount
ls /root
readlink -f /root/sbin/init
chroot /root /sbin/init --version
```

The important outputs:

- `/dev/mmcblk0p1` is mounted at `/root` as ext4.
- `/sbin` is a symlink to `usr/sbin`, and `/sbin/init` resolves to
  `/usr/lib/systemd/systemd`.
- `chroot /root /sbin/init --version` actually starts systemd and prints its
  version. The root filesystem and init are fine.

So the problem is not the card, not the filesystem, and not systemd. It is the
hand-off from the initramfs to the real root.

### 2.4 Find the missing `/dev`

Run:

```sh
ls /root/dev
```

It contains only `.` and `..`. In a normal boot, the initramfs moves its
`devtmpfs` mount onto `/root/dev`, so `/root/dev/console` exists. Here it does
not, which is exactly why `run-init` says “opening console: No such file or
directory”.

### 2.5 Read the initramfs hook that should have moved `/dev`

```sh
cat /scripts/init-bottom/udev
```

The beginning is:

```sh
#!/bin/sh -e
...
udevadm settle --timeout=60
udevadm control --exit
mount -n -o move /dev "${rootmnt:?}/dev" || mount -n --move /dev "${rootmnt}/dev"
```

Two things combine badly:

- `#!/bin/sh -e` makes any failing command abort the whole script.
- `udevadm settle --timeout=60` fails because udev’s queue does not empty in
  60 seconds.

The script therefore aborts before `mount --move /dev`. That is the root cause.

### 2.6 Why does udev not settle?

On this board the initramfs udev queue is held by a late event. The udev
database timestamps showed that 290 of 293 device records were written in the
first ~12 seconds; only the SD partition (`mmcblk0p1`) and
`/dev/btrfs-control` appeared around 120–130 seconds. The btrfs module is
loaded late by the initramfs’s btrfs scan, and the SD partition event is stuck
behind it. The root device itself is registered at ~3.2 seconds, and the root
UUID is resolved with `blkid`, not through `/dev/disk/by-uuid`, so waiting for
udev is unnecessary for this board.

The `Timed out while waiting for udev queue to empty` messages are therefore
expected on this hardware. They are only a problem because the hook treats
them as fatal.

---

## 3. The fix, step by step

### 3.1 Back up the three scripts

```sh
sudo cp -a /usr/share/initramfs-tools/scripts/functions \
           /var/backups/functions.pre-bootfix
sudo cp -a /usr/share/initramfs-tools/scripts/init-top/udev \
           /var/backups/init-top-udev.pre-bootfix
sudo cp -a /usr/share/initramfs-tools/scripts/init-bottom/udev \
           /var/backups/init-bottom-udev.pre-bootfix
```

> **Important:** do not leave executable backup copies inside
> `scripts/init-top/` or `scripts/init-bottom/`. `run_scripts` executes every
> executable file in those directories, so a file named `udev.pre-bootfix`
> will also be run. That is how I accidentally started a second
> `systemd-udevd` during one boot. Store backups outside those directories.

### 3.2 Patch the scripts

```sh
sudo sed -i 's#udevadm settle ${1:+--timeout=$1}#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/functions

sudo sed -i 's#udevadm settle || true#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/init-top/udev

sudo sed -i 's#udevadm settle --timeout=60#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/init-bottom/udev
```

Verify:

```sh
grep -H 'udevadm settle' \
  /usr/share/initramfs-tools/scripts/functions \
  /usr/share/initramfs-tools/scripts/init-top/udev \
  /usr/share/initramfs-tools/scripts/init-bottom/udev
```

Expected:

```
.../functions:        udevadm settle --timeout=3 || true
.../init-top/udev:    udevadm settle --timeout=3 || true
.../init-bottom/udev: udevadm settle --timeout=3 || true
```

The essential change is the `|| true` on `init-bottom/udev`. The timeout value
is explained in [Boot-time tuning](#5-boot-time-tuning).

### 3.3 Regenerate the initramfs

On Armbian, `update-initramfs` also rebuilds the U-Boot `uInitrd` through the
`/etc/initramfs/post-update.d/99-uboot` hook:

```sh
sudo update-initramfs -u -k "$(uname -r)"
```

### 3.4 Verify the generated initramfs

`unmkinitramfs` understands the concatenated cpio archives used by
initramfs-tools:

```sh
TMP=$(mktemp -d)
sudo unmkinitramfs "/boot/initrd.img-$(uname -r)" "$TMP"
sudo grep -rH 'udevadm settle' "$TMP"
sudo find "$TMP" -name '*.pre-udevfix' -print
rm -rf "$TMP"
```

You should see the three `--timeout=3 || true` lines and no backup files inside
`scripts/init-top/` or `scripts/init-bottom/`.

Check the U-Boot wrapper:

```sh
mkimage -l /boot/uInitrd
```

It should report a valid RISC-V RAMDisk image and the same data size as
`/boot/initrd.img-$(uname -r)`.

### 3.5 Cold-boot the board

A **cold** boot is required for a real test, and for this board that means
removing power, not just rebooting:

```sh
sudo poweroff
```

Wait until the **red LED turns off** (a true power-off), then press the power
button once. If the board does not come back, unplug the USB-C power for about
5 minutes, plug it back in, and press the button.

Do **not** use `reboot` and do **not** use U-Boot’s `poweroff` for this test:
U-Boot’s `poweroff` does not cut the rails on this board (the red LED stays on),
so the SD card is not power-cycled.

### 3.6 Confirm the result

On the serial console, the boot should reach:

```
OrangePI login:
```

or you should be able to SSH in. On the board:

```sh
systemd-analyze
pgrep -a systemd-udevd
```

On the final build here, `systemd-analyze` reported **38.677 s** total and there
was exactly one `systemd-udevd` process.

---

## 4. The exact commands and changes

For copy-paste, the minimal patch is:

```sh
# 1. back up
sudo cp -a /usr/share/initramfs-tools/scripts/functions      /var/backups/functions.pre-bootfix
sudo cp -a /usr/share/initramfs-tools/scripts/init-top/udev /var/backups/init-top-udev.pre-bootfix
sudo cp -a /usr/share/initramfs-tools/scripts/init-bottom/udev /var/backups/init-bottom-udev.pre-bootfix

# 2. patch
sudo sed -i 's#udevadm settle ${1:+--timeout=$1}#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/functions
sudo sed -i 's#udevadm settle || true#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/init-top/udev
sudo sed -i 's#udevadm settle --timeout=60#udevadm settle --timeout=3 || true#' \
  /usr/share/initramfs-tools/scripts/init-bottom/udev

# 3. rebuild
sudo update-initramfs -u -k "$(uname -r)"
```

If your `init-bottom/udev` has a different timeout value, adjust the pattern;
the important part is that the line ends with `|| true`.

There is also a helper script in [`scripts/fix-initrd.sh`](scripts/fix-initrd.sh).
It was written to run from the initramfs rescue shell with the root filesystem
mounted at `/root`, but the three `sed` commands above are the whole fix.

---

## 5. Boot-time tuning

The first version of the fix made the settle non-fatal but still used long
timeouts (180 s on `init-bottom`), and I had also left executable backup hooks
inside the scanned script directories. That first post-fix boot still took about
3 min 38 s. After cleaning up the duplicate hooks and shortening the timeouts,
the measurements were:

| Version | Kernel/initramfs | Userspace | Total |
|---|---:|---:|---:|
| First post-fix boot (180 s + duplicate hooks) | 195.7 s | 22.7 s | 3 min 38.4 s |
| `20 s` caps (no duplicate hooks) | 55.8 s | 23.9 s | 1 min 19.7 s |
| `10 s` caps | 35.6 s | 24.0 s | 59.7 s |
| `3 s` caps (final) | 14.7 s | 23.9 s | **38.7 s** |

The 3-second value is safe on this board because:

- the SD card and partition are registered at about 3.2 seconds;
- the root UUID is resolved by `blkid`, which scans the device directly, not
  through udev’s `/dev/disk/by-uuid` symlinks;
- the root filesystem mount and fsck happen independently of the stuck udev
  events.

If your board is slower to bring up the SD card, use `--timeout=5` or `10`
instead. The `|| true` is what protects the boot; the timeout only controls how
long you are willing to wait for udev before continuing.

Userspace still takes ~24 seconds here, mostly because PostgreSQL and a few
self-hosted services start in parallel. That is not part of the boot failure.

---

## 6. Why reboot still does not work

This is the honest part. **The initramfs fix does not make `reboot` work.**

### What happens

`sudo reboot` reaches systemd’s reboot target, the kernel prints:

```
reboot: Restarting system
```

and then the board resets. U-Boot starts again, but it cannot read the SD card:

```
Booting from mmc 0:1 ...
Retrieving file: /boot/uInitrd
mmc fail to set block count
** fs_devread read error - block
Failed to mount ext2 filesystem...
Skipping Armbian_community for failure retrieving initrd
```

It then tries the NVMe and other devices and drops to the U-Boot `=>` prompt.
At that prompt the card still answers identification:

```
=> mmc dev 0
switch to partitions #0, OK
=> mmc info
Device: sdh@d4280000
Name: SE64G
Capacity: 59.5 GiB
```

but data reads fail:

```
=> mmc read 0x40000000 0x2000 1
MMC read: dev # 0, block # 8192, count 1 ... 0 blocks read: ERROR
```

`mmc rescan` does not help. Only removing power for several minutes brings the
card back.

### Why it happens

There are two layers.

**1. The K1 warm reset does not power-cycle the SD card.**
A warm SoC reset leaves the card/controller in a state where commands work but
data transfers do not. A full power removal is needed to reset the card. This
is the hardware/power-state behaviour described in the hydrogen18 blog.

**2. The software reset paths on this firmware are not usable.**
- OpenSBI 1.3 does not provide the SBI SRST reboot service for K1. Proper SBI
  reboot support for K1 was posted in 2026 but is not in this firmware.
- The vendor kernel’s PMIC restart path hangs on this board. The kernel patch
  that disables interrupts and stops other CPUs before the restart (discussed
  on the Linux RISC-V mailing list) is not in Armbian 6.18.55.
- The `k1x_wdt` watchdog driver still declares a global `spinlock_t
  reboot_lock` and never initializes it (only `info->wdt_lock` is initialized).
  That is the same kind of bug the blog found in the older vendor kernel.
- The device tree has `spa,wdt-disabled` but **not**
  `spa,wdt-enable-restart-handler`, so the watchdog is not registered as the
  system restart handler. `reboot` therefore uses the hanging PMIC path.
- The hardware watchdog can reset the SoC, but that is still a warm reset: it
  does not power-cycle the SD card. Setting `RebootWatchdogSec` in systemd
  makes the board reset, but it lands in U-Boot with the same unreadable card.

### What works instead

- **`poweroff` + power button.** Linux `poweroff` cuts the rails (the red LED
  turns off). Pressing the button afterwards is a true cold boot. This is what
  the 9/9 cold-boot test used.
- **A smart plug or USB relay.** `poweroff`, then cut and restore external
  power remotely. This is the practical remote-server solution.
- **U-Boot `poweroff` is not a substitute.** It halts but does not cut the
  rails; the red LED stays on and the card remains wedged.

### Possible future fixes

These are ideas, not tested solutions:

1. **Power-cycle the SD card’s VMMC rail during shutdown.** The regulator
   summary shows `dcdc4` is dedicated to `d4280000.sdh-vmmc` (the SD card’s
   3.3 V rail) and `ldo1` to its I/O rail. A `systemd-shutdown` hook could
   disable those rails after the root filesystem is unmounted, so the next
   boot sees a freshly powered card. This must be done only after unmounting
   the root filesystem; do not toggle it while the system is running.
2. **kexec.** Boot a new kernel without a hardware reset, if the kernel
   supports kexec on this platform. The card keeps its working state, but
   peripherals may not reinitialize cleanly.
3. **Newer OpenSBI/U-Boot** with the 2026 K1 reboot support. This is a firmware
   change, it is riskier, and vendor U-Boot/upstream OpenSBI are not
   drop-in compatible out of the box.

Until one of those is proven, treat `reboot` as unsupported on this board.

---

## 7. All issues diagnosed

| Issue | Cause | Status |
|---|---|---|
| Boot stops at `(initramfs)` / “No init found” | `init-bottom/udev` aborts on `udevadm settle` under `set -e`, so `/dev` is never moved | **Fixed** |
| 3–4 minute boot | Three udev waits, each hitting its timeout | **Tuned** to 3 s; 38.7 s total |
| `reboot` hangs / lands at U-Boot `=>` | Warm reset leaves the SD card unable to do data reads | **Not fixed**; use `poweroff` |
| Button power-on sometimes fails | The card can stay wedged after a short power cycle | **Mitigated** by unplugging 5 min; root cause is the hardware state |
| U-Boot `bad CRC, using default environment` | The U-Boot environment in SPI NOR is invalid/empty | Not boot-critical here; `saveenv` can fix it |
| `MAC mapping file path not set in environment` | U-Boot environment feature not configured | Not boot-critical; check MAC stability if you rely on DHCP reservations |
| `spa,wdt-enable-restart-handler` missing | The DTB does not enable the watchdog restart handler | Not fixed; part of the reboot limitation |
| `k1x_wdt` `reboot_lock` uninitialized | Vendor driver bug carried into Armbian 6.18.55 | Not fixed; kernel patch needed |
| OpenSBI 1.3 | No SBI SRST reboot service for K1 | Not fixed; firmware upgrade needed |
| Root filesystem 90% full | Long-term usage | Maintenance, not boot-critical |
| `dnscrypt-proxy-resolvconf.service` failed | Pre-existing service configuration | Unrelated to boot |
| HDMI HPD / display initialization errors | No HDMI monitor / display probe | Cosmetic for a headless server |
| `v4l2_open` warnings, `dhd`/`btsdio` probe errors | Camera/Wi-Fi/Bluetooth drivers on this image | Noisy but unrelated to the boot failure |

The three `Timed out while waiting for udev queue to empty` lines still appear
in the serial log after the fix. They are expected on this hardware and are now
harmless.

---

## 8. Verification

After the fix and the 3-second tuning:

- **9/9 clean cold boots succeeded**: 7 in the requested series, plus the
  10 s and 3 s validation boots (Linux `poweroff`, red LED off, power button).
- Final boot: **38.677 s** total (`systemd-analyze`: kernel 14.740 s +
  userspace 23.937 s).
- SSH was available about **38 s** after pressing the button.
- Exactly one `systemd-udevd` process.
- No MMC or filesystem errors in `dmesg`.
- The serial log ends at `OrangePI login:`.

The first successful boot after the fix still showed a duplicate udevd because
I had left executable backup files in `scripts/init-top/` and
`scripts/init-bottom/`. That was cleaned up; the 9/9 tests were done after the
cleanup and rebuild.

---

## 9. What you need

- **A serial console.** A 3.3 V USB-TTL adapter (CP2102, CH340, FT232, etc.)
  connected to GND, TX and RX. 115200 8N1. This is the single most useful tool;
  without it you are guessing.
- **`picocom`** (or `minicom`/`screen`). Example:
  `picocom -b 115200 --logfile boot.log /dev/ttyUSB0`.
- **A second computer** to read the serial log while you power-cycle the board.
- **Physical access to the power.** A cold boot requires unplugging power, and
  recovering a wedged card can take 5 minutes.
- **Patience.** The board can be stubborn. Do not assume a black HDMI screen
  means “no boot”; check serial.
- Optional: an SD card reader, in case you need to inspect or restore the card
  from another machine.

---

## 10. Reproducing from scratch

1. Connect serial, open `picocom -b 115200 /dev/ttyUSB0`.
2. Reproduce the failure and capture the log.
3. Confirm the root filesystem is healthy (`chroot /root /sbin/init --version`).
4. Confirm `ls /root/dev` is empty.
5. Patch the three initramfs scripts with the `sed` commands in
   [section 4](#4-the-exact-commands-and-changes).
6. `sudo update-initramfs -u -k "$(uname -r)"`.
7. Verify with `unmkinitramfs` and `grep`.
8. `sudo poweroff`; wait for the red LED to turn off; press the power button.
9. Check `systemd-analyze` and `pgrep -a systemd-udevd`.
10. If you want the faster boot, use `--timeout=3`; if your card is slow, use
    `5` or `10`.

Do not test with `reboot` on a remote board. You will end up at the U-Boot
prompt with an unreadable SD card.

---

## 11. Logs in this repository

All logs are sanitized: UUIDs, MAC addresses, LAN IPs and the username are
replaced with placeholders. They are provided so another person (or an AI) can
see the exact failure and compare it with their own board.

| File | What it shows |
|---|---|
| [`logs/01-original-stuck-boot.txt`](logs/01-original-stuck-boot.txt) | The original serial boot: SPL, U-Boot, kernel, initramfs, `run-init` failure, `(initramfs)` prompt |
| [`logs/02-initramfs-dmesg.txt`](logs/02-initramfs-dmesg.txt) | Full kernel `dmesg` from the stuck initramfs; MMC, PCIe, USB, driver probes |
| [`logs/03-first-successful-boot.log`](logs/03-first-successful-boot.log) | The first boot after the fix (includes the duplicate-udevd mistake) |
| [`logs/04-failed-warm-reboot-sd-wedge.log`](logs/04-failed-warm-reboot-sd-wedge.log) | A `reboot` test: systemd shutdown, U-Boot, SD read errors, `=>` prompt |
| [`logs/05-button-poweron-still-wedged.log`](logs/05-button-poweron-still-wedged.log) | A short button power cycle that did **not** reset the SD card |
| [`logs/06-uboot-retry-fail.log`](logs/06-uboot-retry-fail.log) | U-Boot retry: `mmc read` returns `0 blocks read: ERROR` |
| [`logs/07-cold-boot-series.log`](logs/07-cold-boot-series.log) | The cold-boot series (#1–#7), trimmed to boot-relevant lines |
| [`logs/08-final-38s-boot.log`](logs/08-final-38s-boot.log) | The final 3-second build: U-Boot → kernel → initramfs → login |
| [`logs/09-onboard-changes.log`](logs/09-onboard-changes.log) | The change log kept on the board during the session |
| [`logs/10-onboard-initramfs-build.log`](logs/10-onboard-initramfs-build.log) | The initramfs build/repack attempts, including the failed gzip assumption |
| [`logs/11-key-diagnosis-evidence.txt`](logs/11-key-diagnosis-evidence.txt) | Curated decisive outputs (rootfs healthy, `/root/dev` empty, udev timings, U-Boot errors, kernel driver audit) |

The raw `boot-tests.log` (about 600 KB) is not included; the trimmed series in
`07` keeps the boot boundaries, errors, login prompts and power-down events.

For AI agents, [`AGENTS.md`](AGENTS.md) contains the technical checklist, the
exact patches, the traps that were hit, and the safety rules.

---

## 12. References

- **hydrogen18 — “Trying out the OrangePi RV2 and fixing a kernel bug”**  
  <https://www.hydrogen18.com/blog/orange-pi-rv2-first-look-kernel-watchdog-bug.html>  
  The watchdog bug, reboot behaviour and the capacitor/power-state theory.
- **Armbian** — <https://www.armbian.com/>  
  The image and build framework used here.
- **Armbian kernel source** — <https://gitlab.com/jmontleon/kernel-ark>  
  Branch `fedora-6.18.y-riscv-k1.0`; watchdog driver:
  `drivers/watchdog/k1x_wdt.c`.
- **SpacemiT K1/K3 watchdog documentation** —  
  <https://aipaipai.wiki/en/spacemit/software/SDK/buildroot/k3_buildroot/device/peripheral_driver/23-WDT>  
  Explains `spa,wdt-disabled` and `spa,wdt-enable-restart-handler`.
- **OpenSBI K1 reboot support patch series (2026)** —  
  <https://lists.infradead.org/pipermail/opensbi/2026-April/009735.html>
- **Linux initramfs / early userspace documentation** —  
  <https://www.kernel.org/doc/html/latest/driver-api/early-userspace/early_userspace_support.html>
- **picocom** — the serial terminal used for every log in this repository.

---

## 13. Credits

- The author of this field report (anonymous in this repository).
- **DeepSeek V4.1 Flash 1017** (model running inside **OpenCode**) for the
  diagnosis and the fix, at a cost of about **US$0.35** in API usage.
- **Eric Urban (hydrogen18)** for the original RV2 watchdog/reboot write-up.
- The Armbian, Debian, Linux and SpacemiT communities whose code and
  documentation made the diagnosis possible.

If this saves your board, the best thing you can do is add your own serial log
and board revision to the issue tracker so the next person has more data.
