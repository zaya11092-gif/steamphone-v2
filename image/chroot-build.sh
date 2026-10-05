#!/bin/bash
# Runs INSIDE the arm64 Ubuntu container (see build-image.sh).
# Builds the SteamPhoneOS userspace: mesa (software GL/Vulkan), FEX-EMU with
# host thunks, the x86_64 Steam client, cage compositor, PipeWire audio, and
# the autologin service that boots straight into Steam Big Picture.
set -euo pipefail

BASE_SUITE="${BASE_SUITE:-noble}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
QEMU_SRC="${QEMU_SRC:-https://github.com/Droid-Deck/DroidDeck/releases/download/fex-2609-r3}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# python3-* package postinsts are flaky under qemu-user (they abort
# intermittently, cascading through dpkg). Retry with an intervening
# dpkg --configure -a, which usually unblocks the next attempt.
apt_install_retry() {
    for attempt in 1 2 3; do
        if apt-get install -y --no-install-recommends "$@"; then
            return 0
        fi
        echo "==> apt install failed (attempt $attempt); configuring pending packages and retrying"
        dpkg --configure -a || true
        apt-get -f install -y || true
    done
    return 1
}

echo "==> Base packages"
apt-get update
apt_install_retry \
    ca-certificates curl gnupg xz-utils zstd ca-certificates \
    mesa-utils libgl1-mesa-dri mesa-vulkan-drivers vulkan-tools \
    cage seatd xterm fonts-dejavu-core \
    pipewire pipewire-audio wireplumber libspa-0.2-modules \
    dbus systemd-sysv network-manager \
    polkitd pkexec sudo adduser

# Optional: only needed for the FEX PPA fallback. Its python3-* dependency
# postinsts are flaky under qemu-user, so it must not fail the build.
apt-get install -y --no-install-recommends software-properties-common || {
    echo "WARNING: software-properties-common failed under qemu; continuing without PPA support"
    dpkg --configure -a || true
}

echo "==> FEX-EMU (x86_64 emulation, the DroidDeck recipe)"
# Preferred: the FEX builds DroidDeck ships (with host thunks for
# Vulkan/GL/EGL/DRM/Wayland/ALSA). Fallback: Ubuntu PPA.
FEX_TARBALL_URL="$QEMU_SRC"  # directory-style; resolved below
if curl -fsSL -o /tmp/fex.tar.xz \
    "$(curl -fsSL "https://api.github.com/repos/Droid-Deck/DroidDeck/releases" \
      | grep -o '"browser_download_url": *"[^"]*fex[^"]*\(tar\.xz\|tar\.zst\)"' \
      | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')" 2>/dev/null; then
    mkdir -p /opt/fex
    tar -xf /tmp/fex.tar.xz -C /opt/fex --strip-components=1
    ln -sf /opt/fex/bin/FEXInterpreter /usr/local/bin/FEXInterpreter
    ln -sf /opt/fex/bin/FEXRootFSFetcher /usr/local/bin/FEXRootFSFetcher 2>/dev/null || true
else
    echo "   (falling back to FEX PPA)"
    add-apt-repository -y ppa:fex-emu/fex || apt-get install -y fex-emu || \
        echo "WARNING: FEX install failed; Steam will not run until installed manually"
fi

echo "==> Steam client (x86_64, extracted under /opt)"
mkdir -p /opt/steam
curl -fsSL -o /tmp/steam.deb "https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb"
dpkg -x /tmp/steam.deb /opt/steam
# Steam libraries end up at /opt/steam/usr/lib/steam/...; wrapper below runs
# the bootstrap binary under FEX.

echo "==> FEX x86_64 rootfs images (needed by FEXInterpreter)"
mkdir -p /usr/share/fex-emu/Rootfs
if [ -x /usr/local/bin/FEXRootFSFetcher ]; then
    FEXRootFSFetcher --extract-current || true
fi
# TODO(ci-iteration): the DroidDeck runtime already ships tuned rootfs images;
# fetch and stage them here if FEXRootFSFetcher is unavailable.

echo "==> droiddeck user"
adduser --disabled-password --gecos "DroidDeck" droiddeck
echo 'droiddeck ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/droiddeck
usermod -aG video,render,input,audio droiddeck

echo "==> Steam wrapper (Big Picture under FEX)"
mkdir -p /usr/local/bin
cat > /usr/local/bin/steam <<'EOF'
#!/bin/bash
# SteamPhoneOS steam wrapper: x86_64 Steam under FEX-EMU.
export FEX_ENABLE_THUNKS=1
# Steam wants a writable HOME with its bootstrap already present.
export HOME=${HOME:-/home/droiddeck}
mkdir -p "$HOME/.steam" "$HOME/.local/share/Steam"
exec FEXInterpreter /opt/steam/usr/lib/steam/bin_steam.sh -tenfoot "$@"
EOF
chmod +x /usr/local/bin/steam
# First run bootstraps into ~/.local/share/Steam; seed a launcher alias so the
# session service always finds `steam` even before bootstrap completes.
ln -sf /usr/local/bin/steam /usr/bin/steam

echo "==> Autologin + cage session (boots into Big Picture)"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin droiddeck --noclear %I $TERM
Type=simple
EOF

cat > /home/droiddeck/.profile <<'EOF'
# SteamPhoneOS session: start cage compositor running Steam Big Picture.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$DROIDDECK_SESSION" ]; then
    export DROIDDECK_SESSION=1
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export WLR_RENDERER=pixman            # software rendering: no GPU on iOS
    export WLR_LIBINPUT_NO_DEVICES=1      # input arrives via virtio only
    export PIPEWIRE_RUNTIME_DIR="$XDG_RUNTIME_DIR"
    # Steam UI legibility at VM speed: fixed 1280x720 output.
    exec cage -d -m last -- steam -tenfoot
fi
EOF
chown droiddeck:droiddeck /home/droiddeck/.profile

# PipeWire user services start on demand via socket activation; ensure the
# user lingering is enabled so audio works before first login completes.
loginctl enable-linger droiddeck || true

echo "==> FEX config defaults"
mkdir -p /home/droiddeck/.fex-emu
cat > /home/droiddeck/.fex-emu/Config.json <<'EOF'
{
    "Config": {
        "RootFS": "/usr/share/fex-emu/Rootfs/",
        "ThunkConfig": {
            "EnableThunks": true
        },
        "Multiblock": true
    }
}
EOF
chown -R droiddeck:droiddeck /home/droiddeck/.fex-emu

echo "==> Mark container image for export"
# build-image.sh docker-exports this container's filesystem; the marker just
# documents intent.
touch /.droiddeckos

# 3D track (gpu-rd/3d-plan.md WP2): build Mesa with the gfxstream guest
# driver. Opt-in while the meson option set is being pinned in CI; enabled
# by passing -e BUILD_MESA=1 to the container in build-image.sh.
if [ "${BUILD_MESA:-0}" = "1" ] || [ "${BUILD_MESA:-}" = "true" ]; then
    echo "==> Building Mesa with gfxstream guest components (WP2)"
    /bin/bash /droiddeck/build-mesa.sh
else
    echo "==> Skipping Mesa gfxstream build (BUILD_MESA!=1); image ships llvmpipe/lavapipe only"
fi

echo "==> chroot build complete"
