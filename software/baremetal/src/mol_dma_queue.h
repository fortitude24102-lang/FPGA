#ifndef MOL_DMA_QUEUE_H
#define MOL_DMA_QUEUE_H

#include <stddef.h>
#include <stdint.h>

#include "mol_dma_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MOL_DMA_OK              = 0,
    MOL_DMA_ERR_ARGUMENT    = -1,
    MOL_DMA_ERR_ALIGNMENT   = -2,
    MOL_DMA_ERR_RANGE       = -3,
    MOL_DMA_ERR_STATE       = -4,
    MOL_DMA_ERR_FORMAT      = -5,
    MOL_DMA_ERR_HARDWARE    = -6,
    MOL_DMA_ERR_TIMEOUT     = -7,
    MOL_DMA_ERR_UNSUPPORTED = -8
} mol_dma_rc_t;

typedef struct {
    uint8_t *buffer;
    size_t capacity_bytes;
    uint32_t used_words;
    uint32_t task_count;
    uint32_t batch_id;
    uint32_t batch_flags;
    uint32_t max_result_words;
    uint32_t reserved_result_words;
    uint32_t finalized;
} mol_dma_builder_t;

typedef struct {
    uint32_t job_id;
    uint32_t task_id;
    uint32_t status;
    uint32_t result_words;
    uint64_t compute_cycles;
    uint32_t item_count;
    uint32_t user_tag;
    uint32_t detail;
    const uint8_t *payload;
} mol_dma_result_view_t;

typedef struct {
    const uint8_t *buffer;
    uint32_t total_words;
    uint32_t cursor_words;
    uint32_t trailer_word;
    uint32_t batch_id;
    uint32_t expected_task_count;
    uint32_t completed_count;
    uint32_t records_seen;
} mol_dma_result_iterator_t;

int mol_dma_required_words(uint32_t task_id, uint32_t flags,
                           uint32_t item_count, uint32_t *payload_words,
                           uint32_t *result_words);

int mol_dma_builder_init(mol_dma_builder_t *builder, void *buffer,
                         size_t capacity_bytes, uint32_t batch_id,
                         uint32_t batch_flags, uint32_t max_result_words);

int mol_dma_builder_add_task(mol_dma_builder_t *builder, uint32_t job_id,
                             uint32_t task_id, uint32_t flags,
                             uint32_t item_count, uint32_t user_tag,
                             uint32_t timeout_cycles,
                             const uint32_t *payload,
                             uint32_t payload_words,
                             uint32_t result_capacity_words);

int mol_dma_builder_finalize(mol_dma_builder_t *builder,
                             size_t *transfer_bytes);

int mol_dma_results_open(mol_dma_result_iterator_t *iterator,
                         const void *buffer, size_t response_bytes,
                         uint32_t expected_batch_id);

/* Returns 1 for a record, 0 at the trailer, or a negative mol_dma_rc_t. */
int mol_dma_results_next(mol_dma_result_iterator_t *iterator,
                         mol_dma_result_view_t *view);

/* Locate and validate a response inside a larger zero-filled S2MM buffer. */
int mol_dma_find_response_bytes(const void *buffer, size_t capacity_bytes,
                                uint32_t expected_batch_id,
                                size_t *response_bytes);

#ifndef MOL_DMA_HOST_TEST
#include "xaxidma.h"

typedef struct {
    XAxiDma instance;
    uint32_t initialized;
    uint32_t last_mm2s_status;
    uint32_t last_s2mm_status;
} mol_dma_device_t;

int mol_dma_device_init(mol_dma_device_t *device, uint16_t device_id,
                        uint32_t reset_poll_limit);
int mol_dma_device_reset(mol_dma_device_t *device,
                         uint32_t reset_poll_limit);
int mol_dma_transfer_poll(mol_dma_device_t *device,
                          const void *tx_buffer, size_t tx_bytes,
                          void *rx_buffer, size_t rx_capacity_bytes,
                          uint32_t expected_batch_id,
                          uint32_t poll_limit, size_t *response_bytes);
#endif

#ifdef __cplusplus
}
#endif

#endif
