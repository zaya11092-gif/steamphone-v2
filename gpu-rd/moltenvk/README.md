# MoltenVK bring-up (WP1 of gpu-rd/3d-plan.md)

Vulkan on iOS exists through exactly one production path: MoltenVK's
Vulkan-on-Metal translation. Everything 3D in this project eventually rides
on it — gfxstream's host renderer consumes Vulkan.

- `build.sh` — fetches MoltenVK at a pinned ref, builds the static iOS
  (device) framework, and stages a `Vulkan` module for Swift import.
- CI: `.github/workflows/vulkan-track.yml` job `build-moltenvk` runs this
  and publishes `MoltenVK.xcframework` + the module as an artifact.
- App wiring: `scripts/link_moltenvk.py` links the framework into the app
  targets (static, link-only). `SPGBVulkanProbe.swift` is compiled in
  permanently but activates only when `import Vulkan` resolves
  (`#if canImport(Vulkan)`), so builds without the framework stay green.
- On-device result surfaces in the GPU Bridge diagnostics screen.

## Why the probe matters

Before attempting gfxstream-on-iOS (WP3, the risk gate), we need the G0
facts from a real device, not documentation: does Vulkan initialize, which
apiVersion does MoltenVK expose, does a queue execute work. The probe answers
exactly those.
