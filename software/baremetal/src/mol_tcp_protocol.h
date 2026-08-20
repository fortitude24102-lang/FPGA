#ifndef MOL_TCP_PROTOCOL_H
#define MOL_TCP_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOL_TCP_MAGIC UINT32_C(0x5A)
#define MOL_TCP_VERSION UINT32_C(1)
#define MOL_TCP_HEADER_BYTES UINT32_C(16)
#define MOL_TCP_QUEUE_DEPTH UINT32_C(8)
#define MOL_TCP_SLOT_BYTES UINT32_C(24576)

#define MOL_TCP_FLAG_RESPONSE UINT32_C(1)
#define MOL_TCP_FLAG_BUSY UINT32_C(2)
#define MOL_TCP_FLAG_ERROR UINT32_C(4)
#define MOL_TCP_FLAG_FALLBACK UINT32_C(8)

typedef enum {
    MOL_TCP_OK = 0,
    MOL_TCP_BUSY = 1,
    MOL_TCP_ERR_ARGUMENT = -1,
    MOL_TCP_ERR_BAD_HEADER = -2,
    MOL_TCP_ERR_BAD_LENGTH = -3,
    MOL_TCP_ERR_BAD_TASK = -4,
    MOL_TCP_ERR_BAD_BATCH = -5,
    MOL_TCP_ERR_STATE = -6,
    MOL_TCP_ERR_EMPTY = -7
} mol_tcp_rc_t;

typedef enum {
    MOL_TCP_ERROR_BAD_HEADER = 1,
    MOL_TCP_ERROR_BAD_LENGTH = 2,
    MOL_TCP_ERROR_BAD_TASK = 3,
    MOL_TCP_ERROR_BAD_BATCH = 4,
    MOL_TCP_ERROR_QUEUE_FULL = 5,
    MOL_TCP_ERROR_WEIGHTS_NOT_READY = 6,
    MOL_TCP_ERROR_DMA = 7,
    MOL_TCP_ERROR_RELOAD = 8,
    MOL_TCP_ERROR_INTERNAL = 9
} mol_tcp_error_code_t;

typedef struct {
    uint8_t task_id;
    uint8_t flags;
    uint16_t padding;
    uint32_t payload_len;
    uint32_t trace_id;
    uint32_t batch_size;
} mol_tcp_header_t;

typedef struct {
    uint8_t header_bytes[MOL_TCP_HEADER_BYTES];
    uint32_t header_used;
    mol_tcp_header_t header;
    uint8_t payload[MOL_TCP_SLOT_BYTES];
    uint32_t payload_used;
    uint32_t have_header;
} mol_tcp_stream_t;

typedef struct {
    mol_tcp_header_t header;
    uint32_t connection_slot;
    uint32_t connection_generation;
    uint32_t payload_len;
    uint8_t payload[MOL_TCP_SLOT_BYTES];
} mol_tcp_request_t;

typedef struct {
    mol_tcp_request_t slots[MOL_TCP_QUEUE_DEPTH];
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} mol_tcp_request_queue_t;

int mol_tcp_dma_shape(uint8_t task_id, uint32_t batch_size,
                      uint32_t *dma_flags, uint32_t *payload_words,
                      uint32_t *result_words);
int mol_tcp_decode_header(const uint8_t bytes[MOL_TCP_HEADER_BYTES],
                          mol_tcp_header_t *header);
int mol_tcp_encode_header(uint8_t bytes[MOL_TCP_HEADER_BYTES],
                          const mol_tcp_header_t *header);

void mol_tcp_stream_init(mol_tcp_stream_t *stream);
int mol_tcp_stream_feed(mol_tcp_stream_t *stream, const uint8_t *data,
                        size_t data_bytes, size_t *consumed_bytes);

void mol_tcp_queue_init(mol_tcp_request_queue_t *queue);
int mol_tcp_request_queue_push(mol_tcp_request_queue_t *queue,
                               const mol_tcp_header_t *header,
                               uint32_t connection_slot,
                               uint32_t connection_generation,
                               const uint8_t *payload,
                               uint32_t payload_len);
int mol_tcp_request_queue_pop(mol_tcp_request_queue_t *queue,
                              mol_tcp_request_t *request);

#ifdef __cplusplus
}
#endif

#endif
