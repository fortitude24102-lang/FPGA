#include "accelerator.h"
#include "mol_dma_queue.h"
#include "platform.h"

#include "xil_printf.h"
#include "xparameters.h"
#include "xtime_l.h"

#define DMA_BUFFER_BYTES       MOL_DMA_MAX_TRANSFER_BYTES
#define DMA_POLL_LIMIT         100000000U
#define DMA_RESET_POLL_LIMIT   1000000U
#define ACCEL_POLL_LIMIT       20000000U
#define STRESS_BATCHES         1000U
#define PAYLOAD_SCRATCH_WORDS  (32U + 64U * 32U)

/* Same-input Python reference timings from benchmark_results.json, rounded
 * to whole microseconds for the integer-only UART schema. */
#define PY_TANIMOTO_US          6U
#define PY_GNN_US           13471U
#define PY_ADMET_US            32U
#define PY_PIPELINE_US       13509U

#ifndef XPAR_AXIDMA_0_DEVICE_ID
#ifdef XPAR_AXI_DMA_0_DEVICE_ID
#define XPAR_AXIDMA_0_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#else
#define XPAR_AXIDMA_0_DEVICE_ID 0U
#endif
#endif

static u8 tx_buffer[DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static u8 rx_buffer[DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static u32 payload[PAYLOAD_SCRATCH_WORDS];

static mol_dma_device_t dma_device;
static u32 next_batch_id = 1U;

static u32 load_le32(const void *address)
{
    const u8 *p = (const u8 *)address;
    return (u32)p[0] | ((u32)p[1] << 8) |
           ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static void store_le32(void *address, u32 value)
{
    u8 *p = (u8 *)address;
    p[0] = (u8)value;
    p[1] = (u8)(value >> 8);
    p[2] = (u8)(value >> 16);
    p[3] = (u8)(value >> 24);
}

static u32 elapsed_us(XTime start, XTime end)
{
    u64 ticks = (u64)(end - start);
    u32 us = (u32)((ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND);
    return (us == 0U) ? 1U : us;
}

static void print_perf(const char *name, u32 tasks, size_t tx_bytes,
                       size_t rx_bytes, u32 us, u32 baseline_us)
{
    u64 total_bytes = (u64)tx_bytes + (u64)rx_bytes;
    u32 mbps_x100 = (u32)((total_bytes * 100ULL) / (u64)us);
    u32 speedup_x100 = (baseline_us == 0U) ? 0U :
                       (u32)(((u64)baseline_us * 100ULL) / (u64)us);
    xil_printf("PERF name=%s tasks=%u tx=%u rx=%u us=%u "
               "MBps=%u.%02u speedup=%u.%02u\r\n",
               name, tasks, (u32)tx_bytes, (u32)rx_bytes, us,
               mbps_x100 / 100U, mbps_x100 % 100U,
               speedup_x100 / 100U, speedup_x100 % 100U);
}

static void fill_tanimoto_pair(u32 query_word, u32 database_word)
{
    u32 index;
    for (index = 0U; index < 32U; ++index) {
        payload[index] = query_word;
        payload[32U + index] = database_word;
    }
}

static void fill_tanimoto_shared(u32 count)
{
    u32 index;
    for (index = 0U; index < 32U + count * 32U; ++index) {
        payload[index] = 0xFFFFFFFFU;
    }
}

static void fill_gnn_payload(u32 base)
{
    u32 index;
    for (index = 0U; index < MOL_DMA_PAYLOAD_WORDS_GNN_TOTAL; ++index) {
        payload[base + index] = 0U;
    }
    payload[base] = 1U;
    payload[base + MOL_DMA_PAYLOAD_WORDS_GNN_ADJACENCY] = 0x00000100U;
}

static void fill_admet_payload(u32 base, u32 item_count)
{
    u32 item;
    u32 descriptor;
    for (item = 0U; item < item_count; ++item) {
        for (descriptor = 0U; descriptor < 20U; ++descriptor) {
            payload[base + item * 20U + descriptor] = 0U;
        }
        payload[base + item * 20U] = 0x00000100U;
    }
}

static void fill_pipeline_payload(void)
{
    fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
    fill_gnn_payload(64U);
    fill_admet_payload(1743U, 1U);
}

static int builder_begin(mol_dma_builder_t *builder, u32 batch_flags,
                         u32 *batch_id)
{
    *batch_id = next_batch_id++;
    return mol_dma_builder_init(builder, tx_buffer, sizeof(tx_buffer),
                                *batch_id, batch_flags,
                                MOL_DMA_MAX_TRANSFER_WORDS);
}

static int add_task(mol_dma_builder_t *builder, u32 job_id, u32 task_id,
                    u32 flags, u32 item_count, u32 timeout_cycles)
{
    u32 payload_words;
    u32 result_words;
    int rc = mol_dma_required_words(task_id, flags, item_count,
                                    &payload_words, &result_words);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    return mol_dma_builder_add_task(builder, job_id, task_id, flags,
                                    item_count, 0xA5000000U ^ job_id,
                                    timeout_cycles, payload, payload_words,
                                    result_words);
}

static int execute_batch(mol_dma_builder_t *builder, u32 batch_id,
                         mol_dma_result_iterator_t *iterator,
                         size_t *tx_bytes, size_t *rx_bytes, u32 *transfer_us)
{
    XTime start;
    XTime end;
    int rc;

    if (builder->finalized == 0U) {
        rc = mol_dma_builder_finalize(builder, tx_bytes);
        if (rc != MOL_DMA_OK) {
            return rc;
        }
    } else {
        *tx_bytes = (size_t)builder->used_words * 4U;
    }

    XTime_GetTime(&start);
    rc = mol_dma_transfer_poll(&dma_device, tx_buffer, *tx_bytes,
                               rx_buffer, sizeof(rx_buffer), batch_id,
                               DMA_POLL_LIMIT, rx_bytes);
    XTime_GetTime(&end);
    *transfer_us = elapsed_us(start, end);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    return mol_dma_results_open(iterator, rx_buffer, *rx_bytes, batch_id);
}

static int expect_record(mol_dma_result_iterator_t *iterator, u32 job_id,
                         u32 task_id, u32 status,
                         mol_dma_result_view_t *view)
{
    int rc = mol_dma_results_next(iterator, view);
    if (rc != 1 || view->job_id != job_id || view->task_id != task_id ||
        view->status != status ||
        view->user_tag != (0xA5000000U ^ job_id)) {
        xil_printf("FAIL record job=%u task=%u status=%u rc=%d\r\n",
                   job_id, task_id, status, rc);
        return 1;
    }
    return 0;
}

static int pure_layout_self_test(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t bytes;
    u32 total_words = 25U;
    int rc;

    rc = mol_dma_builder_init(&builder, tx_buffer, sizeof(tx_buffer),
                              0x11223344U, 0U, 64U);
    if (rc != MOL_DMA_OK) {
        return 1;
    }
    fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
    rc = add_task(&builder, 1U, MOL_DMA_TASK_TANIMOTO, 0U, 1U, 1000U);
    if (rc != MOL_DMA_OK ||
        mol_dma_builder_finalize(&builder, &bytes) != MOL_DMA_OK ||
        load_le32(tx_buffer) != MOL_DMA_MAGIC_REQUEST ||
        load_le32(tx_buffer + 16U) * 4U != bytes) {
        return 1;
    }

    /* A small deterministic response checks the zero-copy parser before DMA. */
    store_le32(rx_buffer + 0U, MOL_DMA_MAGIC_RESPONSE);
    store_le32(rx_buffer + 4U,
               (MOL_DMA_BATCH_HEADER_WORDS << 16) | MOL_DMA_VERSION);
    store_le32(rx_buffer + 8U, 0x11223344U);
    store_le32(rx_buffer + 12U, 1U);
    store_le32(rx_buffer + 16U, 0U);
    store_le32(rx_buffer + 20U, total_words);
    store_le32(rx_buffer + 24U, 0U);
    store_le32(rx_buffer + 28U, 0U);
    store_le32(rx_buffer + 32U, 1U);
    store_le32(rx_buffer + 36U, MOL_DMA_TASK_TANIMOTO);
    store_le32(rx_buffer + 40U, 1U);
    store_le32(rx_buffer + 44U, 7U);
    store_le32(rx_buffer + 48U, 0U);
    store_le32(rx_buffer + 52U, 1U);
    store_le32(rx_buffer + 56U, 0xA5000001U);
    store_le32(rx_buffer + 60U, 0U);
    store_le32(rx_buffer + 64U, 0x00010000U);
    store_le32(rx_buffer + 68U, MOL_DMA_MAGIC_TRAILER);
    store_le32(rx_buffer + 72U, 0x11223344U);
    store_le32(rx_buffer + 76U, 1U);
    store_le32(rx_buffer + 80U, 0U);
    store_le32(rx_buffer + 84U, total_words);
    store_le32(rx_buffer + 88U, 0U);
    store_le32(rx_buffer + 92U, 0xFFFFFFFFU);
    store_le32(rx_buffer + 96U, 0U);
    if (mol_dma_results_open(&iterator, rx_buffer, total_words * 4U,
                             0x11223344U) != MOL_DMA_OK ||
        mol_dma_results_next(&iterator, &view) != 1 ||
        load_le32(view.payload) != 0x00010000U ||
        mol_dma_results_next(&iterator, &view) != 0) {
        return 1;
    }
    xil_printf("PASS: pure packet builder/parser self-test\r\n");
    return 0;
}

static u32 legacy_tanimoto_batch_us(u32 count)
{
    u32 index;
    u32 status;
    XTime start;
    XTime end;
    u32 query[32];
    u32 database[32];
    for (index = 0U; index < 32U; ++index) {
        query[index] = 0xFFFFFFFFU;
        database[index] = 0xFFFFFFFFU;
    }
    XTime_GetTime(&start);
    for (index = 0U; index < count; ++index) {
        accel_clear_status();
        accel_write_fingerprints(query, database);
        accel_start(ACCEL_TASK_TANIMOTO);
        (void)accel_wait_done(ACCEL_POLL_LIMIT, &status);
    }
    XTime_GetTime(&end);
    return elapsed_us(start, end);
}

static int run_tanimoto_references(void)
{
    const u32 query[3] = {0xFFFFFFFFU, 0xAAAAAAAAU, 0xF0F0F0F0U};
    const u32 database[3] = {0xFFFFFFFFU, 0x55555555U, 0xCCCCCCCCU};
    const u32 expected[3] = {0x00010000U, 0x00000000U, 0x00005555U};
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 index;

    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK) {
        return 1;
    }
    for (index = 0U; index < 3U; ++index) {
        fill_tanimoto_pair(query[index], database[index]);
        if (add_task(&builder, 100U + index, MOL_DMA_TASK_TANIMOTO,
                     0U, 1U, 100000U) != MOL_DMA_OK) {
            return 1;
        }
    }
    if (execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK) {
        return 1;
    }
    for (index = 0U; index < 3U; ++index) {
        if (expect_record(&iterator, 100U + index, MOL_DMA_TASK_TANIMOTO,
                          MOL_DMA_STATUS_OK, &view) != 0 ||
            view.result_words != 1U ||
            load_le32(view.payload) != expected[index]) {
            return 1;
        }
    }
    xil_printf("PASS: DMA Tanimoto three reference vectors\r\n");
    print_perf("tanimoto_refs", 3U, tx_bytes, rx_bytes, us,
               3U * PY_TANIMOTO_US);
    return 0;
}

static int run_shared_tanimoto_64(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 baseline_us;
    u32 index;

    fill_tanimoto_shared(64U);
    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK ||
        add_task(&builder, 200U, MOL_DMA_TASK_TANIMOTO,
                 MOL_DMA_FLAG_SHARED_QUERY, 64U, 1000000U) != MOL_DMA_OK ||
        execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 200U, MOL_DMA_TASK_TANIMOTO,
                      MOL_DMA_STATUS_OK, &view) != 0 ||
        view.result_words != 64U) {
        return 1;
    }
    for (index = 0U; index < 64U; ++index) {
        if (load_le32(view.payload + index * 4U) != 0x00010000U) {
            return 1;
        }
    }
    baseline_us = legacy_tanimoto_batch_us(64U);
    xil_printf("PASS: DMA shared-query Tanimoto N=64\r\n");
    print_perf("tanimoto_shared64", 64U, tx_bytes, rx_bytes, us, baseline_us);
    return 0;
}

static int run_gnn_modes(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 index;

    fill_gnn_payload(0U);
    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK ||
        add_task(&builder, 300U, MOL_DMA_TASK_GNN, 0U, 1U,
                 10000000U) != MOL_DMA_OK ||
        add_task(&builder, 301U, MOL_DMA_TASK_GNN,
                 MOL_DMA_FLAG_FULL_GNN_OUTPUT, 1U,
                 10000000U) != MOL_DMA_OK ||
        execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 300U, MOL_DMA_TASK_GNN,
                      MOL_DMA_STATUS_OK, &view) != 0 ||
        view.result_words != 1U || load_le32(view.payload) != 0x100U ||
        expect_record(&iterator, 301U, MOL_DMA_TASK_GNN,
                      MOL_DMA_STATUS_OK, &view) != 0 ||
        view.result_words != 3200U || load_le32(view.payload) != 0x100U) {
        return 1;
    }
    for (index = 1U; index < 3200U; ++index) {
        if (load_le32(view.payload + index * 4U) != 0U) {
            return 1;
        }
    }
    xil_printf("PASS: DMA GNN summary/full output[0]=1.0000\r\n");
    print_perf("gnn_summary_full", 2U, tx_bytes, rx_bytes, us,
               2U * PY_GNN_US);
    return 0;
}

