`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module dma_result_bank (
    input  wire        clk,
    input  wire        we,
    input  wire [5:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [5:0]  raddr,
    output wire [31:0] rdata
);
    (* ram_style = "distributed" *) reg [31:0] memory [0:63];
    always @(posedge clk)
        if (we)
            memory[waddr] <= wdata;
    assign rdata = memory[raddr];
endmodule

// Adapts the normalized DMA queue interface to the existing accelerator cores.
// The numerical cores remain single-instanced in generator_accelerator_top.
module dma_accelerator_backend #(
    parameter integer MAX_NODES = 50,
    parameter integer FEATURE_DIM = 64,
    parameter integer HIDDEN_DIM = 128,
    parameter integer DATA_WIDTH = 16
) (
    input  wire clk,
    input  wire rst_n,

    input  wire        task_valid,
    output wire        task_ready,
    input  wire [7:0]  task_id,
    input  wire [31:0] task_flags,
    input  wire [31:0] task_item_count,

    input  wire        payload_valid,
    output wire        payload_ready,
    input  wire [31:0] payload_data,
    input  wire        payload_last,

    output wire        done_valid,
    input  wire        done_ready,
    output wire [23:0] done_status,
    output wire [31:0] done_result_words,
    output wire [31:0] done_detail,

    output wire        result_valid,
    input  wire        result_ready,
    output wire [31:0] result_data,
    input  wire        abort,

    output wire          tanimoto_start,
    output reg           fingerprint_we,
    output reg           fingerprint_db_select,
    output reg  [4:0]    fingerprint_addr,
    output reg  [31:0]   fingerprint_wdata,
    input  wire          tanimoto_busy,
    input  wire          tanimoto_valid,
    input  wire [31:0]   tanimoto_similarity,

    output wire gnn_start,
    output wire gnn_feature_we,
    output wire [(((MAX_NODES*FEATURE_DIM+1)/2 <= 1) ? 1 :
                  $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0]
                gnn_feature_addr,
    output wire [31:0] gnn_feature_wdata,
    output wire [3:0]  gnn_feature_wstrb,
    output wire gnn_adjacency_we,
    output wire [(((MAX_NODES*MAX_NODES+31)/32 <= 1) ? 1 :
                  $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0]
                gnn_adjacency_addr,
    output wire [31:0] gnn_adjacency_wdata,
    output wire [3:0]  gnn_adjacency_wstrb,
    output wire gnn_output_re,
    output wire [(((MAX_NODES*HIDDEN_DIM+1)/2 <= 1) ? 1 :
                  $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0]
                gnn_output_addr,
    input  wire [31:0] gnn_output_rdata,
    input  wire gnn_busy,
    input  wire gnn_valid,

    output wire admet_start,
    output reg  descriptor_we,
    output reg  [4:0] descriptor_addr,
    output reg  [DATA_WIDTH-1:0] descriptor_wdata,
    input  wire admet_busy,
    input  wire admet_valid,
    input  wire [4*DATA_WIDTH-1:0] admet_predictions
);
    localparam integer GNN_FEATURE_WORDS = (MAX_NODES*FEATURE_DIM+1)/2;
    localparam integer GNN_ADJ_WORDS = (MAX_NODES*MAX_NODES+31)/32;
    localparam integer GNN_OUTPUT_WORDS = (MAX_NODES*HIDDEN_DIM+1)/2;
    localparam integer FEATURE_ADDR_W =
        (GNN_FEATURE_WORDS <= 1) ? 1 : $clog2(GNN_FEATURE_WORDS);
    localparam integer ADJ_ADDR_W =
        (GNN_ADJ_WORDS <= 1) ? 1 : $clog2(GNN_ADJ_WORDS);
    localparam integer OUTPUT_ADDR_W =
        (GNN_OUTPUT_WORDS <= 1) ? 1 : $clog2(GNN_OUTPUT_WORDS);

    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_LOAD          = 4'd1;
    localparam [3:0] ST_WAIT_TANI     = 4'd2;
    localparam [3:0] ST_WAIT_SHARED   = 4'd3;
    localparam [3:0] ST_WAIT_GNN      = 4'd4;
    localparam [3:0] ST_WAIT_ADMET    = 4'd5;
    localparam [3:0] ST_PIPE_TANI     = 4'd6;
    localparam [3:0] ST_PIPE_GNN      = 4'd7;
    localparam [3:0] ST_PIPE_ADMET    = 4'd8;
    localparam [3:0] ST_DONE          = 4'd9;
    localparam [3:0] ST_RESULT        = 4'd10;
    localparam [3:0] ST_GNN_READ_WAIT = 4'd11;
    localparam [3:0] ST_START_TANI    = 4'd12;

    reg [3:0] state;
    reg [7:0] active_task;
    reg [31:0] active_flags;
    reg [6:0] active_items;
    reg [31:0] payload_index;
    reg [6:0] admet_item_index;
    reg [31:0] result_words_reg;
    reg [31:0] result_index;
    reg [31:0] result_data_reg;
    reg result_valid_reg;
    reg [1:0] gnn_read_wait;

    reg [31:0] tanimoto_result;

    reg tanimoto_start_reg;
    reg gnn_start_reg;
    reg admet_start_reg;
    reg gnn_feature_we_reg;
    reg [FEATURE_ADDR_W-1:0] gnn_feature_addr_reg;
    reg [31:0] gnn_feature_wdata_reg;
    reg gnn_adjacency_we_reg;
    reg [ADJ_ADDR_W-1:0] gnn_adjacency_addr_reg;
    reg [31:0] gnn_adjacency_wdata_reg;
    reg gnn_output_re_reg;
    reg [OUTPUT_ADDR_W-1:0] gnn_output_addr_reg;

    wire shared_mode = (active_flags & `MOL_DMA_FLAG_SHARED_QUERY) != 0;
    wire full_gnn = (active_flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0;
    wire return_intermediate =
        (active_flags & `MOL_DMA_FLAG_RETURN_INTERMEDIATE) != 0;

    reg [6:0] shared_result_count;

    assign task_ready = (state == ST_IDLE) && !tanimoto_busy &&
                        !gnn_busy && !admet_busy;
    wire [31:0] shared_payload_words =
        32'd32 + ({25'd0, active_items} << 5);
    /* Once the core has sampled a completed candidate, its popcount inputs
     * are registered.  Stream the next candidate into the database RAM while
     * the previous comparison is finishing instead of inserting five idle
     * core cycles between every pair. */
    assign payload_ready = (state == ST_LOAD) ||
        ((state == ST_WAIT_SHARED) && shared_mode &&
         (payload_index < shared_payload_words));
    assign done_valid = (state == ST_DONE);
    assign done_status = 24'd0;
    assign done_result_words = result_words_reg;
    assign done_detail = 32'd0;
    assign result_valid = result_valid_reg;
    assign result_data = result_data_reg;

    assign tanimoto_start = tanimoto_start_reg;
    assign gnn_start = gnn_start_reg;
    assign gnn_feature_we = gnn_feature_we_reg;
    assign gnn_feature_addr = gnn_feature_addr_reg;
    assign gnn_feature_wdata = gnn_feature_wdata_reg;
    assign gnn_feature_wstrb = 4'hf;
    assign gnn_adjacency_we = gnn_adjacency_we_reg;
    assign gnn_adjacency_addr = gnn_adjacency_addr_reg;
    assign gnn_adjacency_wdata = gnn_adjacency_wdata_reg;
    assign gnn_adjacency_wstrb = 4'hf;
    assign gnn_output_re = gnn_output_re_reg;
    assign gnn_output_addr = gnn_output_addr_reg;
    assign admet_start = admet_start_reg;

    function is_gnn_result_word;
        input [7:0] id;
        input [31:0] flags;
        input [31:0] index;
        begin
            if (id == `MOL_DMA_TASK_GNN)
                is_gnn_result_word = 1'b1;
            else if (id == `MOL_DMA_TASK_PIPELINE &&
                     (flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0)
                is_gnn_result_word = (index >= 1 && index <= 3200);
            else if (id == `MOL_DMA_TASK_PIPELINE &&
                     (flags & `MOL_DMA_FLAG_RETURN_INTERMEDIATE) != 0)
                is_gnn_result_word = (index == 1);
            else
                is_gnn_result_word = 1'b0;
        end
    endfunction

    function [31:0] gnn_result_address;
        input [7:0] id;
        input [31:0] index;
        begin
            gnn_result_address = (id == `MOL_DMA_TASK_GNN) ? index : index-1;
        end
    endfunction

    wire [31:0] small_linear_index =
        (active_task == `MOL_DMA_TASK_PIPELINE && full_gnn) ?
            result_index - 32'd3201 :
        (active_task == `MOL_DMA_TASK_PIPELINE && return_intermediate) ?
            result_index - 32'd2 : result_index;
    wire [5:0] small_read_addr = small_linear_index[7:2];
    wire [1:0] small_read_bank = small_linear_index[1:0];
    wire [127:0] small_bank_read_bus;
    wire [31:0] small_result_read =
        (small_read_bank == 0) ? small_bank_read_bus[31:0] :
        (small_read_bank == 1) ? small_bank_read_bus[63:32] :
        (small_read_bank == 2) ? small_bank_read_bus[95:64] :
                                 small_bank_read_bus[127:96];

    genvar result_bank;
    generate
        for (result_bank = 0; result_bank < 4;
             result_bank = result_bank + 1) begin : gen_result_bank
            wire shared_we = (state == ST_WAIT_SHARED) && tanimoto_valid &&
                             shared_result_count[1:0] == result_bank;
            wire admet_we = ((state == ST_WAIT_ADMET) ||
                             (state == ST_PIPE_ADMET)) && admet_valid;
            wire bank_we = shared_we || admet_we;
            wire [5:0] bank_waddr = shared_we ? shared_result_count[6:2] :
                                     (state == ST_WAIT_ADMET ?
                                         admet_item_index[5:0] : 6'd0);
            wire [31:0] bank_wdata = shared_we ? tanimoto_similarity :
                {{(32-DATA_WIDTH){1'b0}},
                 admet_predictions[result_bank*DATA_WIDTH +: DATA_WIDTH]};
            dma_result_bank bank (
                .clk(clk), .we(bank_we), .waddr(bank_waddr),
                .wdata(bank_wdata), .raddr(small_read_addr),
                .rdata(small_bank_read_bus[result_bank*32 +: 32])
            );
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            active_task <= 0;
            active_flags <= 0;
            active_items <= 0;
            payload_index <= 0;
            admet_item_index <= 0;
            result_words_reg <= 0;
            result_index <= 0;
            result_data_reg <= 0;
            result_valid_reg <= 0;
            gnn_read_wait <= 0;
            tanimoto_result <= 0;
            tanimoto_start_reg <= 0;
            gnn_start_reg <= 0;
            admet_start_reg <= 0;
            gnn_feature_we_reg <= 0;
            gnn_feature_addr_reg <= 0;
            gnn_feature_wdata_reg <= 0;
            gnn_adjacency_we_reg <= 0;
            gnn_adjacency_addr_reg <= 0;
            gnn_adjacency_wdata_reg <= 0;
            gnn_output_re_reg <= 0;
            gnn_output_addr_reg <= 0;
            fingerprint_we <= 0;
            fingerprint_db_select <= 0;
            fingerprint_addr <= 0;
            fingerprint_wdata <= 0;
            descriptor_we <= 0;
            descriptor_addr <= 0;
            descriptor_wdata <= 0;
            shared_result_count <= 0;
        end else begin
            tanimoto_start_reg <= 1'b0;
            gnn_start_reg <= 1'b0;
            admet_start_reg <= 1'b0;
            gnn_feature_we_reg <= 1'b0;
            gnn_adjacency_we_reg <= 1'b0;
            gnn_output_re_reg <= 1'b0;
            fingerprint_we <= 1'b0;
            descriptor_we <= 1'b0;

            if (abort) begin
                state <= ST_IDLE;
                result_valid_reg <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        result_valid_reg <= 1'b0;
                        if (task_valid && task_ready) begin
                            active_task <= task_id;
                            active_flags <= task_flags;
                            active_items <= task_item_count[6:0];
                            payload_index <= 0;
                            admet_item_index <= 0;
                            shared_result_count <= 0;
                            state <= ST_LOAD;
                        end
                    end

                    ST_LOAD: begin
                        if (payload_valid && payload_ready) begin
                            payload_index <= payload_index + 1'b1;
                            case (active_task)
                                `MOL_DMA_TASK_TANIMOTO: begin
                                    fingerprint_we <= 1'b1;
                                    fingerprint_db_select <= (payload_index >= 32);
                                    fingerprint_addr <= payload_index[4:0];
                                    fingerprint_wdata <= payload_data;
                                    if (shared_mode && payload_index >= 63 &&
                                        payload_index[4:0] == 31) begin
                                        state <= ST_START_TANI;
                                    end else if (!shared_mode && payload_last) begin
                                        state <= ST_START_TANI;
                                    end
                                end
                                `MOL_DMA_TASK_GNN: begin
                                    if (payload_index < 79) begin
                                        gnn_adjacency_we_reg <= 1'b1;
                                        gnn_adjacency_addr_reg <= payload_index[ADJ_ADDR_W-1:0];
                                        gnn_adjacency_wdata_reg <= payload_data;
                                    end else begin
                                        gnn_feature_we_reg <= 1'b1;
                                        gnn_feature_addr_reg <=
                                            (payload_index-79);
                                        gnn_feature_wdata_reg <= payload_data;
                                    end
                                    if (payload_last) begin
                                        gnn_start_reg <= 1'b1;
                                        state <= ST_WAIT_GNN;
                                    end
                                end
                                `MOL_DMA_TASK_ADMET: begin
                                    descriptor_we <= 1'b1;
                                    descriptor_addr <= payload_index % 20;
                                    descriptor_wdata <= payload_data[DATA_WIDTH-1:0];
                                    if ((payload_index % 20) == 19) begin
                                        admet_start_reg <= 1'b1;
                                        state <= ST_WAIT_ADMET;
                                    end
                                end
                                default: begin
                                    if (payload_index < 64) begin
                                        fingerprint_we <= 1'b1;
                                        fingerprint_db_select <= (payload_index >= 32);
                                        fingerprint_addr <= payload_index[4:0];
                                        fingerprint_wdata <= payload_data;
                                    end else if (payload_index < 143) begin
                                        gnn_adjacency_we_reg <= 1'b1;
                                        gnn_adjacency_addr_reg <=
                                            (payload_index-64);
                                        gnn_adjacency_wdata_reg <= payload_data;
                                    end else if (payload_index < 1743) begin
                                        gnn_feature_we_reg <= 1'b1;
                                        gnn_feature_addr_reg <=
                                            (payload_index-143);
                                        gnn_feature_wdata_reg <= payload_data;
                                    end else begin
                                        descriptor_we <= 1'b1;
                                        descriptor_addr <= payload_index-1743;
                                        descriptor_wdata <= payload_data[DATA_WIDTH-1:0];
                                    end
                                    if (payload_last) begin
                                        state <= ST_START_TANI;
                                    end
                                end
                            endcase
                        end
                    end

                    ST_WAIT_TANI: if (tanimoto_valid) begin
                        tanimoto_result <= tanimoto_similarity;
                        result_words_reg <= 1;
                        state <= ST_DONE;
                    end

                    ST_START_TANI: begin
                        tanimoto_start_reg <= 1'b1;
                        if (active_task == `MOL_DMA_TASK_PIPELINE)
                            state <= ST_PIPE_TANI;
                        else if (shared_mode)
                            state <= ST_WAIT_SHARED;
                        else
                            state <= ST_WAIT_TANI;
                    end

                    ST_WAIT_SHARED: begin
                        if (payload_valid && payload_ready) begin
                            payload_index <= payload_index + 1'b1;
                            fingerprint_we <= 1'b1;
                            fingerprint_db_select <= 1'b1;
                            fingerprint_addr <= payload_index[4:0];
                            fingerprint_wdata <= payload_data;
                            if (payload_index >= 63 &&
                                payload_index[4:0] == 31)
                                state <= ST_START_TANI;
                        end
                        if (tanimoto_valid) begin
                            shared_result_count <=
                                shared_result_count + 1'b1;
                            if (shared_result_count + 1 == active_items) begin
                                result_words_reg <= active_items;
                                state <= ST_DONE;
                            end
                        end
                    end

                    ST_WAIT_GNN: if (gnn_valid) begin
                        result_words_reg <= full_gnn ? 3200 : 1;
                        state <= ST_DONE;
                    end

                    ST_WAIT_ADMET: if (admet_valid) begin
                        if (admet_item_index + 1 == active_items) begin
                            result_words_reg <= {23'd0, active_items, 2'b00};
                            state <= ST_DONE;
                        end else begin
                            admet_item_index <= admet_item_index + 1'b1;
                            state <= ST_LOAD;
                        end
                    end

                    ST_PIPE_TANI: if (tanimoto_valid) begin
                        tanimoto_result <= tanimoto_similarity;
                        gnn_start_reg <= 1'b1;
                        state <= ST_PIPE_GNN;
                    end

                    ST_PIPE_GNN: if (gnn_valid) begin
                        admet_start_reg <= 1'b1;
                        state <= ST_PIPE_ADMET;
                    end

                    ST_PIPE_ADMET: if (admet_valid) begin
                        result_words_reg <= full_gnn ? 3205 :
                                            (return_intermediate ? 6 : 4);
                        state <= ST_DONE;
                    end

                    ST_DONE: if (done_valid && done_ready) begin
                        result_index <= 0;
                        result_valid_reg <= 1'b0;
                        state <= ST_RESULT;
                    end

                    ST_RESULT: begin
                        if (!result_valid_reg) begin
                            if (is_gnn_result_word(active_task, active_flags,
                                                   result_index)) begin
                                gnn_output_addr_reg <=
                                    gnn_result_address(active_task, result_index);
                                gnn_output_re_reg <= 1'b1;
                                gnn_read_wait <= 2;
                                state <= ST_GNN_READ_WAIT;
                            end else begin
                                if (active_task == `MOL_DMA_TASK_TANIMOTO &&
                                    !shared_mode)
                                    result_data_reg <= tanimoto_result;
                                else if (active_task == `MOL_DMA_TASK_PIPELINE &&
                                         (full_gnn || return_intermediate) &&
                                         result_index == 0)
                                    result_data_reg <= tanimoto_result;
                                else
                                    result_data_reg <= small_result_read;
                                result_valid_reg <= 1'b1;
                            end
                        end else if (result_ready) begin
                            result_valid_reg <= 1'b0;
                            if (result_index + 1 == result_words_reg)
                                state <= ST_IDLE;
                            else
                                result_index <= result_index + 1'b1;
                        end
                    end

                    ST_GNN_READ_WAIT: begin
                        if (gnn_read_wait != 0)
                            gnn_read_wait <= gnn_read_wait - 1'b1;
                        else begin
                            result_data_reg <= gnn_output_rdata;
                            result_valid_reg <= 1'b1;
                            state <= ST_RESULT;
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule
