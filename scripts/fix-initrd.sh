#!/bin/sh
# Patch the initramfs udev hooks so a slow/stuck udev never aborts the boot.
# Run inside the board's rootfs via: chroot /root /bin/sh /var/tmp/fix-initrd.sh
# NOTE: this board's initrd.img is a RAW cpio archive (magic 070701), not gzip.
set -eu
K=6.18.55-current-spacemit
LOG=/var/tmp/fix-initrd.log
exec >>"$LOG" 2>&1
echo "===== START $(date -u) ====="
df -h / || true
echo -n "initrd magic: "
od -An -tx1 -N6 "/boot/initrd.img-$K"

SRC=/usr/share/initramfs-tools/scripts
for f in "$SRC/functions" "$SRC/init-top/udev" "$SRC/init-bottom/udev"; do
    [ -e "$f.pre-udevfix" ] || cp -a "$f" "$f.pre-udevfix"
done

# 1) functions: cap wait_for_udev at 20s and never fail
sed -i 's#udevadm settle ${1:+--timeout=$1}#udevadm settle --timeout="${1:-20}" || true#' "$SRC/functions"
# 2) init-top: cap default settle at 20s
sed -i 's#udevadm settle || true#udevadm settle --timeout=20 || true#' "$SRC/init-top/udev"
# 3) init-bottom: allow up to 180s, but never abort the hook on timeout
sed -i 's#udevadm settle --timeout=60#udevadm settle --timeout=180 || true#' "$SRC/init-bottom/udev"

echo "--- source scripts after patch ---"
grep -H 'udevadm settle' "$SRC/functions" "$SRC/init-top/udev" "$SRC/init-bottom/udev"

echo "--- extract current initrd (raw cpio) ---"
rm -rf /var/tmp/ird-old /var/tmp/ird-new
mkdir -p /var/tmp/ird-old
cd /var/tmp/ird-old
cpio -idm --quiet < "/boot/initrd.img-$K"
echo "extracted entries: $(find . | wc -l)"

echo "--- patch extracted initrd copy ---"
sed -i 's#udevadm settle ${1:+--timeout=$1}#udevadm settle --timeout="${1:-20}" || true#' scripts/functions
sed -i 's#udevadm settle || true#udevadm settle --timeout=20 || true#' scripts/init-top/udev
sed -i 's#udevadm settle --timeout=60#udevadm settle --timeout=180 || true#' scripts/init-bottom/udev
grep -H 'udevadm settle' scripts/functions scripts/init-top/udev scripts/init-bottom/udev

echo "--- repack (raw cpio) ---"
find . -print | cpio -o -H newc --quiet > /var/tmp/ird-new.img
ls -l /var/tmp/ird-new.img
od -An -tx1 -N6 /var/tmp/ird-new.img

echo "--- verify repack by extracting it again ---"
mkdir -p /var/tmp/ird-new
cd /var/tmp/ird-new
cpio -idm --quiet < /var/tmp/ird-new.img
echo "new entries: $(find . | wc -l)"
echo "--- diff old vs new tree (should be silent) ---"
diff -rq /var/tmp/ird-old /var/tmp/ird-new || true

echo "--- build uInitrd (keep original -C gzip header) ---"
mkimage -A riscv -O linux -T ramdisk -C gzip -n uInitrd -d /var/tmp/ird-new.img /var/tmp/uInitrd-new
ls -l /var/tmp/uInitrd-new
mkimage -l /var/tmp/uInitrd-new

echo "--- sha256 before install ---"
sha256sum "/boot/initrd.img-$K" "/boot/uInitrd-$K"

echo "--- install (backups first) ---"
[ -e "/boot/initrd.img-$K.pre-udevfix" ] || cp -a "/boot/initrd.img-$K" "/boot/initrd.img-$K.pre-udevfix"
[ -e "/boot/uInitrd-$K.pre-udevfix" ] || cp -a "/boot/uInitrd-$K" "/boot/uInitrd-$K.pre-udevfix"
cat /var/tmp/ird-new.img > "/boot/initrd.img-$K"
cat /var/tmp/uInitrd-new > "/boot/uInitrd-$K"
sync

echo "--- sha256 after install ---"
sha256sum "/boot/initrd.img-$K" "/boot/uInitrd-$K"
ls -l "/boot/initrd.img-$K" "/boot/uInitrd-$K" /boot/uInitrd
mkimage -l "/boot/uInitrd-$K"
echo "===== ALL_OK $(date -u) ====="
