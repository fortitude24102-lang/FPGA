#include "accelerator.h"
#include "mol_dma_queue.h"
#include "mol_tcp_protocol.h"
#include "platform.h"

#include <string.h>

#include "lwip/init.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtime_l.h"

#define MOL_TCP_PORT 5001U
#define MOL_TCP_CONNECTION_COUNT 5U
#define MOL_DMA_RESET_POLL_LIMIT 1000000U
#define MOL_DMA_TIMEOUT_TICKS ((u64)COUNTS_PER_SECOND)
#define MOL_DMA_TASK_TIMEOUT_CYCLES 20000000U
#define MOL_TCP_DMA_BUFFER_BYTES MOL_DMA_MAX_TRANSFER_BYTES

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
} mol_tcp_connection_t;

static struct netif server_netif;
static mol_tcp_connection_t connections[MOL_TCP_CONNECTION_COUNT];
static mol_tcp_request_queue_t request_queue;
static mol_tcp_request_t current_request;
static mol_dma_device_t dma_device;

static uint8_t dma_tx[MOL_TCP_DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static uint8_t dma_rx[MOL_TCP_DMA_BUFFER_BYTES] __attribute__((aligned(64)));
static uint8_t response_frame[MOL_TCP_HEADER_BYTES + MOL_TCP_SLOT_BYTES];
static u32 reference_weights[ACCEL_REFERENCE_WEIGHT_WORDS];

static uint32_t next_batch_id = 1U;
static uint32_t weights_ready;
static uint32_t weights_epoch;
static uint32_t reload_in_progress;
static XTime tcp_timer_mark;
static uint32_t tcp_timer_quarters;

void tcp_fasttmr(void);
void tcp_slowtmr(void);

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

static void release_connection(mol_tcp_connection_t *connection,
                               int abort_connection)
{
    struct tcp_pcb *pcb;

    if (connection == NULL || connection->active == 0U) {
        return;
    }
    pcb = connection->pcb;
    connection->active = 0U;
    connection->pcb = NULL;
    mol_tcp_stream_init(&connection->stream);
    if (pcb == NULL) {
        return;
    }
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_err(pcb, NULL);
    if (abort_connection != 0 || tcp_close(pcb) != ERR_OK) {
        tcp_abort(pcb);
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
    int parse_rc = MOL_TCP_OK;

    if (connection == NULL || connection->active == 0U) {
        if (packet != NULL) {
            pbuf_free(packet);
        }
        return ERR_ARG;
    }
    if (packet == NULL) {
        release_connection(connection, 0);
        return ERR_OK;
    }
    if (err != ERR_OK) {
        pbuf_free(packet);
        release_connection(connection, 1);
        return err;
    }

    tcp_recved(pcb, packet->tot_len);
    memset(&bad_header, 0, sizeof(bad_header));
    bad_header.batch_size = 1U;

    for (part = packet; part != NULL && close_after_error == 0;
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
                        close_after_error = 1;
                        parse_rc = MOL_TCP_ERR_STATE;
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

    if (close_after_error != 0) {
        (void)send_error(connection, &bad_header,
                         parse_error_code(parse_rc),
                         (uint32_t)(-parse_rc), 0U);
        release_connection(connection, 0);
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
            mol_tcp_stream_init(&connection->stream);
            tcp_arg(new_pcb, connection);
            tcp_recv(new_pcb, tcp_receive_callback);
            tcp_err(new_pcb, tcp_error_callback);
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
    (void)xemacif_input(netif);
    service_tcp_timers();
}

static int execute_dma_task(uint8_t task_id, uint32_t trace_id,
                            uint32_t batch_size, const uint32_t *payload,
                            uint32_t payload_words,
                            mol_dma_result_view_t *result)
{
    mol_dma_builder_t builder;
    mol_dma_result_iterator_t iterator;
    uint32_t dma_flags;
    uint32_t expected_payload_words;
    uint32_t result_words;
    uint32_t batch_id = next_batch_id++;
    size_t tx_bytes;
    size_t rx_bytes;
    size_t rx_capacity;
    int rc;

    rc = mol_tcp_dma_shape(task_id, batch_size, &dma_flags,
                           &expected_payload_words, &result_words);
    if (rc != MOL_TCP_OK || expected_payload_words != payload_words) {
        return MOL_DMA_ERR_ARGUMENT;
    }
    rc = mol_dma_builder_init(&builder, dma_tx, sizeof(dma_tx), batch_id,
                              0U, MOL_DMA_MAX_TRANSFER_WORDS);
    if (rc == MOL_DMA_OK) {
        rc = mol_dma_builder_add_task(
            &builder, trace_id, task_id, dma_flags, batch_size, trace_id,
            MOL_DMA_TASK_TIMEOUT_CYCLES, payload, payload_words,
            result_words);
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
    int rc;

    weights_ready = 0U;
    reload_in_progress = 1U;
    accel_pack_reference_weights(reference_weights);
    rc = execute_dma_task(MOL_DMA_TASK_WEIGHT_RELOAD, 0U, 1U,
                          reference_weights,
                          ACCEL_REFERENCE_WEIGHT_WORDS, &result);
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
    mol_tcp_connection_t *connection;
    mol_dma_result_view_t result;
    uint32_t dma_flags;
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
    connection = &connections[current_request.connection_slot];

    if ((current_request.header.task_id == MOL_DMA_TASK_GNN ||
         current_request.header.task_id == MOL_DMA_TASK_ADMET ||
         current_request.header.task_id == MOL_DMA_TASK_PIPELINE) &&
        weights_ready == 0U) {
        (void)send_error(connection, &current_request.header,
                         MOL_TCP_ERROR_WEIGHTS_NOT_READY,
                         weights_epoch, 0U);
        return;
    }

    rc = mol_tcp_dma_shape(current_request.header.task_id,
                           current_request.header.batch_size,
                           &dma_flags, &payload_words, &result_words);
    (void)dma_flags;
    if (rc != MOL_TCP_OK ||
        payload_words * 4U != current_request.payload_len) {
        (void)send_error(connection, &current_request.header,
                         MOL_TCP_ERROR_INTERNAL, (uint32_t)(-rc), 0U);
        return;
    }

    if (current_request.header.task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
        reload_in_progress = 1U;
        weights_ready = 0U;
    }
    rc = execute_dma_task(current_request.header.task_id,
                          current_request.header.trace_id,
                          current_request.header.batch_size,
                          (const uint32_t *)current_request.payload,
                          payload_words, &result);
    if (rc != MOL_DMA_OK) {
        if (current_request.header.task_id == MOL_DMA_TASK_WEIGHT_RELOAD) {
            reload_in_progress = 0U;
            (void)send_error(connection, &current_request.header,
                             MOL_TCP_ERROR_RELOAD, (uint32_t)(-rc), 0U);
        } else {
            (void)send_error(connection, &current_request.header,
                             MOL_TCP_ERROR_DMA, (uint32_t)(-rc), 0U);
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
    if (connection_matches(current_request.connection_slot,
                           current_request.connection_generation)) {
        (void)send_frame(connection, &current_request.header, 0U,
                         result.payload, result.result_words * 4U);
    }
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
    return 0;
}

int main(void)
{
    int rc;

    init_platform();
    XTime_GetTime(&tcp_timer_mark);
    mol_tcp_queue_init(&request_queue);
    memset(connections, 0, sizeof(connections));

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
    (void)initialize_reference_weights();
    xil_printf("PHY address: 7\r\n");
    xil_printf("TCP server: 192.168.1.10:5001\r\n");
    xil_printf("weights_ready=%u epoch=%u\r\n",
               weights_ready, weights_epoch);

    for (;;) {
        (void)xemacif_input(&server_netif);
        service_tcp_timers();
        if (request_queue.count != 0U) {
            dispatch_one_request();
        }
    }
}
