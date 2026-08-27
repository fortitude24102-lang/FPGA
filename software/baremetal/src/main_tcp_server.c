#include "accelerator.h"
#include "mol_dma_queue.h"
#include "mol_http_server.h"
#include "mol_service.h"
#include "mol_tcp_protocol.h"
#include "platform.h"

#include <string.h>

#include "lwip/init.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"
#include "xadcps.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include "xscutimer.h"
#include "xscuwdt.h"
#include "xstatus.h"
#include "xtime_l.h"

#define MOL_TCP_PORT 5001U
#define MOL_HTTP_PORT 80U
#define MOL_TCP_CONNECTION_COUNT 5U
#define MOL_HTTP_CONNECTION_COUNT 4U
#define MOL_DMA_RESET_POLL_LIMIT 1000000U
#define MOL_DMA_TIMEOUT_TICKS ((u64)COUNTS_PER_SECOND)
#define MOL_DMA_TASK_TIMEOUT_CYCLES 20000000U
#define MOL_TCP_DMA_BUFFER_BYTES MOL_DMA_MAX_TRANSFER_BYTES
#define MOL_TCP_POLL_INTERVAL 2U
#define MOL_TCP_IDLE_POLL_LIMIT 5U
#define MOL_CLOCK_WIZARD_BASEADDR 0x80410000U
#define MOL_CLOCK_STATUS_OFFSET 0x004U
#define MOL_CLOCK_CONFIG0_OFFSET 0x200U
#define MOL_CLOCK_CONFIG1_OFFSET 0x204U
#define MOL_CLOCK_OUTPUT0_OFFSET 0x208U
#define MOL_CLOCK_OUTPUT1_OFFSET 0x20cU
#define MOL_CLOCK_LOAD_OFFSET 0x25cU
#define MOL_CLOCK_LOCKED_MASK 0x1U
#define MOL_CLOCK_TIMEOUT_TICKS ((XTime)COUNTS_PER_SECOND / 10000U)
#define MOL_SERVICE_TIMER_HZ 100U
#define MOL_WATCHDOG_SECONDS 10U
#define MOL_WATCHDOG_PRESCALER 255U

#ifndef XPAR_AXIDMA_0_DEVICE_ID
#ifdef XPAR_AXI_DMA_0_DEVICE_ID
#define XPAR_AXIDMA_0_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#else
#error "AXI DMA device identifier is missing from the generated XSA"
#endif
#endif

typedef struct {
    struct tcp_pcb *pcb;
    mol_tcp_stream_t stream;
    uint32_t generation;
    uint32_t active;
    uint32_t slot;
    uint32_t idle_polls;
} mol_tcp_connection_t;

typedef struct {
    struct tcp_pcb *pcb;
    uint16_t request_used;
    uint8_t active;
    uint8_t idle_polls;
    char request[MOL_HTTP_MAX_REQUEST];
} mol_http_connection_t;

static struct netif server_netif;
static mol_tcp_connection_t connections[MOL_TCP_CONNECTION_COUNT];
static mol_http_connection_t http_connections[MOL_HTTP_CONNECTION_COUNT];
static mol_tcp_request_queue_t request_queue;
static mol_tcp_request_t current_request;
static mol_dma_device_t dma_device;
static mol_service_t service;
static XAdcPs service_xadc;
static XScuTimer service_timer;
static XScuWdt service_watchdog;

static uint8_t dma_tx[MOL_TCP_DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static uint8_t dma_rx[MOL_TCP_DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static uint8_t response_frame[MOL_TCP_HEADER_BYTES + MOL_TCP_SLOT_BYTES];
static char http_response[MOL_HTTP_MAX_RESPONSE];
static u32 reference_weights[ACCEL_REFERENCE_WEIGHT_WORDS];

static uint32_t next_batch_id = 1U;
static uint32_t weights_ready;
static uint32_t weights_epoch;
static uint32_t reload_in_progress;
static XTime tcp_timer_mark;
static uint32_t tcp_timer_quarters;

void tcp_fasttmr(void);
void tcp_slowtmr(void);

static uint32_t ticks_to_us(XTime ticks)
{
    return (uint32_t)((ticks * 1000000U) / (XTime)COUNTS_PER_SECOND);
}

static uint64_t service_timer_now(void *context)
{
    XTime now;
    (void)context;
    XTime_GetTime(&now);
    return now;
}

static int service_clock_set(void *context, uint32_t mhz)
{
    uint32_t output_config;
    XTime started;
    XTime now;
    (void)context;

    if (mhz == 50U) {
        output_config = 20U;
    } else if (mhz == 100U) {
        output_config = 10U;
    } else if (mhz == 150U) {
        output_config = (1U << 18) | (667U << 8) | 6U;
    } else {
        return -1;
    }

    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_CONFIG0_OFFSET,
              0x00000a01U);
    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_CONFIG1_OFFSET, 0U);
    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_OUTPUT0_OFFSET,
              output_config);
    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_OUTPUT1_OFFSET, 0U);
    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_LOAD_OFFSET, 7U);
    Xil_Out32(MOL_CLOCK_WIZARD_BASEADDR + MOL_CLOCK_LOAD_OFFSET, 2U);

    XTime_GetTime(&started);
    do {
        if ((Xil_In32(MOL_CLOCK_WIZARD_BASEADDR +
                      MOL_CLOCK_STATUS_OFFSET) &
             MOL_CLOCK_LOCKED_MASK) != 0U) {
            return 0;
        }
        XTime_GetTime(&now);
    } while ((now - started) < MOL_CLOCK_TIMEOUT_TICKS);
    return -1;
}

