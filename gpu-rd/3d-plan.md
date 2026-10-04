# 3D acceleration track — execution plan (steamphone-v2)

Outcome of the v2 discussion. Goal: guest-submitted *draw commands* (not
finished pixels) rendered by the iPhone GPU. The chain:

```
game → Wine/Proton → DXVK → guest Vulkan (Mesa gfxstream driver)
     → virtio-gpu 3D context → our QEMU fork (utmapp v10.0.12-utm + patches)
     → gfxstream host renderer → MoltenVK → Metal → Apple GPU
```

## Work packages, what "done" means, and what ships where

### WP1 — MoltenVK on iOS (the G0 checklist, made runnable)
- CI builds MoltenVK (KhronosGroup/MoltenVK) as a static xcframework for
  `ios-arm64` and publishes it as an artifact.
- `scripts/link_moltenvk.py` injects the framework into the Xcode project
  (link-only, no embed — static build).
- `SPGBVulkanProbe.swift` (guarded by `#if canImport(Vulkan)`) creates a
  Vulkan instance/device/queue on-device; the GPU Bridge diagnostics screen
  reports the result. App builds without MoltenVK present simply show the
  probe as unavailable.
- **Done** = probe reports a Vulkan 1.x device name from Apple's GPU.

### WP2 — Guest driver: Mesa with gfxstream for aarch64
- `image/build-mesa.sh` builds Mesa (pinned) with the gfxstream guest
  components for the SteamPhoneOS image; wired into `chroot-build.sh` behind
  `BUILD_MESA=1` (opt-in while iterating).
- **Done** = guest `vulkaninfo` sees a gfxstream device through virtio-gpu.
- Honest note: the exact meson option set for the gfxstream guest driver is
  one of the known iteration points (see script header); expect CI
  round-trips to pin it.

### WP3 — gfxstream host renderer on iOS (the big one, first-ever attempt)
- CI spike job fetches google/gfxstream at a pin and attempts an iOS-device
  static-library build of the host renderer (continue-on-error: the job's
  success/failure IS the G1.5 go/no-go data).
- **Done** = compiles for ios-arm64; then wire it as the virtio-gpu backend
  instead of (eventually in front of) the SPGB 2D path.

### WP4 — QEMU fork: virtio-gpu 3D contexts
- `gpu-rd/qemu-side/build-fork.sh` downloads the pinned utmapp tarball
  (v10.0.12-utm), applies UTM's qemu patch + our 3D-contexts patch, and
  configures/builds the display layer as a spike. Production
  `build_dependencies.sh` keeps pointing at stock until the patch is proven.
- **Done** = patched QEMU compiles and the SPGB device registers a 3D
  capset; then flip `QEMU_SRC` in `patches/sources` to the fork.

### WP5 — Presentation and threading
- IOSurface-backed MTLTexture shared between QEMU present path and
  CAMetalLayer (zero-copy swapchain); encode on a dedicated queue,
  present on vsync. Extends SPGBHostRenderer's existing boundary.

## Sequencing
WP1 (days) → WP2 (days–weeks) → WP4 spike (weeks) → WP3 spike (the risk
gate) → WP2+WP3+WP4 integration → perf bar (G3: in-guest baseline ≥30 fps).
Streaming remains the full-speed path for heavy titles regardless: TCG CPU
emulation cannot be lifted on stock iOS (no Hypervisor entitlement).

---

## Discovery update (2026-10-03): the rutabaga device is already in the tree

Inspecting the pinned utmapp/QEMU v10.0.12-utm source changed WP4's shape:

- `include/hw/virtio/virtio-gpu.h` declares the full **`VirtIOGPURutabaga`**
  device (`virtio-gpu-rutabaga-device`) — crosvm's paravirt-GPU framework,
  the layer gfxstream plugs into.
- `hw/display/meson.build` compiles `virtio-gpu-rutabaga.c` (and the PCI
  variant) **only when meson finds the `rutabaga` dependency** — a Rust
  crate UTM never builds (their iOS pipeline has no Rust toolchain). The
  device is dormant in every UTM iOS build today.

So WP4 is no longer "port AOSP's virtio-gpu work" — it is "build the
rutabaga crate and let QEMU's own meson light the device up":

1. `gpu-rd/qemu-side/build-rutabaga.sh` — cargo cross-build (iOS target or
   native) + cbindgen headers + a `rutabaga.pc` for pkg-config.
2. `gpu-rd/qemu-side/build-fork.sh` — spike: pinned tarball + UTM's qemu
   patch + native rutabaga + configure → does `config-all-devices.mak`
   select `virtio-gpu-rutabaga`, does it link.
3. When the spike passes: add the iOS rutabaga build to
   `scripts/build_dependencies.sh`'s pipeline, flip `QEMU_SRC` if needed,
   and switch the VM's display device to `virtio-gpu-rutabaga-device` with
   gfxstream capsets.

Remaining hard problem, unchanged: the gfxstream **host renderer on iOS**
(WP3) — rutabaga is the bus, gfxstream is the engine that still has to be
ported onto MoltenVK/Metal. SPGB v1's Metal side remains the fallback 2D
bridge and the pattern the host port follows.

---

## Assembly status (2026-10-04): the missing layer is a pipeline

The chain is no longer hypothetical. What exists and runs in CI today:

| Layer | State | Where |
| --- | --- | --- |
| MoltenVK → Metal | **building** (xcframework artifact) | `gpu-rd/moltenvk/build.sh` |
| gfxstream host | macOS control **green**; iOS leg porting (libproc + mac.mm stubs landed; compiles against MoltenVK headers now) | `gpu-rd/gfxstream-host/` |
| gfxstream_backend.pc | **generated** by the iOS/macOS legs (consumed by rutabaga's meson) | vulkan-track job |
| rutabaga_gfx → virtio-gpu-rutabaga | **GATE PASSED** (device objects compiled+linked into QEMU libcommon.a) | `gpu-rd/qemu-side/` |
| opt-in 3D engine build | **new job**: RUTABAGA_TRACK=1 sysroot + `SteamPhone-3D-experimental.ipa` (SPGB_SKIP_GFXSTREAM=true first — plumbing before backend) | vulkan-track `build-app-3d` |
| guest Mesa | building with `-Dvulkan-drivers=swrast,gfxstream-experimental` (option names pinned empirically) | `image/build-mesa.sh` |

## What "usable and playable" means, concretely

1. **UI usable** (near): paravirt 2D+UI accel — Steam/WebKit draws through the
   guest GL stack onto the Apple GPU. Requires: rutabaga in the shipped QEMU
   (plumbing milestone now building) + gfxstream GLES guest path.
2. **Older/light games playable** (mid): guest Vulkan via gfxstream → DXVK in
   Wine. Needs the full chain above + the gfxstream iOS port finished (WP3).
3. **Modern games**: stay streaming-only. Honest physics: even with perfect
   GPU accel, game logic runs under TCG (no Hypervisor on iOS) *and* x86 game
   code needs FEX→ARM64 translation *inside* the VM — double translation.
   GPU accel removes the renderer bottleneck, not the CPU one.
