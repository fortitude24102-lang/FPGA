`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module dma_result_formatter (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         batch_valid,
    output wire         batch_ready,
    input  wire [31:0]  batch_id,
    input  wire [31:0]  expected_task_count,
    input  wire [7:0]   header_status,
    input  wire [31:0]  output_capacity_words,

    input  wire         result_valid,
    output wire         result_ready,
    output wire         result_reject,
    input  wire [31:0]  result_job_id,
    input  wire [7:0]   result_task_id,
    input  wire [23:0]  result_status,
    input  wire [31:0]  result_words,
    input  wire [63:0]  result_compute_cycles,
    input  wire [31:0]  result_item_count,
    input  wire [31:0]  result_user_tag,
    input  wire [31:0]  result_detail,

    input  wire         result_data_valid,
    output wire         result_data_ready,
    input  wire [31:0]  result_data,

    input  wire         finish_valid,
    output wire         finish_ready,
    input  wire [31:0]  finish_completed_count,
    input  wire [31:0]  finish_error_count,
    input  wire [31:0]  finish_batch_status,
    input  wire [31:0]  finish_first_error_job_id,
    input  wire [31:0]  finish_detail,

    output wire [127:0] m_axis_result_tdata,
    output wire [15:0]  m_axis_result_tkeep,
    output wire         m_axis_result_tvalid,
    input  wire         m_axis_result_tready,
    output wire         m_axis_result_tlast
);

    localparam [2:0] STATE_IDLE           = 3'd0;
    localparam [2:0] STATE_RESPONSE_HEADER = 3'd1;
    localparam [2:0] STATE_WAIT_RECORD     = 3'd2;
    localparam [2:0] STATE_RESULT_HEADER   = 3'd3;
    localparam [2:0] STATE_RESULT_PAYLOAD  = 3'd4;
    localparam [2:0] STATE_TRAILER         = 3'd5;
    localparam [2:0] STATE_COMPLETE        = 3'd6;

    reg [2:0] state;
    reg [2:0] word_index;
    reg [31:0] payload_index;
    reg [31:0] total_word_count;

    reg [31:0] active_batch_id;
    reg [31:0] active_expected_task_count;
    reg [7:0]  active_header_status;
    reg [31:0] active_output_capacity;

    reg [31:0] active_job_id;
    reg [7:0]  active_task_id;
    reg [23:0] active_result_status;
    reg [31:0] active_result_words;
    reg [63:0] active_compute_cycles;
    reg [31:0] active_item_count;
    reg [31:0] active_user_tag;
    reg [31:0] active_detail;

    reg [31:0] trailer_completed_count;
    reg [31:0] trailer_error_count;
    reg [31:0] trailer_total_words;
    reg [31:0] trailer_batch_status;
    reg [31:0] trailer_first_error_job_id;
    reg [31:0] trailer_detail;

    reg [127:0] pack_data;
    reg [2:0] pack_count;
    reg [127:0] output_data;
    reg [15:0] output_keep;
    reg output_valid;
    reg output_last;

    reg word_valid;
    reg [31:0] word_data;
    reg word_last;
    wire word_ready = !output_valid;
    wire word_fire = word_valid && word_ready;

    wire [32:0] candidate_result_total =
        {1'b0, total_word_count} + {1'b0, result_words} + 33'd16;
    assign result_reject = result_ready &&
                           (candidate_result_total > {1'b0, active_output_capacity});

    assign batch_ready = (state == STATE_IDLE) && !output_valid && (pack_count == 0);
    assign result_ready = (state == STATE_WAIT_RECORD);
    assign finish_ready = (state == STATE_WAIT_RECORD) && !result_valid;
    assign result_data_ready = (state == STATE_RESULT_PAYLOAD) && word_ready;

    assign m_axis_result_tdata = output_data;
    assign m_axis_result_tkeep = output_keep;
    assign m_axis_result_tvalid = output_valid;
    assign m_axis_result_tlast = output_last;

    always @* begin
        word_valid = 1'b0;
        word_data = 32'd0;
        word_last = 1'b0;
        case (state)
            STATE_RESPONSE_HEADER: begin
                word_valid = 1'b1;
                case (word_index)
                    3'd0: word_data = `MOL_DMA_MAGIC_RESPONSE;
                    3'd1: word_data = (`MOL_DMA_BATCH_HEADER_WORDS << 16) |
                                           `MOL_DMA_VERSION;
                    3'd2: word_data = active_batch_id;
                    3'd3: word_data = active_expected_task_count;
                    3'd4: word_data = {24'd0, active_header_status};
                    3'd5: word_data = active_output_capacity;
                    3'd6: word_data = 32'd0;
                    default: word_data = 32'd0;
                endcase
            end

            STATE_RESULT_HEADER: begin
                word_valid = 1'b1;
                case (word_index)
                    3'd0: word_data = active_job_id;
                    3'd1: word_data = {active_result_status, active_task_id};
                    3'd2: word_data = active_result_words;
                    3'd3: word_data = active_compute_cycles[31:0];
                    3'd4: word_data = active_compute_cycles[63:32];
                    3'd5: word_data = active_item_count;
                    3'd6: word_data = active_user_tag;
                    default: word_data = active_detail;
                endcase
            end

            STATE_RESULT_PAYLOAD: begin
                word_valid = result_data_valid;
                word_data = result_data;
            end

            STATE_TRAILER: begin
                word_valid = 1'b1;
                word_last = (word_index == 3'd7);
                case (word_index)
                    3'd0: word_data = `MOL_DMA_MAGIC_TRAILER;
                    3'd1: word_data = active_batch_id;
                    3'd2: word_data = trailer_completed_count;
                    3'd3: word_data = trailer_error_count;
                    3'd4: word_data = trailer_total_words;
                    3'd5: word_data = trailer_batch_status;
                    3'd6: word_data = trailer_first_error_job_id;
                    default: word_data = trailer_detail;
                endcase
            end

            default: begin end
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= STATE_IDLE;
            word_index <= 3'd0;
            payload_index <= 32'd0;
            total_word_count <= 32'd0;
            active_batch_id <= 32'd0;
            active_expected_task_count <= 32'd0;
            active_header_status <= 8'd0;
            active_output_capacity <= 32'd0;
            active_job_id <= 32'd0;
            active_task_id <= 8'd0;
            active_result_status <= 24'd0;
            active_result_words <= 32'd0;
            active_compute_cycles <= 64'd0;
            active_item_count <= 32'd0;
            active_user_tag <= 32'd0;
            active_detail <= 32'd0;
            trailer_completed_count <= 32'd0;
            trailer_error_count <= 32'd0;
            trailer_total_words <= 32'd0;
            trailer_batch_status <= 32'd0;
            trailer_first_error_job_id <= 32'hFFFFFFFF;
            trailer_detail <= 32'd0;
            pack_data <= 128'd0;
            pack_count <= 3'd0;
            output_data <= 128'd0;
            output_keep <= 16'd0;
            output_valid <= 1'b0;
            output_last <= 1'b0;
        end else begin
            if (output_valid && m_axis_result_tready) begin
                output_valid <= 1'b0;
                output_last <= 1'b0;
            end

            if (batch_valid && batch_ready) begin
                active_batch_id <= batch_id;
                active_expected_task_count <= expected_task_count;
                active_header_status <= header_status;
                active_output_capacity <= output_capacity_words;
                total_word_count <= 32'd0;
                word_index <= 3'd0;
                state <= STATE_RESPONSE_HEADER;
            end

            if (result_valid && result_ready) begin
                active_job_id <= result_job_id;
                active_task_id <= result_task_id;
                active_compute_cycles <= result_compute_cycles;
                active_item_count <= result_item_count;
                active_user_tag <= result_user_tag;
                word_index <= 3'd0;
                payload_index <= 32'd0;
                if (result_reject) begin
                    active_result_status <= `MOL_DMA_STATUS_RESULT_OVERFLOW;
                    active_result_words <= 32'd0;
                    active_detail <= result_words;
                end else begin
                    active_result_status <= result_status;
                    active_result_words <= result_words;
                    active_detail <= result_detail;
                end
                state <= STATE_RESULT_HEADER;
            end

            if (finish_valid && finish_ready) begin
                trailer_completed_count <= finish_completed_count;
                trailer_error_count <= finish_error_count;
                trailer_total_words <= total_word_count + `MOL_DMA_TRAILER_WORDS;
                trailer_batch_status <= finish_batch_status;
                trailer_first_error_job_id <= finish_first_error_job_id;
                trailer_detail <= finish_detail;
                word_index <= 3'd0;
                state <= STATE_TRAILER;
            end

            if (word_fire) begin
                total_word_count <= total_word_count + 32'd1;
                if ((pack_count == 3'd3) || word_last) begin
                    case (pack_count)
                        3'd0: output_data <= {96'd0, word_data};
                        3'd1: output_data <= {64'd0, word_data, pack_data[31:0]};
                        3'd2: output_data <= {32'd0, word_data, pack_data[63:0]};
                        default: output_data <= {word_data, pack_data[95:0]};
                    endcase
                    case (pack_count)
                        3'd0: output_keep <= 16'h000F;
                        3'd1: output_keep <= 16'h00FF;
                        3'd2: output_keep <= 16'h0FFF;
                        default: output_keep <= 16'hFFFF;
                    endcase
                    output_valid <= 1'b1;
                    output_last <= word_last;
                    pack_count <= 3'd0;
                end else begin
                    case (pack_count)
                        3'd0: pack_data[31:0] <= word_data;
                        3'd1: pack_data[63:32] <= word_data;
                        default: pack_data[95:64] <= word_data;
                    endcase
                    pack_count <= pack_count + 3'd1;
                end

                case (state)
                    STATE_RESPONSE_HEADER: begin
                        if (word_index == 3'd7) begin
                            word_index <= 3'd0;
                            state <= STATE_WAIT_RECORD;
                        end else begin
                            word_index <= word_index + 3'd1;
                        end
                    end

                    STATE_RESULT_HEADER: begin
                        if (word_index == 3'd7) begin
                            word_index <= 3'd0;
                            payload_index <= 32'd0;
                            if (active_result_words == 0)
                                state <= STATE_WAIT_RECORD;
                            else
                                state <= STATE_RESULT_PAYLOAD;
                        end else begin
                            word_index <= word_index + 3'd1;
                        end
                    end

                    STATE_RESULT_PAYLOAD: begin
                        if (payload_index + 32'd1 == active_result_words) begin
                            payload_index <= 32'd0;
                            state <= STATE_WAIT_RECORD;
                        end else begin
                            payload_index <= payload_index + 32'd1;
                        end
                    end

                    STATE_TRAILER: begin
                        if (word_index == 3'd7) begin
                            word_index <= 3'd0;
                            state <= STATE_COMPLETE;
                        end else begin
                            word_index <= word_index + 3'd1;
                        end
                    end

                    default: begin end
                endcase
            end

            if ((state == STATE_COMPLETE) && !output_valid && (pack_count == 0))
                state <= STATE_IDLE;
        end
    end

endmodule
