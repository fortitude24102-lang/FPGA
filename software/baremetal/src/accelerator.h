#ifndef GENERATOR_ACCELERATOR_H
#define GENERATOR_ACCELERATOR_H

#include "xil_types.h"
#include "xparameters.h"

#ifdef XPAR_GENERATOR_ACCELERATOR_TOP_0_S_AXI_BASEADDR
#define ACCEL_BASEADDR XPAR_GENERATOR_ACCELERATOR_TOP_0_S_AXI_BASEADDR
#elif defined(XPAR_GENERATOR_ACCELERATOR_0_S_AXI_BASEADDR)
#define ACCEL_BASEADDR XPAR_GENERATOR_ACCELERATOR_0_S_AXI_BASEADDR
#else
#define ACCEL_BASEADDR 0x43C00000U
#endif

#define ACCEL_REG_CONTROL       0x0000U
#define ACCEL_REG_STATUS        0x0004U
#define ACCEL_QUERY_BASE        0x0100U
#define ACCEL_DATABASE_BASE     0x0180U
#define ACCEL_TANIMOTO_RESULT   0x0200U
#define ACCEL_DESCRIPTOR_BASE   0x0300U
#define ACCEL_ADMET_RESULT_BASE 0x0340U
#define ACCEL_GNN_WEIGHT_DATA   0x0400U
#define ACCEL_GNN_WEIGHT_COMMIT 0x0404U
#define ACCEL_ADMET_WEIGHT_DATA 0x0410U
#define ACCEL_ADMET_COMMIT      0x0414U
#define ACCEL_ADJACENCY_BASE    0x1000U
#define ACCEL_FEATURE_BASE      0x2000U
#define ACCEL_GNN_OUTPUT_BASE   0x4000U

#define ACCEL_STATUS_BUSY  (1U << 0)
#define ACCEL_STATUS_DONE  (1U << 1)
#define ACCEL_STATUS_ERROR (1U << 2)

#define ACCEL_FINGERPRINT_WORDS 32U
#define ACCEL_DESCRIPTOR_COUNT  20U
#define ACCEL_ADJACENCY_WORDS   79U
#define ACCEL_FEATURE_WORDS     1600U
#define ACCEL_GNN_OUTPUT_WORDS  3200U
#define ACCEL_GNN_WEIGHT_COUNT  8192U

typedef enum {
    ACCEL_TASK_TANIMOTO = 0,
    ACCEL_TASK_GNN      = 1,
    ACCEL_TASK_ADMET    = 2,
    ACCEL_TASK_PIPELINE = 3
} accel_task_t;

typedef enum {
    ACCEL_OK          = 0,
    ACCEL_ERR_TIMEOUT = -1,
    ACCEL_ERR_HW      = -2,
    ACCEL_ERR_ARG     = -3
} accel_result_t;

u32 accel_read_status(void);
void accel_clear_status(void);
void accel_start(accel_task_t task);
accel_result_t accel_wait_done(u32 poll_limit, u32 *final_status);

void accel_write_fingerprints(const u32 query[ACCEL_FINGERPRINT_WORDS],
                              const u32 database[ACCEL_FINGERPRINT_WORDS]);
u32 accel_read_tanimoto(void);

void accel_write_descriptors(const s16 values[ACCEL_DESCRIPTOR_COUNT]);
void accel_read_admet(s16 values[4]);
void accel_write_admet_parameter(u32 model, u32 layer, u32 address, s16 value);

void accel_write_gnn_weight(u32 address, s16 value);
void accel_write_adjacency(const u32 words[ACCEL_ADJACENCY_WORDS]);
void accel_write_features(const u32 words[ACCEL_FEATURE_WORDS]);
void accel_read_gnn_output(u32 words[ACCEL_GNN_OUTPUT_WORDS]);
u32 accel_read_gnn_output_word(u32 index);

/* Deterministic Q8.8 weights used by both legacy and DMA acceptance tests. */
void accel_configure_reference_gnn_weights(void);
void accel_configure_reference_admet_weights(void);

accel_result_t accel_tanimoto_self_test(void);

#endif
