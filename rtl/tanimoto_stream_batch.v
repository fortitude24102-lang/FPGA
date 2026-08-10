`timescale 1ns/1ps

module tanimoto_stream_batch (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire          abort,
    input  wire [6:0]    item_count,

    input  wire          payload_valid,
    output wire          payload_ready,
    input  wire [31:0]   payload_data,
    input  wire          payload_last,

    output wire          result_valid,
    input  wire          result_ready,
    output wire [31:0]   result_data,
    output wire          result_last,

    output wire          busy,
    output reg           done,
    output reg           error,

    output reg           core_start,
    output wire [1023:0] core_query_fp,
    output reg  [1023:0] core_db_fp,
    input  wire          core_busy,
    input  wire          core_valid,
    input  wire [31:0]   core_similarity
);

    localparam [2:0] STATE_IDLE           = 3'd0;
    localparam [2:0] STATE_LOAD_QUERY     = 3'd1;
    localparam [2:0] STATE_LOAD_CANDIDATE = 3'd2;
    localparam [2:0] STATE_WAIT_CORE      = 3'd3;
    localparam [2:0] STATE_WAIT_RESULTS   = 3'd4;

    reg [2:0] state;
    reg [6:0] active_item_count;
    reg [5:0] fingerprint_word_index;
    reg [31:0] accepted_payload_words;
    reg [6:0] candidates_started;
    reg [6:0] results_captured;

    reg [1023:0] query_buffer;
    reg result_buffer_valid;
    reg [31:0] result_buffer_data;
    reg result_buffer_last;
    reg core_in_flight;

    wire loading_payload = (state == STATE_LOAD_QUERY) ||
                           (state == STATE_LOAD_CANDIDATE);
    assign payload_ready = loading_payload && !error;
    assign core_query_fp = query_buffer;
    assign result_valid = result_buffer_valid;
    assign result_data = result_buffer_data;
    assign result_last = result_buffer_last;
    assign busy = (state != STATE_IDLE) || result_buffer_valid;

    wire [31:0] expected_payload_words =
        32'd32 + ({25'd0, active_item_count} << 5);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            active_item_count <= 7'd0;
            fingerprint_word_index <= 6'd0;
            accepted_payload_words <= 32'd0;
            candidates_started <= 7'd0;
            results_captured <= 7'd0;
            query_buffer <= 1024'd0;
            core_db_fp <= 1024'd0;
            result_buffer_valid <= 1'b0;
            result_buffer_data <= 32'd0;
            result_buffer_last <= 1'b0;
            core_in_flight <= 1'b0;
            core_start <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            core_start <= 1'b0;
            done <= 1'b0;

            if (abort) begin
                state <= STATE_IDLE;
                fingerprint_word_index <= 6'd0;
                accepted_payload_words <= 32'd0;
                candidates_started <= 7'd0;
                results_captured <= 7'd0;
                result_buffer_valid <= 1'b0;
                core_in_flight <= 1'b0;
                error <= 1'b0;
            end else begin
                if (start && (state == STATE_IDLE) && !result_buffer_valid) begin
                    if ((item_count == 0) || (item_count > 64)) begin
                        error <= 1'b1;
                        done <= 1'b1;
                    end else begin
                        active_item_count <= item_count;
                        fingerprint_word_index <= 6'd0;
                        accepted_payload_words <= 32'd0;
                        candidates_started <= 7'd0;
                        results_captured <= 7'd0;
                        query_buffer <= 1024'd0;
                        core_db_fp <= 1024'd0;
                        error <= 1'b0;
                        state <= STATE_LOAD_QUERY;
                    end
                end

                if (payload_valid && payload_ready) begin
                    if (payload_last !=
                        (accepted_payload_words + 32'd1 == expected_payload_words)) begin
                        error <= 1'b1;
                        done <= 1'b1;
                        state <= STATE_IDLE;
                        result_buffer_valid <= 1'b0;
                        core_in_flight <= 1'b0;
                        fingerprint_word_index <= 6'd0;
                    end else begin
                        accepted_payload_words <= accepted_payload_words + 32'd1;
                        if (state == STATE_LOAD_QUERY) begin
                            query_buffer[fingerprint_word_index*32 +: 32] <= payload_data;
                            if (fingerprint_word_index == 6'd31) begin
                                fingerprint_word_index <= 6'd0;
                                state <= STATE_LOAD_CANDIDATE;
                            end else begin
                                fingerprint_word_index <= fingerprint_word_index + 6'd1;
                            end
                        end else begin
                            core_db_fp[fingerprint_word_index*32 +: 32] <= payload_data;
                            if (fingerprint_word_index == 6'd31) begin
                                fingerprint_word_index <= 6'd0;
                                state <= STATE_WAIT_CORE;
                            end else begin
                                fingerprint_word_index <= fingerprint_word_index + 6'd1;
                            end
                        end
                    end
                end

                if ((state == STATE_WAIT_CORE) && !core_busy &&
                    !result_buffer_valid) begin
                    core_start <= 1'b1;
                    core_in_flight <= 1'b1;
                    candidates_started <= candidates_started + 7'd1;
                    if (candidates_started + 7'd1 == active_item_count) begin
                        state <= STATE_WAIT_RESULTS;
                    end else begin
                        fingerprint_word_index <= 6'd0;
                        state <= STATE_LOAD_CANDIDATE;
                    end
                end

                if (core_valid && core_in_flight) begin
                    core_in_flight <= 1'b0;
                    if (result_buffer_valid) begin
                        error <= 1'b1;
                    end else begin
                        result_buffer_valid <= 1'b1;
                        result_buffer_data <= core_similarity;
                        result_buffer_last <=
                            (results_captured + 7'd1 == active_item_count);
                        results_captured <= results_captured + 7'd1;
                    end
                end

                if (result_buffer_valid && result_ready) begin
                    result_buffer_valid <= 1'b0;
                    if (result_buffer_last) begin
                        state <= STATE_IDLE;
                        done <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
