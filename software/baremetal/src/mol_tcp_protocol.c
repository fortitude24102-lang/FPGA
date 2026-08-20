#include "mol_tcp_protocol.h"

#include <string.h>

#include "mol_dma_protocol.h"

_Static_assert(sizeof(mol_tcp_header_t) == MOL_TCP_HEADER_BYTES,
               "TCP header metadata must be 16 bytes");

static uint32_t load_le32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static void store_le32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

int mol_tcp_dma_shape(uint8_t task_id, uint32_t batch_size,
                      uint32_t *dma_flags, uint32_t *payload_words,
                      uint32_t *result_words)
{
    if (dma_flags == NULL || payload_words == NULL || result_words == NULL) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    if (batch_size == 0U || batch_size > MOL_DMA_MAX_ITEM_COUNT) {
        return MOL_TCP_ERR_BAD_BATCH;
    }
    *dma_flags = 0U;
    switch (task_id) {
    case MOL_DMA_TASK_TANIMOTO:
        if (batch_size == 1U) {
            *payload_words = MOL_DMA_PAYLOAD_WORDS_TANIMOTO_PAIR;
        } else {
            *dma_flags = MOL_DMA_FLAG_SHARED_QUERY;
            *payload_words = MOL_DMA_PAYLOAD_WORDS_FINGERPRINT +
                             batch_size * MOL_DMA_PAYLOAD_WORDS_FINGERPRINT;
        }
        *result_words = batch_size;
        return MOL_TCP_OK;
    case MOL_DMA_TASK_GNN:
        if (batch_size != 1U) {
            return MOL_TCP_ERR_BAD_BATCH;
        }
        *payload_words = MOL_DMA_PAYLOAD_WORDS_GNN_TOTAL;
        *result_words = 1U;
        return MOL_TCP_OK;
    case MOL_DMA_TASK_ADMET:
        *payload_words = batch_size * MOL_DMA_PAYLOAD_WORDS_ADMET_PER_ITEM;
        *result_words =
            batch_size * MOL_DMA_PAYLOAD_WORDS_ADMET_RESULTS_PER_ITEM;
        return MOL_TCP_OK;
    case MOL_DMA_TASK_PIPELINE:
        if (batch_size != 1U) {
            return MOL_TCP_ERR_BAD_BATCH;
        }
        *payload_words = MOL_DMA_PAYLOAD_WORDS_PIPELINE_TOTAL;
        *result_words = 4U;
        return MOL_TCP_OK;
    case MOL_DMA_TASK_WEIGHT_RELOAD:
        if (batch_size != 1U) {
            return MOL_TCP_ERR_BAD_BATCH;
        }
        *payload_words = MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
        *result_words = 1U;
        return MOL_TCP_OK;
    default:
        return MOL_TCP_ERR_BAD_TASK;
    }
}

int mol_tcp_decode_header(const uint8_t bytes[MOL_TCP_HEADER_BYTES],
                          mol_tcp_header_t *header)
{
    uint32_t dma_flags;
    uint32_t payload_words;
    uint32_t result_words;
    int rc;

    if (bytes == NULL || header == NULL) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    if (bytes[0] != MOL_TCP_MAGIC || bytes[1] != MOL_TCP_VERSION) {
        return MOL_TCP_ERR_BAD_HEADER;
    }
    if (bytes[3] != 0U) {
        return MOL_TCP_ERR_BAD_HEADER;
    }
    header->task_id = bytes[2];
    header->flags = bytes[3];
    header->padding = 0U;
    header->payload_len = load_le32(bytes + 4U);
    header->trace_id = load_le32(bytes + 8U);
    header->batch_size = load_le32(bytes + 12U);

    rc = mol_tcp_dma_shape(header->task_id, header->batch_size,
                           &dma_flags, &payload_words, &result_words);
    if (rc != MOL_TCP_OK) {
        return rc;
    }
    (void)dma_flags;
    (void)result_words;
    if (payload_words > MOL_TCP_SLOT_BYTES / 4U ||
        header->payload_len != payload_words * 4U) {
        return MOL_TCP_ERR_BAD_LENGTH;
    }
    return MOL_TCP_OK;
}