static int run_admet_64(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 index;

    fill_admet_payload(0U, 64U);
    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK ||
        add_task(&builder, 400U, MOL_DMA_TASK_ADMET, 0U, 64U,
                 1000000U) != MOL_DMA_OK ||
        execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 400U, MOL_DMA_TASK_ADMET,
                      MOL_DMA_STATUS_OK, &view) != 0 ||
        view.result_words != 256U) {
        return 1;
    }
    for (index = 0U; index < 256U; ++index) {
        if (load_le32(view.payload + index * 4U) != 187U) {
            return 1;
        }
    }
    xil_printf("PASS: DMA ADMET N=64 four outputs/item = 0.7305\r\n");
    print_perf("admet64", 64U, tx_bytes, rx_bytes, us,
               64U * PY_ADMET_US);
    return 0;
}

static int run_pipeline_modes(void)
{
    const u32 flags[3] = {0U, MOL_DMA_FLAG_RETURN_INTERMEDIATE,
                          MOL_DMA_FLAG_FULL_GNN_OUTPUT};
    const u32 sizes[3] = {4U, 6U, 3205U};
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 index;

    fill_pipeline_payload();
    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK) {
        return 1;
    }
    for (index = 0U; index < 3U; ++index) {
        if (add_task(&builder, 500U + index, MOL_DMA_TASK_PIPELINE,
                     flags[index], 1U, 20000000U) != MOL_DMA_OK) {
            return 1;
        }
    }
    if (execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK) {
        return 1;
    }
    for (index = 0U; index < 3U; ++index) {
        if (expect_record(&iterator, 500U + index, MOL_DMA_TASK_PIPELINE,
                          MOL_DMA_STATUS_OK, &view) != 0 ||
            view.result_words != sizes[index]) {
            return 1;
        }
    }
    xil_printf("PASS: DMA Pipeline default/intermediate/full\r\n");
    print_perf("pipeline_modes", 3U, tx_bytes, rx_bytes, us,
               3U * PY_PIPELINE_US);
    return 0;
}

