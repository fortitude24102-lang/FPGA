#include "accelerator.h"

#include "xil_io.h"
#include "xil_printf.h"

static inline void accel_write32(u32 offset, u32 value)
{
    Xil_Out32((UINTPTR)ACCEL_BASEADDR + offset, value);
}

static inline u32 accel_read32(u32 offset)
{
    return Xil_In32((UINTPTR)ACCEL_BASEADDR + offset);
}

u32 accel_read_status(void)
{
    return accel_read32(ACCEL_REG_STATUS);
}

void accel_clear_status(void)
{
    accel_write32(ACCEL_REG_CONTROL, 1U << 8);
}

void accel_start(accel_task_t task)
{
    accel_write32(ACCEL_REG_CONTROL, 1U | (((u32)task & 0x3U) << 1));
}

accel_result_t accel_wait_done(u32 poll_limit, u32 *final_status)
{
    u32 status = 0U;
    u32 poll;

    for (poll = 0U; poll < poll_limit; ++poll) {
        status = accel_read_status();
        if ((status & ACCEL_STATUS_ERROR) != 0U) {
            if (final_status != 0) {
                *final_status = status;
            }
            return ACCEL_ERR_HW;
        }
        if ((status & ACCEL_STATUS_DONE) != 0U) {
            if (final_status != 0) {
                *final_status = status;
            }
            return ACCEL_OK;
        }
    }

    if (final_status != 0) {
        *final_status = status;
    }
    return ACCEL_ERR_TIMEOUT;
}

void accel_write_fingerprints(const u32 query[ACCEL_FINGERPRINT_WORDS],
                              const u32 database[ACCEL_FINGERPRINT_WORDS])
{
    u32 index;

    for (index = 0U; index < ACCEL_FINGERPRINT_WORDS; ++index) {
        accel_write32(ACCEL_QUERY_BASE + index * 4U, query[index]);
        accel_write32(ACCEL_DATABASE_BASE + index * 4U, database[index]);
    }
}

u32 accel_read_tanimoto(void)
{
    return accel_read32(ACCEL_TANIMOTO_RESULT);
}

void accel_write_descriptors(const s16 values[ACCEL_DESCRIPTOR_COUNT])
{
    u32 index;

    for (index = 0U; index < ACCEL_DESCRIPTOR_COUNT; index += 2U) {
        u32 low = (u32)(u16)values[index];
        u32 high = (u32)(u16)values[index + 1U];
        accel_write32(ACCEL_DESCRIPTOR_BASE + (index / 2U) * 4U,
                      low | (high << 16));
    }
}

void accel_read_admet(s16 values[4])
{
    u32 index;

    for (index = 0U; index < 4U; ++index) {
        values[index] = (s16)(u16)accel_read32(
            ACCEL_ADMET_RESULT_BASE + index * 4U);
    }
}

void accel_write_admet_parameter(u32 model, u32 layer, u32 address, s16 value)
{
    u32 commit = (model & 0x3U) |
                 ((layer & 0x3U) << 2) |
                 ((address & 0xFFFFU) << 4);

    accel_write32(ACCEL_ADMET_WEIGHT_DATA, (u32)(u16)value);
    accel_write32(ACCEL_ADMET_COMMIT, commit);
}

void accel_write_gnn_weight(u32 address, s16 value)
{
    accel_write32(ACCEL_GNN_WEIGHT_DATA, (u32)(u16)value);
    accel_write32(ACCEL_GNN_WEIGHT_COMMIT, address & 0x1FFFU);
}

void accel_write_adjacency(const u32 words[ACCEL_ADJACENCY_WORDS])
{
    u32 index;

    for (index = 0U; index < ACCEL_ADJACENCY_WORDS; ++index) {
        accel_write32(ACCEL_ADJACENCY_BASE + index * 4U, words[index]);
    }
}

void accel_write_features(const u32 words[ACCEL_FEATURE_WORDS])
{
    u32 index;

    for (index = 0U; index < ACCEL_FEATURE_WORDS; ++index) {
        accel_write32(ACCEL_FEATURE_BASE + index * 4U, words[index]);
    }
}