int mol_tcp_encode_header(uint8_t bytes[MOL_TCP_HEADER_BYTES],
                          const mol_tcp_header_t *header)
{
    if (bytes == NULL || header == NULL ||
        header->payload_len > MOL_TCP_SLOT_BYTES ||
        (header->flags & 0xF0U) != 0U) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    bytes[0] = (uint8_t)MOL_TCP_MAGIC;
    bytes[1] = (uint8_t)MOL_TCP_VERSION;
    bytes[2] = header->task_id;
    bytes[3] = header->flags;
    store_le32(bytes + 4U, header->payload_len);
    store_le32(bytes + 8U, header->trace_id);
    store_le32(bytes + 12U, header->batch_size);
    return MOL_TCP_OK;
}

void mol_tcp_stream_init(mol_tcp_stream_t *stream)
{
    if (stream != NULL) {
        memset(stream, 0, sizeof(*stream));
    }
}

int mol_tcp_stream_feed(mol_tcp_stream_t *stream, const uint8_t *data,
                        size_t data_bytes, size_t *consumed_bytes)
{
    size_t consumed = 0U;
    size_t copy_bytes;
    int rc;

    if (stream == NULL || consumed_bytes == NULL ||
        (data == NULL && data_bytes != 0U)) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    *consumed_bytes = 0U;
    if (stream->have_header != 0U &&
        stream->payload_used == stream->header.payload_len) {
        return MOL_TCP_ERR_STATE;
    }
    if (stream->have_header == 0U) {
        copy_bytes = MOL_TCP_HEADER_BYTES - stream->header_used;
        if (copy_bytes > data_bytes) {
            copy_bytes = data_bytes;
        }
        if (copy_bytes != 0U) {
            memcpy(stream->header_bytes + stream->header_used,
                   data, copy_bytes);
            stream->header_used += (uint32_t)copy_bytes;
            consumed += copy_bytes;
        }
        if (stream->header_used != MOL_TCP_HEADER_BYTES) {
            *consumed_bytes = consumed;
            return 0;
        }
        rc = mol_tcp_decode_header(stream->header_bytes, &stream->header);
        if (rc != MOL_TCP_OK) {
            *consumed_bytes = consumed;
            return rc;
        }
        stream->have_header = 1U;
    }

    copy_bytes = stream->header.payload_len - stream->payload_used;
    if (copy_bytes > data_bytes - consumed) {
        copy_bytes = data_bytes - consumed;
    }
    if (copy_bytes != 0U) {
        memcpy(stream->payload + stream->payload_used,
               data + consumed, copy_bytes);
        stream->payload_used += (uint32_t)copy_bytes;
        consumed += copy_bytes;
    }
    *consumed_bytes = consumed;
    return (stream->payload_used == stream->header.payload_len) ? 1 : 0;
}

void mol_tcp_queue_init(mol_tcp_request_queue_t *queue)
{
    if (queue != NULL) {
        memset(queue, 0, sizeof(*queue));
    }
}

int mol_tcp_request_queue_push(mol_tcp_request_queue_t *queue,
                               const mol_tcp_header_t *header,
                               uint32_t connection_slot,
                               uint32_t connection_generation,
                               const uint8_t *payload,
                               uint32_t payload_len)
{
    mol_tcp_request_t *slot;

    if (queue == NULL || header == NULL || payload == NULL ||
        payload_len != header->payload_len || payload_len > MOL_TCP_SLOT_BYTES) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    if (queue->count == MOL_TCP_QUEUE_DEPTH) {
        return MOL_TCP_BUSY;
    }
    slot = &queue->slots[queue->tail];
    slot->header = *header;
    slot->connection_slot = connection_slot;
    slot->connection_generation = connection_generation;
    slot->payload_len = payload_len;
    memcpy(slot->payload, payload, payload_len);
    queue->tail = (queue->tail + 1U) % MOL_TCP_QUEUE_DEPTH;
    queue->count += 1U;
    return MOL_TCP_OK;
}

int mol_tcp_request_queue_pop(mol_tcp_request_queue_t *queue,
                              mol_tcp_request_t *request)
{
    mol_tcp_request_t *slot;

    if (queue == NULL || request == NULL) {
        return MOL_TCP_ERR_ARGUMENT;
    }
    if (queue->count == 0U) {
        return MOL_TCP_ERR_EMPTY;
    }
    slot = &queue->slots[queue->head];
    memcpy(request, slot, sizeof(*request));
    slot->payload_len = 0U;
    slot->connection_slot = 0U;
    slot->connection_generation = 0U;
    queue->head = (queue->head + 1U) % MOL_TCP_QUEUE_DEPTH;
    queue->count -= 1U;
    return MOL_TCP_OK;
}
