`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module dma_task_queue #(
    parameter [31:0] DEFAULT_TIMEOUT_CYCLES = 32'd1000000,
    // The AXI ingress owns a 6-bit sequence field; the on-chip scoreboard
    // keeps 16 live tasks and backpressures the host for the remainder.
    parameter integer SCOREBOARD_DEPTH = 16
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         in_batch_valid,
    output wire         in_batch_ready,
    input  wire [31:0]  in_batch_id,
    input  wire [31:0]  in_batch_task_count,
    input  wire [31:0]  in_batch_flags,
    input  wire [31:0]  in_batch_max_result_words,
    input  wire [7:0]   in_batch_status,
    input  wire [31:0]  in_batch_detail,

    input  wire         in_task_valid,
    output wire         in_task_ready,
    input  wire [31:0]  in_task_job_id,
    input  wire [7:0]   in_task_id,
    input  wire [31:0]  in_task_flags,
    input  wire [31:0]  in_task_payload_words,
    input  wire [31:0]  in_task_result_capacity_words,
    input  wire [31:0]  in_task_item_count,
    input  wire [31:0]  in_task_user_tag,
    input  wire [31:0]  in_task_timeout_cycles,
    input  wire [7:0]   in_task_status,
    input  wire [31:0]  in_task_detail,

    input  wire         in_payload_valid,
    output wire         in_payload_ready,
    input  wire [31:0]  in_payload_data,
    input  wire         in_payload_last,

    input  wire         in_end_valid,
    output wire         in_end_ready,
    input  wire [7:0]   in_end_status,
    input  wire [31:0]  in_end_detail,

    output wire         fmt_batch_valid,
    input  wire         fmt_batch_ready,
    output wire [31:0]  fmt_batch_id,
    output wire [31:0]  fmt_expected_task_count,
    output wire [7:0]   fmt_header_status,
    output wire [31:0]  fmt_output_capacity_words,

    output wire         fmt_result_valid,
    input  wire         fmt_result_ready,
    input  wire         fmt_result_reject,
    output wire [31:0]  fmt_result_job_id,
    output wire [7:0]   fmt_result_task_id,
    output wire [23:0]  fmt_result_status,
    output wire [31:0]  fmt_result_words,
    output wire [63:0]  fmt_result_compute_cycles,
    output wire [31:0]  fmt_result_item_count,
    output wire [31:0]  fmt_result_user_tag,
    output wire [31:0]  fmt_result_detail,

    output wire         fmt_result_data_valid,
    input  wire         fmt_result_data_ready,
    output wire [31:0]  fmt_result_data,

    output wire         fmt_finish_valid,
    input  wire         fmt_finish_ready,
    output wire [31:0]  fmt_finish_completed_count,
    output wire [31:0]  fmt_finish_error_count,
    output wire [31:0]  fmt_finish_batch_status,
    output wire [31:0]  fmt_finish_first_error_job_id,
    output wire [31:0]  fmt_finish_detail,

    output wire         backend_task_valid,
    input  wire         backend_task_ready,
    output wire [7:0]   backend_task_id,
    output wire [31:0]  backend_task_flags,
    output wire [31:0]  backend_task_item_count,
    output wire [31:0]  backend_task_user_tag,
    output wire [31:0]  backend_task_timeout_cycles,
    output wire [5:0]   backend_task_sequence,

    output wire         backend_payload_valid,
    input  wire         backend_payload_ready,
    output wire [31:0]  backend_payload_data,
    output wire         backend_payload_last,

    input  wire         backend_done_valid,
    output wire         backend_done_ready,
    input  wire [23:0]  backend_done_status,
    input  wire [31:0]  backend_done_result_words,
    input  wire [31:0]  backend_done_detail,
    input  wire [5:0]   backend_done_sequence,

    input  wire         backend_result_valid,
    output wire         backend_result_ready,
    input  wire [31:0]  backend_result_data,
    output reg          backend_abort,

    input  wire         legacy_active,
    input  wire         legacy_start,
    output reg          legacy_reject,
    output reg          dma_active,
    output wire [6:0]   debug_queue_occupancy,
    output wire [5:0]   debug_active_sequence
);

    localparam [1:0] BATCH_IDLE           = 2'd0;
    localparam [1:0] BATCH_ACTIVE         = 2'd1;
    localparam [1:0] BATCH_FINISH         = 2'd2;
    localparam [1:0] BATCH_WAIT_FORMATTER = 2'd3;
    localparam [1:0] INGRESS_IDLE         = 2'd0;
    localparam [1:0] INGRESS_DISPATCH     = 2'd1;
    localparam [1:0] INGRESS_PAYLOAD      = 2'd2;
    localparam [1:0] INGRESS_DRAIN        = 2'd3;
    localparam [1:0] RETIRE_HEADER        = 2'd0;
    localparam [1:0] RETIRE_BUFFER        = 2'd1;
    localparam [1:0] RETIRE_DIRECT        = 2'd2;
    localparam integer RESULT_POOL_SLOTS = SCOREBOARD_DEPTH;
    localparam integer RESULT_POOL_WORDS = 256;

    reg [1:0] batch_state;
    reg [1:0] ingress_state;
    reg [1:0] retire_state;
    reg [4:0] allocate_ptr;
    reg [4:0] retire_ptr;
    reg [4:0] ingress_slot;
    reg [6:0] occupancy;
    reg [5:0] ingress_sequence;
    reg [5:0] next_sequence;
    reg ingress_large_full;
    reg direct_exclusive;
    reg abort_guard;
    reg end_pending;
    reg [7:0] stored_end_status;
    reg [31:0] stored_end_detail;
    reg [31:0] completed_count;
    reg [31:0] error_count;
    reg [31:0] first_error_job_id;

    reg entry_valid [0:SCOREBOARD_DEPTH-1];
    reg entry_dispatched [0:SCOREBOARD_DEPTH-1];
    reg entry_running [0:SCOREBOARD_DEPTH-1];
    reg entry_complete [0:SCOREBOARD_DEPTH-1];
    reg entry_has_buffer [0:SCOREBOARD_DEPTH-1];
    reg entry_direct [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [5:0] entry_sequence [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_job_id [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [7:0] entry_task_id [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_flags [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_item_count [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_user_tag [0:SCOREBOARD_DEPTH-1];
    reg [31:0] entry_timeout_cycles [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_result_capacity [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_direct_words [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [23:0] entry_result_status [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_result_words [0:SCOREBOARD_DEPTH-1];
    (* ram_style = "distributed" *)
    reg [31:0] entry_result_detail [0:SCOREBOARD_DEPTH-1];
    // Task timeouts are 32-bit.  A 32-bit counter is exact because timeout
    // checks use the pre-increment value against timeout-1, including the
    // 0xffffffff boundary; formatter output is zero-extended below.
    reg [31:0] entry_compute_cycles [0:SCOREBOARD_DEPTH-1];
    reg [4:0] entry_pool_select [0:SCOREBOARD_DEPTH-1];

    // A 16-entry scoreboard deliberately keeps the wire sequence namespace
    // at 6 bits.  Map the 64 sequence values to their live physical slots so
    // completion is a direct lookup, rather than a 32-way associative scan.
    reg [4:0] sequence_slot [0:63];
    reg sequence_live [0:63];

    reg [RESULT_POOL_SLOTS-1:0] pool_valid;
`ifndef SYNTHESIS
    reg [31:0] result_pool [0:RESULT_POOL_SLOTS*RESULT_POOL_WORDS-1];
    reg [31:0] result_pool_read_data;
