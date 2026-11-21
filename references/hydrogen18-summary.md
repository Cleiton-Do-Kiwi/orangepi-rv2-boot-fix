# hydrogen18 blog — summary and link

The most useful external reference for the Orange Pi RV2’s watchdog and reboot
behaviour is Eric Urban’s (hydrogen18) write-up:

**Trying out the OrangePi RV2 and fixing a kernel bug**  
<https://www.hydrogen18.com/blog/orange-pi-rv2-first-look-kernel-watchdog-bug.html>

The article is not copied here (copyright); read it at the link above.

## What it covers

- The board requires active cooling; without it the behaviour becomes
  unpredictable.
- A vendor kernel watchdog driver (`CONFIG_KY_WATCHDOG` / `x1_wdt.c` in the
  6.6.63-ky kernel) had an uninitialized `reboot_lock`, producing
  `BUG: spinlock bad magic` on watchdog pings.
- The watchdog restart handler was only enabled when the device tree contained
  `spa,wdt-enable-restart-handler`; it was absent.
- `shutdown -r now` did not reliably reboot the board.
- Tripping the watchdog (opening `/dev/watchdog`, setting a timeout, and
  stopping the keep-alive) **did** reset the SoC reliably in their tests.
- The board has a power-state issue: after a warm reset it can get stuck at
  boot, and only leaving it unpowered for minutes (capacitor discharge)
  reliably recovers it.
- Their conclusion was that there is an unidentified board-level/power issue
  that software cannot fully fix.

## How it relates to this repository

The fix in this repository is **not** the watchdog patch from that article. It
is an initramfs fix for a different failure: the `init-bottom/udev` hook
aborting on `udevadm settle` under `set -e`, which prevents `/dev` from being
moved into the real root and makes `run-init` fail with “No init found”.

The reboot limitation described in this repository is consistent with the
article’s power-state/SD-card observations, and the kernel driver audit found
that the `k1x_wdt.c` driver in Armbian 6.18.55 still has the uninitialized
`reboot_lock` and the device tree still lacks the restart-handler property.

## Useful kernel/source links

- Armbian kernel source (the tree used to build 6.18.55-current-spacemit):  
  <https://gitlab.com/jmontleon/kernel-ark>  
  branch `fedora-6.18.y-riscv-k1.0`
- Watchdog driver: `drivers/watchdog/k1x_wdt.c` in that tree.
- SpacemiT K1/K3 watchdog documentation:  
  <https://aipaipai.wiki/en/spacemit/software/SDK/buildroot/k3_buildroot/device/peripheral_driver/23-WDT>
- OpenSBI K1 reboot support patch series (2026):  
  <https://lists.infradead.org/pipermail/opensbi/2026-April/009735.html>
