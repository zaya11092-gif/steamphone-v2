/*
 * SPGB QEMU-side backend interface (gate G2 scaffold).
 * Canonical protocol: Platform/GPUBridge/SPGBProtocol.h
 */

#ifndef SPGB_BACKEND_H
#define SPGB_BACKEND_H

#include "spgb-protocol.h"

/* Implemented in the iOS app layer (Swift SPGBHostRenderer behind a C shim):
 * spgb_host_create / spgb_host_execute / spgb_host_destroy per
 * SPGBProtocol.h. When QEMU is compiled for non-iOS hosts during
 * development, link a null implementation. */

int spgb_backend_init(void *virtio_gpu);
void spgb_backend_fini(void *virtio_gpu);

int spgb_resource_create(void *virtio_gpu, void *cmd,
                         uint32_t resource_id, uint32_t format,
                         uint32_t width, uint32_t height);
int spgb_transfer_2d(void *virtio_gpu, void *cmd,
                     uint32_t resource_id, uint32_t x, uint32_t y,
                     uint32_t w, uint32_t h, uint32_t stride,
                     const void *pixels);
int spgb_resource_flush(void *virtio_gpu, uint32_t resource_id);

#endif /* SPGB_BACKEND_H */
