#!/bin/bash
# build-minimal-alpine-rg353vs.sh - minimal flashable Alpine Linux image for Anbernic RG353VS (RK3566).
# boots to shell login on the LCD (tty1, needs a USB keyboard)
# debug: UART2 (ttyS2, 1500000 baud).
#
# Usage:  bash build-minimal-alpine-rg353vs.sh [out.img]
#
# ROCKNIX (mainline-based) supplies what only exists for this hardware: mainline U-Boot, kernel, and RG353VS device tree.
# Downloads ~1.4 GB ROCKNIX image unless ROCKNIX-RK3566*Generic.img[.gz] or $ROCKNIX_IMG supplied. Only KERNEL, DTB, and U-Boot are kept in cache.
# Downloads Alpine aarch64 minirootfs unless alpine-minirootfs-*-aarch64.tar.gz supplied
#
# ROCKNIX kernel has ROCKNIX's initramfs compiled in.
# It contains /init that assumes ROCKNIX system
# We set "rdinit=" to a file that does not exist to make the kernel skip that init and mount root= itself, but the kernel mounts the root on /root
# init/do_mounts.c and initramfs has no /root, so the mount fails with error -2 and the kernel
# panics. The root-mountpoint.cpio below is an initrd that contains only an empty /root directory.
#
# Env: ROCKNIX_TAG ("latest" or version e.g. "20260901")  ROCKNIX_IMG  ALPINE_TAR  ALPINE_BRANCH ("latest" or version e.g. "v3.24")  ALPINE_MIRROR ROOT_MB (512)  ROOT_PASSWORD (alpine)  HOSTNAME_ (rg353vs)  CACHE_DIR (./rg-cache)  WORKDIR (.)
# Host tools: curl sfdisk mtools dosfstools e2fsprogs openssl gzip tar (git for the GitHub fallback)
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,25p' "$0"; exit 0; }

OUT=${1:-alpine-rg353vs-bare.img}
ROCKNIX_TAG=${ROCKNIX_TAG:-20260901}  # set to desired version or "latest"
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.24} # set to desired version or "latest"
ROOT_MB=${ROOT_MB:-512}
ROOT_PASSWORD=${ROOT_PASSWORD:-alpine}
HOSTNAME_=${HOSTNAME_:-rg353vs}
ALPINE_TAR=${ALPINE_TAR:-}
CACHE=${CACHE_DIR:-$PWD/rg-cache}
mkdir -p "$CACHE"; CACHE=$(cd "$CACHE" && pwd)
export MTOOLS_SKIP_CHECK=1

for t in curl sfdisk mcopy mmd mkfs.vfat mke2fs openssl gzip tar; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t   (Debian/Ubuntu: apt install curl fdisk mtools dosfstools e2fsprogs openssl)"
done

BOOT_MB=64
BOOT_START=32768  # 16 MiB: same as ROCKNIX, leaves room for U-Boot
BOOT_SECTORS=$((BOOT_MB * 2048))
ROOT_START=$((BOOT_START + BOOT_SECTORS))
ROOT_SECTORS=$((ROOT_MB * 2048))
TOTAL_SECTORS=$((ROOT_START + ROOT_SECTORS + 2048))   # +1 MiB for backup GPT

W=$(mktemp -d -p "${WORKDIR:-$PWD}" .rg353vs-bare.XXXXXX)
trap 'rm -rf "$W"' EXIT