static int service_xadc_read(void *context, uint16_t *temperature_q8_8,
                             uint16_t *vccint_mv, uint16_t *vccaux_mv)
{
    XAdcPs *xadc = &service_xadc;
    float temperature;
    float vccint;
    float vccaux;

    (void)context;
    if (temperature_q8_8 == NULL || vccint_mv == NULL ||
        vccaux_mv == NULL) {
        return -1;
    }
    temperature = XAdcPs_RawToTemperature(
        XAdcPs_GetAdcData(xadc, XADCPS_CH_TEMP));
    vccint = XAdcPs_RawToVoltage(
        XAdcPs_GetAdcData(xadc, XADCPS_CH_VCCINT));
    vccaux = XAdcPs_RawToVoltage(
        XAdcPs_GetAdcData(xadc, XADCPS_CH_VCCAUX));
    *temperature_q8_8 = (uint16_t)(temperature * 256.0f + 0.5f);
    *vccint_mv = (uint16_t)(vccint * 1000.0f + 0.5f);
    *vccaux_mv = (uint16_t)(vccaux * 1000.0f + 0.5f);
    return 0;
}

static int service_mmio_write(void *context, uintptr_t address,
                              uint32_t value)
{
    (void)context;
    Xil_Out32((UINTPTR)address, value);
    return 0;
}

static void service_watchdog_kick(void *context)
{
    (void)context;
    XScuWdt_RestartWdt(&service_watchdog);
}

static void service_idle(void *context)
{
    (void)context;
    __asm__ volatile("wfi");
}

static void service_timer_interrupt(void *context)
{
    XScuTimer_ClearInterruptStatus((XScuTimer *)context);
}

static int initialize_service_hardware(void)
{
    mol_service_hooks_t hooks;
    XAdcPs_Config *xadc_config;
    XScuTimer_Config *timer_config;
    XScuWdt_Config *watchdog_config;
    uint32_t watchdog_control;
    uint32_t watchdog_load;
    int status;

    xadc_config = XAdcPs_LookupConfig(XPAR_XADCPS_0_DEVICE_ID);
    if (xadc_config == NULL) {
        return -1;
    }
    status = XAdcPs_CfgInitialize(&service_xadc, xadc_config,
                                  xadc_config->BaseAddress);
    if (status != XST_SUCCESS) {
        return -2;
    }
    XAdcPs_SetSequencerMode(&service_xadc, XADCPS_SEQ_MODE_CONTINPASS);

    timer_config = XScuTimer_LookupConfig(XPAR_XSCUTIMER_0_DEVICE_ID);
    if (timer_config == NULL ||
        XScuTimer_CfgInitialize(&service_timer, timer_config,
                                timer_config->BaseAddr) != XST_SUCCESS) {
        return -3;
    }
    status = XScuGic_Connect(&dma_device.interrupt_controller,
                             XPAR_SCUTIMER_INTR,
                             service_timer_interrupt, &service_timer);
    if (status != XST_SUCCESS) {
        return -4;
    }
    XScuGic_SetPriorityTriggerType(&dma_device.interrupt_controller,
                                   XPAR_SCUTIMER_INTR, 0xb0U, 0x1U);
    XScuGic_Enable(&dma_device.interrupt_controller, XPAR_SCUTIMER_INTR);
    XScuTimer_EnableAutoReload(&service_timer);
    XScuTimer_LoadTimer(&service_timer,
                        (uint32_t)COUNTS_PER_SECOND / MOL_SERVICE_TIMER_HZ);
    XScuTimer_EnableInterrupt(&service_timer);
    XScuTimer_Start(&service_timer);

    watchdog_config = XScuWdt_LookupConfig(XPAR_SCUWDT_0_DEVICE_ID);
    if (watchdog_config == NULL ||
        XScuWdt_CfgInitialize(&service_watchdog, watchdog_config,
                              watchdog_config->BaseAddr) != XST_SUCCESS) {
        return -5;
    }
    watchdog_control = XScuWdt_GetControlReg(&service_watchdog);
    watchdog_control &= ~XSCUWDT_CONTROL_PRESCALER_MASK;
    watchdog_control |= MOL_WATCHDOG_PRESCALER <<
                        XSCUWDT_CONTROL_PRESCALER_SHIFT;
    XScuWdt_SetControlReg(&service_watchdog, watchdog_control);
    XScuWdt_SetWdMode(&service_watchdog);
    watchdog_load = ((uint32_t)COUNTS_PER_SECOND /
                     (MOL_WATCHDOG_PRESCALER + 1U)) *
                    MOL_WATCHDOG_SECONDS;
    XScuWdt_LoadWdt(&service_watchdog, watchdog_load);
    XScuWdt_Start(&service_watchdog);

    memset(&hooks, 0, sizeof(hooks));
    hooks.context = &service_xadc;
    hooks.timer_now = service_timer_now;
    hooks.clock_set = service_clock_set;
    hooks.xadc_read = service_xadc_read;
    hooks.mmio_write = service_mmio_write;
    hooks.watchdog_kick = service_watchdog_kick;
    hooks.idle = service_idle;
    mol_service_init(&service, &hooks, (uint32_t)COUNTS_PER_SECOND,
                     ACCEL_BASEADDR);
    return 0;
}

