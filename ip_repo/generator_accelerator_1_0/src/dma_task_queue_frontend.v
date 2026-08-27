`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module dma_task_queue_frontend (
    input  wire         aclk,
    input  wire         aresetn,
    input  wire [127:0] s_axis_job_tdata,
    input  wire  [15:0] s_axis_job_tkeep,
    input  wire         s_axis_job_tvalid,
    output wire         s_axis_job_tready,
    input  wire         s_axis_job_tlast,

    output reg          batch_valid,
    input  wire         batch_ready,
    output reg  [31:0]  batch_id,
    output reg  [31:0]  batch_task_count,
    output reg  [31:0]  batch_total_words,
    output reg  [31:0]  batch_flags,
    output reg  [31:0]  batch_max_result_words,
    output reg  [7:0]   batch_status,
    output reg  [31:0]  batch_detail,

    output reg          task_valid,
    input  wire         task_ready,
    output reg  [31:0]  task_job_id,
    output reg  [7:0]   task_id,
    output reg  [31:0]  task_flags,
    output reg  [31:0]  task_payload_words,
    output reg  [31:0]  task_result_capacity_words,
    output reg  [31:0]  task_item_count,
    output reg  [31:0]  task_user_tag,
    output reg  [31:0]  task_timeout_cycles,
    output reg  [7:0]   task_status,
    output reg  [31:0]  task_detail,

    output wire         payload_valid,
    input  wire         payload_ready,
    output wire [31:0]  payload_data,
    output wire         payload_last,

    output wire         batch_end_valid,
    input  wire         batch_end_ready,
    output reg  [7:0]   batch_end_status,
    output reg  [31:0]  batch_end_detail,
    output reg  [31:0]  batch_observed_words
);

    localparam [2:0] STATE_BATCH_HEADER = 3'd0;
    localparam [2:0] STATE_TASK_HEADER  = 3'd1;
    localparam [2:0] STATE_PAYLOAD      = 3'd2;
    localparam [2:0] STATE_DRAIN        = 3'd3;
    localparam [2:0] STATE_END          = 3'd4;

    reg [2:0] state;
    reg [2:0] header_word_index;
    reg [31:0] payload_word_index;
    reg [31:0] task_index;

    reg [127:0] beat_data;
    reg         beat_valid;
    reg         beat_last;
    reg [2:0]   beat_word_count;
    reg [1:0]   beat_lane;
    reg         beat_stream_error;

    reg [7:0] batch_status_accum;
    reg [7:0] active_task_status;
    reg [7:0] drain_status;
    reg       batch_end_valid_int;

    function [2:0] keep_word_count;
        input [15:0] keep;
        begin
            case (keep)
                16'h000F: keep_word_count = 3'd1;
                16'h00FF: keep_word_count = 3'd2;
                16'h0FFF: keep_word_count = 3'd3;
                16'hFFFF: keep_word_count = 3'd4;
                default:  keep_word_count = 3'd0;
            endcase
        end
    endfunction

    function [7:0] checked_batch_status;
        input [7:0] prior;
        input [2:0] word_index;
        input [31:0] word_value;
        begin
            checked_batch_status = prior;
            if (prior == `MOL_DMA_STATUS_OK) begin
                case (word_index)
                    3'd0: if (word_value != `MOL_DMA_MAGIC_REQUEST)
                              checked_batch_status = `MOL_DMA_STATUS_BAD_MAGIC;
                    3'd1: if ((word_value[15:0] != `MOL_DMA_VERSION) ||
                              (word_value[31:16] != `MOL_DMA_BATCH_HEADER_WORDS))
                              checked_batch_status = `MOL_DMA_STATUS_BAD_VERSION;
                    3'd3: if ((word_value == 0) ||
                              (word_value > `MOL_DMA_MAX_TASKS))
                              checked_batch_status = `MOL_DMA_STATUS_BAD_LENGTH;
                    3'd4: if ((word_value < `MOL_DMA_BATCH_HEADER_WORDS) ||
                              (word_value > `MOL_DMA_MAX_TRANSFER_WORDS))
                              checked_batch_status = `MOL_DMA_STATUS_BAD_LENGTH;
                    3'd5: if ((word_value & ~32'd1) != 0)
                              checked_batch_status = `MOL_DMA_STATUS_BAD_FLAGS;
                    3'd6: if (word_value < (32'd16 + (batch_task_count << 3)))
                              checked_batch_status = `MOL_DMA_STATUS_RESULT_OVERFLOW;
                    3'd7: if (word_value != 0)
                              checked_batch_status = `MOL_DMA_STATUS_BAD_FLAGS;
                    default: begin end
                endcase
            end
        end
    endfunction

    function [7:0] checked_task_status;
        input [7:0] id;
        input [31:0] flags;
        input [31:0] payload_words_value;
        input [31:0] result_capacity;
        input [31:0] item_count_value;
        input [31:0] reserved;
        reg [31:0] required_payload;
        reg [31:0] required_result;
        reg [31:0] allowed_flags;
        reg [63:0] required_payload_wide;
        reg [63:0] required_result_wide;
        begin
            checked_task_status = `MOL_DMA_STATUS_OK;
            required_payload = 32'd0;
            required_result = 32'd0;
            allowed_flags = 32'd0;
            required_payload_wide = 64'd0;
            required_result_wide = 64'd0;

            if (!((id <= `MOL_DMA_TASK_PIPELINE) ||
                  (id == `MOL_DMA_TASK_WEIGHT_RELOAD))) begin
                checked_task_status = `MOL_DMA_STATUS_BAD_TASK;
            end else if ((flags & ~32'h00000700) != 0 || reserved != 0) begin
                checked_task_status = `MOL_DMA_STATUS_BAD_FLAGS;
            end else if ((item_count_value == 0) ||
                         (item_count_value > `MOL_DMA_MAX_ITEM_COUNT)) begin
                checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
            end else begin
                case (id)
                    `MOL_DMA_TASK_TANIMOTO: begin
                        allowed_flags = `MOL_DMA_FLAG_SHARED_QUERY;
                        if ((flags & `MOL_DMA_FLAG_SHARED_QUERY) != 0) begin
                            required_payload = `MOL_DMA_PAYLOAD_WORDS_FINGERPRINT +
                                               (item_count_value << 5);
                            required_result = item_count_value;
                        end else begin
                            if (item_count_value != 1)
                                checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
                            required_payload = `MOL_DMA_PAYLOAD_WORDS_TANIMOTO_PAIR;
                            required_result = 32'd1;
                        end
                    end
                    `MOL_DMA_TASK_GNN: begin
                        allowed_flags = `MOL_DMA_FLAG_FULL_GNN_OUTPUT;
                        if (item_count_value > 32)
                            checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
                        required_payload_wide = 64'd1679 * item_count_value;
                        required_result_wide =
                            ((flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0) ?
                            64'd3200 * item_count_value : item_count_value;
                        required_payload = required_payload_wide[31:0];
                        required_result = required_result_wide[31:0];
                    end
                    `MOL_DMA_TASK_ADMET: begin
                        allowed_flags = 32'd0;
                        required_payload = (item_count_value << 4) +
                                           (item_count_value << 2);
                        required_result = item_count_value << 2;
                    end
                    `MOL_DMA_TASK_PIPELINE: begin
                        allowed_flags = `MOL_DMA_FLAG_FULL_GNN_OUTPUT |
                                        `MOL_DMA_FLAG_RETURN_INTERMEDIATE;
                        if (item_count_value > 16)
                            checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
                        required_payload_wide = 64'd1763 * item_count_value;
                        if ((flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0)
                            required_result_wide = 64'd3205 * item_count_value;
                        else if ((flags & `MOL_DMA_FLAG_RETURN_INTERMEDIATE) != 0)
                            required_result_wide = 64'd6 * item_count_value;
                        else
                            required_result_wide = 64'd4 * item_count_value;
                        required_payload = required_payload_wide[31:0];
                        required_result = required_result_wide[31:0];
                    end
                    `MOL_DMA_TASK_WEIGHT_RELOAD: begin
                        allowed_flags = 32'd0;
                        if (item_count_value != 1)
                            checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
                        required_payload = `MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
                        required_result = 32'd1;
                    end
                    default: checked_task_status = `MOL_DMA_STATUS_BAD_TASK;
                endcase

                if ((checked_task_status == `MOL_DMA_STATUS_OK) &&
                    (required_payload_wide[63:32] != 0 ||
                     required_result_wide[63:32] != 0))
                    checked_task_status = `MOL_DMA_STATUS_BAD_LENGTH;
                if ((checked_task_status == `MOL_DMA_STATUS_OK) &&
                    ((flags & ~allowed_flags) != 0))
                    checked_task_status = `MOL_DMA_STATUS_BAD_FLAGS;
                if ((checked_task_status == `MOL_DMA_STATUS_OK) &&
                    (payload_words_value != required_payload))
                    checked_task_status = `MOL_DMA_STATUS_BAD_LENGTH;
                if ((checked_task_status == `MOL_DMA_STATUS_OK) &&
                    (result_capacity < required_result))
                    checked_task_status = `MOL_DMA_STATUS_RESULT_OVERFLOW;
            end
        end
    endfunction

    wire [31:0] current_word =
        (beat_lane == 2'd0) ? beat_data[31:0] :
        (beat_lane == 2'd1) ? beat_data[63:32] :
        (beat_lane == 2'd2) ? beat_data[95:64] : beat_data[127:96];
    wire current_is_last_lane = (beat_lane + 3'd1 == beat_word_count);
    wire current_has_tlast = beat_last && current_is_last_lane;

    wire header_can_advance =
        (state == STATE_BATCH_HEADER) ? !batch_valid :
        (state == STATE_TASK_HEADER)  ? (!task_valid && !batch_valid) : 1'b0;
    assign payload_valid = beat_valid && (state == STATE_PAYLOAD) &&
                           !task_valid &&
                           (active_task_status == `MOL_DMA_STATUS_OK);
    assign payload_data = current_word;
    assign payload_last = payload_valid &&
                          (payload_word_index + 32'd1 == task_payload_words);
    wire payload_can_advance = (state == STATE_PAYLOAD) && !task_valid &&
                               ((active_task_status != `MOL_DMA_STATUS_OK) ||
                                payload_ready);
    wire consume_word = beat_valid &&
                        (((state == STATE_BATCH_HEADER) ||
                          (state == STATE_TASK_HEADER)) ? header_can_advance :
                         (state == STATE_PAYLOAD) ? payload_can_advance :
                         (state == STATE_DRAIN));
    wire refill_ready = consume_word && current_is_last_lane;

    assign batch_end_valid = batch_end_valid_int && !batch_valid && !task_valid;
    /* Replace a fully consumed beat on the same edge.  The old implementation
     * deasserted TREADY for an extra clock between every pair of 128-bit
     * beats, reducing a four-lane payload path to 80% of its possible rate. */
    assign s_axis_job_tready = (!beat_valid || refill_ready) &&
                               !batch_end_valid_int;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= STATE_BATCH_HEADER;
            header_word_index <= 3'd0;
            payload_word_index <= 32'd0;
            task_index <= 32'd0;
            beat_data <= 128'd0;
            beat_valid <= 1'b0;
            beat_last <= 1'b0;
            beat_word_count <= 3'd4;
            beat_lane <= 2'd0;
            beat_stream_error <= 1'b0;
            batch_status_accum <= `MOL_DMA_STATUS_OK;
            active_task_status <= `MOL_DMA_STATUS_OK;
            drain_status <= `MOL_DMA_STATUS_OK;

            batch_valid <= 1'b0;
            batch_id <= 32'd0;
            batch_task_count <= 32'd0;
            batch_total_words <= 32'd0;
            batch_flags <= 32'd0;
            batch_max_result_words <= 32'd0;
            batch_status <= `MOL_DMA_STATUS_OK;
            batch_detail <= 32'd0;

            task_valid <= 1'b0;
            task_job_id <= 32'd0;
            task_id <= 8'd0;
            task_flags <= 32'd0;
            task_payload_words <= 32'd0;
            task_result_capacity_words <= 32'd0;
            task_item_count <= 32'd0;
            task_user_tag <= 32'd0;
            task_timeout_cycles <= 32'd0;
            task_status <= `MOL_DMA_STATUS_OK;
            task_detail <= 32'd0;

            batch_end_valid_int <= 1'b0;
            batch_end_status <= `MOL_DMA_STATUS_OK;
            batch_end_detail <= 32'd0;
            batch_observed_words <= 32'd0;
        end else begin
            if (batch_valid && batch_ready)
                batch_valid <= 1'b0;
            if (task_valid && task_ready)
                task_valid <= 1'b0;
            if (batch_end_valid && batch_end_ready) begin
                batch_end_valid_int <= 1'b0;
                state <= STATE_BATCH_HEADER;
                header_word_index <= 3'd0;
                payload_word_index <= 32'd0;
                task_index <= 32'd0;
                batch_observed_words <= 32'd0;
                batch_status_accum <= `MOL_DMA_STATUS_OK;
                active_task_status <= `MOL_DMA_STATUS_OK;
                drain_status <= `MOL_DMA_STATUS_OK;
            end

            if (s_axis_job_tvalid && s_axis_job_tready) begin
                beat_data <= s_axis_job_tdata;
                beat_valid <= 1'b1;
                beat_last <= s_axis_job_tlast;
                beat_lane <= 2'd0;
                if (keep_word_count(s_axis_job_tkeep) == 0) begin
                    beat_word_count <= 3'd4;
                    beat_stream_error <= 1'b1;
                end else begin
                    beat_word_count <= keep_word_count(s_axis_job_tkeep);
                    beat_stream_error <= (!s_axis_job_tlast &&
                                          (s_axis_job_tkeep != 16'hFFFF));
                end
            end

            if (consume_word) begin
                batch_observed_words <= batch_observed_words + 32'd1;
                if (current_is_last_lane) begin
                    /* A simultaneous AXIS handshake has already loaded the
                     * replacement beat above, so it must remain valid. */
                    if (!(s_axis_job_tvalid && s_axis_job_tready))
                        beat_valid <= 1'b0;
                end
                else
                    beat_lane <= beat_lane + 2'd1;

                if (beat_stream_error && current_is_last_lane) begin
                    drain_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                    if ((state == STATE_BATCH_HEADER) &&
                        (header_word_index == 3'd7)) begin
                        batch_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                        batch_detail <= batch_observed_words + 32'd1;
                        batch_valid <= 1'b1;
                        header_word_index <= 3'd0;
                    end
                    if (current_has_tlast) begin
                        batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                        batch_end_detail <= batch_observed_words + 32'd1;
                        batch_end_valid_int <= 1'b1;
                        state <= STATE_END;
                    end else begin
                        state <= STATE_DRAIN;
                    end
                end else begin
                    case (state)
                        STATE_BATCH_HEADER: begin
                            batch_status_accum <= checked_batch_status(
                                batch_status_accum, header_word_index, current_word
                            );
                            case (header_word_index)
                                3'd2: batch_id <= current_word;
                                3'd3: batch_task_count <= current_word;
                                3'd4: batch_total_words <= current_word;
                                3'd5: batch_flags <= current_word;
                                3'd6: batch_max_result_words <= current_word;
                                3'd7: begin
                                    batch_status <= checked_batch_status(
                                        batch_status_accum, header_word_index, current_word
                                    );
                                    batch_detail <= 32'd0;
                                    batch_valid <= 1'b1;
                                    header_word_index <= 3'd0;
                                    if (checked_batch_status(batch_status_accum,
                                                             header_word_index,
                                                             current_word) != `MOL_DMA_STATUS_OK) begin
                                        drain_status <= checked_batch_status(
                                            batch_status_accum, header_word_index, current_word
                                        );
                                        if (current_has_tlast) begin
                                            batch_end_status <= checked_batch_status(
                                                batch_status_accum, header_word_index, current_word
                                            );
                                            batch_end_detail <= 32'd0;
                                            batch_end_valid_int <= 1'b1;
                                            state <= STATE_END;
                                        end else begin
                                            state <= STATE_DRAIN;
                                        end
                                    end else if (current_has_tlast) begin
                                        batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                        batch_end_detail <= batch_observed_words + 32'd1;
                                        batch_end_valid_int <= 1'b1;
                                        state <= STATE_END;
                                    end else begin
                                        state <= STATE_TASK_HEADER;
                                    end
                                end
                                default: begin end
                            endcase
                            if (header_word_index != 3'd7) begin
                                header_word_index <= header_word_index + 3'd1;
                                if (current_has_tlast) begin
                                    batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                    batch_end_detail <= batch_observed_words + 32'd1;
                                    batch_end_valid_int <= 1'b1;
                                    state <= STATE_END;
                                end
                            end
                        end

                        STATE_TASK_HEADER: begin
                            case (header_word_index)
                                3'd0: task_job_id <= current_word;
                                3'd1: begin
                                    task_id <= current_word[7:0];
                                    task_flags <= {current_word[31:8], 8'd0};
                                end
                                3'd2: task_payload_words <= current_word;
                                3'd3: task_result_capacity_words <= current_word;
                                3'd4: task_item_count <= current_word;
                                3'd5: task_user_tag <= current_word;
                                3'd6: task_timeout_cycles <= current_word;
                                3'd7: begin
                                    task_status <= checked_task_status(
                                        task_id, task_flags, task_payload_words,
                                        task_result_capacity_words, task_item_count,
                                        current_word
                                    );
                                    active_task_status <= checked_task_status(
                                        task_id, task_flags, task_payload_words,
                                        task_result_capacity_words, task_item_count,
                                        current_word
                                    );
                                    task_detail <= 32'd0;
                                    task_valid <= 1'b1;
                                    payload_word_index <= 32'd0;
                                    header_word_index <= 3'd0;
                                    if (task_payload_words == 0) begin
                                        task_index <= task_index + 32'd1;
                                        if (task_index + 32'd1 == batch_task_count) begin
                                            if (current_has_tlast) begin
                                                if (batch_observed_words + 32'd1 == batch_total_words)
                                                    batch_end_status <= `MOL_DMA_STATUS_OK;
                                                else
                                                    batch_end_status <= `MOL_DMA_STATUS_BAD_LENGTH;
                                                batch_end_detail <= 32'd0;
                                                batch_end_valid_int <= 1'b1;
                                                state <= STATE_END;
                                            end else begin
                                                drain_status <= `MOL_DMA_STATUS_BAD_LENGTH;
                                                state <= STATE_DRAIN;
                                            end
                                        end else if (current_has_tlast) begin
                                            batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                            batch_end_detail <= batch_observed_words + 32'd1;
                                            batch_end_valid_int <= 1'b1;
                                            state <= STATE_END;
                                        end else if ((checked_task_status(
                                                          task_id, task_flags,
                                                          task_payload_words,
                                                          task_result_capacity_words,
                                                          task_item_count,
                                                          current_word
                                                      ) != `MOL_DMA_STATUS_OK) &&
                                                     ((batch_flags & 32'd1) == 0)) begin
                                            drain_status <= `MOL_DMA_STATUS_OK;
                                            state <= STATE_DRAIN;
                                        end else begin
                                            active_task_status <= `MOL_DMA_STATUS_OK;
                                            state <= STATE_TASK_HEADER;
                                        end
                                    end else if (current_has_tlast) begin
                                        batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                        batch_end_detail <= batch_observed_words + 32'd1;
                                        batch_end_valid_int <= 1'b1;
                                        state <= STATE_END;
                                    end else begin
                                        state <= STATE_PAYLOAD;
                                    end
                                end
                                default: begin end
                            endcase
                            if (header_word_index != 3'd7) begin
                                header_word_index <= header_word_index + 3'd1;
                                if (current_has_tlast) begin
                                    batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                    batch_end_detail <= batch_observed_words + 32'd1;
                                    batch_end_valid_int <= 1'b1;
                                    state <= STATE_END;
                                end
                            end
                        end

                        STATE_PAYLOAD: begin
                            if (payload_word_index + 32'd1 == task_payload_words) begin
                                payload_word_index <= 32'd0;
                                task_index <= task_index + 32'd1;
                                if (task_index + 32'd1 == batch_task_count) begin
                                    if (current_has_tlast) begin
                                        if (batch_observed_words + 32'd1 != batch_total_words)
                                            batch_end_status <= `MOL_DMA_STATUS_BAD_LENGTH;
                                        else
                                            batch_end_status <= `MOL_DMA_STATUS_OK;
                                        batch_end_detail <= 32'd0;
                                        batch_end_valid_int <= 1'b1;
                                        state <= STATE_END;
                                    end else begin
                                        drain_status <= `MOL_DMA_STATUS_BAD_LENGTH;
                                        state <= STATE_DRAIN;
                                    end
                                end else if (current_has_tlast) begin
                                    batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                    batch_end_detail <= batch_observed_words + 32'd1;
                                    batch_end_valid_int <= 1'b1;
                                    state <= STATE_END;
                                end else if ((active_task_status != `MOL_DMA_STATUS_OK) &&
                                             ((batch_flags & 32'd1) == 0)) begin
                                    drain_status <= `MOL_DMA_STATUS_OK;
                                    state <= STATE_DRAIN;
                                end else begin
                                    active_task_status <= `MOL_DMA_STATUS_OK;
                                    header_word_index <= 3'd0;
                                    state <= STATE_TASK_HEADER;
                                end
                            end else begin
                                payload_word_index <= payload_word_index + 32'd1;
                                if (current_has_tlast) begin
                                    batch_end_status <= `MOL_DMA_STATUS_STREAM_TRUNCATED;
                                    batch_end_detail <= batch_observed_words + 32'd1;
                                    batch_end_valid_int <= 1'b1;
                                    state <= STATE_END;
                                end
                            end
                        end

                        STATE_DRAIN: begin
                            if (current_has_tlast) begin
                                batch_end_status <= drain_status;
                                batch_end_detail <= 32'd0;
                                batch_end_valid_int <= 1'b1;
                                state <= STATE_END;
                            end
                        end

                        default: begin end
                    endcase
                end
            end
        end
    end

endmodule
