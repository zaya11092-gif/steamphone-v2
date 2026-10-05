#!/bin/bash
# SteamPhoneOS guest disk image builder.
#
# Runs on an ubuntu-latest GitHub Actions runner (or any Ubuntu host with
# Docker). Produces a bootable ARM64 Linux disk image that Steam Big Picture
# auto-starts in, using the same core recipe as the Android DroidDeck project:
# ARM64 userland + FEX-EMU for the x86_64 Steam client and games.
#
# Usage: sudo ./build-image.sh [version]
#
# Layout produced:
#   image/out/SteamPhoneOS-<version>-arm64.qcow2
#
# This script is expected to be iterated on in CI; see image/README.md.

set -euo pipefail

VERSION="${1:-0.2.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
WORK_DIR="$SCRIPT_DIR/work"
RAW_IMAGE="$WORK_DIR/droiddeckos.raw"
DISK_SIZE="14G"
BOOT_SIZE="512MiB"
# Ubuntu 24.04 LTS arm64: long support, modern mesa with llvmpipe + lavapipe,
# and debootstrap-friendly.
BASE_SUITE="noble"
MIRROR="http://ports.ubuntu.com/ubuntu-ports"
QEMU_SRC="https://github.com/Droid-Deck/DroidDeck/releases/download/fex-2609-r3"

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
command -v qemu-img >/dev/null || apt-get install -y qemu-utils
command -v sfdisk >/dev/null || apt-get install -y fdisk

mkdir -p "$OUT_DIR" "$WORK_DIR"

# NOTE: no qemu-user binfmt registration needed - the workflow runs on a
# native arm64 runner, so the arm64 container executes directly.

echo "==> Creating raw disk ($DISK_SIZE)"
rm -f "$RAW_IMAGE"
truncate -s "$DISK_SIZE" "$RAW_IMAGE"

echo "==> Partitioning (GPT: ESP + root)"
sfdisk "$RAW_IMAGE" <<EOF
label: gpt
unit: sectors
1 : size=$((512*2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=ESP
2 : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=root
EOF

echo "==> Preparing debootstrap rootfs (arm64 $BASE_SUITE) in a container"
# Everything guest-side happens inside the arm64 Ubuntu container so that
# package postinst scripts execute under qemu-user-static transparently.
# The finished container is committed to an image so its filesystem can be
# exported into the disk image below.
docker rm -f droiddeck-build >/dev/null 2>&1 || true
docker rmi droiddeck-rootfs:tmp >/dev/null 2>&1 || true
docker run --name droiddeck-build --privileged \
    -v "$SCRIPT_DIR":/droiddeck \
    -v "$WORK_DIR":/work \
    -e BASE_SUITE="$BASE_SUITE" \
    -e MIRROR="$MIRROR" \
    -e QEMU_SRC="$QEMU_SRC" \
    -e BUILD_MESA="${BUILD_MESA:-0}" \
    -e MESA_REF="${MESA_REF:-}" \
    --platform linux/arm64 \
    ubuntu:$BASE_SUITE \
    /bin/bash /droiddeck/chroot-build.sh
docker commit droiddeck-build droiddeck-rootfs:tmp
docker rm droiddeck-build

echo "==> Loop-mounting image partitions"
LOOPDEV=$(losetup --find --show -P "$RAW_IMAGE")
trap 'umount "$WORK_DIR/mnt/droiddeck" 2>/dev/null; umount -R "$WORK_DIR/mnt" 2>/dev/null || true; losetup -d "$LOOPDEV" 2>/dev/null || true' EXIT
mkfs.fat -F32 -n ESP "${LOOPDEV}p1"
mkfs.ext4 -L root "${LOOPDEV}p2"
mkdir -p "$WORK_DIR/mnt"
mount "${LOOPDEV}p2" "$WORK_DIR/mnt"
mkdir -p "$WORK_DIR/mnt/boot/efi"
mount "${LOOPDEV}p1" "$WORK_DIR/mnt/boot/efi"

echo "==> Importing container rootfs into the image"
# docker export works on containers only: create one from the committed image.
IMPORT_CID="$(docker create droiddeck-rootfs:tmp)"
docker export "$IMPORT_CID" | tar -C "$WORK_DIR/mnt" -xpf -
docker rm "$IMPORT_CID" >/dev/null

echo "==> Installing kernel + bootloader into the image (chroot via qemu)"
mount --bind /dev "$WORK_DIR/mnt/dev"
mount --bind /proc "$WORK_DIR/mnt/proc"
mount --bind /sys "$WORK_DIR/mnt/sys"
# The install script lives on the host; bind it into the chroot.
mkdir -p "$WORK_DIR/mnt/droiddeck"
mount --bind "$SCRIPT_DIR" "$WORK_DIR/mnt/droiddeck"
# DNS: the docker-exported rootfs has no usable resolv.conf; borrow the host's.
cp /etc/resolv.conf "$WORK_DIR/mnt/etc/resolv.conf"
cp /usr/bin/qemu-aarch64-static "$WORK_DIR/mnt/usr/bin/" 2>/dev/null || \
    apt-get install -y qemu-user-static && cp /usr/bin/qemu-aarch64-static "$WORK_DIR/mnt/usr/bin/"
chroot "$WORK_DIR/mnt" /bin/bash /droiddeck/image-install-kernel.sh
rm -f "$WORK_DIR/mnt/usr/bin/qemu-aarch64-static"
umount "$WORK_DIR/mnt/droiddeck"
umount "$WORK_DIR/mnt/dev" "$WORK_DIR/mnt/proc" "$WORK_DIR/mnt/sys"

echo "==> Syncing and detaching"
umount "$WORK_DIR/mnt/boot/efi" "$WORK_DIR/mnt"
losetup -d "$LOOPDEV"
trap - EXIT

echo "==> Converting to qcow2"
qemu-img convert -c -f raw -O qcow2 "$RAW_IMAGE" "$OUT_DIR/SteamPhoneOS-$VERSION-arm64.qcow2"
rm -f "$RAW_IMAGE"

echo "==> Done: $OUT_DIR/SteamPhoneOS-$VERSION-arm64.qcow2"
ls -lh "$OUT_DIR"
