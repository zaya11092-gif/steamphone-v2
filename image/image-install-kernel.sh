#!/bin/bash
# Runs chrooted inside the mounted disk image (under qemu-aarch64-static).
# Installs the kernel and UEFI bootloader; GRUB targets the ESP QEMU_EFI
# (shipped inside UTM's app bundle) will load.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing kernel + GRUB (arm64)"
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-generic grub-efi-arm64 grub2-common

echo "==> GRUB to ESP"
grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --boot-directory=/boot --no-nvram --removable || \
    grub-install --target=arm64-efi --efi-directory=/boot/efi --no-nvram

echo "==> GRUB defaults (fast, quiet boot)"
cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0"
GRUB_TERMINAL=console
EOF
update-grub

echo "==> kernel + bootloader installed"
