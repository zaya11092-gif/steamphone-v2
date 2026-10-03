# SPGB QEMU-side integration (gate G2)

`spgb-backend.c` / `spgb-backend.h` are the reference scaffold for wiring the
SteamPhone GPU Bridge into utmapp/QEMU's `virtio-gpu` device. They compile
nowhere yet — G2 is the work item that changes that. The file's header
comment lists the five exact integration points in the QEMU tree.

## Why in-process is the good news

On iOS, UTM's engine runs QEMU as a static library *inside the app process*.
That means the "QEMU→Metal translator" needs **no IPC, no shared memory and
no kernel interfaces**: `virtio_gpu_resource_flush()` in the guest path can
call the Swift `SPGBHostRenderer.execute()` through a 3-function C shim:

```
guest Mesa driver ──virtqueue──▶ virtio-gpu (QEMU, in-process)
                                     │ spgb_resource_flush()
                                     ▼
                              spgb-backend.c  ──packs SPGB bytes──▶  spgb_host_execute()
                                                                        │
                                             SPGBHostRenderer (Metal) ◀─┘
```

## G2 checklist

1. Fork `utmapp/QEMU`, add `spgb-backend.c` (adjust to real `VirtIOGPU`
   structs), register the `VIRTIO_GPU_CAPSET_SPGB` capset.
2. Point `scripts/build_dependencies.sh`'s `QEMU_SRC` at the fork tarball.
3. C shim file in the app target exporting `spgb_host_create/execute/destroy`
   that forward to `SPGBHostRenderer` (a `@_cdecl` Swift shim or an ObjC++
   bridge — the latter is cleaner).
4. Guest: Mesa winsys fork emitting SPGB (tracked separately).
5. Validation: boot DroidDeckOS/SteamPhoneOS image, `vkcube`-class demo
   rendering through the bridge = G2 pass.

## G3 (the bar)

In-guest baseline scene ≥ 30 fps sustained through the bridge → fold into
the shipped image. Below bar → findings documented, streaming remains the
high-performance path (the plan's standing decision).