static int run_mixed_batch(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 task;

    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK) {
        return 1;
    }
    fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
    if (add_task(&builder, 600U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK) return 1;
    fill_gnn_payload(0U);
    if (add_task(&builder, 601U, MOL_DMA_TASK_GNN, 0U, 1U,
                 10000000U) != MOL_DMA_OK) return 1;
    fill_admet_payload(0U, 1U);
    if (add_task(&builder, 602U, MOL_DMA_TASK_ADMET, 0U, 1U,
                 1000000U) != MOL_DMA_OK) return 1;
    fill_pipeline_payload();
    if (add_task(&builder, 603U, MOL_DMA_TASK_PIPELINE, 0U, 1U,
                 20000000U) != MOL_DMA_OK) return 1;
    if (execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK) return 1;
    for (task = 0U; task < 4U; ++task) {
        if (expect_record(&iterator, 600U + task, task,
                          MOL_DMA_STATUS_OK, &view) != 0) return 1;
    }
    xil_printf("PASS: DMA mixed task order 0/1/2/3\r\n");
    print_perf("mixed0123", 4U, tx_bytes, rx_bytes, us,
               PY_TANIMOTO_US + PY_GNN_US +
               PY_ADMET_US + PY_PIPELINE_US);
    return 0;
}

static int run_protocol_errors(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;

    fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
    if (builder_begin(&builder, MOL_DMA_BATCH_FLAG_CONTINUE_ON_TASK_ERROR,
                      &batch_id) != MOL_DMA_OK ||
        add_task(&builder, 700U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK ||
        add_task(&builder, 701U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK ||
        mol_dma_builder_finalize(&builder, &tx_bytes) != MOL_DMA_OK) return 1;
    store_le32(tx_buffer + (8U + 1U) * 4U,
               MOL_DMA_TASK_TANIMOTO | 0x800U);
    if (execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 700U, MOL_DMA_TASK_TANIMOTO,
                      MOL_DMA_STATUS_BAD_FLAGS, &view) != 0 ||
        expect_record(&iterator, 701U, MOL_DMA_TASK_TANIMOTO,
                      MOL_DMA_STATUS_OK, &view) != 0) return 1;

    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK ||
        add_task(&builder, 704U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK ||
        add_task(&builder, 705U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK ||
        mol_dma_builder_finalize(&builder, &tx_bytes) != MOL_DMA_OK) return 1;
    store_le32(tx_buffer + (8U + 1U) * 4U,
               MOL_DMA_TASK_TANIMOTO | 0x800U);
    if (execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 704U, MOL_DMA_TASK_TANIMOTO,
                      MOL_DMA_STATUS_BAD_FLAGS, &view) != 0 ||
        mol_dma_results_next(&iterator, &view) != 0) return 1;

    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK) return 1;
    fill_gnn_payload(0U);
    if (add_task(&builder, 702U, MOL_DMA_TASK_GNN, 0U, 1U, 1U) != MOL_DMA_OK ||
        execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 702U, MOL_DMA_TASK_GNN,
                      MOL_DMA_STATUS_TASK_TIMEOUT, &view) != 0) return 1;

    if (mol_dma_device_reset(&dma_device, DMA_RESET_POLL_LIMIT) != MOL_DMA_OK)
        return 1;
    if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK) return 1;
    fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
    if (add_task(&builder, 703U, MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                 100000U) != MOL_DMA_OK ||
        execute_batch(&builder, batch_id, &iterator,
                      &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
        expect_record(&iterator, 703U, MOL_DMA_TASK_TANIMOTO,
                      MOL_DMA_STATUS_OK, &view) != 0) return 1;
    xil_printf("PASS: continue/stop-on-error, timeout and DMA reset recovery\r\n");
    return 0;
}