void accel_read_gnn_output(u32 words[ACCEL_GNN_OUTPUT_WORDS])
{
    u32 index;

    for (index = 0U; index < ACCEL_GNN_OUTPUT_WORDS; ++index) {
        words[index] = accel_read32(ACCEL_GNN_OUTPUT_BASE + index * 4U);
    }
}

u32 accel_read_gnn_output_word(u32 index)
{
    if (index >= ACCEL_GNN_OUTPUT_WORDS) {
        return 0U;
    }
    return accel_read32(ACCEL_GNN_OUTPUT_BASE + index * 4U);
}

void accel_configure_reference_gnn_weights(void)
{
    u32 index;
    for (index = 0U; index < ACCEL_GNN_WEIGHT_COUNT; ++index) {
        accel_write_gnn_weight(index, 0);
    }
    accel_write_gnn_weight(0U, (s16)0x0100);
}

void accel_configure_reference_admet_weights(void)
{
    const u32 input_weights = 20U * 10U;
    const u32 hidden_count = 10U;
    u32 model;
    u32 address;

    for (model = 0U; model < 4U; ++model) {
        for (address = 0U; address < input_weights; ++address) {
            accel_write_admet_parameter(model, 0U, address, 0);
        }
        for (address = 0U; address < hidden_count; ++address) {
            accel_write_admet_parameter(model, 1U, address, 0);
            accel_write_admet_parameter(model, 2U, address, 0);
        }
        accel_write_admet_parameter(model, 3U, 0U, 0);
        accel_write_admet_parameter(model, 0U, 0U, (s16)0x0100);
        accel_write_admet_parameter(model, 2U, 0U, (s16)0x0100);
    }
}

static void accel_set_packed_weight(u32 words[ACCEL_REFERENCE_WEIGHT_WORDS],
                                    u32 halfword_index, s16 value)
{
    u32 word_index = halfword_index >> 1;
    u32 packed = (u32)(u16)value;

    if ((halfword_index & 1U) == 0U) {
        words[word_index] = (words[word_index] & 0xFFFF0000U) | packed;
    } else {
        words[word_index] = (words[word_index] & 0x0000FFFFU) |
                            (packed << 16);
    }
}

void accel_pack_reference_weights(u32 words[ACCEL_REFERENCE_WEIGHT_WORDS])
{
    const u32 gnn_values = ACCEL_GNN_WEIGHT_COUNT;
    const u32 admet_values_per_model = 221U;
    const u32 admet_layer2_offset = 210U;
    u32 model;
    u32 index;

    if (words == 0) {
        return;
    }
    for (index = 0U; index < ACCEL_REFERENCE_WEIGHT_WORDS; ++index) {
        words[index] = 0U;
    }

    accel_set_packed_weight(words, 0U, (s16)0x0100);
    for (model = 0U; model < 4U; ++model) {
        u32 model_base = gnn_values + model * admet_values_per_model;
        accel_set_packed_weight(words, model_base, (s16)0x0100);
        accel_set_packed_weight(words, model_base + admet_layer2_offset,
                                (s16)0x0100);
    }
}

accel_result_t accel_tanimoto_self_test(void)
{
    u32 query[ACCEL_FINGERPRINT_WORDS];
    u32 database[ACCEL_FINGERPRINT_WORDS];
    u32 status = 0U;
    u32 index;
    accel_result_t result;

    for (index = 0U; index < ACCEL_FINGERPRINT_WORDS; ++index) {
        query[index] = 0xFFFFFFFFU;
        database[index] = 0xFFFFFFFFU;
    }

    accel_clear_status();
    accel_write_fingerprints(query, database);
    accel_start(ACCEL_TASK_TANIMOTO);
    result = accel_wait_done(10000000U, &status);

    if (result != ACCEL_OK) {
        xil_printf("Accelerator wait failed: rc=%d status=0x%08x\r\n",
                   (int)result, status);
        return result;
    }

    if (accel_read_tanimoto() != 0x00010000U) {
        xil_printf("Unexpected Tanimoto result: 0x%08x\r\n",
                   accel_read_tanimoto());
        return ACCEL_ERR_HW;
    }

    return ACCEL_OK;
}
