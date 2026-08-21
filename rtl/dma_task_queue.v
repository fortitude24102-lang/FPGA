`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module dma_task_queue #(
    parameter [31:0] DEFAULT_TIMEOUT_CYCLES = 32'd1000000
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
    output reg          dma_active
);

    localparam [1:0] BATCH_IDLE           = 2'd0;
    localparam [1:0] BATCH_ACTIVE         = 2'd1;
    localparam [1:0] BATCH_FINISH         = 2'd2;
    localparam [1:0] BATCH_WAIT_FORMATTER = 2'd3;
    localparam [1:0] INGRESS_IDLE         = 2'd0;
    localparam [1:0] INGRESS_DISPATCH     = 2'd1;
    localparam [1:0] INGRESS_PAYLOAD      = 2'd2;
    localparam [1:0] RETIRE_HEADER        = 2'd0;
    localparam [1:0] RETIRE_BUFFER        = 2'd1;
    localparam [1:0] RETIRE_DIRECT        = 2'd2;
    localparam integer RESULT_POOL_SLOTS = 4;
    localparam integer RESULT_POOL_WORDS = 256;

    reg [1:0] batch_state;
    reg [1:0] ingress_state;
    reg [1:0] retire_state;
    reg [5:0] allocate_ptr;
    reg [5:0] retire_ptr;
    reg [6:0] occupancy;
    reg [5:0] ingress_sequence;
    reg ingress_large_full;
    reg end_pending;
    reg [7:0] stored_end_status;
    reg [31:0] stored_end_detail;
    reg [31:0] completed_count;
    reg [31:0] error_count;
    reg [31:0] first_error_job_id;

    reg entry_valid [0:63];
    reg entry_dispatched [0:63];
    reg entry_running [0:63];
    reg entry_complete [0:63];
    reg entry_has_buffer [0:63];
    reg entry_direct [0:63];
    reg [5:0] entry_sequence [0:63];
    reg [31:0] entry_job_id [0:63];
    reg [7:0] entry_task_id [0:63];
    reg [31:0] entry_flags [0:63];
    reg [31:0] entry_item_count [0:63];
    reg [31:0] entry_user_tag [0:63];
    reg [31:0] entry_timeout_cycles [0:63];
    reg [23:0] entry_result_status [0:63];
    reg [31:0] entry_result_words [0:63];
    reg [31:0] entry_result_detail [0:63];
    reg [63:0] entry_compute_cycles [0:63];
    reg [1:0] entry_pool_select [0:63];

    reg [RESULT_POOL_SLOTS-1:0] pool_valid;
    reg [31:0] result_pool [0:RESULT_POOL_SLOTS*RESULT_POOL_WORDS-1];
    reg free_pool_available;
    reg [1:0] free_pool_select;
    reg capture_active;
    reg [5:0] capture_sequence;
    reg [1:0] capture_pool_select;
    reg [8:0] capture_word_index;
    reg [31:0] capture_word_count;
    reg [31:0] retire_word_index;
    reg retire_reject;

    integer state_index;
    integer assertion_index;
    integer pool_scan;

    always @* begin
        free_pool_available = 1'b0;
        free_pool_select = 2'd0;
        for (pool_scan = 0; pool_scan < RESULT_POOL_SLOTS;
             pool_scan = pool_scan + 1) begin
            if (!pool_valid[pool_scan] && !free_pool_available) begin
                free_pool_available = 1'b1;
                free_pool_select = pool_scan[1:0];
            end
        end
    end

    wire queue_full = (occupancy == 7'd64);
    wire queue_empty = (occupancy == 7'd0);
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

    assign in_task_ready = (batch_state == BATCH_ACTIVE) && !end_pending &&
                           (ingress_state == INGRESS_IDLE) && !queue_full;
    assign backend_task_valid = (ingress_state == INGRESS_DISPATCH) &&
                                (!ingress_large_full ||
                                 (ingress_sequence == retire_ptr));
    assign backend_task_id = entry_task_id[ingress_sequence];
    assign backend_task_flags = entry_flags[ingress_sequence];
    assign backend_task_item_count = entry_item_count[ingress_sequence];
    assign backend_task_timeout_cycles =
        (entry_timeout_cycles[ingress_sequence] == 0) ?
        DEFAULT_TIMEOUT_CYCLES : entry_timeout_cycles[ingress_sequence];
    assign backend_task_sequence = ingress_sequence;

    assign backend_payload_valid = (ingress_state == INGRESS_PAYLOAD) &&
                                   in_payload_valid;
    assign backend_payload_data = in_payload_data;
    assign backend_payload_last = in_payload_last;
    assign in_payload_ready = (ingress_state == INGRESS_PAYLOAD) &&
                              backend_payload_ready;

    wire done_entry_matches =
        entry_valid[backend_done_sequence] &&
        entry_dispatched[backend_done_sequence] &&
        entry_running[backend_done_sequence] &&
        !entry_complete[backend_done_sequence] &&
        (entry_sequence[backend_done_sequence] == backend_done_sequence);
    wire done_is_buffered =
        (backend_done_result_words != 0) &&
        (backend_done_result_words <= RESULT_POOL_WORDS);
    wire done_is_direct = backend_done_result_words > RESULT_POOL_WORDS;
    assign backend_done_ready = !capture_active && done_entry_matches &&
        ((backend_done_result_words == 0) ||
         (done_is_buffered && free_pool_available) ||
         (done_is_direct && (backend_done_sequence == retire_ptr) &&
          (retire_state == RETIRE_HEADER)));
    wire done_accept = backend_done_valid && backend_done_ready;

    wire retire_available = entry_valid[retire_ptr] &&
                            entry_complete[retire_ptr];
    assign fmt_result_valid = (batch_state == BATCH_ACTIVE) &&
                              (retire_state == RETIRE_HEADER) &&
                              retire_available;
    assign fmt_result_job_id = entry_job_id[retire_ptr];
    assign fmt_result_task_id = entry_task_id[retire_ptr];
    assign fmt_result_status = entry_result_status[retire_ptr];
    assign fmt_result_words = entry_result_words[retire_ptr];
    assign fmt_result_compute_cycles = entry_compute_cycles[retire_ptr];
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

    assign fmt_result_data_valid =
        (retire_state == RETIRE_BUFFER) ? 1'b1 :
        (retire_state == RETIRE_DIRECT) ?
            (!retire_reject && backend_result_valid) : 1'b0;
    assign fmt_result_data =
        (retire_state == RETIRE_BUFFER) ?
        result_pool[{entry_pool_select[retire_ptr], retire_word_index[7:0]}] :
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

    wire [63:0] timeout_hit;
    genvar timeout_index;
    generate
        for (timeout_index = 0; timeout_index < 64;
             timeout_index = timeout_index + 1) begin : g_timeout_hit
            assign timeout_hit[timeout_index] =
                entry_valid[timeout_index] && entry_running[timeout_index] &&
                !entry_complete[timeout_index] &&
                (entry_compute_cycles[timeout_index] + 64'd1 >=
                 ((entry_timeout_cycles[timeout_index] == 0) ?
                  DEFAULT_TIMEOUT_CYCLES :
                  entry_timeout_cycles[timeout_index]));
        end
    endgenerate
    wire timeout_fire = (|timeout_hit) && !done_accept && !capture_active &&
                        (retire_state != RETIRE_DIRECT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_state <= BATCH_IDLE;
            ingress_state <= INGRESS_IDLE;
            retire_state <= RETIRE_HEADER;
            allocate_ptr <= 6'd0;
            retire_ptr <= 6'd0;
            occupancy <= 7'd0;
            ingress_sequence <= 6'd0;
            ingress_large_full <= 1'b0;
            end_pending <= 1'b0;
            stored_end_status <= 8'd0;
            stored_end_detail <= 32'd0;
            completed_count <= 32'd0;
            error_count <= 32'd0;
            first_error_job_id <= 32'hFFFFFFFF;
            pool_valid <= 0;
            capture_active <= 1'b0;
            capture_sequence <= 6'd0;
            capture_pool_select <= 2'd0;
            capture_word_index <= 9'd0;
            capture_word_count <= 32'd0;
            retire_word_index <= 32'd0;
            retire_reject <= 1'b0;
            backend_abort <= 1'b0;
            legacy_reject <= 1'b0;
            dma_active <= 1'b0;
            for (state_index = 0; state_index < 64;
                 state_index = state_index + 1) begin
                entry_valid[state_index] <= 1'b0;
                entry_dispatched[state_index] <= 1'b0;
                entry_running[state_index] <= 1'b0;
                entry_complete[state_index] <= 1'b0;
                entry_has_buffer[state_index] <= 1'b0;
                entry_direct[state_index] <= 1'b0;
                entry_sequence[state_index] <= state_index[5:0];
                entry_job_id[state_index] <= 32'd0;
                entry_task_id[state_index] <= 8'd0;
                entry_flags[state_index] <= 32'd0;
                entry_item_count[state_index] <= 32'd0;
                entry_user_tag[state_index] <= 32'd0;
                entry_timeout_cycles[state_index] <= 32'd0;
                entry_result_status[state_index] <= 24'd0;
                entry_result_words[state_index] <= 32'd0;
                entry_result_detail[state_index] <= 32'd0;
                entry_compute_cycles[state_index] <= 64'd0;
                entry_pool_select[state_index] <= 2'd0;
            end
        end else begin
            backend_abort <= 1'b0;
            legacy_reject <= legacy_start && dma_active;

            for (state_index = 0; state_index < 64;
                 state_index = state_index + 1) begin
                if (entry_valid[state_index] && entry_running[state_index] &&
                    !entry_complete[state_index])
                    entry_compute_cycles[state_index] <=
                        entry_compute_cycles[state_index] + 64'd1;
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
                allocate_ptr <= 6'd0;
                retire_ptr <= 6'd0;
                occupancy <= 7'd0;
                end_pending <= 1'b0;
                completed_count <= 32'd0;
                error_count <= 32'd0;
                first_error_job_id <= 32'hFFFFFFFF;
                pool_valid <= 0;
                capture_active <= 1'b0;
                retire_word_index <= 32'd0;
                retire_reject <= 1'b0;
                dma_active <= 1'b1;
                for (state_index = 0; state_index < 64;
                     state_index = state_index + 1) begin
                    entry_valid[state_index] <= 1'b0;
                    entry_complete[state_index] <= 1'b0;
                    entry_has_buffer[state_index] <= 1'b0;
                    entry_direct[state_index] <= 1'b0;
                end
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
                entry_sequence[allocate_ptr] <= allocate_ptr;
                entry_job_id[allocate_ptr] <= in_task_job_id;
                entry_task_id[allocate_ptr] <= in_task_id;
                entry_flags[allocate_ptr] <= in_task_flags;
                entry_item_count[allocate_ptr] <= in_task_item_count;
                entry_user_tag[allocate_ptr] <= in_task_user_tag;
                entry_timeout_cycles[allocate_ptr] <= in_task_timeout_cycles;
                entry_result_status[allocate_ptr] <= {16'd0, in_task_status};
                entry_result_words[allocate_ptr] <= 32'd0;
                entry_result_detail[allocate_ptr] <= in_task_detail;
                entry_compute_cycles[allocate_ptr] <= 64'd0;
                entry_pool_select[allocate_ptr] <= 2'd0;
                ingress_sequence <= allocate_ptr;
                ingress_large_full <=
                    ((in_task_id == `MOL_DMA_TASK_GNN) ||
                     (in_task_id == `MOL_DMA_TASK_PIPELINE)) &&
                    ((in_task_flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0);
                allocate_ptr <= allocate_ptr + 6'd1;
                if (in_task_status == `MOL_DMA_STATUS_OK)
                    ingress_state <= INGRESS_DISPATCH;
            end

            if (backend_task_valid && backend_task_ready) begin
                entry_dispatched[ingress_sequence] <= 1'b1;
                ingress_state <= INGRESS_PAYLOAD;
            end
            if (backend_payload_valid && backend_payload_ready &&
                backend_payload_last) begin
                entry_running[ingress_sequence] <= 1'b1;
                ingress_state <= INGRESS_IDLE;
            end

            if (done_accept) begin
                entry_result_status[backend_done_sequence] <=
                    backend_done_status;
                entry_result_words[backend_done_sequence] <=
                    backend_done_result_words;
                entry_result_detail[backend_done_sequence] <=
                    backend_done_detail;
                entry_running[backend_done_sequence] <= 1'b0;
                if (backend_done_result_words == 0) begin
                    entry_complete[backend_done_sequence] <= 1'b1;
                end else if (done_is_buffered) begin
                    pool_valid[free_pool_select] <= 1'b1;
                    entry_has_buffer[backend_done_sequence] <= 1'b1;
                    entry_pool_select[backend_done_sequence] <= free_pool_select;
                    capture_active <= 1'b1;
                    capture_sequence <= backend_done_sequence;
                    capture_pool_select <= free_pool_select;
                    capture_word_index <= 9'd0;
                    capture_word_count <= backend_done_result_words;
                end else begin
                    entry_direct[backend_done_sequence] <= 1'b1;
                    entry_complete[backend_done_sequence] <= 1'b1;
                end
            end

            if (capture_active && backend_result_valid &&
                backend_result_ready) begin
                result_pool[{capture_pool_select, capture_word_index[7:0]}] <=
                    backend_result_data;
                if (capture_word_index + 9'd1 == capture_word_count) begin
                    entry_complete[capture_sequence] <= 1'b1;
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
                retire_ptr <= retire_ptr + 6'd1;
                retire_state <= RETIRE_HEADER;
                retire_word_index <= 32'd0;
                retire_reject <= 1'b0;
            end

            if (timeout_fire) begin
                backend_abort <= 1'b1;
                for (state_index = 0; state_index < 64;
                     state_index = state_index + 1) begin
                    if (entry_valid[state_index] &&
                        entry_running[state_index] &&
                        !entry_complete[state_index]) begin
                        entry_running[state_index] <= 1'b0;
                        entry_complete[state_index] <= 1'b1;
                        entry_has_buffer[state_index] <= 1'b0;
                        entry_direct[state_index] <= 1'b0;
                        entry_result_status[state_index] <=
                            `MOL_DMA_STATUS_TASK_TIMEOUT;
                        entry_result_words[state_index] <= 32'd0;
                        entry_result_detail[state_index] <=
                            entry_compute_cycles[state_index][31:0] + 32'd1;
                    end
                end
                pool_valid <= 0;
            end
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
            if (occupancy > 7'd64)
                $fatal(1, "scoreboard occupancy exceeded 64: %0d", occupancy);
            if (allocate_fire && entry_valid[allocate_ptr])
                $fatal(1, "scoreboard overwrote live sequence %0d", allocate_ptr);
            if (allocate_fire)
                for (assertion_index = 0; assertion_index < 64;
                     assertion_index = assertion_index + 1)
                    if (entry_valid[assertion_index] &&
                        (entry_sequence[assertion_index] == allocate_ptr))
                        $fatal(1, "duplicate live sequence %0d", allocate_ptr);
        end
    end
`endif

endmodule