# ---- 1. ROCKNIX (U-Boot, kernel, dtb)
resolve_rocknix_tag() {
  if [ "$ROCKNIX_TAG" = latest ]; then
    local t
    t=$(curl -fsSL -m 30 https://api.github.com/repos/ROCKNIX/distribution/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$t" ] && ROCKNIX_TAG=$t || { echo "could not resolve the latest ROCKNIX release, using 20260901"; ROCKNIX_TAG=20260901; }
  fi
}

extract_rocknix_files() {
  # $1 = ROCKNIX image (.img or .img.gz), optional $2 = "delete" source
  local src=$1 img=$1 dst="$ROCKNIX_DIR.tmp" drop=${2:-}
  rm -rf "$dst"; mkdir -p "$dst"
  case "$src" in *.gz)
      img=$W/rocknix.img
      echo "unpacking $(basename "$src") (temporary, ~2.2 GB) ..."
      gzip -dc "$src" > "$img"
      [ "$drop" = delete ] && rm -f "$src" ;;
  esac
  local p1; p1=$(sfdisk -d "$img" | sed -n 's/.*start= *\([0-9]*\),.*/\1/p' | head -1)
  [ -n "$p1" ] || die "no partition table in $src (is it a ROCKNIX RK3566 image?)"
  [ "$(dd if="$img" bs=512 skip=64 count=1 2>/dev/null | head -c4)" = RKNS ] || die "$src has no Rockchip idbloader at sector 64"
  local fat="$img@@$((p1 * 512))"
  mcopy -n -i "$fat" ::KERNEL "$dst/KERNEL"
  mcopy -n -i "$fat" ::device_trees/rk3566-anbernic-rg353vs.dtb "$dst/rk3566-anbernic-rg353vs.dtb"
  dd if="$img" of="$dst/u-boot.bin" bs=512 skip=64 count=$((BOOT_START - 64)) status=none     # idbloader @ 64, u-boot.itb @ 16384
  [ "$img" = "$src" ] || rm -f "$img" # delete image to save space
  touch "$dst/.complete"; rm -rf "$ROCKNIX_DIR"; mv "$dst" "$ROCKNIX_DIR"
  echo "cached: $ROCKNIX_DIR"
}

ensure_rocknix() {
  resolve_rocknix_tag
  ROCKNIX_DIR=$CACHE/rocknix-$ROCKNIX_TAG
  [ -f "$ROCKNIX_DIR/.complete" ] && { echo "ROCKNIX $ROCKNIX_TAG files: cached ($ROCKNIX_DIR)"; return; }
  local src=${ROCKNIX_IMG:-}
  [ -n "$src" ] || src=$(ls -1 ./ROCKNIX-RK3566*Generic.img ./ROCKNIX-RK3566*Generic.img.gz 2>/dev/null | head -1 || true)
  if [ -z "$src" ]; then
    local url="https://github.com/ROCKNIX/distribution/releases/download/$ROCKNIX_TAG/ROCKNIX-RK3566.aarch64-$ROCKNIX_TAG-Generic.img.gz"
    mkdir -p "$CACHE/download"; src=$CACHE/download/$(basename "$url")
    say "downloading ROCKNIX $ROCKNIX_TAG (~1.4 GB; resumable; deleted after extraction)"
    curl -fL --retry 5 --retry-delay 3 -C - -o "$src" "$url" || die "download failed: $url"
    gzip -t "$src" || { rm -f "$src"; die "downloaded file is corrupt (deleted): rerun to retry"; }
    extract_rocknix_files "$src" delete
    rmdir "$CACHE/download" 2>/dev/null || true
  else
    say "extracting ROCKNIX files from $src"
    extract_rocknix_files "$src"
  fi
}

# ---- 2. Alpine minirootfs
MIRRORS="
https://dl-cdn.alpinelinux.org/alpine
https://mirror.leaseweb.com/alpine
https://mirrors.gigenet.com/alpinelinux
https://mirror.clarkson.edu/alpine
https://mirror.csclub.uwaterloo.ca/alpine
"

pick_mirror() {
  local m
  [ -n "${ALPINE_MIRROR:-}" ] && { echo "${ALPINE_MIRROR%/}"; return 0; }
  while read -r m; do
    case "$m" in ''|\#*) continue ;; esac
    m=${m%/}
    if curl -fsS -m 20 -r 0-0 -o /dev/null "$m/$ALPINE_BRANCH/main/aarch64/APKINDEX.tar.gz" 2>/dev/null; then
      echo "$m"; return 0
    fi
    echo "  mirror not usable: $m" >&2
  done <<< "$MIRRORS"
  return 1
}