static void service_tcp_timers(void)
{
    XTime now;
    const XTime quarter_second = (XTime)COUNTS_PER_SECOND / 4U;

    XTime_GetTime(&now);
    while ((now - tcp_timer_mark) >= quarter_second) {
        tcp_timer_mark += quarter_second;
        tcp_fasttmr();
        tcp_timer_quarters += 1U;
        if ((tcp_timer_quarters & 1U) == 0U) {
            tcp_slowtmr();
        }
    }
}

static uint32_t load_le32(const void *address)
{
    const uint8_t *bytes = (const uint8_t *)address;
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static void store_le32(void *address, uint32_t value)
{
    uint8_t *bytes = (uint8_t *)address;
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

static uint32_t parse_error_code(int rc)
{
    switch (rc) {
    case MOL_TCP_ERR_BAD_HEADER:
        return MOL_TCP_ERROR_BAD_HEADER;
    case MOL_TCP_ERR_BAD_LENGTH:
        return MOL_TCP_ERROR_BAD_LENGTH;
    case MOL_TCP_ERR_BAD_TASK:
        return MOL_TCP_ERROR_BAD_TASK;
    case MOL_TCP_ERR_BAD_BATCH:
        return MOL_TCP_ERROR_BAD_BATCH;
    default:
        return MOL_TCP_ERROR_INTERNAL;
    }
}

static int connection_matches(uint32_t slot, uint32_t generation)
{
    return slot < MOL_TCP_CONNECTION_COUNT &&
           connections[slot].active != 0U &&
           connections[slot].generation == generation &&
           connections[slot].pcb != NULL;
}

static err_t send_frame(mol_tcp_connection_t *connection,
                        const mol_tcp_header_t *request_header,
                        uint8_t response_flags,
                        const void *payload, uint32_t payload_len)
{
    mol_tcp_header_t response_header;
    uint32_t total_bytes = MOL_TCP_HEADER_BYTES + payload_len;
    err_t err;

    if (connection == NULL || connection->active == 0U ||
        connection->pcb == NULL || request_header == NULL ||
        payload_len > MOL_TCP_SLOT_BYTES ||
        (payload == NULL && payload_len != 0U)) {
        return ERR_ARG;
    }
    if (tcp_sndbuf(connection->pcb) < total_bytes) {
        return ERR_MEM;
    }

    response_header = *request_header;
    response_header.flags = response_flags | MOL_TCP_FLAG_RESPONSE;
    response_header.payload_len = payload_len;
    if (mol_tcp_encode_header(response_frame, &response_header) != MOL_TCP_OK) {
        return ERR_ARG;
    }
    if (payload_len != 0U) {
        memcpy(response_frame + MOL_TCP_HEADER_BYTES, payload, payload_len);
    }
    err = tcp_write(connection->pcb, response_frame, (u16_t)total_bytes,
                    TCP_WRITE_FLAG_COPY);
    if (err == ERR_OK) {
        err = tcp_output(connection->pcb);
        if (err == ERR_OK) {
            connection->idle_polls = 0U;
        }
    }
    return err;
}

static err_t send_error(mol_tcp_connection_t *connection,
                        const mol_tcp_header_t *request_header,
                        uint32_t error_code, uint32_t detail,
                        uint8_t extra_flags)
{
    uint8_t error_payload[8];
    store_le32(error_payload, error_code);
    store_le32(error_payload + 4U, detail);
    return send_frame(connection, request_header,
                      MOL_TCP_FLAG_ERROR | extra_flags,
                      error_payload, sizeof(error_payload));
}

static err_t release_connection(mol_tcp_connection_t *connection,
                                int abort_connection)
{
    struct tcp_pcb *pcb;
    err_t close_rc;

    if (connection == NULL || connection->active == 0U) {
        return ERR_OK;
    }
    pcb = connection->pcb;
    connection->active = 0U;
    connection->pcb = NULL;
    connection->idle_polls = 0U;
    mol_tcp_stream_init(&connection->stream);
    if (pcb == NULL) {
        return ERR_OK;
    }
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_poll(pcb, NULL, 0U);
    if (abort_connection != 0) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    close_rc = tcp_close(pcb);
    if (close_rc != ERR_OK) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    return ERR_OK;
}

static void send_request_error(const mol_tcp_request_t *request,
                               uint32_t error_code, uint32_t detail,
                               uint8_t extra_flags)
{
    mol_tcp_connection_t *connection;

    if (request == NULL ||
        !connection_matches(request->connection_slot,
                            request->connection_generation)) {
        return;
    }
    connection = &connections[request->connection_slot];
    if (send_error(connection, &request->header, error_code, detail,
                   extra_flags) != ERR_OK) {
        (void)release_connection(connection, 1);
    }
}

static void send_request_result(const mol_tcp_request_t *request,
                                const void *payload, uint32_t payload_len)
{
    mol_tcp_connection_t *connection;

    if (request == NULL ||
        !connection_matches(request->connection_slot,
                            request->connection_generation)) {
        return;
    }
    connection = &connections[request->connection_slot];
    if (send_frame(connection, &request->header, 0U,
                   payload, payload_len) != ERR_OK) {
        (void)release_connection(connection, 1);
    }
}

static void tcp_error_callback(void *arg, err_t err)
{
    mol_tcp_connection_t *connection = (mol_tcp_connection_t *)arg;
    (void)err;
    if (connection != NULL) {
        connection->active = 0U;
        connection->pcb = NULL;
        mol_tcp_stream_init(&connection->stream);
    }
}

static err_t tcp_receive_callback(void *arg, struct tcp_pcb *pcb,
                                  struct pbuf *packet, err_t err)
{
    mol_tcp_connection_t *connection = (mol_tcp_connection_t *)arg;
    struct pbuf *part;
    mol_tcp_header_t bad_header;
    int close_after_error = 0;
    int abort_after_packet = 0;
    int parse_rc = MOL_TCP_OK;

    if (connection == NULL || connection->active == 0U) {
        if (packet != NULL) {
            pbuf_free(packet);
        }
        if (pcb != NULL) {
            tcp_abort(pcb);
        }
        return ERR_ABRT;
    }
    if (packet == NULL) {
        return release_connection(connection, 0);
    }
    if (err != ERR_OK) {
        pbuf_free(packet);
        return release_connection(connection, 1);
    }

    connection->idle_polls = 0U;
    tcp_recved(pcb, packet->tot_len);
    memset(&bad_header, 0, sizeof(bad_header));
    bad_header.batch_size = 1U;

    for (part = packet;
         part != NULL && close_after_error == 0 && abort_after_packet == 0;
         part = part->next) {
        const uint8_t *bytes = (const uint8_t *)part->payload;
        size_t offset = 0U;

        while (offset < part->len) {
            size_t consumed = 0U;
            parse_rc = mol_tcp_stream_feed(&connection->stream,
                                           bytes + offset,
                                           part->len - offset,
                                           &consumed);
            offset += consumed;
            if (parse_rc < MOL_TCP_OK) {
                if (connection->stream.header_used == MOL_TCP_HEADER_BYTES) {
                    bad_header = connection->stream.header;
                    if (bad_header.batch_size == 0U) {
                        bad_header.batch_size = 1U;
                    }
                }
                close_after_error = 1;
                break;
            }
            if (parse_rc == 1) {
                int queue_rc = mol_tcp_request_queue_push(
                    &request_queue, &connection->stream.header,
                    connection->slot, connection->generation,
                    connection->stream.payload,
                    connection->stream.payload_used);
                if (queue_rc == MOL_TCP_BUSY) {
                    if (send_error(connection, &connection->stream.header,
                                   MOL_TCP_ERROR_QUEUE_FULL,
                                   request_queue.count,
                                   MOL_TCP_FLAG_BUSY) != ERR_OK) {
                        abort_after_packet = 1;
                        break;
                    }
                } else if (queue_rc != MOL_TCP_OK) {
                    close_after_error = 1;
                    parse_rc = queue_rc;
                }
                mol_tcp_stream_init(&connection->stream);
            }
            if (consumed == 0U && parse_rc == 0) {
                break;
            }
        }
    }
    pbuf_free(packet);

    if (abort_after_packet != 0) {
        return release_connection(connection, 1);
    }

    if (close_after_error != 0) {
        if (send_error(connection, &bad_header,
                       parse_error_code(parse_rc),
                       (uint32_t)(-parse_rc), 0U) != ERR_OK) {
            return release_connection(connection, 1);
        }
        return release_connection(connection, 0);
    }
    return ERR_OK;
}

static err_t tcp_poll_callback(void *arg, struct tcp_pcb *pcb)
{
    mol_tcp_connection_t *connection = (mol_tcp_connection_t *)arg;

    if (connection == NULL || connection->active == 0U ||
        connection->pcb != pcb) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    connection->idle_polls += 1U;
    if (connection->idle_polls >= MOL_TCP_IDLE_POLL_LIMIT) {
        xil_printf("TCP_IDLE_CLOSE slot=%u generation=%u\r\n",
                   connection->slot, connection->generation);
        return release_connection(connection, 1);
    }
    return ERR_OK;
}

static err_t tcp_accept_callback(void *arg, struct tcp_pcb *new_pcb,
                                 err_t err)
{
    uint32_t slot;
    (void)arg;

    if (err != ERR_OK || new_pcb == NULL) {
        return ERR_VAL;
    }
    for (slot = 0U; slot < MOL_TCP_CONNECTION_COUNT; ++slot) {
        mol_tcp_connection_t *connection = &connections[slot];
        if (connection->active == 0U) {
            connection->generation += 1U;
            if (connection->generation == 0U) {
                connection->generation = 1U;
            }
            connection->slot = slot;
            connection->pcb = new_pcb;
            connection->active = 1U;
            connection->idle_polls = 0U;
            mol_tcp_stream_init(&connection->stream);
            tcp_arg(new_pcb, connection);
            tcp_recv(new_pcb, tcp_receive_callback);
            tcp_err(new_pcb, tcp_error_callback);
            tcp_poll(new_pcb, tcp_poll_callback, MOL_TCP_POLL_INTERVAL);
            xil_printf("TCP_CONNECT slot=%u generation=%u\r\n",
                       slot, connection->generation);
            return ERR_OK;
        }
    }
    tcp_abort(new_pcb);
    return ERR_ABRT;
}

static void network_progress(void *context)
{
    struct netif *netif = (struct netif *)context;
    XTime now;
    (void)xemacif_input(netif);
    service_tcp_timers();
    XTime_GetTime(&now);
    mol_service_poll(&service, now);
}

static int execute_dma_task(uint8_t task_id, uint32_t trace_id,
                            uint32_t batch_size, const uint32_t *payload,
                            uint32_t payload_words,
                            mol_dma_result_view_t *result)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    uint32_t dma_flags;
    uint32_t item_count;
    uint32_t expected_payload_words;
    uint32_t result_words;
    uint32_t batch_id = next_batch_id++;
    size_t tx_bytes;
    size_t rx_bytes;
    size_t rx_capacity;
    int rc;

    rc = mol_tcp_dma_shape(task_id, batch_size, &dma_flags,
                           &item_count, &expected_payload_words,
                           &result_words);
    if (rc != MOL_TCP_OK || item_count != batch_size ||
        expected_payload_words != payload_words) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    rc = mol_dma_builder_init(&builder, dma_tx, sizeof(dma_tx), batch_id,
                              0U, MOL_DMA_MAX_TRANSFER_WORDS);
    if (rc == MOL_DMA_OK) {
        if (task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
            rc = mol_dma_builder_add_weight_reload(
                &builder, trace_id, payload, payload_words,
                MOL_DMA_TASK_TIMEOUT_CYCLES);
        } else {
            rc = mol_dma_builder_add_task(
                &builder, trace_id, task_id, dma_flags, batch_size, trace_id,
                MOL_DMA_TASK_TIMEOUT_CYCLES, payload, payload_words,
                result_words);
        }
    }
    if (rc == MOL_DMA_OK) {
        rc = mol_dma_builder_finalize(&builder, &tx_bytes);
    }
    if (rc != MOL_DMA_OK) {
        return rc;
    }

    rx_capacity = (size_t)builder.reserved_result_words * 4U;
    rc = mol_dma_transfer_irq_ex(
        &dma_device, dma_tx, tx_bytes, dma_rx, rx_capacity, batch_id,
        MOL_DMA_TIMEOUT_TICKS, network_progress, &server_netif,
        &rx_bytes, 0U);
    xil_printf("DMA_IRQ_COUNTS mm2s=%u s2mm=%u polling=%u\r\n",
               dma_device.mm2s_irq_count, dma_device.s2mm_irq_count,
               dma_device.polling_transfer_count);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    rc = mol_dma_results_open(&iterator, dma_rx, rx_bytes, batch_id);
    if (rc != MOL_DMA_OK) {
        return rc;
    }
    rc = mol_dma_results_next(&iterator, result);
    if (rc != 1 || result->job_id != trace_id ||
        result->task_id != task_id ||
        result->item_count != batch_size ||
        result->status != MOL_DMA_STATUS_OK ||
        result->result_words != result_words) {
        return MOL_DMA_ERR_FORMAT;
    }
    if (mol_dma_results_next(&iterator, result) != 0) {
        return MOL_DMA_ERR_FORMAT;
    }
    return MOL_DMA_OK;
}

static int initialize_reference_weights(void)
{
    mol_dma_result_view_t result;
    XTime started;
    XTime finished;
    int rc;

    weights_ready = 0U;
    reload_in_progress = 1U;
    accel_pack_reference_weights(reference_weights);
    rc = mol_service_begin(&service, MOL_DMA_TASK_WEIGHT_RELOAD, 1U);
    XTime_GetTime(&started);
    if (rc == MOL_SERVICE_OK) {
        rc = execute_dma_task(MOL_DMA_TASK_WEIGHT_RELOAD, 0U, 1U,
                              reference_weights,
                              ACCEL_REFERENCE_WEIGHT_WORDS, &result);
    } else {
        rc = MOL_DMA_ERR_STATE;
    }
    XTime_GetTime(&finished);
    if (service.fallback_active != 0U) {
        rc = MOL_DMA_ERR_TIMEOUT;
    }
    mol_service_complete(&service, rc == MOL_DMA_OK,
                         ticks_to_us(finished - started));
    if (rc == MOL_DMA_OK) {
        weights_epoch = load_le32(result.payload);
        weights_ready = 1U;
    }
    reload_in_progress = 0U;
    xil_printf("WEIGHTS_INIT ready=%u epoch=%u rc=%d\r\n",
               weights_ready, weights_epoch, rc);
    return rc;
}

static void dispatch_one_request(void)
{
    mol_dma_result_view_t result;
    XTime started;
    XTime finished;
    uint32_t dma_flags;
    uint32_t item_count;
    uint32_t payload_words;
    uint32_t result_words;
    int rc;

    if (mol_tcp_request_queue_pop(&request_queue, &current_request) !=
        MOL_TCP_OK) {
        return;
    }
    if (!connection_matches(current_request.connection_slot,
                            current_request.connection_generation)) {
        return;
    }
    if ((current_request.header.task_id == MOL_DMA_TASK_GNN ||
         current_request.header.task_id == MOL_DMA_TASK_ADMET ||
         current_request.header.task_id == MOL_DMA_TASK_PIPELINE) &&
        weights_ready == 0U) {
        send_request_error(&current_request,
                           MOL_TCP_ERROR_WEIGHTS_NOT_READY,
                           weights_epoch, 0U);
        return;
    }

    rc = mol_tcp_dma_shape(current_request.header.task_id,
                           current_request.header.batch_size,
                           &dma_flags, &item_count, &payload_words,
                           &result_words);
    (void)dma_flags;
    if (rc != MOL_TCP_OK || item_count != current_request.header.batch_size ||
        payload_words * 4U != current_request.payload_len) {
        send_request_error(&current_request, MOL_TCP_ERROR_INTERNAL,
                           (uint32_t)(-rc), 0U);
        return;
    }

    if (current_request.header.task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
        reload_in_progress = 1U;
        weights_ready = 0U;
    }
    rc = mol_service_begin(&service, current_request.header.task_id,
                           current_request.header.batch_size);
    if (rc != MOL_SERVICE_OK) {
        send_request_error(&current_request, MOL_TCP_ERROR_QUEUE_FULL,
                           service.state, MOL_TCP_FLAG_BUSY);
        return;
    }
    XTime_GetTime(&started);
    rc = execute_dma_task(current_request.header.task_id,
                          current_request.header.trace_id,
                          current_request.header.batch_size,
                          (const uint32_t *)current_request.payload,
                          payload_words, &result);
    XTime_GetTime(&finished);
    if (service.fallback_active != 0U) {
        rc = MOL_DMA_ERR_TIMEOUT;
    }
    mol_service_complete(&service, rc == MOL_DMA_OK,
                         ticks_to_us(finished - started));
    if (rc != MOL_DMA_OK) {
        if (current_request.header.task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
            reload_in_progress = 0U;
            send_request_error(&current_request, MOL_TCP_ERROR_RELOAD,
                               (uint32_t)(-rc), 0U);
        } else {
            send_request_error(&current_request, MOL_TCP_ERROR_DMA,
                               (uint32_t)(-rc), 0U);
        }
        return;
    }

    if (current_request.header.task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
        weights_epoch = load_le32(result.payload);
        weights_ready = 1U;
        reload_in_progress = 0U;
        xil_printf("WEIGHTS_RELOAD ready=1 epoch=%u trace=%u\r\n",
                   weights_epoch, current_request.header.trace_id);
    }
    mol_service_set_batch(
        &service,
        service.batch_completed + current_request.header.batch_size >
                service.batch_total ?
            service.batch_total :
            service.batch_completed + current_request.header.batch_size,
        service.batch_total);
    send_request_result(&current_request, result.payload,
                        result.result_words * 4U);
}

static err_t release_http_connection(mol_http_connection_t *connection,
                                     int abort_connection)
{
    struct tcp_pcb *pcb;
    err_t rc;
    if (connection == NULL || connection->active == 0U) {
        return ERR_OK;
    }
    pcb = connection->pcb;
    connection->active = 0U;
    connection->pcb = NULL;
    connection->request_used = 0U;
    connection->idle_polls = 0U;
    if (pcb == NULL) {
        return ERR_OK;
    }
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_poll(pcb, NULL, 0U);
    if (abort_connection != 0) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    rc = tcp_close(pcb);
    if (rc != ERR_OK) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    return ERR_OK;
}

static void http_error_callback(void *arg, err_t err)
{
    mol_http_connection_t *connection = (mol_http_connection_t *)arg;
    (void)err;
    if (connection != NULL) {
        connection->active = 0U;
        connection->pcb = NULL;
        connection->request_used = 0U;
        connection->idle_polls = 0U;
    }
}

static err_t http_receive_callback(void *arg, struct tcp_pcb *pcb,
                                   struct pbuf *packet, err_t err)
{
    mol_http_connection_t *connection = (mol_http_connection_t *)arg;
    mol_service_snapshot_t health;
    mol_benchmark_snapshot_t benchmark;
    struct pbuf *part;
    size_t response_len = 0U;
    int respond_rc;
    err_t send_rc;

    if (connection == NULL || connection->active == 0U ||
        connection->pcb != pcb) {
        if (packet != NULL) {
            pbuf_free(packet);
        }
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    if (packet == NULL) {
        return release_http_connection(connection, 0);
    }
    if (err != ERR_OK) {
        pbuf_free(packet);
        return release_http_connection(connection, 1);
    }
    connection->idle_polls = 0U;
    tcp_recved(pcb, packet->tot_len);
    for (part = packet; part != NULL; part = part->next) {
        if ((size_t)connection->request_used + part->len >
            sizeof(connection->request)) {
            pbuf_free(packet);
            return release_http_connection(connection, 1);
        }
        memcpy(connection->request + connection->request_used,
               part->payload, part->len);
        connection->request_used =
            (uint16_t)(connection->request_used + part->len);
    }
    pbuf_free(packet);

    mol_service_snapshot(&service, &health);
    mol_service_benchmark_snapshot(&service, &benchmark);
    respond_rc = mol_http_respond(connection->request,
                                  connection->request_used,
                                  &health, &benchmark, http_response,
                                  sizeof(http_response), &response_len);
    if (respond_rc == MOL_HTTP_INCOMPLETE) {
        return ERR_OK;
    }
    if (respond_rc != MOL_HTTP_READY || response_len > 0xffffU) {
        return release_http_connection(connection, 1);
    }
    send_rc = tcp_write(pcb, http_response, (u16_t)response_len,
                        TCP_WRITE_FLAG_COPY);
    if (send_rc == ERR_OK) {
        send_rc = tcp_output(pcb);
    }
    return release_http_connection(connection, send_rc != ERR_OK);
}

static err_t http_poll_callback(void *arg, struct tcp_pcb *pcb)
{
    mol_http_connection_t *connection = (mol_http_connection_t *)arg;
    if (connection == NULL || connection->active == 0U ||
        connection->pcb != pcb) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    connection->idle_polls += 1U;
    if (connection->idle_polls >= MOL_TCP_IDLE_POLL_LIMIT) {
        return release_http_connection(connection, 1);
    }
    return ERR_OK;
}

static err_t http_accept_callback(void *arg, struct tcp_pcb *new_pcb,
                                  err_t err)
{
    uint32_t slot;
    (void)arg;
    if (err != ERR_OK || new_pcb == NULL) {
        return ERR_VAL;
    }
    for (slot = 0U; slot < MOL_HTTP_CONNECTION_COUNT; ++slot) {
        mol_http_connection_t *connection = &http_connections[slot];
        if (connection->active == 0U) {
            memset(connection, 0, sizeof(*connection));
            connection->pcb = new_pcb;
            connection->active = 1U;
            tcp_arg(new_pcb, connection);
            tcp_recv(new_pcb, http_receive_callback);
            tcp_err(new_pcb, http_error_callback);
            tcp_poll(new_pcb, http_poll_callback, MOL_TCP_POLL_INTERVAL);
            return ERR_OK;
        }
    }
    tcp_abort(new_pcb);
    return ERR_ABRT;
}

static int initialize_network(void)
{
    static const uint8_t mac_address[6] = {
        0x02U, 0x00U, 0x00U, 0x00U, 0x70U, 0x15U
    };
    ip_addr_t ip_address;
    ip_addr_t netmask;
    ip_addr_t gateway;
    struct tcp_pcb *listener;
    err_t err;

    IP4_ADDR(&ip_address, 192, 168, 1, 10);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gateway, 192, 168, 1, 1);
    lwip_init();
    if (xemac_add(&server_netif, &ip_address, &netmask, &gateway,
                  (unsigned char *)mac_address,
                  XPAR_XEMACPS_0_BASEADDR) == NULL) {
        return -1;
    }
    netif_set_default(&server_netif);
    netif_set_up(&server_netif);

    listener = tcp_new();
    if (listener == NULL) {
        return -2;
    }
    err = tcp_bind(listener, IP_ADDR_ANY, MOL_TCP_PORT);
    if (err != ERR_OK) {
        tcp_close(listener);
        return -3;
    }
    listener = tcp_listen(listener);
    if (listener == NULL) {
        return -4;
    }
    tcp_accept(listener, tcp_accept_callback);

    listener = tcp_new();
    if (listener == NULL) {
        return -5;
    }
    err = tcp_bind(listener, IP_ADDR_ANY, MOL_HTTP_PORT);
    if (err != ERR_OK) {
        tcp_close(listener);
        return -6;
    }
    listener = tcp_listen(listener);
    if (listener == NULL) {
        return -7;
    }
    tcp_accept(listener, http_accept_callback);
    return 0;
}

int main(void)
{
    XTime now;
    int rc;

    init_platform();
    XTime_GetTime(&tcp_timer_mark);
    mol_tcp_queue_init(&request_queue);
    memset(connections, 0, sizeof(connections));
    memset(http_connections, 0, sizeof(http_connections));

    xil_printf("\r\nZ15 molecular accelerator TCP service\r\n");
    rc = mol_dma_device_init(&dma_device, XPAR_AXIDMA_0_DEVICE_ID,
                             MOL_DMA_RESET_POLL_LIMIT);
    if (rc == MOL_DMA_OK) {
        rc = mol_dma_device_connect_irqs(
            &dma_device,
            XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR,
            XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR);
    }
    if (rc != MOL_DMA_OK) {
        xil_printf("FATAL DMA_INIT rc=%d\r\n", rc);
        cleanup_platform();
        return 1;
    }

    rc = initialize_network();
    if (rc != 0) {
        xil_printf("FATAL NETWORK_INIT rc=%d\r\n", rc);
        cleanup_platform();
        return 1;
    }
    rc = initialize_service_hardware();
    if (rc != 0) {
        xil_printf("FATAL SERVICE_INIT rc=%d\r\n", rc);
        cleanup_platform();
        return 1;
    }
    (void)mol_service_mark_ready(&service);
    (void)initialize_reference_weights();
    xil_printf("PHY address: 7\r\n");
    xil_printf("TCP server: 192.168.1.10:5001\r\n");
    xil_printf("HTTP dashboard: http://192.168.1.10/\r\n");
    xil_printf("DMA mode: interrupt\r\n");
    xil_printf("weights_ready=%u epoch=%u\r\n",
               weights_ready, weights_epoch);

    for (;;) {
        (void)xemacif_input(&server_netif);
        service_tcp_timers();
        XTime_GetTime(&now);
        mol_service_poll(&service, now);
        if (request_queue.count != 0U) {
            dispatch_one_request();
        } else {
            mol_service_idle(&service);
        }
    }
}