static int run_stress(void)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    mol_dma_result_view_t view;
    size_t tx_bytes;
    size_t rx_bytes;
    u32 batch_id;
    u32 us;
    u32 iteration;
    u32 hash = 2166136261U;

    for (iteration = 0U; iteration < STRESS_BATCHES; ++iteration) {
        fill_tanimoto_pair(0xFFFFFFFFU, 0xFFFFFFFFU);
        if (builder_begin(&builder, 0U, &batch_id) != MOL_DMA_OK ||
            add_task(&builder, 0x10000U + iteration,
                     MOL_DMA_TASK_TANIMOTO, 0U, 1U,
                     100000U) != MOL_DMA_OK ||
            execute_batch(&builder, batch_id, &iterator,
                          &tx_bytes, &rx_bytes, &us) != MOL_DMA_OK ||
            expect_record(&iterator, 0x10000U + iteration,
                          MOL_DMA_TASK_TANIMOTO,
                          MOL_DMA_STATUS_OK, &view) != 0 ||
            load_le32(view.payload) != 0x00010000U) {
            xil_printf("FAIL: stress batch %u\r\n", iteration);
            return 1;
        }
        hash = (hash ^ batch_id) * 16777619U;
        hash = (hash ^ load_le32(view.payload)) * 16777619U;
    }
    xil_printf("PASS: DMA stress batches=1000 hash=0x%08x\r\n", hash);
    return 0;
}