fetch_alpine_tar() {
  [ -n "$ALPINE_TAR" ] && [ -f "$ALPINE_TAR" ] && return
  ALPINE_TAR=$(ls -1 ./alpine-minirootfs-*-aarch64.tar.gz "$CACHE"/alpine-minirootfs-*-aarch64.tar.gz 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$ALPINE_TAR" ] && { echo "Alpine minirootfs: $ALPINE_TAR"; return; }
  say "downloading the Alpine $ALPINE_BRANCH minirootfs"
  local m yaml name
  if m=$(pick_mirror 2>/dev/null); then
    yaml=$(curl -fsSL -m 30 "$m/$ALPINE_BRANCH/releases/aarch64/latest-releases.yaml" 2>/dev/null || true)
    name=$(echo "$yaml" | sed -n 's/^ *file: *\(alpine-minirootfs-[0-9.]*-aarch64\.tar\.gz\).*/\1/p' | head -1)
    if [ -n "$name" ] && curl -fL --retry 3 -o "$CACHE/$name" "$m/$ALPINE_BRANCH/releases/aarch64/$name" \
       && curl -fsSL "$m/$ALPINE_BRANCH/releases/aarch64/$name.sha256" 2>/dev/null | ( cd "$CACHE" && sha256sum -c - >/dev/null 2>&1 ); then
      ALPINE_TAR=$CACHE/$name; echo "downloaded $name from $m (sha256 OK)"; return
    fi
    rm -f "$CACHE/$name" 2>/dev/null; echo "mirror download failed, trying GitHub"
  fi
  command -v git >/dev/null || die "no mirror reachable and git is missing for the GitHub fallback: put alpine-minirootfs-*-aarch64.tar.gz in the current directory"
  local g=$W/docker-alpine
  git clone -q --depth 1 --branch "$ALPINE_BRANCH" https://github.com/alpinelinux/docker-alpine "$g" || die "cannot fetch the Alpine minirootfs from any source"
  name=$(basename "$(ls "$g"/aarch64/alpine-minirootfs-*-aarch64.tar.gz | head -1)")
  ( cd "$g" && grep " aarch64/$name\$" checksums.sha512 | sha512sum -c - >/dev/null ) || die "checksum mismatch for $name"
  cp "$g/aarch64/$name" "$CACHE/$name"; ALPINE_TAR=$CACHE/$name; echo "downloaded $name from GitHub (sha512 OK)"
}

say "inputs"
ensure_rocknix
fetch_alpine_tar

# ---- 3. partition table: GPT, p1 = FAT (boot), p2 = ext4 (root)
newuuid() { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
DISK_GUID=$(newuuid); BOOT_PARTUUID=$(newuuid); ROOT_PARTUUID=$(newuuid)
say "creating $OUT"
rm -f "$OUT"; truncate -s $((TOTAL_SECTORS * 512)) "$OUT"
sfdisk -q "$OUT" <<EOF
label: gpt
label-id: $DISK_GUID
unit: sectors
first-lba: 34

start=$BOOT_START, size=$BOOT_SECTORS, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=$BOOT_PARTUUID, name="BOOT"
start=$ROOT_START, size=$ROOT_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$ROOT_PARTUUID, name="root"
EOF
dd if="$ROCKNIX_DIR/u-boot.bin" of="$OUT" bs=512 seek=64 conv=notrunc status=none     # idbloader @ sector 64, u-boot.itb @ 16384

# ---- 4. boot partition: kernel, dtb, extlinux.conf and the initrd that provides /root (see the header)
say "building the boot partition"
cpio_entry() {  # name mode nlink : one entry of a minimal uncompressed "newc" cpio (the kernel only has the LZO decompressor)
  local name=$1 mode=$2 nlink=$3 nsz=$((${#1} + 1))
  printf '070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X' 1 "$mode" 0 0 "$nlink" 0 0 0 0 0 0 "$nsz" 0
  printf '%s\0' "$name"
  local pad=$(( (4 - (110 + nsz) % 4) % 4 )); [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero
  return 0
}
{ cpio_entry root 0x41C0 2; cpio_entry 'TRAILER!!!' 0 1; } > "$W/root-mountpoint.cpio"
cat > "$W/extlinux.conf" <<EOF
LABEL Alpine
  LINUX /KERNEL
  FDT /rk3566-anbernic-rg353vs.dtb
  INITRD /root-mountpoint.cpio
  APPEND root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rootwait rw rdinit=/no-embedded-initramfs init=/sbin/init console=ttyS2,1500000n8 console=tty0
EOF
truncate -s ${BOOT_MB}M "$W/p1.img"; mkfs.vfat -F 32 -n BOOT "$W/p1.img" >/dev/null
mmd   -i "$W/p1.img" ::extlinux
mcopy -i "$W/p1.img" "$ROCKNIX_DIR/KERNEL"                       ::KERNEL
mcopy -i "$W/p1.img" "$ROCKNIX_DIR/rk3566-anbernic-rg353vs.dtb"  ::rk3566-anbernic-rg353vs.dtb
mcopy -i "$W/p1.img" "$W/root-mountpoint.cpio"                   ::root-mountpoint.cpio
mcopy -i "$W/p1.img" "$W/extlinux.conf"                          ::extlinux/extlinux.conf
dd if="$W/p1.img" of="$OUT" bs=512 seek=$BOOT_START conv=notrunc status=none

# ---- 5. root filesystem: Alpine minirootfs + busybox init
say "building the Alpine root filesystem"
R=$W/root; mkdir -p "$R"
tar --numeric-owner -xpf "$ALPINE_TAR" -C "$R"
echo "$HOSTNAME_" > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost\n' "$HOSTNAME_" > "$R/etc/hosts"
echo "nameserver 9.9.9.9" > "$R/etc/resolv.conf"
date +%s > "$R/etc/build-epoch"
echo "/dev/root  /  ext4  rw,noatime  0 0" > "$R/etc/fstab"
HASH=$(openssl passwd -6 "$ROOT_PASSWORD"); sed -i "s|^root:[^:]*:|root:$HASH:|" "$R/etc/shadow"

cat > "$R/etc/inittab" <<'EOF'
# busybox init (the minirootfs has no OpenRC)
::sysinit:/etc/rc.sysinit
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
ttyS2::respawn:/sbin/getty -L 1500000 ttyS2 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/rc.shutdown
EOF
cat > "$R/etc/rc.sysinit" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
grep -q ' /dev ' /proc/mounts || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs -o nosuid,nodev          tmpfs /dev/shm
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /run
mount -t tmpfs -o nosuid,nodev          tmpfs /tmp
hostname -F /etc/hostname
ip link set lo up
# no battery-backed clock on the device: start from the build time instead of 1970
if [ "$(date +%Y)" -lt 2026 ] && [ -r /etc/build-epoch ]; then date -s "@$(cat /etc/build-epoch)" >/dev/null 2>&1; fi
echo "Alpine $(cat /etc/alpine-release) on $(uname -srm)" > /dev/console
EOF
cat > "$R/etc/rc.shutdown" <<'EOF'
#!/bin/sh
sync
umount -a -r 2>/dev/null
EOF
chmod 755 "$R/etc/rc.sysinit" "$R/etc/rc.shutdown"
printf 'Welcome to Alpine Linux on the Anbernic RG353VS (bare image: no packages, no network setup)\n\n' > "$R/etc/motd"

# ---- 6. write root partition, then compress the image
say "writing the ext4 root partition"
mke2fs -q -t ext4 -L root -d "$R" "$W/root.img" "${ROOT_MB}M"
dd if="$W/root.img" of="$OUT" bs=512 seek=$ROOT_START conv=notrunc,sparse status=none
say "compressing $OUT"
gzip -9 -f "$OUT" # -> $OUT.gz, removes the raw image
echo
echo "Done: $OUT.gz   (root password: $ROOT_PASSWORD)"
echo "Flash it to a microSD card in slot TF1:"
echo "  gunzip -c $OUT.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
