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

    output wire         backend_payload_valid,
    input  wire         backend_payload_ready,
    output wire [31:0]  backend_payload_data,
    output wire         backend_payload_last,

    input  wire         backend_done_valid,
    output wire         backend_done_ready,
    input  wire [23:0]  backend_done_status,
    input  wire [31:0]  backend_done_result_words,
    input  wire [31:0]  backend_done_detail,

    input  wire         backend_result_valid,
    output wire         backend_result_ready,
    input  wire [31:0]  backend_result_data,
    output reg          backend_abort,

    input  wire         legacy_active,
    input  wire         legacy_start,
    output reg          legacy_reject,
    output reg          dma_active
);

    localparam [3:0] STATE_IDLE            = 4'd0;
    localparam [3:0] STATE_WAIT_TASK       = 4'd1;
    localparam [3:0] STATE_SEND_BACKEND    = 4'd2;
    localparam [3:0] STATE_FORWARD_PAYLOAD = 4'd3;
    localparam [3:0] STATE_WAIT_BACKEND    = 4'd4;
    localparam [3:0] STATE_SUBMIT_RESULT   = 4'd5;
    localparam [3:0] STATE_FORWARD_RESULT  = 4'd6;
    localparam [3:0] STATE_DISCARD_RESULT  = 4'd7;
    localparam [3:0] STATE_COMPLETE_TASK   = 4'd8;
    localparam [3:0] STATE_FINISH          = 4'd9;
    localparam [3:0] STATE_WAIT_FORMATTER  = 4'd10;

    reg [3:0] state;
    reg [31:0] active_job_id;
    reg [7:0] active_task_id;
    reg [31:0] active_task_flags;
    reg [31:0] active_item_count;
    reg [31:0] active_user_tag;
    reg [31:0] active_timeout_cycles;
    reg [23:0] active_result_status;
    reg [31:0] active_result_words;
    reg [31:0] active_result_detail;
    reg [63:0] active_compute_cycles;
    reg [31:0] result_word_index;

    reg end_pending;
    reg [7:0] stored_end_status;
    reg [31:0] stored_end_detail;
    reg [31:0] completed_count;
    reg [31:0] error_count;
    reg [31:0] first_error_job_id;

    wire [31:0] selected_timeout =
        (active_timeout_cycles == 0) ? DEFAULT_TIMEOUT_CYCLES :
                                       active_timeout_cycles;

    assign fmt_batch_valid = (state == STATE_IDLE) && in_batch_valid &&
                             !legacy_active;
    assign in_batch_ready = (state == STATE_IDLE) && !legacy_active &&
                            fmt_batch_ready;
    assign fmt_batch_id = in_batch_id;
    assign fmt_expected_task_count = in_batch_task_count;
    assign fmt_header_status = in_batch_status;
    assign fmt_output_capacity_words = in_batch_max_result_words;

    assign in_task_ready = (state == STATE_WAIT_TASK) && !end_pending;
    assign backend_task_valid = (state == STATE_SEND_BACKEND);
    assign backend_task_id = active_task_id;
    assign backend_task_flags = active_task_flags;
    assign backend_task_item_count = active_item_count;
    assign backend_task_timeout_cycles = selected_timeout;

    assign backend_payload_valid = (state == STATE_FORWARD_PAYLOAD) &&
                                   in_payload_valid;
    assign backend_payload_data = in_payload_data;
    assign backend_payload_last = in_payload_last;
    assign in_payload_ready = (state == STATE_FORWARD_PAYLOAD) &&
                              backend_payload_ready;

    assign backend_done_ready = (state == STATE_WAIT_BACKEND);
    assign fmt_result_valid = (state == STATE_SUBMIT_RESULT);
    assign fmt_result_job_id = active_job_id;
    assign fmt_result_task_id = active_task_id;
    assign fmt_result_status = active_result_status;
    assign fmt_result_words = active_result_words;
    assign fmt_result_compute_cycles = active_compute_cycles;
    assign fmt_result_item_count = active_item_count;
    assign fmt_result_user_tag = active_user_tag;
    assign fmt_result_detail = active_result_detail;

    assign fmt_result_data_valid = (state == STATE_FORWARD_RESULT) &&
                                   backend_result_valid;
    assign fmt_result_data = backend_result_data;
    assign backend_result_ready =
        (state == STATE_FORWARD_RESULT) ? fmt_result_data_ready :
        (state == STATE_DISCARD_RESULT);

    assign in_end_ready = dma_active && !end_pending;
    assign fmt_finish_valid = (state == STATE_FINISH);
    assign fmt_finish_completed_count = completed_count;
    assign fmt_finish_error_count = error_count;
    assign fmt_finish_batch_status = {24'd0, stored_end_status};
    assign fmt_finish_first_error_job_id = first_error_job_id;
    assign fmt_finish_detail = stored_end_detail;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            active_job_id <= 32'd0;
            active_task_id <= 8'd0;
            active_task_flags <= 32'd0;
            active_item_count <= 32'd0;
            active_user_tag <= 32'd0;
            active_timeout_cycles <= 32'd0;
            active_result_status <= 24'd0;
            active_result_words <= 32'd0;
            active_result_detail <= 32'd0;
            active_compute_cycles <= 64'd0;
            result_word_index <= 32'd0;
            end_pending <= 1'b0;
            stored_end_status <= 8'd0;
            stored_end_detail <= 32'd0;
            completed_count <= 32'd0;
            error_count <= 32'd0;
            first_error_job_id <= 32'hFFFFFFFF;
            backend_abort <= 1'b0;
            legacy_reject <= 1'b0;
            dma_active <= 1'b0;
        end else begin
            backend_abort <= 1'b0;
            legacy_reject <= legacy_start && dma_active;

            if (in_end_valid && in_end_ready) begin
                end_pending <= 1'b1;
                stored_end_status <= in_end_status;
                stored_end_detail <= in_end_detail;
            end

            case (state)
                STATE_IDLE: begin
                    if (in_batch_valid && in_batch_ready) begin
                        completed_count <= 32'd0;
                        error_count <= 32'd0;
                        first_error_job_id <= 32'hFFFFFFFF;
                        end_pending <= 1'b0;
                        dma_active <= 1'b1;
                        state <= STATE_WAIT_TASK;
                    end
                end

                STATE_WAIT_TASK: begin
                    if (end_pending) begin
                        state <= STATE_FINISH;
                    end else if (in_task_valid && in_task_ready) begin
                        active_job_id <= in_task_job_id;
                        active_task_id <= in_task_id;
                        active_task_flags <= in_task_flags;
                        active_item_count <= in_task_item_count;
                        active_user_tag <= in_task_user_tag;
                        active_timeout_cycles <= in_task_timeout_cycles;
                        active_result_detail <= in_task_detail;
                        active_compute_cycles <= 64'd0;
                        result_word_index <= 32'd0;
                        if (in_task_status != `MOL_DMA_STATUS_OK) begin
                            active_result_status <= in_task_status;
                            active_result_words <= 32'd0;
                            state <= STATE_SUBMIT_RESULT;
                        end else begin
                            active_result_status <= 24'd0;
                            active_result_words <= 32'd0;
                            state <= STATE_SEND_BACKEND;
                        end
                    end
                end

                STATE_SEND_BACKEND: begin
                    if (backend_task_valid && backend_task_ready)
                        state <= STATE_FORWARD_PAYLOAD;
                end

                STATE_FORWARD_PAYLOAD: begin
                    if (in_payload_valid && in_payload_ready && in_payload_last) begin
                        active_compute_cycles <= 64'd0;
                        state <= STATE_WAIT_BACKEND;
                    end
                end

                STATE_WAIT_BACKEND: begin
                    if (backend_done_valid && backend_done_ready) begin
                        active_result_status <= backend_done_status;
                        active_result_words <= backend_done_result_words;
                        active_result_detail <= backend_done_detail;
                        result_word_index <= 32'd0;
                        state <= STATE_SUBMIT_RESULT;
                    end else if (active_compute_cycles + 64'd1 >= selected_timeout) begin
                        backend_abort <= 1'b1;
                        active_result_status <= `MOL_DMA_STATUS_TASK_TIMEOUT;
                        active_result_words <= 32'd0;
                        active_compute_cycles <= active_compute_cycles + 64'd1;
                        active_result_detail <= active_compute_cycles[31:0] + 32'd1;
                        state <= STATE_SUBMIT_RESULT;
                    end else begin
                        active_compute_cycles <= active_compute_cycles + 64'd1;
                    end
                end

                STATE_SUBMIT_RESULT: begin
                    if (fmt_result_valid && fmt_result_ready) begin
                        result_word_index <= 32'd0;
                        if (fmt_result_reject) begin
                            active_result_status <= `MOL_DMA_STATUS_RESULT_OVERFLOW;
                            if (active_result_words == 0)
                                state <= STATE_COMPLETE_TASK;
                            else
                                state <= STATE_DISCARD_RESULT;
                        end else if (active_result_words == 0) begin
                            state <= STATE_COMPLETE_TASK;
                        end else begin
                            state <= STATE_FORWARD_RESULT;
                        end
                    end
                end

                STATE_FORWARD_RESULT: begin
                    if (backend_result_valid && backend_result_ready) begin
                        if (result_word_index + 32'd1 == active_result_words) begin
                            result_word_index <= 32'd0;
                            state <= STATE_COMPLETE_TASK;
                        end else begin
                            result_word_index <= result_word_index + 32'd1;
                        end
                    end
                end

                STATE_DISCARD_RESULT: begin
                    if (backend_result_valid && backend_result_ready) begin
                        if (result_word_index + 32'd1 == active_result_words) begin
                            result_word_index <= 32'd0;
                            state <= STATE_COMPLETE_TASK;
                        end else begin
                            result_word_index <= result_word_index + 32'd1;
                        end
                    end
                end

                STATE_COMPLETE_TASK: begin
                    completed_count <= completed_count + 32'd1;
                    if (active_result_status != 0) begin
                        error_count <= error_count + 32'd1;
                        if (error_count == 0)
                            first_error_job_id <= active_job_id;
                    end
                    state <= STATE_WAIT_TASK;
                end

                STATE_FINISH: begin
                    if (fmt_finish_valid && fmt_finish_ready) begin
                        end_pending <= 1'b0;
                        state <= STATE_WAIT_FORMATTER;
                    end
                end

                STATE_WAIT_FORMATTER: begin
                    if (fmt_batch_ready) begin
                        dma_active <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
