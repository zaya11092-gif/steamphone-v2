# SteamPhone (steamphone-v2)

SteamOS-style gaming on iPhone — **v2 of the DroidDeck iOS port**, adding the
**SteamPhone GPU Bridge (SPGB)**: a real QEMU→Metal translation layer for the
local virtual machine, with an on-device harness proving the Metal side
executes the protocol.

> Unofficial, GPL-3.0, not affiliated with Valve or Droid-Deck. v1 lineage:
> this repo carries the full v1 history (custom launcher, guest image
> builder, Moonlight streaming skeleton, CI) and rebrands the user-facing app
> to **SteamPhone** (`com.steamphone.*`), version 0.2.0.

## What v2 adds: the QEMU→Metal translator

iOS apps may only touch the GPU through Metal. v1's local VM was
software-rendered for that reason. v2 introduces the translation pipeline
with explicit gates (full audit in `gpu-rd/G0-audit.md`):

```
guest Mesa driver ──virtqueue──▶ virtio-gpu (QEMU, in-process)
                                     │  G2: spgb-backend.c packs SPGB bytes
                                     ▼
                        spgb_host_execute(stream)
                                     │
                                     ▼
              SPGBHostRenderer — Metal encoders (G1: shipped, testable)
```

Because UTM's engine runs QEMU **inside the app process**, the boundary is a
plain C call — no IPC, no shared memory, no kernel interfaces.

| Piece | Status | Where |
| --- | --- | --- |
| Wire protocol v1 (frozen, little-endian, 10 opcodes) | shipped | `Platform/DroidDeck/GPUBridge/SPGBProtocol.h` |
| Metal translator core (resources/uploads/clear/quads/present) | shipped | `SPGBHostRenderer.swift` |
| Guest-side byte-exact command generator | shipped | `SPGBGuestSimulator.swift` |
| On-device harness with gate checklist + FPS | shipped | `GPUBridgeDiagnosticsView.swift` (launcher menu → *GPU Bridge diagnostics (G1)*) |
| QEMU virtio-gpu backend scaffold | G2 scaffold | `gpu-rd/qemu-side/spgb-backend.c` (+ integration map) |
| Guest Mesa winsys speaking SPGB | G2 work item | — |

**Honest scope:** SPGB v1 is a 2D compositing protocol — the layer Steam's UI
needs first. It is not yet GPU acceleration for games: that requires G2
(QEMU wiring + guest Mesa driver + 3D protocol extensions) and passing the
G3 performance bar. Until then, local gaming stays software-rendered and
**streaming remains the full-speed path** (M4, moonlight-common-c vendored).

## Everything inherited from v1 (still here)

- Custom Deck-style launcher (`Platform/DroidDeck/`) with resumable guest
  image download, VM resource tuning, About/licenses.
- SteamPhoneOS guest image builder (`image/`): Ubuntu 24.04 arm64 + FEX-EMU
  + Steam Big Picture under cage + PipeWire, built in CI.
- CI: `SteamPhone-JIT.ipa` + `SteamPhone-SE.ipa` artifacts on every push;
  guest image on tags.
- Performance expectations, sideloading guide, and attribution — unchanged
  from v1 (see sections below).

## What to honestly expect

| Mode | Experience |
| --- | --- |
| **Stream from your PC** | Full speed, 60 fps, modern games (M4). |
| **Local (JIT edition)** | Usable-slow Steam UI; lightweight games marginal. |
| **Local (SE edition)** | Slower fallback, zero extra install steps. |

Target devices: 8 GB-RAM iPhones (15 Pro+); 6 GB works with reduced memory.

## Sideload

Download `SteamPhone-JIT.ipa` / `SteamPhone-SE.ipa` from Releases (CI
artifacts until then); sideload with SideStore/AltStore/Sideloadly. Free
Apple IDs: 3-app limit, weekly refresh (SideStore refreshes on-device). JIT
edition: use SideStore/AltStore *Enable JIT* when launching — v2's
equivalent of Android DroidDeck's "restrict child processes" tweak.

## Building

Same as v1 — GitHub Actions on push produces the IPAs; local builds follow
UTM's `Documentation/iOSDevelopment.md` with
`./scripts/build_utm.sh -k iphoneos -s iOS` (and `-s iOS-SE`), packaged via
`./scripts/package.sh ipa`. The GPU Bridge needs no build changes: it is
registered in the Xcode project via `scripts/inject_droiddeck.py`.

## License & attribution

GPL-3.0 (`LICENSE`). Derivative work of UTM v5.0.6 (Apache-2.0), QEMU
(GPLv2, via utmapp/QEMU), moonlight-common-c (GPL-3.0), and the Android
DroidDeck project (GPL-3.0). Internal target names retain UTM/DroidDeck
identities for fork stability; user-facing names are SteamPhone /
SteamPhoneOS / steamphone-v2.