int main(void)
{
    int failures = 0;
    int rc;

    init_platform();
    xil_printf("\r\nZ15 molecular accelerator DMA batch self-test\r\n");
    xil_printf("Accelerator AXI-Lite: 0x%08x\r\n", (u32)ACCEL_BASEADDR);
    xil_printf("AXI DMA control: 0x80400000, HP0 burst, AXIS 128-bit\r\n");
    xil_printf("UART0: PS MIO14/MIO15, 115200 8N1\r\n");
    xil_printf("PERF_BASELINE source=benchmark_results.json "
               "tanimoto_us=%u gnn_us=%u admet_us=%u pipeline_us=%u\r\n",
               PY_TANIMOTO_US, PY_GNN_US,
               PY_ADMET_US, PY_PIPELINE_US);

    if (pure_layout_self_test() != 0) {
        xil_printf("FAIL: pure packet builder/parser self-test\r\n");
        cleanup_platform();
        return 1;
    }

    rc = mol_dma_device_init(&dma_device, XPAR_AXIDMA_0_DEVICE_ID,
                             DMA_RESET_POLL_LIMIT);
    if (rc != MOL_DMA_OK) {
        xil_printf("FAIL: AXI DMA init rc=%d device=%u\r\n",
                   rc, (u32)XPAR_AXIDMA_0_DEVICE_ID);
        cleanup_platform();
        return 1;
    }

    xil_printf("INFO: configuring reference GNN/ADMET weights\r\n");
    accel_configure_reference_gnn_weights();
    accel_configure_reference_admet_weights();

    failures += run_tanimoto_references();
    failures += run_shared_tanimoto_64();
    failures += run_gnn_modes();
    failures += run_admet_64();
    failures += run_pipeline_modes();
    failures += run_mixed_batch();
    failures += run_protocol_errors();
    failures += run_stress();

    if (failures == 0) {
        xil_printf("ALL DMA BATCH SELF-TESTS PASSED\r\n");
    } else {
        xil_printf("DMA BATCH SELF-TEST FAILED errors=%d\r\n", failures);
    }
    cleanup_platform();
    return (failures == 0) ? 0 : 1;
}
