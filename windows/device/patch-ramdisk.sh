#!/system/bin/sh
set -e
cd /data/local/tmp/magiskpatch
export KEEPVERITY=true KEEPFORCEENCRYPT=true RECOVERYMODE=false VENDORBOOT=false
PREINITDEVICE="${PREINITDEVICE:-}"
cp -f ramdisk.img ramdisk.img.work
# Keep this banner: it names the codec, so the second decompress-to-/dev/null
# that used to exist purely to re-scrape it is unnecessary.
./magiskboot decompress ramdisk.img.work ramdisk.cpio 2>&1 | tee /data/local/tmp/magiskpatch/decompress.log
./magiskboot compress=xz magisk magisk.xz
./magiskboot compress=xz stub.apk stub.xz
./magiskboot compress=xz init-ld init-ld.xz
{ echo "KEEPVERITY=$KEEPVERITY"; echo "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT"
  echo "RECOVERYMODE=$RECOVERYMODE"; echo "VENDORBOOT=$VENDORBOOT"
  # WITHOUT a preinit device Magisk has nowhere persistent to stage module data:
  # "mount: preinit dir not found" every boot, module files as ZERO-BYTE files,
  # /data/adb/modules wiped at the next boot. Resolved on the host.
  [ -n "$PREINITDEVICE" ] && echo "PREINITDEVICE=$PREINITDEVICE"; } > config
cp -af ramdisk.cpio ramdisk.cpio.orig
./magiskboot cpio ramdisk.cpio \
  "add 0750 init magiskinit" \
  "mkdir 0750 overlay.d" \
  "mkdir 0750 overlay.d/sbin" \
  "add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
  "add 0644 overlay.d/sbin/stub.xz stub.xz" \
  "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
  "patch" "backup ramdisk.cpio.orig" "mkdir 000 .backup" \
  "add 000 .backup/.magisk config"
FMT=$(sed -n 's/.*Detected format: \[*\([a-z0-9_]*\).*/\1/p' /data/local/tmp/magiskpatch/decompress.log | head -1)
[ -n "$FMT" ] || FMT=lz4_legacy
echo "codec: $FMT"
rm -f ramdiskpatched.img
./magiskboot compress=$FMT ramdisk.cpio ramdiskpatched.img
ls -la ramdiskpatched.img
