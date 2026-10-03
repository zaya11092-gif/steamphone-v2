/*
 * SPGB — SteamPhone GPU Bridge, QEMU-side backend scaffold (gate G2)
 *
 * Copyright (C) 2026 steamphone-v2 contributors
 * GPLv2 (as a derivative of QEMU) when integrated into utmapp/QEMU; the
 * standalone file itself is GPL-3.0 with the project.
 *
 * This is the reference skeleton for wiring SPGB into QEMU's virtio-gpu
 * device. It is NOT yet part of the utmapp/QEMU tarball that
 * scripts/build_dependencies.sh downloads — integrating it is the G2 work
 * item. Kept here (compiled nowhere) so the integration contract is reviewable
 * alongside the host renderer it drives.
 *
 * Integration points in utmapp/QEMU (based on the upstream virtio-gpu
 * device and how AOSP's emulator QEMU wires gfxstream):
 *
 *   1. hw/display/virtio-gpu.c
 *      - virtio_gpu_context_create(): when the guest opens a context with
 *        ctx->ctx_flags carrying SPGB_CONTEXT_TYPE (a new
 *        VIRTIO_GPU_CAPSET_SPGB capset), route resource + command handlers
 *        to the spgb_* functions below instead of the default 2D path.
 *      - virtio_gpu_transfer_to_host_2d / resource_flush: forward as
 *        SPGB_CMD_TRANSFER_2D / SPGB_CMD_PRESENT into spgb_execute().
 *
 *   2. hw/display/virtio-gpu-pci.c — no changes (device metadata only).
 *
 *   3. include/hw/virtio/virtio-gpu.h — add the capset id and the
 *      spgb backend struct to VirtIOGPU state.
 *
 *   4. ui/Makefile.objs / meson.build — compile spgb-backend.c into the
 *      QEMU library (it is host-side code, like ui/console.c).
 *
 *   5. Host renderer ABI: on iOS the app process IS the QEMU process, so
 *      spgb_host_execute() resolves to the Swift SPGBHostRenderer.execute
 *      via a small C shim (see SPGBProtocol.h entry points). The shim is
 *      the ONLY boundary; no IPC, no shared memory setup needed.
 *
 * Guest side (separate repo work, tracked in gpu-rd/):
 *   - Mesa needs a driver that speaks SPGB over virtio-gpu. The pragmatic
 *     route is forking Mesa's virtio-gpu/virgl gallium winsys to emit the
 *     SPGB capset and command encoding (Mesa's existing virtio transport
 *     already handles the virtqueue plumbing).
 *   - Until that exists, the iOS app's SPGBGuestSimulator stands in as the
 *     command source for validation.
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "hw/virtio/virtio-gpu.h"
#include "spgb-backend.h"
#include "spgb-protocol.h" /* canonical copy: Platform/GPUBridge/SPGBProtocol.h */

/* Capset id requested from the guest; registered in
 * virtio_gpu_fill_ctx_capsets() during G2 integration. */
#define VIRTIO_GPU_CAPSET_SPGB 0x53504742 /* 'SPGB' */

struct spgb_backend {
    spgb_host_t host;          /* Metal renderer handle (iOS app side) */
    uint32_t resource_map[VIRTIO_GPU_MAX_RES]; /* guest handle -> spgb id */
};

/* Command packing helpers mirroring SPGBProtocol.h layouts. */

static void spgb_put_u32(uint8_t **cursor, uint32_t value)
{
    memcpy(*cursor, &value, sizeof(value));
    *cursor += sizeof(value);
}

static void spgb_put_f32(uint8_t **cursor, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    spgb_put_u32(cursor, bits);
}

static size_t spgb_cmd_header(uint8_t **cursor, uint32_t opcode, uint32_t payload_size)
{
    spgb_put_u32(cursor, opcode);
    spgb_put_u32(cursor, payload_size);
    return sizeof(struct spgb_cmd_header) + payload_size;
}

/* Backend entry points called from virtio-gpu.c. */

