#include "mol_dma_queue.h"

#include <limits.h>

static uint32_t get_u32(const uint8_t *buffer, uint32_t word_index)
{
    const uint8_t *p = buffer + ((size_t)word_index * 4U);
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void put_u32(uint8_t *buffer, uint32_t word_index, uint32_t value)
{
    uint8_t *p = buffer + ((size_t)word_index * 4U);
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static int is_aligned_64(const void *pointer)
{
    return (((uintptr_t)pointer & (uintptr_t)63U) == (uintptr_t)0U);
}

static int add_u32_checked(uint32_t a, uint32_t b, uint32_t *sum)
{
    if (sum == NULL || a > UINT32_MAX - b) {
        return MOL_DMA_ERR_RANGE;
    }
    *sum = a + b;
    return MOL_DMA_OK;
}

static int multiply_u32_checked(uint32_t a, uint32_t b, uint32_t *product)
{
    if (product == NULL || (b != 0U && a > UINT32_MAX / b)) {
        return MOL_DMA_ERR_RANGE;
    }
    *product = a * b;
    return MOL_DMA_OK;
}

void mol_dma_irq_record(mol_dma_irq_state_t *state, uint32_t direction,
                        uint32_t irq_status)
{
    if (state == NULL) {
        return;
    }
    if ((irq_status & MOL_DMA_IRQ_ERROR) != 0U) {
        state->error = 1U;
    }
    if ((irq_status & MOL_DMA_IRQ_IOC) != 0U) {
        if (direction == 0U) {
            state->mm2s_done = 1U;
        } else {
            state->s2mm_done = 1U;
        }
    }
}

int mol_dma_irq_complete(const mol_dma_irq_state_t *state)
{
    return state != NULL && state->error == 0U &&
           state->mm2s_done != 0U && state->s2mm_done != 0U;
}

int mol_dma_required_words(uint32_t task_id, uint32_t flags,
                           uint32_t item_count, uint32_t *payload_words,
                           uint32_t *result_words)
{
    uint32_t payload = 0U;
    uint32_t result = 0U;
    int rc;

    if (payload_words == NULL || result_words == NULL || item_count == 0U ||
        item_count > MOL_DMA_MAX_ITEM_COUNT) {
        return MOL_DMA_ERR_ARGUMENT;
    }

    switch (task_id) {
    case MOL_DMA_TASK_TANIMOTO:
        if ((flags & ~MOL_DMA_FLAG_SHARED_QUERY) != 0U) {
            return MOL_DMA_ERR_ARGUMENT;
        }
        if ((flags & MOL_DMA_FLAG_SHARED_QUERY) != 0U) {
            rc = multiply_u32_checked(item_count,
                                      MOL_DMA_PAYLOAD_WORDS_FINGERPRINT,
                                      &payload);
            if (rc != MOL_DMA_OK ||
                add_u32_checked(payload,
                                MOL_DMA_PAYLOAD_WORDS_FINGERPRINT,
                                &payload) != MOL_DMA_OK) {
                return MOL_DMA_ERR_RANGE;
            }
            result = item_count;
        } else {
            if (item_count != 1U) {
                return MOL_DMA_ERR_ARGUMENT;
            }
            payload = MOL_DMA_PAYLOAD_WORDS_TANIMOTO_PAIR;
            result = 1U;
        }
        break;
    case MOL_DMA_TASK_GNN:
        if ((flags & ~MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0U ||
            item_count > 32U) {
            return MOL_DMA_ERR_ARGUMENT;
        }
        rc = multiply_u32_checked(item_count, MOL_DMA_PAYLOAD_WORDS_GNN_TOTAL,
                                  &payload);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        rc = multiply_u32_checked(item_count,
                                  ((flags & MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0U) ?
                                  MOL_DMA_PAYLOAD_WORDS_GNN_FULL_RESULT : 1U,
                                  &result);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        break;
    case MOL_DMA_TASK_ADMET:
        if (flags != 0U) {
            return MOL_DMA_ERR_ARGUMENT;
        }
        rc = multiply_u32_checked(item_count,
                                  MOL_DMA_PAYLOAD_WORDS_ADMET_PER_ITEM,
                                  &payload);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        rc = multiply_u32_checked(item_count,
                                  MOL_DMA_PAYLOAD_WORDS_ADMET_RESULTS_PER_ITEM,
                                  &result);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        break;
    case MOL_DMA_TASK_PIPELINE:
        if ((flags & ~(MOL_DMA_FLAG_FULL_GNN_OUTPUT |
                       MOL_DMA_FLAG_RETURN_INTERMEDIATE)) != 0U ||
            item_count > 16U) {
            return MOL_DMA_ERR_ARGUMENT;
        }
        rc = multiply_u32_checked(item_count,
                                  MOL_DMA_PAYLOAD_WORDS_PIPELINE_TOTAL,
                                  &payload);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        if ((flags & MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0U) {
            rc = multiply_u32_checked(item_count, 3205U, &result);
        } else if ((flags & MOL_DMA_FLAG_RETURN_INTERMEDIATE) != 0U) {
            rc = multiply_u32_checked(item_count, 6U, &result);
        } else {
            rc = multiply_u32_checked(item_count, 4U, &result);
        }
        if (rc != MOL_DMA_OK) {
            return rc;
        }
        break;
    case MOL_DMA_TASK_WEIGHT_RELOAD:
        if (flags != 0U || item_count != 1U) {
            return MOL_DMA_ERR_ARGUMENT;
        }
        payload = MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
        result = 1U;
        break;
    default:
        return MOL_DMA_ERR_ARGUMENT;
    }

    *payload_words = payload;
    *result_words = result;
    return MOL_DMA_OK;
}

int mol_dma_builder_init(mol_dma_builder_t *builder, void *buffer,
                         size_t capacity_bytes, uint32_t batch_id,
                         uint32_t batch_flags, uint32_t max_result_words)
{
    uint32_t index;

    if (builder == NULL || buffer == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (!is_aligned_64(buffer)) {
        return MOL_DMA_ERR_ALIGNMENT;
    }
    if (capacity_bytes < (size_t)MOL_DMA_BATCH_HEADER_WORDS * 4U ||
        capacity_bytes > (size_t)MOL_DMA_MAX_TRANSFER_BYTES ||
        (capacity_bytes & 3U) != 0U ||
        max_result_words < (MOL_DMA_BATCH_HEADER_WORDS +
                            MOL_DMA_TRAILER_WORDS) ||
        max_result_words > MOL_DMA_MAX_TRANSFER_WORDS) {
        return MOL_DMA_ERR_RANGE;
    }
    if ((batch_flags & ~MOL_DMA_BATCH_FLAG_CONTINUE_ON_TASK_ERROR) != 0U) {
        return MOL_DMA_ERR_ARGUMENT;
    }

    builder->buffer = (uint8_t *)buffer;
    builder->capacity_bytes = capacity_bytes;
    builder->used_words = MOL_DMA_BATCH_HEADER_WORDS;
    builder->task_count = 0U;
    builder->batch_id = batch_id;
    builder->batch_flags = batch_flags;
    builder->max_result_words = max_result_words;
    builder->reserved_result_words = MOL_DMA_BATCH_HEADER_WORDS +
                                     MOL_DMA_TRAILER_WORDS;
    builder->finalized = 0U;

    for (index = 0U; index < MOL_DMA_BATCH_HEADER_WORDS; ++index) {
        put_u32(builder->buffer, index, 0U);
    }
    put_u32(builder->buffer, MOL_DMA_BATCH_MAGIC_WORD,
            MOL_DMA_MAGIC_REQUEST);
    put_u32(builder->buffer, MOL_DMA_BATCH_VERSION_HEADER_WORDS_WORD,
            (MOL_DMA_BATCH_HEADER_WORDS << 16) | MOL_DMA_VERSION);
    put_u32(builder->buffer, MOL_DMA_BATCH_BATCH_ID_WORD, batch_id);
    put_u32(builder->buffer, MOL_DMA_BATCH_BATCH_FLAGS_WORD, batch_flags);
    put_u32(builder->buffer, MOL_DMA_BATCH_MAX_RESULT_WORDS_WORD,
            max_result_words);
    return MOL_DMA_OK;
}

int mol_dma_builder_add_task(mol_dma_builder_t *builder, uint32_t job_id,
                             uint32_t task_id, uint32_t flags,
                             uint32_t item_count, uint32_t user_tag,
                             uint32_t timeout_cycles,
                             const uint32_t *payload,
                             uint32_t payload_words,
                             uint32_t result_capacity_words)
{
    uint32_t required_payload;
    uint32_t required_result;
    uint32_t record_words;
    uint32_t new_used_words;
    uint32_t result_record_words;
    uint32_t new_reserved_result_words;
    uint32_t header_word;
    uint32_t index;
    int rc;

    if (builder == NULL || builder->buffer == NULL || payload == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (builder->finalized != 0U ||
        builder->task_count >= MOL_DMA_MAX_TASKS) {
        return MOL_DMA_ERR_STATE;
    }

    rc = mol_dma_required_words(task_id, flags, item_count,
                                &required_payload, &required_result);
    if (rc != MOL_DMA_OK || payload_words != required_payload ||
        result_capacity_words < required_result) {
        return MOL_DMA_ERR_ARGUMENT;
    }

    rc = add_u32_checked(MOL_DMA_TASK_HEADER_WORDS, payload_words,
                         &record_words);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    rc = add_u32_checked(builder->used_words, record_words, &new_used_words);
    if (rc != MOL_DMA_OK || new_used_words > MOL_DMA_MAX_TRANSFER_WORDS ||
        (size_t)new_used_words * 4U > builder->capacity_bytes) {
        return MOL_DMA_ERR_RANGE;
    }

    rc = add_u32_checked(MOL_DMA_RESULT_HEADER_WORDS,
                         result_capacity_words, &result_record_words);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    rc = add_u32_checked(builder->reserved_result_words,
                         result_record_words,
                         &new_reserved_result_words);
    if (rc != MOL_DMA_OK ||
        new_reserved_result_words > builder->max_result_words) {
        return MOL_DMA_ERR_RANGE;
    }

    header_word = builder->used_words;
    for (index = 0U; index < MOL_DMA_TASK_HEADER_WORDS; ++index) {
        put_u32(builder->buffer, header_word + index, 0U);
    }
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_JOB_ID_WORD, job_id);
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_TASK_AND_FLAGS_WORD,
            task_id | flags);
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_PAYLOAD_WORDS_WORD,
            payload_words);
    put_u32(builder->buffer,
            header_word + MOL_DMA_TASK_RESULT_CAPACITY_WORDS_WORD,
            result_capacity_words);
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_ITEM_COUNT_WORD,
            item_count);
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_USER_TAG_WORD,
            user_tag);
    put_u32(builder->buffer, header_word + MOL_DMA_TASK_TIMEOUT_CYCLES_WORD,
            timeout_cycles);
    for (index = 0U; index < payload_words; ++index) {
        put_u32(builder->buffer,
                header_word + MOL_DMA_TASK_HEADER_WORDS + index,
                payload[index]);
    }

    builder->used_words = new_used_words;
    builder->reserved_result_words = new_reserved_result_words;
    builder->task_count += 1U;
    return MOL_DMA_OK;
}

int mol_dma_builder_finalize(mol_dma_builder_t *builder,
                             size_t *transfer_bytes)
{
    if (builder == NULL || transfer_bytes == NULL || builder->buffer == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (builder->finalized != 0U || builder->task_count == 0U) {
        return MOL_DMA_ERR_STATE;
    }

    put_u32(builder->buffer, MOL_DMA_BATCH_TASK_COUNT_WORD,
            builder->task_count);
    put_u32(builder->buffer, MOL_DMA_BATCH_TOTAL_WORDS_WORD,
            builder->used_words);
    builder->finalized = 1U;
    *transfer_bytes = (size_t)builder->used_words * 4U;
    return MOL_DMA_OK;
}

static int valid_success_result_size(uint32_t task_id, uint32_t item_count,
                                     uint32_t result_words)
{
    uint32_t words;
    if (item_count == 0U || item_count > MOL_DMA_MAX_ITEM_COUNT) {
        return 0;
    }
    switch (task_id) {
    case MOL_DMA_TASK_TANIMOTO:
        return result_words == item_count;
    case MOL_DMA_TASK_GNN:
        if (item_count > 32U ||
            multiply_u32_checked(item_count,
                                 MOL_DMA_PAYLOAD_WORDS_GNN_FULL_RESULT,
                                 &words) != MOL_DMA_OK) {
            return 0;
        }
        return result_words == item_count || result_words == words;
    case MOL_DMA_TASK_ADMET:
        return multiply_u32_checked(item_count,
                                    MOL_DMA_PAYLOAD_WORDS_ADMET_RESULTS_PER_ITEM,
                                    &words) == MOL_DMA_OK &&
               result_words == words;
    case MOL_DMA_TASK_PIPELINE:
        if (item_count > 16U) {
            return 0;
        }
        if (multiply_u32_checked(item_count, 4U, &words) == MOL_DMA_OK &&
            result_words == words) {
            return 1;
        }
        if (multiply_u32_checked(item_count, 6U, &words) == MOL_DMA_OK &&
            result_words == words) {
            return 1;
        }
        return multiply_u32_checked(item_count, 3205U, &words) == MOL_DMA_OK &&
               result_words == words;
    case MOL_DMA_TASK_WEIGHT_RELOAD:
        return item_count == 1U && result_words == 1U;
    default:
        return 0;
    }
}

int mol_dma_results_open(mol_dma_result_iterator_t *iterator,
                         const void *buffer, size_t response_bytes,
                         uint32_t expected_batch_id)
{
    const uint8_t *bytes = (const uint8_t *)buffer;
    uint32_t total_words;
    uint32_t trailer_word;
    uint32_t cursor;
    uint32_t records = 0U;
    uint32_t errors = 0U;
    uint32_t first_error_job = UINT32_MAX;
    uint32_t expected_tasks;

    if (iterator == NULL || buffer == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (!is_aligned_64(buffer)) {
        return MOL_DMA_ERR_ALIGNMENT;
    }
    if (response_bytes < 4U * (MOL_DMA_BATCH_HEADER_WORDS +
                              MOL_DMA_TRAILER_WORDS) ||
        response_bytes > MOL_DMA_MAX_TRANSFER_BYTES ||
        (response_bytes & 3U) != 0U) {
        return MOL_DMA_ERR_FORMAT;
    }
    total_words = (uint32_t)(response_bytes / 4U);
    trailer_word = total_words - MOL_DMA_TRAILER_WORDS;

    if (get_u32(bytes, MOL_DMA_RESPONSE_MAGIC_WORD) !=
            MOL_DMA_MAGIC_RESPONSE ||
        get_u32(bytes, MOL_DMA_RESPONSE_VERSION_HEADER_WORDS_WORD) !=
            ((MOL_DMA_BATCH_HEADER_WORDS << 16) | MOL_DMA_VERSION) ||
        get_u32(bytes, MOL_DMA_RESPONSE_BATCH_ID_WORD) != expected_batch_id ||
        get_u32(bytes, MOL_DMA_RESPONSE_HEADER_STATUS_WORD) >
            MOL_DMA_STATUS_INTERNAL_ERROR ||
        get_u32(bytes, MOL_DMA_RESPONSE_OUTPUT_CAPACITY_WORDS_WORD) <
            total_words ||
        get_u32(bytes, MOL_DMA_RESPONSE_OUTPUT_FLAGS_WORD) != 0U ||
        get_u32(bytes, MOL_DMA_RESPONSE_RESERVED_WORD) != 0U) {
        return MOL_DMA_ERR_FORMAT;
    }

    expected_tasks = get_u32(bytes, MOL_DMA_RESPONSE_EXPECTED_TASK_COUNT_WORD);
    if (expected_tasks > MOL_DMA_MAX_TASKS ||
        get_u32(bytes, trailer_word + MOL_DMA_TRAILER_MAGIC_WORD) !=
            MOL_DMA_MAGIC_TRAILER ||
        get_u32(bytes, trailer_word + MOL_DMA_TRAILER_BATCH_ID_WORD) !=
            expected_batch_id ||
        get_u32(bytes, trailer_word + MOL_DMA_TRAILER_TOTAL_RESULT_WORDS_WORD) !=
            total_words ||
        get_u32(bytes, trailer_word + MOL_DMA_TRAILER_BATCH_STATUS_WORD) >
            MOL_DMA_STATUS_INTERNAL_ERROR) {
        return MOL_DMA_ERR_FORMAT;
    }

    cursor = MOL_DMA_BATCH_HEADER_WORDS;
    while (cursor < trailer_word) {
        uint32_t task_status;
        uint32_t task_id;
        uint32_t status;
        uint32_t result_words;
        uint32_t item_count;
        uint32_t record_end;
        uint32_t job_id;

        if (trailer_word - cursor < MOL_DMA_RESULT_HEADER_WORDS) {
            return MOL_DMA_ERR_FORMAT;
        }
        task_status = get_u32(bytes,
                              cursor + MOL_DMA_RESULT_TASK_AND_STATUS_WORD);
        task_id = task_status & 0xFFU;
        status = task_status >> 8;
        result_words = get_u32(bytes,
                               cursor + MOL_DMA_RESULT_RESULT_WORDS_WORD);
        item_count = get_u32(bytes, cursor + MOL_DMA_RESULT_ITEM_COUNT_WORD);
        job_id = get_u32(bytes, cursor + MOL_DMA_RESULT_JOB_ID_WORD);

        if (status > MOL_DMA_STATUS_INTERNAL_ERROR ||
            add_u32_checked(cursor + MOL_DMA_RESULT_HEADER_WORDS,
                            result_words, &record_end) != MOL_DMA_OK ||
            record_end > trailer_word ||
            ((status == MOL_DMA_STATUS_OK) ?
             !valid_success_result_size(task_id, item_count, result_words) :
             (result_words != 0U))) {
            return MOL_DMA_ERR_FORMAT;
        }
        if (status != MOL_DMA_STATUS_OK) {
            errors += 1U;
            if (first_error_job == UINT32_MAX) {
                first_error_job = job_id;
            }
        }
        records += 1U;
        if (records > expected_tasks || records > MOL_DMA_MAX_TASKS) {
            return MOL_DMA_ERR_FORMAT;
        }
        cursor = record_end;
    }

    if (cursor != trailer_word ||
        records != get_u32(bytes,
                           trailer_word + MOL_DMA_TRAILER_COMPLETED_COUNT_WORD) ||
        errors != get_u32(bytes,
                          trailer_word + MOL_DMA_TRAILER_ERROR_COUNT_WORD) ||
        records > expected_tasks ||
        get_u32(bytes, trailer_word + MOL_DMA_TRAILER_FIRST_ERROR_JOB_ID_WORD) !=
            first_error_job) {
        return MOL_DMA_ERR_FORMAT;
    }

    iterator->buffer = bytes;
    iterator->total_words = total_words;
    iterator->cursor_words = MOL_DMA_BATCH_HEADER_WORDS;
    iterator->trailer_word = trailer_word;
    iterator->batch_id = expected_batch_id;
    iterator->expected_task_count = expected_tasks;
    iterator->completed_count = records;
    iterator->records_seen = 0U;
    return MOL_DMA_OK;
}

int mol_dma_results_next(mol_dma_result_iterator_t *iterator,
                         mol_dma_result_view_t *view)
{
    uint32_t cursor;
    uint32_t task_status;

    if (iterator == NULL || view == NULL || iterator->buffer == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (iterator->cursor_words == iterator->trailer_word) {
        return 0;
    }
    if (iterator->records_seen >= iterator->completed_count ||
        iterator->cursor_words > iterator->trailer_word -
                                 MOL_DMA_RESULT_HEADER_WORDS) {
        return MOL_DMA_ERR_FORMAT;
    }

    cursor = iterator->cursor_words;
    task_status = get_u32(iterator->buffer,
                          cursor + MOL_DMA_RESULT_TASK_AND_STATUS_WORD);
    view->job_id = get_u32(iterator->buffer,
                           cursor + MOL_DMA_RESULT_JOB_ID_WORD);
    view->task_id = task_status & 0xFFU;
    view->status = task_status >> 8;
    view->result_words = get_u32(iterator->buffer,
                                 cursor + MOL_DMA_RESULT_RESULT_WORDS_WORD);
    view->compute_cycles =
        (uint64_t)get_u32(iterator->buffer,
                          cursor + MOL_DMA_RESULT_COMPUTE_CYCLES_LO_WORD) |
        ((uint64_t)get_u32(iterator->buffer,
                           cursor + MOL_DMA_RESULT_COMPUTE_CYCLES_HI_WORD)
         << 32);
    view->item_count = get_u32(iterator->buffer,
                               cursor + MOL_DMA_RESULT_ITEM_COUNT_WORD);
    view->user_tag = get_u32(iterator->buffer,
                             cursor + MOL_DMA_RESULT_USER_TAG_WORD);
    view->detail = get_u32(iterator->buffer,
                           cursor + MOL_DMA_RESULT_DETAIL_WORD);
    view->payload = iterator->buffer +
                    (size_t)(cursor + MOL_DMA_RESULT_HEADER_WORDS) * 4U;

    iterator->cursor_words += MOL_DMA_RESULT_HEADER_WORDS +
                              view->result_words;
    iterator->records_seen += 1U;
    return 1;
}

int mol_dma_find_response_bytes(const void *buffer, size_t capacity_bytes,
                                uint32_t expected_batch_id,
                                size_t *response_bytes)
{
    const uint8_t *bytes = (const uint8_t *)buffer;
    uint32_t capacity_words;
    uint32_t trailer_word;

    if (buffer == NULL || response_bytes == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (!is_aligned_64(buffer)) {
        return MOL_DMA_ERR_ALIGNMENT;
    }
    if (capacity_bytes < 4U * (MOL_DMA_BATCH_HEADER_WORDS +
                              MOL_DMA_TRAILER_WORDS) ||
        capacity_bytes > MOL_DMA_MAX_TRANSFER_BYTES ||
        (capacity_bytes & 3U) != 0U) {
        return MOL_DMA_ERR_RANGE;
    }
    capacity_words = (uint32_t)(capacity_bytes / 4U);

    for (trailer_word = MOL_DMA_BATCH_HEADER_WORDS;
         trailer_word <= capacity_words - MOL_DMA_TRAILER_WORDS;
         ++trailer_word) {
        mol_dma_result_iterator_t candidate;
        uint32_t words;
        if (get_u32(bytes, trailer_word) != MOL_DMA_MAGIC_TRAILER ||
            get_u32(bytes, trailer_word + MOL_DMA_TRAILER_BATCH_ID_WORD) !=
                expected_batch_id) {
            continue;
        }
        words = get_u32(bytes,
                        trailer_word + MOL_DMA_TRAILER_TOTAL_RESULT_WORDS_WORD);
        if (words != trailer_word + MOL_DMA_TRAILER_WORDS) {
            continue;
        }
        if (mol_dma_results_open(&candidate, buffer, (size_t)words * 4U,
                                 expected_batch_id) == MOL_DMA_OK) {
            *response_bytes = (size_t)words * 4U;
            return MOL_DMA_OK;
        }
    }
    return MOL_DMA_ERR_FORMAT;
}

#ifndef MOL_DMA_HOST_TEST
#include "xaxidma_hw.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xtime_l.h"

#ifndef XPAR_SCUGIC_0_DEVICE_ID
#define XPAR_SCUGIC_0_DEVICE_ID 0U
#endif

static uint32_t dma_channel_status(const mol_dma_device_t *device,
                                   int direction)
{
    UINTPTR offset = (direction == XAXIDMA_DEVICE_TO_DMA) ?
                     XAXIDMA_RX_OFFSET : XAXIDMA_TX_OFFSET;
    return XAxiDma_ReadReg(device->instance.RegBase + offset,
                           XAXIDMA_SR_OFFSET);
}

static void dma_irq_handler(mol_dma_device_t *device, int direction,
                            uint32_t portable_direction)
{
    uint32_t irq_status = XAxiDma_IntrGetIrq(&device->instance, direction);
    uint32_t portable_status = 0U;

    if ((irq_status & XAXIDMA_IRQ_ALL_MASK) == 0U) {
        return;
    }
    XAxiDma_IntrAckIrq(&device->instance, irq_status, direction);
    if ((irq_status & XAXIDMA_IRQ_IOC_MASK) != 0U) {
        portable_status |= MOL_DMA_IRQ_IOC;
        if (portable_direction == 0U) {
            device->mm2s_irq_count += 1U;
        } else {
            device->s2mm_irq_count += 1U;
        }
    }
    if ((irq_status & XAXIDMA_IRQ_ERROR_MASK) != 0U) {
        portable_status |= MOL_DMA_IRQ_ERROR;
    }
    mol_dma_irq_record(&device->irq_state, portable_direction,
                       portable_status);
}

static void dma_mm2s_isr(void *reference)
{
    dma_irq_handler((mol_dma_device_t *)reference,
                    XAXIDMA_DMA_TO_DEVICE, 0U);
}

static void dma_s2mm_isr(void *reference)
{
    dma_irq_handler((mol_dma_device_t *)reference,
                    XAXIDMA_DEVICE_TO_DMA, 1U);
}

int mol_dma_device_reset(mol_dma_device_t *device,
                         uint32_t reset_poll_limit)
{
    uint32_t poll;
    if (device == NULL || reset_poll_limit == 0U) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    XAxiDma_Reset(&device->instance);
    for (poll = 0U; poll < reset_poll_limit; ++poll) {
        if (XAxiDma_ResetIsDone(&device->instance)) {
            device->last_mm2s_status = 0U;
            device->last_s2mm_status = 0U;
            if (device->irqs_connected != 0U) {
                XAxiDma_IntrEnable(&device->instance,
                    XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                    XAXIDMA_DMA_TO_DEVICE);
                XAxiDma_IntrEnable(&device->instance,
                    XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                    XAXIDMA_DEVICE_TO_DMA);
            }
            return MOL_DMA_OK;
        }
    }
    return MOL_DMA_ERR_TIMEOUT;
}

int mol_dma_device_init(mol_dma_device_t *device, uint16_t device_id,
                        uint32_t reset_poll_limit)
{
    XAxiDma_Config *config;
    int status;
    if (device == NULL) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    device->initialized = 0U;
    device->irqs_connected = 0U;
    device->mm2s_irq_count = 0U;
    device->s2mm_irq_count = 0U;
    device->irq_transfer_count = 0U;
    device->polling_transfer_count = 0U;
    config = XAxiDma_LookupConfig((uint32_t)device_id);
    if (config == NULL) {
        return MOL_DMA_ERR_HARDWARE;
    }
    status = XAxiDma_CfgInitialize(&device->instance, config);
    if (status != XST_SUCCESS) {
        return MOL_DMA_ERR_HARDWARE;
    }
    if (XAxiDma_HasSg(&device->instance)) {
        return MOL_DMA_ERR_UNSUPPORTED;
    }
    device->initialized = 1U;
    return mol_dma_device_reset(device, reset_poll_limit);
}

int mol_dma_device_connect_irqs(mol_dma_device_t *device,
                                uint32_t mm2s_irq_id,
                                uint32_t s2mm_irq_id)
{
    XScuGic_Config *config;
    int status;

    if (device == NULL || device->initialized == 0U ||
        mm2s_irq_id == s2mm_irq_id) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    config = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
    if (config == NULL) {
        return MOL_DMA_ERR_HARDWARE;
    }
    status = XScuGic_CfgInitialize(&device->interrupt_controller, config,
                                   config->CpuBaseAddress);
    if (status != XST_SUCCESS) {
        return MOL_DMA_ERR_HARDWARE;
    }
    status = XScuGic_Connect(&device->interrupt_controller, mm2s_irq_id,
                             dma_mm2s_isr, device);
    if (status != XST_SUCCESS) {
        return MOL_DMA_ERR_HARDWARE;
    }
    status = XScuGic_Connect(&device->interrupt_controller, s2mm_irq_id,
                             dma_s2mm_isr, device);
    if (status != XST_SUCCESS) {
        XScuGic_Disconnect(&device->interrupt_controller, mm2s_irq_id);
        return MOL_DMA_ERR_HARDWARE;
    }

    device->mm2s_irq_id = mm2s_irq_id;
    device->s2mm_irq_id = s2mm_irq_id;
    device->irqs_connected = 1U;
    XScuGic_SetPriorityTriggerType(&device->interrupt_controller,
                                   mm2s_irq_id, 0xA0U, 0x3U);
    XScuGic_SetPriorityTriggerType(&device->interrupt_controller,
                                   s2mm_irq_id, 0xA0U, 0x3U);
    XScuGic_Enable(&device->interrupt_controller, mm2s_irq_id);
    XScuGic_Enable(&device->interrupt_controller, s2mm_irq_id);

    XAxiDma_IntrAckIrq(&device->instance, XAXIDMA_IRQ_ALL_MASK,
                       XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrAckIrq(&device->instance, XAXIDMA_IRQ_ALL_MASK,
                       XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrEnable(&device->instance,
                       XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                       XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrEnable(&device->instance,
                       XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                       XAXIDMA_DEVICE_TO_DMA);

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(
        XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler,
        &device->interrupt_controller);
    Xil_ExceptionEnable();
    return MOL_DMA_OK;
}

int mol_dma_device_prepare_irqs(mol_dma_device_t *device)
{
    if (device == NULL || device->initialized == 0U ||
        device->irqs_connected == 0U) {
        return MOL_DMA_ERR_STATE;
    }
    device->irq_state.mm2s_done = 0U;
    device->irq_state.s2mm_done = 0U;
    device->irq_state.error = 0U;
    XAxiDma_IntrAckIrq(&device->instance, XAXIDMA_IRQ_ALL_MASK,
                       XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrAckIrq(&device->instance, XAXIDMA_IRQ_ALL_MASK,
                       XAXIDMA_DEVICE_TO_DMA);
    return MOL_DMA_OK;
}

int mol_dma_device_wait_irqs(mol_dma_device_t *device,
                             uint32_t required_events,
                             uint64_t timeout_ticks,
                             mol_dma_progress_fn progress,
                             void *context)
{
    XTime start;
    XTime now;
    int complete;

    if (device == NULL || device->irqs_connected == 0U ||
        timeout_ticks == 0U || required_events == 0U ||
        (required_events & ~(MOL_DMA_WAIT_MM2S | MOL_DMA_WAIT_S2MM)) != 0U) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    XTime_GetTime(&start);
    for (;;) {
        if (device->irq_state.error != 0U) {
            device->last_mm2s_status = dma_channel_status(
                device, XAXIDMA_DMA_TO_DEVICE);
            device->last_s2mm_status = dma_channel_status(
                device, XAXIDMA_DEVICE_TO_DMA);
            (void)mol_dma_device_reset(device, 1000000U);
            return MOL_DMA_ERR_HARDWARE;
        }
        complete = (((required_events & MOL_DMA_WAIT_MM2S) == 0U) ||
                    device->irq_state.mm2s_done != 0U) &&
                   (((required_events & MOL_DMA_WAIT_S2MM) == 0U) ||
                    device->irq_state.s2mm_done != 0U);
        if (complete) {
            return MOL_DMA_OK;
        }
        if (progress != NULL) {
            progress(context);
        }
        XTime_GetTime(&now);
        if ((uint64_t)(now - start) >= timeout_ticks) {
            device->last_mm2s_status = dma_channel_status(
                device, XAXIDMA_DMA_TO_DEVICE);
            device->last_s2mm_status = dma_channel_status(
                device, XAXIDMA_DEVICE_TO_DMA);
            (void)mol_dma_device_reset(device, 1000000U);
            return MOL_DMA_ERR_TIMEOUT;
        }
    }
}

int mol_dma_transfer_irq_ex(mol_dma_device_t *device,
                            const void *tx_buffer, size_t tx_bytes,
                            void *rx_buffer, size_t rx_capacity_bytes,
                            uint32_t expected_batch_id,
                            uint64_t timeout_ticks,
                            mol_dma_progress_fn progress, void *context,
                            size_t *response_bytes,
                            uint32_t transfer_flags)
{
    XTime phase_start;
    XTime phase_end;
    int status;
    int rc;

    if (device == NULL || device->initialized == 0U ||
        tx_buffer == NULL || rx_buffer == NULL || response_bytes == NULL ||
        timeout_ticks == 0U || device->irqs_connected == 0U ||
        (transfer_flags & ~MOL_DMA_TRANSFER_TX_UNCACHED) != 0U) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    if (!is_aligned_64(tx_buffer) || !is_aligned_64(rx_buffer)) {
        return MOL_DMA_ERR_ALIGNMENT;
    }
    if (tx_bytes == 0U || tx_bytes > MOL_DMA_MAX_TRANSFER_BYTES ||
        rx_capacity_bytes == 0U ||
        rx_capacity_bytes > MOL_DMA_MAX_TRANSFER_BYTES ||
        (tx_bytes & 3U) != 0U || (rx_capacity_bytes & 3U) != 0U) {
        return MOL_DMA_ERR_RANGE;
    }

    device->irq_transfer_count += 1U;

    device->last_tx_flush_ticks = 0U;
    device->last_rx_flush_ticks = 0U;
    device->last_engine_ticks = 0U;
    device->last_rx_invalidate_ticks = 0U;
    device->last_parse_ticks = 0U;

    if ((transfer_flags & MOL_DMA_TRANSFER_TX_UNCACHED) == 0U) {
        XTime_GetTime(&phase_start);
        Xil_DCacheFlushRange((UINTPTR)tx_buffer, (uint32_t)tx_bytes);
        XTime_GetTime(&phase_end);
        device->last_tx_flush_ticks = (uint64_t)(phase_end - phase_start);
    }

    XTime_GetTime(&phase_start);
    Xil_DCacheFlushRange((UINTPTR)rx_buffer, (uint32_t)rx_capacity_bytes);
    XTime_GetTime(&phase_end);
    device->last_rx_flush_ticks = (uint64_t)(phase_end - phase_start);

    /* Arm S2MM first so no result beat can be lost when MM2S starts. */
    XTime_GetTime(&phase_start);
    rc = mol_dma_device_prepare_irqs(device);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    status = XAxiDma_SimpleTransfer(&device->instance, (UINTPTR)rx_buffer,
                                    (uint32_t)rx_capacity_bytes,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        (void)mol_dma_device_reset(device, 1000000U);
        return MOL_DMA_ERR_HARDWARE;
    }
    status = XAxiDma_SimpleTransfer(&device->instance, (UINTPTR)tx_buffer,
                                    (uint32_t)tx_bytes,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        (void)mol_dma_device_reset(device, 1000000U);
        return MOL_DMA_ERR_HARDWARE;
    }
    rc = mol_dma_device_wait_irqs(device,
            MOL_DMA_WAIT_MM2S | MOL_DMA_WAIT_S2MM,
            timeout_ticks, progress, context);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    XTime_GetTime(&phase_end);
    device->last_engine_ticks = (uint64_t)(phase_end - phase_start);

    XTime_GetTime(&phase_start);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buffer,
                              (uint32_t)rx_capacity_bytes);
    XTime_GetTime(&phase_end);
    device->last_rx_invalidate_ticks = (uint64_t)(phase_end - phase_start);

    XTime_GetTime(&phase_start);
    rc = mol_dma_find_response_bytes(rx_buffer, rx_capacity_bytes,
                                     expected_batch_id, response_bytes);
    XTime_GetTime(&phase_end);
    device->last_parse_ticks = (uint64_t)(phase_end - phase_start);
    return rc;
}

int mol_dma_transfer_poll_ex(mol_dma_device_t *device,
                             const void *tx_buffer, size_t tx_bytes,
                             void *rx_buffer, size_t rx_capacity_bytes,
                             uint32_t expected_batch_id,
                             uint32_t poll_limit, size_t *response_bytes,
                             uint32_t transfer_flags)
{
    if (device != NULL) {
        device->polling_transfer_count += 1U;
    }
    return mol_dma_transfer_irq_ex(device, tx_buffer, tx_bytes,
                                   rx_buffer, rx_capacity_bytes,
                                   expected_batch_id, poll_limit,
                                   NULL, NULL, response_bytes,
                                   transfer_flags);
}

int mol_dma_transfer_poll(mol_dma_device_t *device,
                          const void *tx_buffer, size_t tx_bytes,
                          void *rx_buffer, size_t rx_capacity_bytes,
                          uint32_t expected_batch_id,
                          uint32_t poll_limit, size_t *response_bytes)
{
    return mol_dma_transfer_poll_ex(device, tx_buffer, tx_bytes,
                                    rx_buffer, rx_capacity_bytes,
                                    expected_batch_id, poll_limit,
                                    response_bytes, 0U);
}
#endif