`else
    wire [31:0] result_pool_read_data;
`endif
    reg capture_active;
    reg [4:0] capture_slot;
    reg [4:0] capture_pool_select;
    reg [8:0] capture_word_index;
    reg [31:0] capture_word_count;
    reg [31:0] retire_word_index;
    reg retire_reject;

    integer state_index;
    integer completion_index;
    integer assertion_index;
    integer sequence_index;

    wire queue_full = (occupancy == SCOREBOARD_DEPTH);
    wire queue_empty = (occupancy == 7'd0);
    assign debug_queue_occupancy = occupancy;
    assign debug_active_sequence = entry_valid[retire_ptr] ?
                                   entry_sequence[retire_ptr] : 6'd0;

    wire task_requests_full =
        (in_task_flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0;
    wire task_is_legal_direct = task_requests_full &&
        (in_task_item_count == 32'd1) &&
        (((in_task_id == `MOL_DMA_TASK_GNN) &&
          (in_task_result_capacity_words >= 32'd3200)) ||
         ((in_task_id == `MOL_DMA_TASK_PIPELINE) &&
          (in_task_result_capacity_words >= 32'd3205)));
    wire [31:0] task_direct_words =
        (in_task_id == `MOL_DMA_TASK_PIPELINE) ? 32'd3205 : 32'd3200;
    wire batch_accept = in_batch_valid && in_batch_ready;
    wire allocate_fire = in_task_valid && in_task_ready;
    wire end_fire = in_end_valid && in_end_ready;

    assign fmt_batch_valid = (batch_state == BATCH_IDLE) && in_batch_valid &&
                             !legacy_active;
    assign in_batch_ready = (batch_state == BATCH_IDLE) && !legacy_active &&
                            fmt_batch_ready;
    assign fmt_batch_id = in_batch_id;
    assign fmt_expected_task_count = in_batch_task_count;
    assign fmt_header_status = in_batch_status;
    assign fmt_output_capacity_words = in_batch_max_result_words;

    wire timeout_request = |timeout_hit;

    assign in_task_ready = (batch_state == BATCH_ACTIVE) && !end_pending &&
                           (ingress_state == INGRESS_IDLE) && !queue_full &&
                           !direct_exclusive && !timeout_request &&
                           !abort_guard;
    assign backend_task_valid = (ingress_state == INGRESS_DISPATCH) &&
                                !timeout_request && !abort_guard &&
                                ((ingress_large_full &&
                                  (ingress_slot == retire_ptr)) ||
                                 (!ingress_large_full &&
                                  !pool_valid[ingress_slot]));
    assign backend_task_id = entry_task_id[ingress_slot];
    assign backend_task_flags = entry_flags[ingress_slot];
    assign backend_task_item_count = entry_item_count[ingress_slot];
    assign backend_task_user_tag = entry_user_tag[ingress_slot];
    assign backend_task_timeout_cycles =
        (entry_timeout_cycles[ingress_slot] == 0) ?
        DEFAULT_TIMEOUT_CYCLES : entry_timeout_cycles[ingress_slot];
    assign backend_task_sequence = ingress_sequence;
    wire backend_task_fire = backend_task_valid && backend_task_ready;

    assign backend_payload_valid = (ingress_state == INGRESS_PAYLOAD) &&
                                   !timeout_request && !abort_guard &&
                                   in_payload_valid;
    assign backend_payload_data = in_payload_data;
    assign backend_payload_last = in_payload_last;
    assign in_payload_ready = (ingress_state == INGRESS_DRAIN) ? 1'b1 :
                              ((ingress_state == INGRESS_PAYLOAD) &&
                               !timeout_request && !abort_guard &&
                               backend_payload_ready);
    wire backend_payload_fire = backend_payload_valid &&
                                backend_payload_ready;
    wire backend_payload_last_fire = backend_payload_fire &&
                                     (backend_payload_last === 1'b1);

    wire done_metadata_known =
        (^backend_done_sequence !== 1'bx) &&
        (^backend_done_status !== 1'bx) &&
        (^backend_done_result_words !== 1'bx) &&
        (^backend_done_detail !== 1'bx);
    // Never use X completion metadata as an array index.  The known check
    // below still rejects it; this only keeps simulation deterministic.
    wire [5:0] done_sequence_safe = done_metadata_known ?
                                backend_done_sequence : 6'd0;
    wire [4:0] done_entry_slot = sequence_slot[done_sequence_safe];
    wire done_entry_found = sequence_live[done_sequence_safe] &&
        entry_valid[done_entry_slot] &&
        entry_dispatched[done_entry_slot] &&
        entry_running[done_entry_slot] &&
        !entry_complete[done_entry_slot] &&
        (entry_sequence[done_entry_slot] == done_sequence_safe);
    wire done_entry_matches = done_metadata_known && done_entry_found;
    wire done_is_buffered = done_entry_found &&
        !entry_direct[done_entry_slot] &&
        (backend_done_result_words != 0) &&
        (backend_done_result_words <= RESULT_POOL_WORDS) &&
        (backend_done_result_words <=
         entry_result_capacity[done_entry_slot]);
    wire done_is_direct = done_entry_found &&
        entry_direct[done_entry_slot] &&
        (backend_done_result_words ==
         entry_direct_words[done_entry_slot]) &&
        (backend_done_result_words <=
         entry_result_capacity[done_entry_slot]);
    wire done_is_zero = backend_done_result_words == 0;
    wire done_shape_valid = done_is_zero || done_is_buffered ||
                            done_is_direct;
    assign backend_done_ready = !capture_active && !abort_guard &&
                                done_entry_matches;
    wire done_accept = backend_done_valid && backend_done_ready;
    wire protocol_abort_fire = done_accept && !done_shape_valid;

    wire retire_available = entry_valid[retire_ptr] &&
                            entry_complete[retire_ptr];
    assign fmt_result_valid = (batch_state == BATCH_ACTIVE) &&
                              (retire_state == RETIRE_HEADER) &&
                              retire_available;
    assign fmt_result_job_id = entry_job_id[retire_ptr];
    assign fmt_result_task_id = entry_task_id[retire_ptr];
    assign fmt_result_status = entry_result_status[retire_ptr];
    assign fmt_result_words = entry_result_words[retire_ptr];
    assign fmt_result_compute_cycles =
        {32'd0, entry_compute_cycles[retire_ptr]};
    assign fmt_result_item_count = entry_item_count[retire_ptr];
    assign fmt_result_user_tag = entry_user_tag[retire_ptr];
    assign fmt_result_detail = entry_result_detail[retire_ptr];

    wire retire_header_fire = fmt_result_valid && fmt_result_ready;
    wire buffered_result_fire = (retire_state == RETIRE_BUFFER) &&
                                fmt_result_data_ready;
    wire direct_result_fire = (retire_state == RETIRE_DIRECT) &&
                              backend_result_valid && backend_result_ready;
    wire buffered_result_last = buffered_result_fire &&
        (retire_word_index + 32'd1 == entry_result_words[retire_ptr]);
    wire direct_result_last = direct_result_fire &&
        (retire_word_index + 32'd1 == entry_result_words[retire_ptr]);
    wire reject_buffered_result = retire_header_fire && fmt_result_reject &&
                                  !entry_direct[retire_ptr];
    wire zero_word_result = retire_header_fire &&
                            (entry_result_words[retire_ptr] == 0);
    wire retire_fire = reject_buffered_result || zero_word_result ||
                       buffered_result_last || direct_result_last;
    wire retiring_rejected = reject_buffered_result ||
                             ((retire_state == RETIRE_DIRECT) &&
                              retire_reject && direct_result_last);
    wire retiring_error = retiring_rejected ||
                          (entry_result_status[retire_ptr] != 0);

    wire result_pool_write_enable = rst_n && capture_active &&
                                    backend_result_valid &&
                                    backend_result_ready;
    wire [12:0] result_pool_write_addr =
        {capture_pool_select, capture_word_index[7:0]};
    wire result_pool_read_enable = rst_n &&
        ((retire_header_fire && !entry_direct[retire_ptr] &&
          !fmt_result_reject && (entry_result_words[retire_ptr] != 0)) ||
         (buffered_result_fire && !buffered_result_last));
    wire [12:0] result_pool_read_addr = retire_header_fire ?
        {entry_pool_select[retire_ptr], 8'd0} :
        {entry_pool_select[retire_ptr], retire_word_index[7:0] + 8'd1};

`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .MEMORY_SIZE(262144),
        .MEMORY_PRIMITIVE("block"),
        .CLOCKING_MODE("common_clock"),
        .WRITE_DATA_WIDTH_A(32),
        .BYTE_WRITE_WIDTH_A(32),
        .ADDR_WIDTH_A(13),
        .READ_DATA_WIDTH_B(32),
        .ADDR_WIDTH_B(13),
        .READ_LATENCY_B(1),
        .WRITE_MODE_B("read_first")
    ) result_pool_bram (
        .clka(clk),
        .ena(result_pool_write_enable),
        .wea(result_pool_write_enable),
        .addra(result_pool_write_addr),
        .dina(backend_result_data),
        .clkb(clk),
        .enb(result_pool_read_enable),
        .addrb(result_pool_read_addr),
        .doutb(result_pool_read_data),
        .rstb(1'b0),
        .regceb(1'b1),
        .sleep(1'b0),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .sbiterrb(),
        .dbiterrb()
    );
`endif

    assign fmt_result_data_valid =
        (retire_state == RETIRE_BUFFER) ? 1'b1 :
        (retire_state == RETIRE_DIRECT) ?
            (!retire_reject && backend_result_valid) : 1'b0;
    assign fmt_result_data =
        (retire_state == RETIRE_BUFFER) ?
        result_pool_read_data :
        backend_result_data;
    assign backend_result_ready = capture_active ? 1'b1 :
        (retire_state == RETIRE_DIRECT) ?
            (retire_reject ? 1'b1 : fmt_result_data_ready) : 1'b0;

    assign in_end_ready = (batch_state == BATCH_ACTIVE) && !end_pending;
    assign fmt_finish_valid = (batch_state == BATCH_FINISH);
    assign fmt_finish_completed_count = completed_count;
    assign fmt_finish_error_count = error_count;
    assign fmt_finish_batch_status = {24'd0, stored_end_status};
    assign fmt_finish_first_error_job_id = first_error_job_id;
    assign fmt_finish_detail = stored_end_detail;

    wire [SCOREBOARD_DEPTH-1:0] timeout_hit;
    genvar timeout_index;
    generate
        for (timeout_index = 0; timeout_index < SCOREBOARD_DEPTH;
             timeout_index = timeout_index + 1) begin : g_timeout_hit
            assign timeout_hit[timeout_index] =
                entry_valid[timeout_index] && entry_running[timeout_index] &&
                !entry_complete[timeout_index] &&
                ((((entry_timeout_cycles[timeout_index] == 0) ?
                   DEFAULT_TIMEOUT_CYCLES :
                   entry_timeout_cycles[timeout_index]) == 0) ||
                 (entry_compute_cycles[timeout_index] >=
                  (((entry_timeout_cycles[timeout_index] == 0) ?
                    DEFAULT_TIMEOUT_CYCLES :
                    entry_timeout_cycles[timeout_index]) - 32'd1)));
        end
    endgenerate
    wire timeout_fire = timeout_request && !done_accept && !capture_active;
    wire recovery_fire = timeout_fire || protocol_abort_fire;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (result_pool_write_enable)
            result_pool[result_pool_write_addr] <= backend_result_data;
        if (result_pool_read_enable)
            result_pool_read_data <= result_pool[result_pool_read_addr];
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_state <= BATCH_IDLE;
            ingress_state <= INGRESS_IDLE;
            retire_state <= RETIRE_HEADER;
            allocate_ptr <= 5'd0;
            retire_ptr <= 5'd0;
            ingress_slot <= 5'd0;
            occupancy <= 7'd0;
            ingress_sequence <= 6'd0;
            next_sequence <= 6'd0;
            ingress_large_full <= 1'b0;
            direct_exclusive <= 1'b0;
            abort_guard <= 1'b0;
            end_pending <= 1'b0;
            stored_end_status <= 8'd0;
            stored_end_detail <= 32'd0;
            completed_count <= 32'd0;
            error_count <= 32'd0;
            first_error_job_id <= 32'hFFFFFFFF;
            pool_valid <= 0;
            capture_active <= 1'b0;
            capture_slot <= 5'd0;
            capture_pool_select <= 5'd0;
            capture_word_index <= 9'd0;
            capture_word_count <= 32'd0;
            retire_word_index <= 32'd0;
            retire_reject <= 1'b0;
            backend_abort <= 1'b0;
            legacy_reject <= 1'b0;
            dma_active <= 1'b0;
            for (sequence_index = 0; sequence_index < 64;
                 sequence_index = sequence_index + 1) begin
                sequence_slot[sequence_index] <= 5'd0;
                sequence_live[sequence_index] <= 1'b0;
            end
        end else begin
            backend_abort <= 1'b0;
            legacy_reject <= legacy_start && dma_active;

            if (abort_guard && !backend_abort && !backend_done_valid &&
                !backend_result_valid)
                abort_guard <= 1'b0;

            for (state_index = 0; state_index < SCOREBOARD_DEPTH;
                 state_index = state_index + 1) begin
                if (entry_valid[state_index] && entry_running[state_index] &&
                    !entry_complete[state_index])
                    entry_compute_cycles[state_index] <=
                        entry_compute_cycles[state_index] + 32'd1;
            end

            case ({allocate_fire, retire_fire})
                2'b10: occupancy <= occupancy + 7'd1;
                2'b01: occupancy <= occupancy - 7'd1;
                default: occupancy <= occupancy;
            endcase

            if (batch_accept) begin
                batch_state <= BATCH_ACTIVE;
                ingress_state <= INGRESS_IDLE;
                retire_state <= RETIRE_HEADER;
                allocate_ptr <= 5'd0;
                retire_ptr <= 5'd0;
                ingress_slot <= 5'd0;
                next_sequence <= 6'd0;
                occupancy <= 7'd0;
                end_pending <= 1'b0;
                completed_count <= 32'd0;
                error_count <= 32'd0;
                first_error_job_id <= 32'hFFFFFFFF;
                pool_valid <= 0;
                capture_active <= 1'b0;
                direct_exclusive <= 1'b0;
                abort_guard <= 1'b0;
                retire_word_index <= 32'd0;
                retire_reject <= 1'b0;
                dma_active <= 1'b1;
                for (state_index = 0; state_index < SCOREBOARD_DEPTH;
                     state_index = state_index + 1) begin
                    entry_valid[state_index] <= 1'b0;
                    entry_complete[state_index] <= 1'b0;
                    entry_has_buffer[state_index] <= 1'b0;
                    entry_direct[state_index] <= 1'b0;
                    entry_dispatched[state_index] <= 1'b0;
                    entry_running[state_index] <= 1'b0;
                end
                for (sequence_index = 0; sequence_index < 64;
                     sequence_index = sequence_index + 1)
                    sequence_live[sequence_index] <= 1'b0;
            end else begin
                case (batch_state)
                    BATCH_ACTIVE: begin
                        if (end_pending && queue_empty &&
                            (ingress_state == INGRESS_IDLE) &&
                            !capture_active &&
                            (retire_state == RETIRE_HEADER))
                            batch_state <= BATCH_FINISH;
                    end
                    BATCH_FINISH: begin
                        if (fmt_finish_valid && fmt_finish_ready)
                            batch_state <= BATCH_WAIT_FORMATTER;
                    end
                    BATCH_WAIT_FORMATTER: begin
                        if (fmt_batch_ready) begin
                            batch_state <= BATCH_IDLE;
                            end_pending <= 1'b0;
                            dma_active <= 1'b0;
                        end
                    end
                    default: begin end
                endcase
            end

            if (end_fire) begin
                end_pending <= 1'b1;
                stored_end_status <= in_end_status;
                stored_end_detail <= in_end_detail;
            end

            if (allocate_fire) begin
                entry_valid[allocate_ptr] <= 1'b1;
                entry_dispatched[allocate_ptr] <= 1'b0;
                entry_running[allocate_ptr] <= 1'b0;
                entry_complete[allocate_ptr] <=
                    (in_task_status != `MOL_DMA_STATUS_OK);
                entry_has_buffer[allocate_ptr] <= 1'b0;
                entry_direct[allocate_ptr] <= 1'b0;
                entry_timeout_cycles[allocate_ptr] <= in_task_timeout_cycles;
                entry_compute_cycles[allocate_ptr] <= 32'd0;
                entry_pool_select[allocate_ptr] <= 5'd0;
                ingress_slot <= allocate_ptr;
                ingress_sequence <= next_sequence;
                next_sequence <= next_sequence + 6'd1;
                sequence_slot[next_sequence] <= allocate_ptr;
                sequence_live[next_sequence] <= 1'b1;
                ingress_large_full <= task_is_legal_direct;
                allocate_ptr <= (allocate_ptr == SCOREBOARD_DEPTH - 1) ?
                                5'd0 : allocate_ptr + 5'd1;
                if (in_task_status == `MOL_DMA_STATUS_OK)
                    ingress_state <= INGRESS_DISPATCH;
            end

            if (backend_task_fire) begin
                entry_dispatched[ingress_slot] <= 1'b1;
                if (ingress_large_full) begin
                    entry_direct[ingress_slot] <= 1'b1;
                    direct_exclusive <= 1'b1;
                end else begin
                    pool_valid[ingress_slot] <= 1'b1;
                    entry_has_buffer[ingress_slot] <= 1'b1;
                    entry_pool_select[ingress_slot] <= ingress_slot;
                end
                ingress_state <= INGRESS_PAYLOAD;
            end
            if (backend_payload_last_fire) begin
                entry_running[ingress_slot] <= 1'b1;
                ingress_state <= INGRESS_IDLE;
            end
            if ((ingress_state == INGRESS_DRAIN) && in_payload_valid &&
                in_payload_last)
                ingress_state <= INGRESS_IDLE;

            if (done_accept) begin
                entry_running[done_entry_slot] <= 1'b0;
                if (done_shape_valid) begin
                    if (done_is_zero) begin
                        if (entry_has_buffer[done_entry_slot])
                            pool_valid[
                                entry_pool_select[done_entry_slot]] <=
                                1'b0;
                        entry_has_buffer[done_entry_slot] <= 1'b0;
                        if (entry_direct[done_entry_slot]) begin
                            entry_direct[done_entry_slot] <= 1'b0;
                            direct_exclusive <= 1'b0;
                        end
                        entry_complete[done_entry_slot] <= 1'b1;
                    end else if (done_is_buffered) begin
                        capture_active <= 1'b1;
                        capture_slot <= done_entry_slot;
                        capture_pool_select <=
                            entry_pool_select[done_entry_slot];
                        capture_word_index <= 9'd0;
                        capture_word_count <= backend_done_result_words;
                    end else begin
                        entry_complete[done_entry_slot] <= 1'b1;
                    end
                end
            end

            if (capture_active && backend_result_valid &&
                backend_result_ready) begin
                if (capture_word_index + 9'd1 == capture_word_count) begin
                    entry_complete[capture_slot] <= 1'b1;
                    capture_active <= 1'b0;
                    capture_word_index <= 9'd0;
                end else begin
                    capture_word_index <= capture_word_index + 9'd1;
                end
            end

            if (retire_header_fire) begin
                retire_word_index <= 32'd0;
                retire_reject <= fmt_result_reject;
                if ((entry_result_words[retire_ptr] != 0) &&
                    !(fmt_result_reject && !entry_direct[retire_ptr])) begin
                    if (entry_direct[retire_ptr])
                        retire_state <= RETIRE_DIRECT;
                    else
                        retire_state <= RETIRE_BUFFER;
                end
            end else if (buffered_result_fire || direct_result_fire) begin
                if (!retire_fire)
                    retire_word_index <= retire_word_index + 32'd1;
            end

            if (retire_fire) begin
                if (entry_has_buffer[retire_ptr])
                    pool_valid[entry_pool_select[retire_ptr]] <= 1'b0;
                if (entry_direct[retire_ptr])
                    direct_exclusive <= 1'b0;
                sequence_live[entry_sequence[retire_ptr]] <= 1'b0;
                entry_valid[retire_ptr] <= 1'b0;
                entry_dispatched[retire_ptr] <= 1'b0;
                entry_running[retire_ptr] <= 1'b0;
                entry_complete[retire_ptr] <= 1'b0;
                entry_has_buffer[retire_ptr] <= 1'b0;
                entry_direct[retire_ptr] <= 1'b0;
                completed_count <= completed_count + 32'd1;
                if (retiring_error) begin
                    error_count <= error_count + 32'd1;
                    if (error_count == 0)
                        first_error_job_id <= entry_job_id[retire_ptr];
                end
                retire_ptr <= (retire_ptr == SCOREBOARD_DEPTH - 1) ?
                              5'd0 : retire_ptr + 5'd1;
                retire_state <= RETIRE_HEADER;
                retire_word_index <= 32'd0;
                retire_reject <= 1'b0;
            end

            if (recovery_fire) begin
                backend_abort <= 1'b1;
                abort_guard <= 1'b1;
                direct_exclusive <= 1'b0;
                if (ingress_state == INGRESS_PAYLOAD)
                    ingress_state <= backend_payload_last_fire ?
                                     INGRESS_IDLE : INGRESS_DRAIN;
                else if ((ingress_state == INGRESS_DISPATCH) &&
                         backend_task_fire)
                    ingress_state <= INGRESS_DRAIN;
                for (state_index = 0; state_index < SCOREBOARD_DEPTH;
                     state_index = state_index + 1) begin
                    if (entry_valid[state_index] &&
                        (entry_dispatched[state_index] ||
                         (protocol_abort_fire && backend_task_fire &&
                          (state_index == ingress_slot))) &&
                        !entry_complete[state_index]) begin
                        if (protocol_abort_fire && backend_task_fire &&
                            (state_index == ingress_slot))
                            pool_valid[ingress_slot] <= 1'b0;
                        else if (entry_has_buffer[state_index])
                            pool_valid[entry_pool_select[state_index]] <= 1'b0;
                        entry_running[state_index] <= 1'b0;
                        entry_complete[state_index] <= 1'b1;
                        entry_has_buffer[state_index] <= 1'b0;
                        entry_direct[state_index] <= 1'b0;
                    end
                end
            end
        end
    end

    // Immutable descriptors are written exactly once when their slot is
    // allocated.  Keeping them out of the asynchronous-reset control process
    // permits the existing distributed-RAM directives to take effect.
    always @(posedge clk) begin
        if (allocate_fire) begin
            entry_sequence[allocate_ptr] <= next_sequence;
            entry_job_id[allocate_ptr] <= in_task_job_id;
            entry_task_id[allocate_ptr] <= in_task_id;
            entry_flags[allocate_ptr] <= in_task_flags;
            entry_item_count[allocate_ptr] <= in_task_item_count;
            entry_user_tag[allocate_ptr] <= in_task_user_tag;
            entry_result_capacity[allocate_ptr] <=
                in_task_result_capacity_words;
            entry_direct_words[allocate_ptr] <= task_direct_words;
        end
    end

    // Completion metadata is meaningful only while entry_valid/complete is
    // asserted.  Keeping it out of the reset-controlled process lets Vivado
    // infer the existing asynchronous-read distributed RAMs without changing
    // the completion, timeout, or retirement ordering.
    always @(posedge clk) begin
        if (allocate_fire) begin
            entry_result_status[allocate_ptr] <= {16'd0, in_task_status};
            entry_result_words[allocate_ptr] <= 32'd0;
            entry_result_detail[allocate_ptr] <= in_task_detail;
        end
        if (done_accept && done_shape_valid) begin
            entry_result_status[done_entry_slot] <= backend_done_status;
            entry_result_words[done_entry_slot] <= backend_done_result_words;
            entry_result_detail[done_entry_slot] <= backend_done_detail;
        end
        if (recovery_fire)
            for (completion_index = 0; completion_index < SCOREBOARD_DEPTH;
                 completion_index = completion_index + 1)
                if (entry_valid[completion_index] &&
                    (entry_dispatched[completion_index] ||
                     (protocol_abort_fire && backend_task_fire &&
                      (completion_index == ingress_slot))) &&
                    !entry_complete[completion_index]) begin
                    entry_result_status[completion_index] <=
                        protocol_abort_fire ?
                        `MOL_DMA_STATUS_INTERNAL_ERROR :
                        `MOL_DMA_STATUS_TASK_TIMEOUT;
                    entry_result_words[completion_index] <= 32'd0;
                    entry_result_detail[completion_index] <=
                        protocol_abort_fire ? backend_done_result_words :
                        entry_compute_cycles[completion_index] + 32'd1;
                end
    end

`ifndef SYNTHESIS
    reg [5:0] expected_retire_sequence;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            expected_retire_sequence <= 6'd0;
        else begin
            if (batch_accept)
                expected_retire_sequence <= 6'd0;
            else if (retire_fire) begin
                if (entry_sequence[retire_ptr] != expected_retire_sequence)
                    $fatal(1, "non-monotonic retirement: got %0d expected %0d",
                           entry_sequence[retire_ptr], expected_retire_sequence);
                expected_retire_sequence <= expected_retire_sequence + 6'd1;
            end
            if (occupancy > SCOREBOARD_DEPTH)
                $fatal(1, "scoreboard occupancy exceeded %0d: %0d", SCOREBOARD_DEPTH, occupancy);
            if (batch_accept && in_batch_task_count > 32'd64)
                $fatal(1, "scoreboard batch count exceeds 6-bit ownership: %0d",
                       in_batch_task_count);
            if (allocate_fire && entry_valid[allocate_ptr])
                $fatal(1, "scoreboard overwrote live sequence %0d", allocate_ptr);
            if (backend_task_valid && backend_task_ready &&
                !ingress_large_full && pool_valid[ingress_slot])
                $fatal(1, "result slot reused before sequence %0d retired",
                       ingress_sequence);
            if (backend_done_valid && !done_metadata_known &&
                backend_done_ready !== 1'b0)
                $fatal(1, "unknown completion metadata did not fail closed");
            if (abort_guard && backend_done_ready)
                $fatal(1, "aborted backend completion reacquired ownership");
            if (allocate_fire)
                for (assertion_index = 0; assertion_index < SCOREBOARD_DEPTH;
                     assertion_index = assertion_index + 1)
                    if (entry_valid[assertion_index] &&
                        (entry_sequence[assertion_index] == next_sequence))
                        $fatal(1, "duplicate live sequence %0d", next_sequence);
            for (assertion_index = 0; assertion_index < SCOREBOARD_DEPTH;
                 assertion_index = assertion_index + 1) begin
                if (entry_has_buffer[assertion_index] &&
                    entry_pool_select[assertion_index] !=
                    assertion_index[4:0])
                    $fatal(1, "sequence %0d owns result slot %0d",
                           entry_sequence[assertion_index],
                           entry_pool_select[assertion_index]);
                if (direct_exclusive &&
                    entry_dispatched[assertion_index] &&
                    !entry_complete[assertion_index] &&
                    !entry_direct[assertion_index])
                    $fatal(1, "small sequence %0d overlaps direct FULL",
                           entry_sequence[assertion_index]);
            end
        end
    end
`endif

endmodule