int spgb_backend_init(VirtIOGPU *g)
{
    struct spgb_backend *spgb = g_new0(struct spgb_backend, 1);

    /* The layer/view is owned by the embedding app; the host shim finds it
     * through the display change listener registered by QEMU's iOS port. */
    if (spgb_host_create(&spgb->host, NULL) != 0) {
        g_free(spgb);
        return -1;
    }
    g->spgb = spgb;
    return 0;
}

void spgb_backend_fini(VirtIOGPU *g)
{
    struct spgb_backend *spgb = g->spgb;

    if (!spgb) {
        return;
    }
    spgb_host_destroy(spgb->host);
    g_free(spgb);
    g->spgb = NULL;
}

/* virtio_gpu_resource_create_2d() override for SPGB contexts. */
int spgb_resource_create(VirtIOGPU *g, struct virtio_gpu_ctrl_command *cmd,
                         uint32_t resource_id, uint32_t format,
                         uint32_t width, uint32_t height)
{
    struct spgb_backend *spgb = g->spgb;
    uint8_t buf[sizeof(struct spgb_cmd_header) + sizeof(struct spgb_resource_create)];
    uint8_t *cursor = buf;
    uint32_t spgb_format = SPGB_FMT_RGBA8_UNORM; /* map virtio_gpu formats here */

    if (!spgb || resource_id >= VIRTIO_GPU_MAX_RES) {
        return -1;
    }
    spgb_cmd_header(&cursor, SPGB_CMD_RESOURCE_CREATE, sizeof(struct spgb_resource_create));
    spgb_put_u32(&cursor, resource_id);
    spgb_put_u32(&cursor, width);
    spgb_put_u32(&cursor, height);
    spgb_put_u32(&cursor, spgb_format);
    spgb->resource_map[resource_id] = resource_id; /* 1:1 for now */

    return spgb_host_execute(spgb->host, buf, sizeof(buf));
}

/* virtio_gpu_transfer_to_host_2d() override: the guest's backing storage
 * (already mapped by QEMU) is inlined into the SPGB stream. */
int spgb_transfer_2d(VirtIOGPU *g, struct virtio_gpu_ctrl_command *cmd,
                     uint32_t resource_id, uint32_t x, uint32_t y,
                     uint32_t w, uint32_t h, uint32_t stride,
                     const void *pixels)
{
    struct spgb_backend *spgb = g->spgb;
    const size_t payload = sizeof(struct spgb_transfer_2d) + w * h * 4;
    uint8_t *buf = g_malloc(sizeof(struct spgb_cmd_header) + payload);
    uint8_t *cursor = buf;
    int ret;

    if (!spgb) {
        g_free(buf);
        return -1;
    }
    spgb_cmd_header(&cursor, SPGB_CMD_TRANSFER_2D, payload);
    spgb_put_u32(&cursor, resource_id);
    spgb_put_u32(&cursor, x);
    spgb_put_u32(&cursor, y);
    spgb_put_u32(&cursor, w);
    spgb_put_u32(&cursor, h);
    spgb_put_u32(&cursor, stride);
    memcpy(cursor, pixels, w * h * 4);

    ret = spgb_host_execute(spgb->host, buf, sizeof(struct spgb_cmd_header) + payload);
    g_free(buf);
    return ret;
}

/* virtio_gpu_resource_flush() maps to PRESENT + SUBMIT: the guest finished
 * a frame and wants the scanout updated. */
int spgb_resource_flush(VirtIOGPU *g, uint32_t resource_id)
{
    struct spgb_backend *spgb = g->spgb;
    uint8_t buf[sizeof(struct spgb_cmd_header) * 2 +
                sizeof(struct spgb_present) + sizeof(struct spgb_submit)];
    uint8_t *cursor = buf;

    if (!spgb) {
        return -1;
    }
    spgb_cmd_header(&cursor, SPGB_CMD_PRESENT, sizeof(struct spgb_present));
    spgb_put_u32(&cursor, resource_id);
    spgb_cmd_header(&cursor, SPGB_CMD_SUBMIT, sizeof(struct spgb_submit));
    spgb_put_u32(&cursor, 0);

    return spgb_host_execute(spgb->host, buf, sizeof(buf));
}
