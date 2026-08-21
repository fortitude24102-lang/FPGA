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

module dma_weight_reload_controller #(
    parameter integer FEATURE_DIM = 64,
    parameter integer HIDDEN_DIM = 128
) (
    input  wire clk,
    input  wire rst_n,
    input  wire task_valid,
    output wire task_ready,
    input  wire [31:0] expected_crc,
    input  wire payload_valid,
    output wire payload_ready,
    input  wire [31:0] payload_data,
    input  wire payload_last,
    output wire done_valid,
    input  wire done_ready,
    output wire [23:0] done_status,
    output wire [31:0] done_result_words,
    output wire [31:0] done_detail,
    output wire result_valid,
    input  wire result_ready,
    output wire [31:0] result_data,
    input  wire abort,
    output reg  gnn_weight_we,
    output reg  [(((FEATURE_DIM*HIDDEN_DIM) <= 1) ? 1 :
                  $clog2(FEATURE_DIM*HIDDEN_DIM))-1:0] gnn_weight_addr,
    output reg  [15:0] gnn_weight_wdata,
    output reg  admet_cfg_we,
    output reg  [1:0] admet_cfg_model,
    output reg  [1:0] admet_cfg_layer,
    output reg  [15:0] admet_cfg_addr,
    output reg  [15:0] admet_cfg_wdata,
    output reg  weight_cfg_bank,
    output wire weight_run_bank
);
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_LOAD = 3'd1;
    localparam [2:0] ST_WRITE_LOW = 3'd2;
    localparam [2:0] ST_WRITE_HIGH = 3'd3;
    localparam [2:0] ST_DONE = 3'd4;
    localparam [2:0] ST_RESULT = 3'd5;

    reg [2:0] state;
    reg [31:0] expected_crc_reg;
    reg [31:0] crc_state;
    reg [31:0] observed_crc;
    reg [31:0] reload_word;
    reg reload_word_last;
    reg [13:0] reload_weight_index;
    reg [1:0] reload_admet_model;
    reg [1:0] reload_admet_layer;
    reg [7:0] reload_admet_addr;
    reg active_bank;
    reg [31:0] reload_epoch;
    reg reload_good;

    function automatic [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] byte_value;
        integer bit_index;
        reg [31:0] crc;
        begin
            crc = crc_in ^ byte_value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                crc = crc[0] ? ((crc >> 1) ^ 32'hedb8_8320) : (crc >> 1);
            crc32_byte = crc;
        end
    endfunction

    function automatic [31:0] crc32_word;
        input [31:0] crc_in;
        input [31:0] word_value;
        reg [31:0] crc;
        begin
            crc = crc32_byte(crc_in, word_value[7:0]);
            crc = crc32_byte(crc, word_value[15:8]);
            crc = crc32_byte(crc, word_value[23:16]);
            crc32_word = crc32_byte(crc, word_value[31:24]);
        end
    endfunction

    task advance_reload_address;
        begin
            reload_weight_index <= reload_weight_index + 1'b1;
            if (reload_weight_index >= 14'd8192) begin
                case (reload_admet_layer)
                    2'd0: begin
                        if (reload_admet_addr == 8'd199) begin
                            reload_admet_layer <= 2'd1;
                            reload_admet_addr <= 8'd0;
                        end else begin
                            reload_admet_addr <= reload_admet_addr + 1'b1;
                        end
                    end
                    2'd1: begin
                        if (reload_admet_addr == 8'd9) begin
                            reload_admet_layer <= 2'd2;
                            reload_admet_addr <= 8'd0;
                        end else begin
                            reload_admet_addr <= reload_admet_addr + 1'b1;
                        end
                    end
                    2'd2: begin
                        if (reload_admet_addr == 8'd9) begin
                            reload_admet_layer <= 2'd3;
                            reload_admet_addr <= 8'd0;
                        end else begin
                            reload_admet_addr <= reload_admet_addr + 1'b1;
                        end
                    end
                    default: begin
                        reload_admet_model <= reload_admet_model + 1'b1;
                        reload_admet_layer <= 2'd0;
                        reload_admet_addr <= 8'd0;
                    end
                endcase
            end
        end
    endtask

    task emit_reload_weight;
        input [15:0] value;
        begin
            if (reload_weight_index < 14'd8192) begin
                gnn_weight_we <= 1'b1;
                gnn_weight_addr <= reload_weight_index[12:0];
                gnn_weight_wdata <= value;
            end else begin
                admet_cfg_we <= 1'b1;
                admet_cfg_model <= reload_admet_model;
                admet_cfg_layer <= reload_admet_layer;
                admet_cfg_addr <= {8'd0, reload_admet_addr};
                admet_cfg_wdata <= value;
            end
            advance_reload_address();
        end
    endtask

    assign task_ready = state == ST_IDLE;
    assign payload_ready = state == ST_LOAD;
    assign done_valid = state == ST_DONE;
    assign done_status = reload_good ? 24'd0 : `MOL_DMA_STATUS_INTERNAL_ERROR;
    assign done_result_words = 32'd1;
    assign done_detail = observed_crc;
    assign result_valid = state == ST_RESULT;
    assign result_data = reload_epoch;
    assign weight_run_bank = active_bank;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            expected_crc_reg <= 0;
            crc_state <= 32'hffff_ffff;
            observed_crc <= 0;
            reload_word <= 0;
            reload_word_last <= 1'b0;
            reload_weight_index <= 0;
            reload_admet_model <= 0;
            reload_admet_layer <= 0;
            reload_admet_addr <= 0;
            active_bank <= 1'b0;
            weight_cfg_bank <= 1'b1;
            reload_epoch <= 0;
            reload_good <= 1'b0;
            gnn_weight_we <= 1'b0;
            gnn_weight_addr <= 0;
            gnn_weight_wdata <= 0;
            admet_cfg_we <= 1'b0;
            admet_cfg_model <= 0;
            admet_cfg_layer <= 0;
            admet_cfg_addr <= 0;
            admet_cfg_wdata <= 0;
        end else begin
            gnn_weight_we <= 1'b0;
            admet_cfg_we <= 1'b0;
            if (abort) begin
                state <= ST_IDLE;
                crc_state <= 32'hffff_ffff;
                reload_good <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: if (task_valid) begin
                        expected_crc_reg <= expected_crc;
                        crc_state <= 32'hffff_ffff;
                        reload_weight_index <= 0;
                        reload_admet_model <= 0;
                        reload_admet_layer <= 0;
                        reload_admet_addr <= 0;
                        weight_cfg_bank <= ~active_bank;
                        reload_good <= 1'b0;
                        state <= ST_LOAD;
                    end
                    ST_LOAD: if (payload_valid) begin
                        reload_word <= payload_data;
                        reload_word_last <= payload_last;
                        crc_state <= crc32_word(crc_state, payload_data);
                        if (payload_last)
                            observed_crc <=
                                crc32_word(crc_state, payload_data) ^ 32'hffff_ffff;
                        state <= ST_WRITE_LOW;
                    end
                    ST_WRITE_LOW: begin
                        emit_reload_weight(reload_word[15:0]);
                        state <= ST_WRITE_HIGH;
                    end
                    ST_WRITE_HIGH: begin
                        emit_reload_weight(reload_word[31:16]);
                        if (reload_word_last) begin
                            reload_good <= observed_crc == expected_crc_reg;
                            if (observed_crc == expected_crc_reg) begin
                                active_bank <= weight_cfg_bank;
                                reload_epoch <= reload_epoch + 1'b1;
                            end
                            state <= ST_DONE;
                        end else begin
                            state <= ST_LOAD;
                        end
                    end
                    ST_DONE: if (done_ready)
                        state <= ST_RESULT;
                    ST_RESULT: if (result_ready)
                        state <= ST_IDLE;
                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule

// Routes the single payload stream into three independent lane controllers.
// The fourth controller is active only for Pipeline, which
// reserve all three numerical cores until their result stream has drained.
module dma_accelerator_backend #(
    parameter integer MAX_NODES = 50,
    parameter integer FEATURE_DIM = 64,
    parameter integer HIDDEN_DIM = 128,
    parameter integer DATA_WIDTH = 16
) (
    input  wire clk,
    input  wire rst_n,
    input  wire task_valid,
    output wire task_ready,
    input  wire [7:0] task_id,
    input  wire [31:0] task_flags,
    input  wire [31:0] task_item_count,
    input  wire [31:0] task_user_tag,
    input  wire [5:0] task_sequence,
    input  wire payload_valid,
    output wire payload_ready,
    input  wire [31:0] payload_data,
    input  wire payload_last,
    output wire done_valid,
    input  wire done_ready,
    output wire [23:0] done_status,
    output wire [31:0] done_result_words,
    output wire [31:0] done_detail,
    output wire [5:0] done_sequence,
    output wire result_valid,
    input  wire result_ready,
    output wire [31:0] result_data,
    input  wire abort,
    output wire [2:0] engine_busy,
    output wire [2:0] engine_start,
    output wire [2:0] engine_done,

    output wire tanimoto_start,
    output wire fingerprint_we,
    output wire fingerprint_db_select,
    output wire [4:0] fingerprint_addr,
    output wire [31:0] fingerprint_wdata,
    output wire tanimoto_input_write_bank,
    output wire tanimoto_input_run_bank,
    input  wire tanimoto_busy,
    input  wire tanimoto_valid,
    input  wire [31:0] tanimoto_similarity,

    output wire gnn_start,
    output wire gnn_input_write_bank,
    output wire gnn_input_run_bank,
    output wire gnn_feature_we,
    output wire [(((MAX_NODES*FEATURE_DIM+1)/2 <= 1) ? 1 :
                  $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0]
                gnn_feature_addr,
    output wire [31:0] gnn_feature_wdata,
    output wire [3:0] gnn_feature_wstrb,
    output wire gnn_adjacency_we,
    output wire [(((MAX_NODES*MAX_NODES+31)/32 <= 1) ? 1 :
                  $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0]
                gnn_adjacency_addr,
    output wire [31:0] gnn_adjacency_wdata,
    output wire [3:0] gnn_adjacency_wstrb,
    output wire gnn_output_re,
    output wire [(((MAX_NODES*HIDDEN_DIM+1)/2 <= 1) ? 1 :
                  $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0]
                gnn_output_addr,
    input  wire [31:0] gnn_output_rdata,
    input  wire gnn_busy,
    input  wire gnn_valid,
    output wire gnn_weight_we,
    output wire [(((FEATURE_DIM*HIDDEN_DIM) <= 1) ? 1 :
                  $clog2(FEATURE_DIM*HIDDEN_DIM))-1:0] gnn_weight_addr,
    output wire [15:0] gnn_weight_wdata,

    output wire admet_start,
    output wire admet_input_write_bank,
    output wire admet_input_run_bank,
    output wire descriptor_we,
    output wire [4:0] descriptor_addr,
    output wire [DATA_WIDTH-1:0] descriptor_wdata,
    input  wire admet_busy,
    input  wire admet_valid,
    input  wire [4*DATA_WIDTH-1:0] admet_predictions,
    output wire admet_cfg_we,
    output wire [1:0] admet_cfg_model,
    output wire [1:0] admet_cfg_layer,
    output wire [15:0] admet_cfg_addr,
    output wire [15:0] admet_cfg_wdata,
    output wire weight_cfg_bank,
    output wire weight_run_bank
);
    localparam [2:0] ROUTE_NONE = 3'd0;
    localparam [2:0] ROUTE_TANI = 3'd1;
    localparam [2:0] ROUTE_GNN  = 3'd2;
    localparam [2:0] ROUTE_ADMET = 3'd3;
    localparam [2:0] ROUTE_EXCLUSIVE = 3'd4;
    localparam [2:0] ROUTE_RELOAD = 3'd5;

    reg [2:0] ingress_route;
    reg [2:0] completion_owner;
    reg [2:0] completion_next;
    reg completion_results;
    reg [31:0] completion_words_left;
    reg exclusive_active;
    reg [5:0] tani_sequence;
    reg [5:0] gnn_sequence;
    reg [5:0] admet_sequence;
    reg [5:0] exclusive_sequence;
    reg [5:0] reload_sequence;

    wire tani_task_ready, tani_payload_ready, tani_done_valid;
    wire [23:0] tani_done_status;
    wire [31:0] tani_done_words, tani_done_detail;
    wire tani_result_valid;
    wire [31:0] tani_result_data;
    wire [2:0] tani_controller_busy;
    wire tani_start_i, tani_fingerprint_we;
    wire tani_fingerprint_db_select;
    wire [4:0] tani_fingerprint_addr;
    wire [31:0] tani_fingerprint_wdata;
    wire tani_input_write_bank, tani_input_run_bank;

    wire gnn_task_ready_i, gnn_payload_ready_i, gnn_done_valid_i;
    wire [23:0] gnn_done_status_i;
    wire [31:0] gnn_done_words_i, gnn_done_detail_i;
    wire gnn_result_valid_i;
    wire [31:0] gnn_result_data_i;
    wire [2:0] gnn_controller_busy;
    wire gnn_start_i, gnn_feature_we_i, gnn_adjacency_we_i;
    wire [(((MAX_NODES*FEATURE_DIM+1)/2 <= 1) ? 1 :
           $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0] gnn_feature_addr_i;
    wire [31:0] gnn_feature_wdata_i;
    wire [3:0] gnn_feature_wstrb_i;
    wire gnn_input_write_bank_i, gnn_input_run_bank_i;
    wire [(((MAX_NODES*MAX_NODES+31)/32 <= 1) ? 1 :
           $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0] gnn_adjacency_addr_i;
    wire [31:0] gnn_adjacency_wdata_i;
    wire [3:0] gnn_adjacency_wstrb_i;
    wire gnn_output_re_i;
    wire [(((MAX_NODES*HIDDEN_DIM+1)/2 <= 1) ? 1 :
           $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0] gnn_output_addr_i;

    wire admet_task_ready_i, admet_payload_ready_i, admet_done_valid_i;
    wire [23:0] admet_done_status_i;
    wire [31:0] admet_done_words_i, admet_done_detail_i;
    wire admet_result_valid_i;
    wire [31:0] admet_result_data_i;
    wire [2:0] admet_controller_busy;
    wire admet_start_i, admet_descriptor_we_i;
    wire [4:0] admet_descriptor_addr_i;
    wire [DATA_WIDTH-1:0] admet_descriptor_wdata_i;
    wire admet_input_write_bank_i, admet_input_run_bank_i;

    wire exclusive_task_ready_i, exclusive_payload_ready_i;
    wire exclusive_done_valid_i;
    wire [23:0] exclusive_done_status_i;
    wire [31:0] exclusive_done_words_i, exclusive_done_detail_i;
    wire exclusive_result_valid_i;
    wire [31:0] exclusive_result_data_i;
    wire [2:0] exclusive_controller_busy;
    wire exclusive_tani_start, exclusive_fingerprint_we;
    wire exclusive_fingerprint_db_select;
    wire [4:0] exclusive_fingerprint_addr;
    wire [31:0] exclusive_fingerprint_wdata;
    wire exclusive_tani_input_write_bank, exclusive_tani_input_run_bank;
    wire exclusive_gnn_start, exclusive_gnn_feature_we;
    wire [(((MAX_NODES*FEATURE_DIM+1)/2 <= 1) ? 1 :
           $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0]
         exclusive_gnn_feature_addr;
    wire [31:0] exclusive_gnn_feature_wdata;
    wire [3:0] exclusive_gnn_feature_wstrb;
    wire exclusive_gnn_input_write_bank, exclusive_gnn_input_run_bank;
    wire exclusive_gnn_adjacency_we;
    wire [(((MAX_NODES*MAX_NODES+31)/32 <= 1) ? 1 :
           $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0]
         exclusive_gnn_adjacency_addr;
    wire [31:0] exclusive_gnn_adjacency_wdata;
    wire [3:0] exclusive_gnn_adjacency_wstrb;
    wire exclusive_gnn_output_re;
    wire [(((MAX_NODES*HIDDEN_DIM+1)/2 <= 1) ? 1 :
           $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0]
         exclusive_gnn_output_addr;
    wire exclusive_admet_start, exclusive_descriptor_we;
    wire [4:0] exclusive_descriptor_addr;
    wire [DATA_WIDTH-1:0] exclusive_descriptor_wdata;
    wire exclusive_admet_input_write_bank, exclusive_admet_input_run_bank;

    wire reload_task_ready_i, reload_payload_ready_i;
    wire reload_done_valid_i;
    wire [23:0] reload_done_status_i;
    wire [31:0] reload_done_words_i, reload_done_detail_i;
    wire reload_result_valid_i;
    wire [31:0] reload_result_data_i;
    wire reload_gnn_weight_we;
    wire [(((FEATURE_DIM*HIDDEN_DIM) <= 1) ? 1 :
           $clog2(FEATURE_DIM*HIDDEN_DIM))-1:0] reload_gnn_weight_addr;
    wire [15:0] reload_gnn_weight_wdata;
    wire reload_admet_cfg_we;
    wire [1:0] reload_admet_cfg_model, reload_admet_cfg_layer;
    wire [15:0] reload_admet_cfg_addr, reload_admet_cfg_wdata;

    wire all_lanes_idle = !tani_controller_busy[0] &&
                          !gnn_controller_busy[0] &&
                          !admet_controller_busy[0] &&
                          !tanimoto_busy && !gnn_busy && !admet_busy;
    wire exclusive_request = task_id == `MOL_DMA_TASK_PIPELINE;
    wire reload_request = task_id == `MOL_DMA_TASK_WEIGHT_RELOAD;
    wire selected_lane_ready =
        (task_id == `MOL_DMA_TASK_TANIMOTO) ? tani_task_ready :
        (task_id == `MOL_DMA_TASK_GNN) ? gnn_task_ready_i :
        (task_id == `MOL_DMA_TASK_ADMET) ? admet_task_ready_i :
        exclusive_request ? (all_lanes_idle && exclusive_task_ready_i) :
        reload_request ? reload_task_ready_i : 1'b0;

    assign task_ready = ingress_route == ROUTE_NONE && selected_lane_ready &&
                        (reload_request || !exclusive_active);
    assign payload_ready =
        (ingress_route == ROUTE_TANI) ? tani_payload_ready :
        (ingress_route == ROUTE_GNN) ? gnn_payload_ready_i :
        (ingress_route == ROUTE_ADMET) ? admet_payload_ready_i :
        (ingress_route == ROUTE_EXCLUSIVE) ? exclusive_payload_ready_i :
        (ingress_route == ROUTE_RELOAD) ? reload_payload_ready_i : 1'b0;

    wire owner_done_valid =
        (completion_owner == ROUTE_TANI) ? tani_done_valid :
        (completion_owner == ROUTE_GNN) ? gnn_done_valid_i :
        (completion_owner == ROUTE_ADMET) ? admet_done_valid_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_done_valid_i :
        (completion_owner == ROUTE_RELOAD) ? reload_done_valid_i : 1'b0;
    assign done_valid = !completion_results && owner_done_valid;
    assign done_status =
        (completion_owner == ROUTE_TANI) ? tani_done_status :
        (completion_owner == ROUTE_GNN) ? gnn_done_status_i :
        (completion_owner == ROUTE_ADMET) ? admet_done_status_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_done_status_i :
        reload_done_status_i;
    assign done_result_words =
        (completion_owner == ROUTE_TANI) ? tani_done_words :
        (completion_owner == ROUTE_GNN) ? gnn_done_words_i :
        (completion_owner == ROUTE_ADMET) ? admet_done_words_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_done_words_i :
        reload_done_words_i;
    assign done_detail =
        (completion_owner == ROUTE_TANI) ? tani_done_detail :
        (completion_owner == ROUTE_GNN) ? gnn_done_detail_i :
        (completion_owner == ROUTE_ADMET) ? admet_done_detail_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_done_detail_i :
        reload_done_detail_i;
    assign done_sequence =
        (completion_owner == ROUTE_TANI) ? tani_sequence :
        (completion_owner == ROUTE_GNN) ? gnn_sequence :
        (completion_owner == ROUTE_ADMET) ? admet_sequence :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_sequence :
        reload_sequence;

    wire owner_result_valid =
        (completion_owner == ROUTE_TANI) ? tani_result_valid :
        (completion_owner == ROUTE_GNN) ? gnn_result_valid_i :
        (completion_owner == ROUTE_ADMET) ? admet_result_valid_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_result_valid_i :
        (completion_owner == ROUTE_RELOAD) ? reload_result_valid_i : 1'b0;
    assign result_valid = completion_results && owner_result_valid;
    assign result_data =
        (completion_owner == ROUTE_TANI) ? tani_result_data :
        (completion_owner == ROUTE_GNN) ? gnn_result_data_i :
        (completion_owner == ROUTE_ADMET) ? admet_result_data_i :
        (completion_owner == ROUTE_EXCLUSIVE) ? exclusive_result_data_i :
        reload_result_data_i;

    wire tani_done_ready = completion_owner == ROUTE_TANI &&
                           !completion_results && done_ready;
    wire gnn_done_ready_i = completion_owner == ROUTE_GNN &&
                            !completion_results && done_ready;
    wire admet_done_ready_i = completion_owner == ROUTE_ADMET &&
                              !completion_results && done_ready;
    wire exclusive_done_ready_i = completion_owner == ROUTE_EXCLUSIVE &&
                                   !completion_results && done_ready;
    wire reload_done_ready_i = completion_owner == ROUTE_RELOAD &&
                               !completion_results && done_ready;
    wire tani_result_ready = completion_owner == ROUTE_TANI &&
                             completion_results && result_ready;
    wire gnn_result_ready_i = completion_owner == ROUTE_GNN &&
                              completion_results && result_ready;
    wire admet_result_ready_i = completion_owner == ROUTE_ADMET &&
                                completion_results && result_ready;
    wire exclusive_result_ready_i = completion_owner == ROUTE_EXCLUSIVE &&
                                     completion_results && result_ready;
    wire reload_result_ready_i = completion_owner == ROUTE_RELOAD &&
                                 completion_results && result_ready;

    assign engine_busy = exclusive_active ? 3'b111 :
        {admet_controller_busy[0], gnn_controller_busy[0],
         tani_controller_busy[0]};
    assign tanimoto_start = exclusive_active ? exclusive_tani_start : tani_start_i;
    assign gnn_start = exclusive_active ? exclusive_gnn_start : gnn_start_i;
    assign admet_start = exclusive_active ? exclusive_admet_start : admet_start_i;
    assign engine_start = {admet_start, gnn_start, tanimoto_start};
    assign engine_done = {engine_busy[2] && admet_valid,
                          engine_busy[1] && gnn_valid,
                          engine_busy[0] && tanimoto_valid};

    assign fingerprint_we = exclusive_active ? exclusive_fingerprint_we :
                            tani_fingerprint_we;
    assign fingerprint_db_select = exclusive_active ?
        exclusive_fingerprint_db_select : tani_fingerprint_db_select;
    assign fingerprint_addr = exclusive_active ? exclusive_fingerprint_addr :
                              tani_fingerprint_addr;
    assign fingerprint_wdata = exclusive_active ? exclusive_fingerprint_wdata :
                               tani_fingerprint_wdata;
    assign tanimoto_input_write_bank = exclusive_active ?
        exclusive_tani_input_write_bank : tani_input_write_bank;
    assign tanimoto_input_run_bank = exclusive_active ?
        exclusive_tani_input_run_bank : tani_input_run_bank;
    assign gnn_feature_we = exclusive_active ? exclusive_gnn_feature_we :
                            gnn_feature_we_i;
    assign gnn_feature_addr = exclusive_active ? exclusive_gnn_feature_addr :
                              gnn_feature_addr_i;
    assign gnn_feature_wdata = exclusive_active ? exclusive_gnn_feature_wdata :
                               gnn_feature_wdata_i;
    assign gnn_feature_wstrb = exclusive_active ? exclusive_gnn_feature_wstrb :
                               gnn_feature_wstrb_i;
    assign gnn_input_write_bank = exclusive_active ?
        exclusive_gnn_input_write_bank : gnn_input_write_bank_i;
    assign gnn_input_run_bank = exclusive_active ?
        exclusive_gnn_input_run_bank : gnn_input_run_bank_i;
    assign gnn_adjacency_we = exclusive_active ? exclusive_gnn_adjacency_we :
                              gnn_adjacency_we_i;
    assign gnn_adjacency_addr = exclusive_active ? exclusive_gnn_adjacency_addr :
                                gnn_adjacency_addr_i;
    assign gnn_adjacency_wdata = exclusive_active ? exclusive_gnn_adjacency_wdata :
                                 gnn_adjacency_wdata_i;
    assign gnn_adjacency_wstrb = exclusive_active ? exclusive_gnn_adjacency_wstrb :
                                 gnn_adjacency_wstrb_i;
    assign gnn_output_re = exclusive_active ? exclusive_gnn_output_re :
                           gnn_output_re_i;
    assign gnn_output_addr = exclusive_active ? exclusive_gnn_output_addr :
                             gnn_output_addr_i;
    assign gnn_weight_we = reload_gnn_weight_we;
    assign gnn_weight_addr = reload_gnn_weight_addr;
    assign gnn_weight_wdata = reload_gnn_weight_wdata;
    assign descriptor_we = exclusive_active ? exclusive_descriptor_we :
                           admet_descriptor_we_i;
    assign descriptor_addr = exclusive_active ? exclusive_descriptor_addr :
                             admet_descriptor_addr_i;
    assign descriptor_wdata = exclusive_active ? exclusive_descriptor_wdata :
                              admet_descriptor_wdata_i;
    assign admet_input_write_bank = exclusive_active ?
        exclusive_admet_input_write_bank : admet_input_write_bank_i;
    assign admet_input_run_bank = exclusive_active ?
        exclusive_admet_input_run_bank : admet_input_run_bank_i;
    assign admet_cfg_we = reload_admet_cfg_we;
    assign admet_cfg_model = reload_admet_cfg_model;
    assign admet_cfg_layer = reload_admet_cfg_layer;
    assign admet_cfg_addr = reload_admet_cfg_addr;
    assign admet_cfg_wdata = reload_admet_cfg_wdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ingress_route <= ROUTE_NONE;
            completion_owner <= ROUTE_NONE;
            completion_next <= ROUTE_TANI;
            completion_results <= 1'b0;
            completion_words_left <= 0;
            exclusive_active <= 1'b0;
            tani_sequence <= 0;
            gnn_sequence <= 0;
            admet_sequence <= 0;
            exclusive_sequence <= 0;
            reload_sequence <= 0;
        end else if (abort) begin
            ingress_route <= ROUTE_NONE;
            completion_owner <= ROUTE_NONE;
            completion_next <= ROUTE_TANI;
            completion_results <= 1'b0;
            completion_words_left <= 0;
            exclusive_active <= 1'b0;
        end else begin
            if (task_valid && task_ready) begin
                if (task_id == `MOL_DMA_TASK_TANIMOTO) begin
                    ingress_route <= ROUTE_TANI;
                    tani_sequence <= task_sequence;
                end else if (task_id == `MOL_DMA_TASK_GNN) begin
                    ingress_route <= ROUTE_GNN;
                    gnn_sequence <= task_sequence;
                end else if (task_id == `MOL_DMA_TASK_ADMET) begin
                    ingress_route <= ROUTE_ADMET;
                    admet_sequence <= task_sequence;
                end else if (task_id == `MOL_DMA_TASK_WEIGHT_RELOAD) begin
                    ingress_route <= ROUTE_RELOAD;
                    reload_sequence <= task_sequence;
                end else begin
                    ingress_route <= ROUTE_EXCLUSIVE;
                    exclusive_sequence <= task_sequence;
                    exclusive_active <= 1'b1;
                end
            end
            if (payload_valid && payload_ready && payload_last)
                ingress_route <= ROUTE_NONE;

            if (completion_owner == ROUTE_NONE) begin
                case (completion_next)
                    ROUTE_TANI: begin
                        if (tani_done_valid)
                            completion_owner <= ROUTE_TANI;
                        else if (gnn_done_valid_i)
                            completion_owner <= ROUTE_GNN;
                        else if (admet_done_valid_i)
                            completion_owner <= ROUTE_ADMET;
                        else if (exclusive_done_valid_i)
                            completion_owner <= ROUTE_EXCLUSIVE;
                        else if (reload_done_valid_i)
                            completion_owner <= ROUTE_RELOAD;
                    end
                    ROUTE_GNN: begin
                        if (gnn_done_valid_i)
                            completion_owner <= ROUTE_GNN;
                        else if (admet_done_valid_i)
                            completion_owner <= ROUTE_ADMET;
                        else if (exclusive_done_valid_i)
                            completion_owner <= ROUTE_EXCLUSIVE;
                        else if (reload_done_valid_i)
                            completion_owner <= ROUTE_RELOAD;
                        else if (tani_done_valid)
                            completion_owner <= ROUTE_TANI;
                    end
                    ROUTE_ADMET: begin
                        if (admet_done_valid_i)
                            completion_owner <= ROUTE_ADMET;
                        else if (exclusive_done_valid_i)
                            completion_owner <= ROUTE_EXCLUSIVE;
                        else if (reload_done_valid_i)
                            completion_owner <= ROUTE_RELOAD;
                        else if (tani_done_valid)
                            completion_owner <= ROUTE_TANI;
                        else if (gnn_done_valid_i)
                            completion_owner <= ROUTE_GNN;
                    end
                    ROUTE_EXCLUSIVE: begin
                        if (exclusive_done_valid_i)
                            completion_owner <= ROUTE_EXCLUSIVE;
                        else if (reload_done_valid_i)
                            completion_owner <= ROUTE_RELOAD;
                        else if (tani_done_valid)
                            completion_owner <= ROUTE_TANI;
                        else if (gnn_done_valid_i)
                            completion_owner <= ROUTE_GNN;
                        else if (admet_done_valid_i)
                            completion_owner <= ROUTE_ADMET;
                    end
                    default: begin
                        if (reload_done_valid_i)
                            completion_owner <= ROUTE_RELOAD;
                        else if (tani_done_valid)
                            completion_owner <= ROUTE_TANI;
                        else if (gnn_done_valid_i)
                            completion_owner <= ROUTE_GNN;
                        else if (admet_done_valid_i)
                            completion_owner <= ROUTE_ADMET;
                        else if (exclusive_done_valid_i)
                            completion_owner <= ROUTE_EXCLUSIVE;
                    end
                endcase
            end else if (!completion_results && done_valid && done_ready) begin
                case (completion_owner)
                    ROUTE_TANI: completion_next <= ROUTE_GNN;
                    ROUTE_GNN: completion_next <= ROUTE_ADMET;
                    ROUTE_ADMET: completion_next <= ROUTE_EXCLUSIVE;
                    ROUTE_EXCLUSIVE: completion_next <= ROUTE_RELOAD;
                    default: completion_next <= ROUTE_TANI;
                endcase
                if (done_result_words == 0) begin
                    if (completion_owner == ROUTE_EXCLUSIVE)
                        exclusive_active <= 1'b0;
                    completion_owner <= ROUTE_NONE;
                    completion_words_left <= 0;
                end else begin
                    completion_results <= 1'b1;
                    completion_words_left <= done_result_words;
                end
            end else if (completion_results && result_valid && result_ready) begin
                if (completion_words_left == 1) begin
                    if (completion_owner == ROUTE_EXCLUSIVE)
                        exclusive_active <= 1'b0;
                    completion_owner <= ROUTE_NONE;
                    completion_results <= 1'b0;
                    completion_words_left <= 0;
                end else begin
                    completion_words_left <= completion_words_left - 1'b1;
                end
            end
        end
    end

    dma_accelerator_lane_controller #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) tani_lane (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid && task_ready && task_id == `MOL_DMA_TASK_TANIMOTO),
        .task_ready(tani_task_ready), .task_id(task_id),
        .task_flags(task_flags), .task_item_count(task_item_count),
        .task_sequence(6'd0),
        .payload_valid(payload_valid && ingress_route == ROUTE_TANI),
        .payload_ready(tani_payload_ready), .payload_data(payload_data),
        .payload_last(payload_last), .done_valid(tani_done_valid),
        .done_ready(tani_done_ready), .done_status(tani_done_status),
        .done_result_words(tani_done_words), .done_detail(tani_done_detail),
        .done_sequence(), .result_valid(tani_result_valid),
        .result_ready(tani_result_ready), .result_data(tani_result_data),
        .abort(abort), .engine_busy(tani_controller_busy),
        .engine_start(), .engine_done(),
        .tanimoto_start(tani_start_i), .fingerprint_we(tani_fingerprint_we),
        .fingerprint_db_select(tani_fingerprint_db_select),
        .fingerprint_addr(tani_fingerprint_addr),
        .fingerprint_wdata(tani_fingerprint_wdata),
        .tanimoto_input_write_bank(tani_input_write_bank),
        .tanimoto_input_run_bank(tani_input_run_bank),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(tanimoto_similarity),
        .gnn_start(), .gnn_input_write_bank(), .gnn_input_run_bank(),
        .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(), .gnn_adjacency_we(),
        .gnn_adjacency_addr(), .gnn_adjacency_wdata(),
        .gnn_adjacency_wstrb(), .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'd0), .gnn_busy(1'b0), .gnn_valid(1'b0),
        .admet_start(), .admet_input_write_bank(), .admet_input_run_bank(),
        .descriptor_we(), .descriptor_addr(),
        .descriptor_wdata(), .admet_busy(1'b0), .admet_valid(1'b0),
        .admet_predictions({4*DATA_WIDTH{1'b0}})
    );

    dma_accelerator_lane_controller #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) gnn_lane (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid && task_ready && task_id == `MOL_DMA_TASK_GNN),
        .task_ready(gnn_task_ready_i), .task_id(task_id),
        .task_flags(task_flags), .task_item_count(task_item_count),
        .task_sequence(6'd0),
        .payload_valid(payload_valid && ingress_route == ROUTE_GNN),
        .payload_ready(gnn_payload_ready_i), .payload_data(payload_data),
        .payload_last(payload_last), .done_valid(gnn_done_valid_i),
        .done_ready(gnn_done_ready_i), .done_status(gnn_done_status_i),
        .done_result_words(gnn_done_words_i), .done_detail(gnn_done_detail_i),
        .done_sequence(), .result_valid(gnn_result_valid_i),
        .result_ready(gnn_result_ready_i), .result_data(gnn_result_data_i),
        .abort(abort), .engine_busy(gnn_controller_busy),
        .engine_start(), .engine_done(),
        .tanimoto_start(), .fingerprint_we(), .fingerprint_db_select(),
        .fingerprint_addr(), .fingerprint_wdata(), .tanimoto_busy(1'b0),
        .tanimoto_input_write_bank(), .tanimoto_input_run_bank(),
        .tanimoto_valid(1'b0), .tanimoto_similarity(32'd0),
        .gnn_start(gnn_start_i),
        .gnn_input_write_bank(gnn_input_write_bank_i),
        .gnn_input_run_bank(gnn_input_run_bank_i),
        .gnn_feature_we(gnn_feature_we_i),
        .gnn_feature_addr(gnn_feature_addr_i),
        .gnn_feature_wdata(gnn_feature_wdata_i),
        .gnn_feature_wstrb(gnn_feature_wstrb_i),
        .gnn_adjacency_we(gnn_adjacency_we_i),
        .gnn_adjacency_addr(gnn_adjacency_addr_i),
        .gnn_adjacency_wdata(gnn_adjacency_wdata_i),
        .gnn_adjacency_wstrb(gnn_adjacency_wstrb_i),
        .gnn_output_re(gnn_output_re_i), .gnn_output_addr(gnn_output_addr_i),
        .gnn_output_rdata(gnn_output_rdata), .gnn_busy(gnn_busy),
        .gnn_valid(gnn_valid), .admet_start(), .admet_input_write_bank(),
        .admet_input_run_bank(), .descriptor_we(),
        .descriptor_addr(), .descriptor_wdata(), .admet_busy(1'b0),
        .admet_valid(1'b0), .admet_predictions({4*DATA_WIDTH{1'b0}})
    );

    dma_accelerator_lane_controller #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) admet_lane (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid && task_ready && task_id == `MOL_DMA_TASK_ADMET),
        .task_ready(admet_task_ready_i), .task_id(task_id),
        .task_flags(task_flags), .task_item_count(task_item_count),
        .task_sequence(6'd0),
        .payload_valid(payload_valid && ingress_route == ROUTE_ADMET),
        .payload_ready(admet_payload_ready_i), .payload_data(payload_data),
        .payload_last(payload_last), .done_valid(admet_done_valid_i),
        .done_ready(admet_done_ready_i), .done_status(admet_done_status_i),
        .done_result_words(admet_done_words_i),
        .done_detail(admet_done_detail_i), .done_sequence(),
        .result_valid(admet_result_valid_i),
        .result_ready(admet_result_ready_i), .result_data(admet_result_data_i),
        .abort(abort), .engine_busy(admet_controller_busy),
        .engine_start(), .engine_done(), .tanimoto_start(),
        .fingerprint_we(), .fingerprint_db_select(), .fingerprint_addr(),
        .fingerprint_wdata(), .tanimoto_busy(1'b0), .tanimoto_valid(1'b0),
        .tanimoto_input_write_bank(), .tanimoto_input_run_bank(),
        .tanimoto_similarity(32'd0), .gnn_start(), .gnn_input_write_bank(),
        .gnn_input_run_bank(), .gnn_feature_we(),
        .gnn_feature_addr(), .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(), .gnn_adjacency_wdata(),
        .gnn_adjacency_wstrb(), .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'd0), .gnn_busy(1'b0), .gnn_valid(1'b0),
        .admet_start(admet_start_i),
        .admet_input_write_bank(admet_input_write_bank_i),
        .admet_input_run_bank(admet_input_run_bank_i),
        .descriptor_we(admet_descriptor_we_i),
        .descriptor_addr(admet_descriptor_addr_i),
        .descriptor_wdata(admet_descriptor_wdata_i),
        .admet_busy(admet_busy), .admet_valid(admet_valid),
        .admet_predictions(admet_predictions)
    );

    dma_accelerator_lane_controller #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) exclusive_lane (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid && task_ready && exclusive_request),
        .task_ready(exclusive_task_ready_i), .task_id(task_id),
        .task_flags(task_flags), .task_item_count(task_item_count),
        .task_sequence(6'd0),
        .payload_valid(payload_valid && ingress_route == ROUTE_EXCLUSIVE),
        .payload_ready(exclusive_payload_ready_i), .payload_data(payload_data),
        .payload_last(payload_last), .done_valid(exclusive_done_valid_i),
        .done_ready(exclusive_done_ready_i),
        .done_status(exclusive_done_status_i),
        .done_result_words(exclusive_done_words_i),
        .done_detail(exclusive_done_detail_i), .done_sequence(),
        .result_valid(exclusive_result_valid_i),
        .result_ready(exclusive_result_ready_i),
        .result_data(exclusive_result_data_i), .abort(abort),
        .engine_busy(exclusive_controller_busy), .engine_start(), .engine_done(),
        .tanimoto_start(exclusive_tani_start),
        .fingerprint_we(exclusive_fingerprint_we),
        .fingerprint_db_select(exclusive_fingerprint_db_select),
        .fingerprint_addr(exclusive_fingerprint_addr),
        .fingerprint_wdata(exclusive_fingerprint_wdata),
        .tanimoto_input_write_bank(exclusive_tani_input_write_bank),
        .tanimoto_input_run_bank(exclusive_tani_input_run_bank),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(tanimoto_similarity),
        .gnn_start(exclusive_gnn_start),
        .gnn_input_write_bank(exclusive_gnn_input_write_bank),
        .gnn_input_run_bank(exclusive_gnn_input_run_bank),
        .gnn_feature_we(exclusive_gnn_feature_we),
        .gnn_feature_addr(exclusive_gnn_feature_addr),
        .gnn_feature_wdata(exclusive_gnn_feature_wdata),
        .gnn_feature_wstrb(exclusive_gnn_feature_wstrb),
        .gnn_adjacency_we(exclusive_gnn_adjacency_we),
        .gnn_adjacency_addr(exclusive_gnn_adjacency_addr),
        .gnn_adjacency_wdata(exclusive_gnn_adjacency_wdata),
        .gnn_adjacency_wstrb(exclusive_gnn_adjacency_wstrb),
        .gnn_output_re(exclusive_gnn_output_re),
        .gnn_output_addr(exclusive_gnn_output_addr),
        .gnn_output_rdata(gnn_output_rdata), .gnn_busy(gnn_busy),
        .gnn_valid(gnn_valid),
        .admet_start(exclusive_admet_start),
        .admet_input_write_bank(exclusive_admet_input_write_bank),
        .admet_input_run_bank(exclusive_admet_input_run_bank),
        .descriptor_we(exclusive_descriptor_we),
        .descriptor_addr(exclusive_descriptor_addr),
        .descriptor_wdata(exclusive_descriptor_wdata),
        .admet_busy(admet_busy), .admet_valid(admet_valid),
        .admet_predictions(admet_predictions)
    );

    dma_weight_reload_controller #(
        .FEATURE_DIM(FEATURE_DIM), .HIDDEN_DIM(HIDDEN_DIM)
    ) reload_controller (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid && task_ready && reload_request),
        .task_ready(reload_task_ready_i), .expected_crc(task_user_tag),
        .payload_valid(payload_valid && ingress_route == ROUTE_RELOAD),
        .payload_ready(reload_payload_ready_i), .payload_data(payload_data),
        .payload_last(payload_last), .done_valid(reload_done_valid_i),
        .done_ready(reload_done_ready_i), .done_status(reload_done_status_i),
        .done_result_words(reload_done_words_i),
        .done_detail(reload_done_detail_i),
        .result_valid(reload_result_valid_i),
        .result_ready(reload_result_ready_i), .result_data(reload_result_data_i),
        .abort(abort), .gnn_weight_we(reload_gnn_weight_we),
        .gnn_weight_addr(reload_gnn_weight_addr),
        .gnn_weight_wdata(reload_gnn_weight_wdata),
        .admet_cfg_we(reload_admet_cfg_we),
        .admet_cfg_model(reload_admet_cfg_model),
        .admet_cfg_layer(reload_admet_cfg_layer),
        .admet_cfg_addr(reload_admet_cfg_addr),
        .admet_cfg_wdata(reload_admet_cfg_wdata),
        .weight_cfg_bank(weight_cfg_bank), .weight_run_bank(weight_run_bank)
    );
endmodule

// Adapts the normalized DMA queue interface to the existing accelerator cores.
// The numerical cores remain single-instanced in generator_accelerator_top.
module dma_accelerator_lane_controller #(
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
    input  wire [5:0]  task_sequence,

    input  wire        payload_valid,
    output wire        payload_ready,
    input  wire [31:0] payload_data,
    input  wire        payload_last,

    output wire        done_valid,
    input  wire        done_ready,
    output wire [23:0] done_status,
    output wire [31:0] done_result_words,
    output wire [31:0] done_detail,
    output wire [5:0]  done_sequence,

    output wire        result_valid,
    input  wire        result_ready,
    output wire [31:0] result_data,
    input  wire        abort,

    output wire [2:0] engine_busy,
    output wire [2:0] engine_start,
    output wire [2:0] engine_done,

    output wire          tanimoto_start,
    output wire          tanimoto_input_write_bank,
    output wire          tanimoto_input_run_bank,
    output reg           fingerprint_we,
    output reg           fingerprint_db_select,
    output reg  [4:0]    fingerprint_addr,
    output reg  [31:0]   fingerprint_wdata,
    input  wire          tanimoto_busy,
    input  wire          tanimoto_valid,
    input  wire [31:0]   tanimoto_similarity,

    output wire gnn_start,
    output wire gnn_input_write_bank,
    output wire gnn_input_run_bank,
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
    output wire admet_input_write_bank,
    output wire admet_input_run_bank,
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
    localparam [3:0] ST_PIPE_WAIT     = 4'd6;
    localparam [3:0] ST_DONE          = 4'd9;
    localparam [3:0] ST_RESULT        = 4'd10;
    localparam [3:0] ST_GNN_READ_WAIT = 4'd11;
    localparam [3:0] ST_START_TANI    = 4'd12;
    localparam [23:0] STATUS_INTERNAL_ERROR =
        `MOL_DMA_STATUS_INTERNAL_ERROR;

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
    reg [2:0] pipeline_done_mask;
    reg [1:0] input_bank_occupied;
    reg [1:0] input_bank_ready;
    reg input_bank_loading;
    reg input_compute_running;
    reg summary_capture_pending;
    reg [1:0] summary_capture_wait;
    reg [10:0] item_payload_index;
    reg [5:0] loaded_items;
    reg [5:0] completed_items;
    reg [5:0] run_item_index;
    reg [5:0] bank_item_index [0:1];
    reg [31:0] tanimoto_item_result [0:15];
    reg [31:0] gnn_item_result [0:31];
    reg unsupported_mode;

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
    reg input_write_bank_reg;
    reg input_write_port_bank_reg;
    reg input_run_bank_reg;

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
    wire ping_pong_mode = active_task == `MOL_DMA_TASK_PIPELINE ||
                          (active_task == `MOL_DMA_TASK_GNN && !full_gnn);
    assign payload_ready = (state == ST_LOAD &&
        (!ping_pong_mode || input_bank_loading ||
         !input_bank_occupied[input_write_bank_reg])) ||
        ((state == ST_WAIT_SHARED) && shared_mode &&
         (payload_index < shared_payload_words));
    assign done_valid = (state == ST_DONE);
    assign done_status = unsupported_mode ? STATUS_INTERNAL_ERROR : 24'd0;
    assign done_result_words = result_words_reg;
    assign done_detail = unsupported_mode ? 32'h4655_4c4c : 32'd0;
    assign done_sequence = 6'd0;
    assign result_valid = result_valid_reg;
    assign result_data = result_data_reg;

    assign tanimoto_start = tanimoto_start_reg;
    assign tanimoto_input_write_bank = input_write_port_bank_reg;
    assign tanimoto_input_run_bank = input_run_bank_reg;
    assign gnn_start = gnn_start_reg;
    assign gnn_input_write_bank = input_write_port_bank_reg;
    assign gnn_input_run_bank = input_run_bank_reg;
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
    assign admet_input_write_bank = input_write_port_bank_reg;
    assign admet_input_run_bank = input_run_bank_reg;
    assign engine_busy = {3{state != ST_IDLE}};
    assign engine_start = {admet_start_reg, gnn_start_reg,
                           tanimoto_start_reg};
    assign engine_done = {admet_valid, gnn_valid, tanimoto_valid};

    function is_gnn_result_word;
        input [7:0] id;
        input [31:0] flags;
        input [31:0] index;
        begin
            if (id == `MOL_DMA_TASK_GNN)
                is_gnn_result_word =
                    (flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0;
            else if (id == `MOL_DMA_TASK_PIPELINE &&
                     (flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0)
                is_gnn_result_word = (index >= 1 && index <= 3200);
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

    wire [31:0] intermediate_item = result_index / 6;
    wire [31:0] intermediate_slot = result_index % 6;
    wire [31:0] small_linear_index =
        (active_task == `MOL_DMA_TASK_PIPELINE && full_gnn) ?
            result_index - 32'd3201 :
        (active_task == `MOL_DMA_TASK_PIPELINE && return_intermediate) ?
            {intermediate_item[29:0], 2'b00} + intermediate_slot - 2 :
            result_index;
    wire [5:0] small_read_addr =
        (active_task == `MOL_DMA_TASK_PIPELINE && return_intermediate &&
         !full_gnn) ? intermediate_item[5:0] : small_linear_index[7:2];
    wire [1:0] small_read_bank =
        (active_task == `MOL_DMA_TASK_PIPELINE && return_intermediate &&
         !full_gnn) ? intermediate_slot[1:0] - 2'd2 :
                      small_linear_index[1:0];
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
                             (active_task == `MOL_DMA_TASK_PIPELINE &&
                              input_compute_running)) && admet_valid;
            wire bank_we = shared_we || admet_we;
            wire [5:0] bank_waddr = shared_we ? shared_result_count[6:2] :
                                     (active_task == `MOL_DMA_TASK_PIPELINE ?
                                         run_item_index :
                                         admet_item_index[5:0]);
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
            pipeline_done_mask <= 3'b000;
            input_bank_occupied <= 2'b00;
            input_bank_ready <= 2'b00;
            input_bank_loading <= 1'b0;
            input_compute_running <= 1'b0;
            summary_capture_pending <= 1'b0;
            summary_capture_wait <= 2'd0;
            item_payload_index <= 11'd0;
            loaded_items <= 6'd0;
            completed_items <= 6'd0;
            run_item_index <= 6'd0;
            bank_item_index[0] <= 6'd0;
            bank_item_index[1] <= 6'd0;
            unsupported_mode <= 1'b0;
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
            input_write_bank_reg <= 1'b0;
            input_write_port_bank_reg <= 1'b0;
            input_run_bank_reg <= 1'b0;
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
                active_task <= 0;
                active_flags <= 0;
                active_items <= 0;
                payload_index <= 0;
                admet_item_index <= 0;
                result_words_reg <= 0;
                result_index <= 0;
                result_data_reg <= 0;
                result_valid_reg <= 1'b0;
                gnn_read_wait <= 0;
                pipeline_done_mask <= 3'b000;
                input_bank_occupied <= 2'b00;
                input_bank_ready <= 2'b00;
                input_bank_loading <= 1'b0;
                input_compute_running <= 1'b0;
                summary_capture_pending <= 1'b0;
                summary_capture_wait <= 2'd0;
                item_payload_index <= 11'd0;
                loaded_items <= 6'd0;
                completed_items <= 6'd0;
                run_item_index <= 6'd0;
                bank_item_index[0] <= 6'd0;
                bank_item_index[1] <= 6'd0;
                input_write_bank_reg <= 1'b0;
                input_write_port_bank_reg <= 1'b0;
                input_run_bank_reg <= 1'b0;
                unsupported_mode <= 1'b0;
            end else begin
                if (ping_pong_mode && input_compute_running &&
                    !summary_capture_pending) begin
                    if (active_task == `MOL_DMA_TASK_PIPELINE) begin
                        pipeline_done_mask <= pipeline_done_mask |
                            {admet_valid, gnn_valid, tanimoto_valid};
                        if (tanimoto_valid)
                            tanimoto_item_result[run_item_index[3:0]] <=
                                tanimoto_similarity;
                        if ((pipeline_done_mask |
                             {admet_valid, gnn_valid, tanimoto_valid}) ==
                            3'b111) begin
                            gnn_output_addr_reg <= {OUTPUT_ADDR_W{1'b0}};
                            gnn_output_re_reg <= 1'b1;
                            summary_capture_pending <= 1'b1;
                            summary_capture_wait <= 2'd2;
                        end
                    end else if (gnn_valid) begin
                        gnn_output_addr_reg <= {OUTPUT_ADDR_W{1'b0}};
                        gnn_output_re_reg <= 1'b1;
                        summary_capture_pending <= 1'b1;
                        summary_capture_wait <= 2'd2;
                    end
                end

                if (summary_capture_pending) begin
                    if (summary_capture_wait != 0)
                        summary_capture_wait <= summary_capture_wait - 1'b1;
                    else begin
                        gnn_item_result[run_item_index] <= gnn_output_rdata;
                        summary_capture_pending <= 1'b0;
                        input_bank_occupied[input_run_bank_reg] <= 1'b0;
                        completed_items <= completed_items + 1'b1;
                        if (completed_items + 1'b1 == active_items) begin
                            input_compute_running <= 1'b0;
                            if (active_task == `MOL_DMA_TASK_PIPELINE)
                                result_words_reg <= full_gnn ? 32'd3205 :
                                    (return_intermediate ?
                                     ({25'd0, active_items} << 2) +
                                     ({25'd0, active_items} << 1) :
                                     ({25'd0, active_items} << 2));
                            else
                                result_words_reg <= {25'd0, active_items};
                            state <= ST_DONE;
                        end else begin
                            input_compute_running <= 1'b0;
                        end
                    end
                end

                if (ping_pong_mode && !input_compute_running &&
                    !summary_capture_pending && input_bank_ready != 0 &&
                    (state == ST_LOAD || state == ST_WAIT_GNN ||
                     state == ST_PIPE_WAIT)) begin
                    input_compute_running <= 1'b1;
                    pipeline_done_mask <= 3'b000;
                    if (input_bank_ready[0]) begin
                        input_run_bank_reg <= 1'b0;
                        input_write_bank_reg <= 1'b1;
                        run_item_index <= bank_item_index[0];
                        input_bank_ready[0] <= 1'b0;
                    end else begin
                        input_run_bank_reg <= 1'b1;
                        input_write_bank_reg <= 1'b0;
                        run_item_index <= bank_item_index[1];
                        input_bank_ready[1] <= 1'b0;
                    end
                    if (active_task == `MOL_DMA_TASK_PIPELINE) begin
                        tanimoto_start_reg <= 1'b1;
                        gnn_start_reg <= 1'b1;
                        admet_start_reg <= 1'b1;
                    end else begin
                        gnn_start_reg <= 1'b1;
                    end
                end

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
                            pipeline_done_mask <= 3'b000;
                            input_bank_occupied <= 2'b00;
                            input_bank_ready <= 2'b00;
                            input_bank_loading <= 1'b0;
                            input_compute_running <= 1'b0;
                            summary_capture_pending <= 1'b0;
                            summary_capture_wait <= 2'd0;
                            item_payload_index <= 11'd0;
                            loaded_items <= 6'd0;
                            completed_items <= 6'd0;
                            run_item_index <= 6'd0;
                            input_write_bank_reg <= 1'b0;
                            input_write_port_bank_reg <= 1'b0;
                            input_run_bank_reg <= 1'b0;
                            unsupported_mode <=
                                (task_id == `MOL_DMA_TASK_PIPELINE ||
                                 task_id == `MOL_DMA_TASK_GNN) &&
                                (task_flags & `MOL_DMA_FLAG_FULL_GNN_OUTPUT) != 0 &&
                                task_item_count > 1;
                            state <= ST_LOAD;
                        end
                    end

                    ST_LOAD: begin
                        if (payload_valid && payload_ready && unsupported_mode) begin
                            if (payload_last) begin
                                result_words_reg <= 32'd0;
                                state <= ST_DONE;
                            end
                        end else if (payload_valid && payload_ready) begin
                            input_write_port_bank_reg <= input_write_bank_reg;
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
                                    if (!full_gnn && !input_bank_loading) begin
                                        input_bank_loading <= 1'b1;
                                        input_bank_occupied[input_write_bank_reg] <=
                                            1'b1;
                                    end
                                    if ((!full_gnn ? item_payload_index :
                                         payload_index) < 79) begin
                                        gnn_adjacency_we_reg <= 1'b1;
                                        gnn_adjacency_addr_reg <=
                                            (!full_gnn ? item_payload_index :
                                             payload_index);
                                        gnn_adjacency_wdata_reg <= payload_data;
                                    end else begin
                                        gnn_feature_we_reg <= 1'b1;
                                        gnn_feature_addr_reg <=
                                            (!full_gnn ? item_payload_index :
                                             payload_index) - 79;
                                        gnn_feature_wdata_reg <= payload_data;
                                    end
                                    if (!full_gnn &&
                                        (item_payload_index == 1678 ||
                                         payload_last)) begin
                                        input_bank_loading <= 1'b0;
                                        bank_item_index[input_write_bank_reg] <=
                                            loaded_items;
                                        loaded_items <= loaded_items + 1'b1;
                                        item_payload_index <= 11'd0;
                                        input_write_bank_reg <=
                                            ~input_write_bank_reg;
                                        if (!input_compute_running) begin
                                            input_run_bank_reg <=
                                                input_write_bank_reg;
                                            run_item_index <= loaded_items;
                                            input_compute_running <= 1'b1;
                                            input_bank_ready[
                                                input_write_bank_reg] <= 1'b0;
                                            gnn_start_reg <= 1'b1;
                                        end else begin
                                            input_bank_ready[
                                                input_write_bank_reg] <= 1'b1;
                                        end
                                        if (payload_last)
                                            state <= ST_WAIT_GNN;
                                    end else if (!full_gnn) begin
                                        item_payload_index <=
                                            item_payload_index + 1'b1;
                                    end else if (payload_last) begin
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
                                `MOL_DMA_TASK_PIPELINE: begin
                                    if (!input_bank_loading) begin
                                        input_bank_loading <= 1'b1;
                                        input_bank_occupied[input_write_bank_reg] <=
                                            1'b1;
                                    end
                                    if (item_payload_index < 64) begin
                                        fingerprint_we <= 1'b1;
                                        fingerprint_db_select <=
                                            (item_payload_index >= 32);
                                        fingerprint_addr <= item_payload_index[4:0];
                                        fingerprint_wdata <= payload_data;
                                    end else if (item_payload_index < 143) begin
                                        gnn_adjacency_we_reg <= 1'b1;
                                        gnn_adjacency_addr_reg <=
                                            (item_payload_index-64);
                                        gnn_adjacency_wdata_reg <= payload_data;
                                    end else if (item_payload_index < 1743) begin
                                        gnn_feature_we_reg <= 1'b1;
                                        gnn_feature_addr_reg <=
                                            (item_payload_index-143);
                                        gnn_feature_wdata_reg <= payload_data;
                                    end else begin
                                        descriptor_we <= 1'b1;
                                        descriptor_addr <= item_payload_index-1743;
                                        descriptor_wdata <= payload_data[DATA_WIDTH-1:0];
                                    end
                                    if (item_payload_index == 1762) begin
                                        input_bank_loading <= 1'b0;
                                        bank_item_index[input_write_bank_reg] <=
                                            loaded_items;
                                        loaded_items <= loaded_items + 1'b1;
                                        item_payload_index <= 11'd0;
                                        input_write_bank_reg <=
                                            ~input_write_bank_reg;
                                        if (!input_compute_running) begin
                                            input_run_bank_reg <=
                                                input_write_bank_reg;
                                            run_item_index <= loaded_items;
                                            input_compute_running <= 1'b1;
                                            input_bank_ready[
                                                input_write_bank_reg] <= 1'b0;
                                            tanimoto_start_reg <= 1'b1;
                                            gnn_start_reg <= 1'b1;
                                            admet_start_reg <= 1'b1;
                                            pipeline_done_mask <= 3'b000;
                                        end else begin
                                            input_bank_ready[
                                                input_write_bank_reg] <= 1'b1;
                                        end
                                        if (payload_last)
                                            state <= ST_PIPE_WAIT;
                                    end else begin
                                        item_payload_index <=
                                            item_payload_index + 1'b1;
                                    end
                                end
                                default: state <= ST_IDLE;
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
                        if (shared_mode)
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

                    ST_WAIT_GNN: if (full_gnn && gnn_valid) begin
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

                    ST_PIPE_WAIT: begin end

                    ST_DONE: if (done_valid && done_ready) begin
                        result_index <= 0;
                        result_valid_reg <= 1'b0;
                        state <= (result_words_reg == 0) ? ST_IDLE : ST_RESULT;
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
                                else if (active_task == `MOL_DMA_TASK_GNN)
                                    result_data_reg <=
                                        gnn_item_result[result_index[4:0]];
                                else if (active_task == `MOL_DMA_TASK_PIPELINE &&
                                         full_gnn && result_index == 0)
                                    result_data_reg <= tanimoto_item_result[0];
                                else if (active_task == `MOL_DMA_TASK_PIPELINE &&
                                         return_intermediate &&
                                         intermediate_slot == 0)
                                    result_data_reg <= tanimoto_item_result[
                                        intermediate_item[3:0]];
                                else if (active_task == `MOL_DMA_TASK_PIPELINE &&
                                         return_intermediate &&
                                         intermediate_slot == 1)
                                    result_data_reg <= gnn_item_result[
                                        intermediate_item[4:0]];
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
