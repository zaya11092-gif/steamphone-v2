/*
 * SPGB — SteamPhone GPU Bridge wire protocol (v1)
 *
 * The contract between QEMU's virtio-gpu backend (guest side) and the
 * Metal host renderer (iOS side). QEMU runs in-process inside the app, so
 * the "transport" is a direct C call: the backend packs spgb commands into
 * a byte stream and calls spgb_execute(stream, len). The same byte layout
 * is what a G2 guest Mesa driver would emit over virtio-gpu, minus the
 * virtio framing.
 *
 * All values little-endian. Every command starts with spgb_cmd_header.
 * Payload structs are packed; pointers are passed out-of-band by the
 * caller (in-process), never serialized.
 *
 * This file is the single source of truth: Platform/GPUBridge/SPGBTypes.swift
 * mirrors it for the Swift host renderer and gpu-rd/qemu-side/spgb-backend.c
 * mirrors it for QEMU. Keep the three in sync.
 */

#ifndef SPGB_PROTOCOL_H
#define SPGB_PROTOCOL_H

#include <stdint.h>

#define SPGB_PROTOCOL_VERSION 1

/* Command opcodes */
enum {
    SPGB_CMD_NOP              = 0,
    SPGB_CMD_RESOURCE_CREATE  = 1,  /* allocate host-side texture        */
    SPGB_CMD_RESOURCE_DESTROY = 2,
    SPGB_CMD_TRANSFER_2D      = 3,  /* upload a 2D pixel region (inline) */
    SPGB_CMD_SET_TARGET       = 4,  /* bind resource as render target    */
    SPGB_CMD_CLEAR            = 5,  /* clear the current target          */
    SPGB_CMD_SET_TEXTURE      = 6,  /* bind resource to sampler slot     */
    SPGB_CMD_DRAW_QUAD        = 7,  /* textured 2D quad, pixel coords    */
    SPGB_CMD_PRESENT          = 8,  /* draw target to screen & present   */
    SPGB_CMD_SUBMIT           = 9,  /* end of batch, commit to GPU       */
};

/* Resource formats */
enum {
    SPGB_FMT_INVALID     = 0,
    SPGB_FMT_RGBA8_UNORM = 1,  /* host bytes R,G,B,A                    */
    SPGB_FMT_BGRA8_UNORM = 2,
};

/* Common header of every command */
struct spgb_cmd_header {
    uint32_t opcode;
    uint32_t payload_size;   /* bytes of payload following the header   */
};

struct spgb_resource_create {
    uint32_t id;
    uint32_t width;
    uint32_t height;
    uint32_t format;         /* SPGB_FMT_*                              */
};

struct spgb_resource_destroy {
    uint32_t id;
};

struct spgb_transfer_2d {
    uint32_t id;
    uint32_t x, y, w, h;     /* region in pixels                        */
    uint32_t stride;         /* row stride in pixels                    */
    /* uint8_t pixels[] payload follows, w*h*4 bytes (RGBA8/BGRA8)      */
};

struct spgb_set_target {
    uint32_t id;
};

struct spgb_clear {
    float r, g, b, a;
};

struct spgb_set_texture {
    uint32_t slot;           /* sampler slot, 0..SPGB_MAX_TEXTURES-1    */
    uint32_t id;
};

struct spgb_draw_quad {
    float x, y, w, h;        /* destination rect in target pixels       */
    float u0, v0, u1, v1;    /* source uv rect                          */
    float alpha;             /* 0..1                                    */
};

struct spgb_present {
    uint32_t target_id;      /* resource to present                     */
};

struct spgb_submit {
    uint32_t flags;          /* reserved, 0                             */
};

#define SPGB_MAX_TEXTURES 8

/*
 * Host-side entry points implemented by the Metal renderer (G1: Swift,
 * SPGBHostRenderer; G2: same ABI compiled into the QEMU backend's reach).
 *
 * typedef struct spgb_host *spgb_host_t;
 * int  spgb_host_create(spgb_host_t *out, void *layer_or_view);
 * int  spgb_host_execute(spgb_host_t host, const uint8_t *stream, uint32_t len);
 * void spgb_host_destroy(spgb_host_t host);
 */

#endif /* SPGB_PROTOCOL_H */
