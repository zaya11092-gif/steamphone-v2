# SteamPhoneOS guest image

The disk image the DroidDeck iOS app downloads and boots: an ARM64 Ubuntu
userland with the x86_64 Steam client running under FEX-EMU — the same core
recipe the Android DroidDeck project uses, moved from proot-on-Android into a
fully emulated VM (the only way iOS permits any of this).

## What's inside

| Layer | Choice | Why |
| --- | --- | --- |
| Base | Ubuntu 24.04 LTS arm64 | Long support; modern Mesa; chroot-friendly packaging |
| Kernel | `linux-image-arm64` (generic) | Works on QEMU `virt`; GRUB on the ESP, booted via QEMU_EFI |
| Graphics | Mesa llvmpipe (GL) + lavapipe (Vulkan) | Software rendering — **there is no host GPU** under QEMU on iOS |
| Compositor | cage (wlroots) with `WLR_RENDERER=pixman` | Single-app kiosk compositor for Steam Big Picture |
| x86 emulation | FEX-EMU (+ host thunks) | Runs the x86_64 Steam client and games; same engine DroidDeck ships |
| Steam | official `steam.deb`, extracted to /opt, run via wrapper with `-tenfoot` | Big Picture is the Deck-style UI |
| Audio | PipeWire + WirePlumber | Talks to QEMU's audio device |
| Session | autologin tty1 → cage → steam -tenfoot | Boot straight to the Deck experience |

## Building

CI: `.github/workflows/build-image.yml` (ubuntu runner + qemu-user-static
binfmt via Docker). Locally on any Ubuntu box with Docker:

```bash
sudo ./image/build-image.sh 0.1.0
```

Output: `image/out/SteamPhoneOS-<version>-arm64.qcow2`.

## Known iteration points (expected to need CI round-trips)

1. **FEX install path** — the script prefers the FEX builds DroidDeck
   publishes on their releases (thunks included) and falls back to the Ubuntu
   PPA. Asset naming may change; the GitHub-API lookup in `chroot-build.sh`
   may need adjusting.
2. **FEX x86_64 rootfs images** — FEXInterpreter needs rootfs images staged in
   `/usr/share/fex-emu/Rootfs/`. `FEXRootFSFetcher` may need network access
   tuning inside the container.
3. **Steam bootstrap** — first launch self-updates into `~/.local/share/Steam`;
   doing that once during image build (running steam headless briefly) would
   pre-seed it and save the user minutes of first-boot downloading.
4. **cage/pixman on virtio-gpu** — if cage fails to light up on the
   virtio-gpu scanout, try `WLR_RENDERER=gles2` (llvmpipe GL) or weston as
   fallback compositor.
5. **boot time** — GRUB_TIMEOUT=0 and quiet boot keep it tolerable; expect
   several minutes to a usable Steam UI under TCG anyway (JIT edition).

## Sizing

The 14 GiB sparse image compresses to roughly 3–5 GiB as qcow2. The app
downloads it resumable and imports it into the VM bundle on first launch.
