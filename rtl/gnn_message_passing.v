`timescale 1ns / 1ps

// One GNN message-passing layer:
//   aggregate_i = sum(node_feature_j), for every adjacency[i][j] == 1
//   output_i    = ReLU(aggregate_i * weight)
//
// Features and weights use signed Q8.8 by default.  One multiplier is reused
// for the linear transform.  The default 50x64x128 configuration completes
// in about 583k clocks (5.83 ms at 100 MHz).
//
// PACKED_IO=1 is convenient for small testbenches.  The production top sets
// PACKED_IO=0 and accesses block-RAM-oriented 32-bit load/read ports, avoiding
// more than 150k input/output flip-flops.
module gnn_message_passing #(
    parameter integer MAX_NODES   = 50,
    parameter integer FEATURE_DIM = 64,
    parameter integer HIDDEN_DIM  = 128,
    parameter integer DATA_WIDTH  = 16,
    parameter integer FRAC_BITS   = 8,
    parameter integer ACC_WIDTH   = 48,
    parameter integer PACKED_IO   = 1
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,

    input  wire [MAX_NODES*FEATURE_DIM*DATA_WIDTH-1:0] node_features_in,
    input  wire [MAX_NODES*MAX_NODES-1:0] adjacency_in,
    output wire [MAX_NODES*HIDDEN_DIM*DATA_WIDTH-1:0] node_features_out,

    // 32-bit memory load ports used when PACKED_IO=0.
    input  wire feature_we,
    input  wire [
        (((MAX_NODES*FEATURE_DIM+1)/2 <= 1)
            ? 1 : $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0
    ]
        feature_word_addr,
    input  wire [31:0] feature_wdata,
    input  wire [3:0]  feature_wstrb,
    input  wire adjacency_we,
    input  wire [
        (((MAX_NODES*MAX_NODES+31)/32 <= 1)
            ? 1 : $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0
    ]
        adjacency_word_addr,
    input  wire [31:0] adjacency_wdata,
    input  wire [3:0]  adjacency_wstrb,

    input  wire output_re,
    input  wire [
        (((MAX_NODES*HIDDEN_DIM+1)/2 <= 1)
            ? 1 : $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0
    ]
        output_word_addr,
    output reg  [31:0] output_rdata,

    input  wire weight_we,
    input  wire [$clog2(FEATURE_DIM*HIDDEN_DIM)-1:0] weight_addr,
    input  wire [DATA_WIDTH-1:0] weight_wdata,
    output wire busy,
    output wire valid
);

    localparam integer FEATURE_WORDS =
        (MAX_NODES*FEATURE_DIM+1)/2;
    localparam integer ADJACENCY_WORDS =
        (MAX_NODES*MAX_NODES+31)/32;
    localparam integer OUTPUT_WORDS =
        (MAX_NODES*HIDDEN_DIM+1)/2;
    localparam integer NODE_IDX_W =
        (MAX_NODES <= 1) ? 1 : $clog2(MAX_NODES);
    localparam integer FEAT_IDX_W =
        (FEATURE_DIM <= 1) ? 1 : $clog2(FEATURE_DIM);
    localparam integer HID_IDX_W =
        (HIDDEN_DIM <= 1) ? 1 : $clog2(HIDDEN_DIM);
    localparam integer FEATURE_ELEMENT_ADDR_W =
        (MAX_NODES*FEATURE_DIM <= 1)
            ? 1 : $clog2(MAX_NODES*FEATURE_DIM);
    localparam integer ADJACENCY_ELEMENT_ADDR_W =
        (MAX_NODES*MAX_NODES <= 1)
            ? 1 : $clog2(MAX_NODES*MAX_NODES);
    localparam integer OUTPUT_ELEMENT_ADDR_W =
        (MAX_NODES*HIDDEN_DIM <= 1)
            ? 1 : $clog2(MAX_NODES*HIDDEN_DIM);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_CLEAR_AGG = 3'd1;
    localparam [2:0] ST_AGG_RUN   = 3'd2;
    localparam [2:0] ST_MAC_INIT  = 3'd3;
    localparam [2:0] ST_MAC_RUN   = 3'd4;
    localparam [2:0] ST_DONE      = 3'd5;

    reg [2:0] state;
    reg [NODE_IDX_W-1:0] node_idx;
    reg [HID_IDX_W-1:0] hidden_idx;
    reg [NODE_IDX_W-1:0] aggregate_neighbor_issue;
    reg [FEAT_IDX_W-1:0] aggregate_feature_issue;
    reg aggregate_all_issued;
    reg aggregate_read_valid;
    reg aggregate_read_adjacency;
    reg aggregate_read_half;
    reg [FEAT_IDX_W-1:0] aggregate_read_feature;
    reg [31:0] feature_read_data;

    reg [FEAT_IDX_W-1:0] mac_feature_issue;
    reg mac_all_issued;
    reg mac_read_valid;
    reg signed [DATA_WIDTH-1:0] weight_read_data;
    reg signed [ACC_WIDTH-1:0] aggregate_read_data;

    (* ram_style = "block" *)
    reg [31:0] feature_memory [0:FEATURE_WORDS-1];
    (* ram_style = "distributed" *)
    reg [31:0] adjacency_memory [0:ADJACENCY_WORDS-1];
    (* ram_style = "block" *)
    reg [31:0] output_memory [0:OUTPUT_WORDS-1];
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] weight_memory
        [0:FEATURE_DIM*HIDDEN_DIM-1];

    reg signed [ACC_WIDTH-1:0] aggregate_feature [0:FEATURE_DIM-1];
    reg signed [ACC_WIDTH-1:0] mac_accumulator;

    function [31:0] packed_feature_word;
        input integer word_index;
        integer bit_index;
        begin
            packed_feature_word = 32'd0;
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
                if (word_index*32 + bit_index <
                    MAX_NODES*FEATURE_DIM*DATA_WIDTH)
                    packed_feature_word[bit_index] =
                        node_features_in[word_index*32 + bit_index];
        end
    endfunction

    function [31:0] packed_adjacency_word;
        input integer word_index;
        integer bit_index;
        begin
            packed_adjacency_word = 32'd0;
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
                if (word_index*32 + bit_index < MAX_NODES*MAX_NODES)
                    packed_adjacency_word[bit_index] =
                        adjacency_in[word_index*32 + bit_index];
        end
    endfunction

    integer memory_idx;
    integer byte_lane;
    generate
        if (PACKED_IO != 0) begin : gen_packed_load
            always @(posedge clk) begin
                if (start && state == ST_IDLE) begin
                    for (memory_idx = 0;
                         memory_idx < FEATURE_WORDS;
                         memory_idx = memory_idx + 1)
                        feature_memory[memory_idx] <=
                            packed_feature_word(memory_idx);
                    for (memory_idx = 0;
                         memory_idx < ADJACENCY_WORDS;
                         memory_idx = memory_idx + 1)
                        adjacency_memory[memory_idx] <=
                            packed_adjacency_word(memory_idx);
                end
            end
        end else begin : gen_external_load
            always @(posedge clk) begin
                if (feature_we && state == ST_IDLE)
                    for (byte_lane = 0;
                         byte_lane < 4;
                         byte_lane = byte_lane + 1)
                        if (feature_wstrb[byte_lane])
                            feature_memory[feature_word_addr]
                                [byte_lane*8 +: 8] <=
                                    feature_wdata[byte_lane*8 +: 8];
                if (adjacency_we && state == ST_IDLE)
                    for (byte_lane = 0;
                         byte_lane < 4;
                         byte_lane = byte_lane + 1)
                        if (adjacency_wstrb[byte_lane])
                            adjacency_memory[adjacency_word_addr]
                                [byte_lane*8 +: 8] <=
                                    adjacency_wdata[byte_lane*8 +: 8];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (output_re)
            output_rdata <= output_memory[output_word_addr];
        if (weight_we && state == ST_IDLE)
            weight_memory[weight_addr] <= weight_wdata;
    end

    wire [ADJACENCY_ELEMENT_ADDR_W-1:0]
        aggregate_adjacency_element =
            node_idx*MAX_NODES + aggregate_neighbor_issue;
    wire aggregate_issue_adjacency =
        adjacency_memory[aggregate_adjacency_element / 32]
            [aggregate_adjacency_element % 32];
    wire [FEATURE_ELEMENT_ADDR_W-1:0] aggregate_feature_element =
        aggregate_neighbor_issue*FEATURE_DIM + aggregate_feature_issue;
    wire signed [DATA_WIDTH-1:0] aggregate_feature_value =
        aggregate_read_half
            ? $signed(feature_read_data[31:16])
            : $signed(feature_read_data[15:0]);

    wire signed [ACC_WIDTH-1:0] multiply_result =
        weight_read_data * aggregate_read_data;
    wire signed [ACC_WIDTH-1:0] mac_next =
        mac_accumulator + multiply_result;
    wire [OUTPUT_ELEMENT_ADDR_W-1:0] output_element_addr =
        node_idx*HIDDEN_DIM + hidden_idx;
    wire [DATA_WIDTH-1:0] quantized_mac = relu_quantize(mac_next);

    function [DATA_WIDTH-1:0] relu_quantize;
        input signed [ACC_WIDTH-1:0] value_q16;
        reg signed [ACC_WIDTH-1:0] shifted_value;
        reg signed [ACC_WIDTH-1:0] maximum_value;
        begin
            shifted_value = value_q16 >>> FRAC_BITS;
            maximum_value = (1 << (DATA_WIDTH-1)) - 1;
            if (value_q16 <= 0)
                relu_quantize = {DATA_WIDTH{1'b0}};
            else if (shifted_value > maximum_value)
                relu_quantize = {1'b0, {(DATA_WIDTH-1){1'b1}}};
            else
                relu_quantize = shifted_value[DATA_WIDTH-1:0];
        end
    endfunction

    integer feature_clear_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            node_idx        <= {NODE_IDX_W{1'b0}};
            hidden_idx      <= {HID_IDX_W{1'b0}};
            aggregate_neighbor_issue <= {NODE_IDX_W{1'b0}};
            aggregate_feature_issue  <= {FEAT_IDX_W{1'b0}};
            aggregate_all_issued     <= 1'b0;
            aggregate_read_valid     <= 1'b0;
            aggregate_read_adjacency <= 1'b0;
            aggregate_read_half      <= 1'b0;
            aggregate_read_feature   <= {FEAT_IDX_W{1'b0}};
            feature_read_data        <= 32'd0;
            mac_feature_issue        <= {FEAT_IDX_W{1'b0}};
            mac_all_issued           <= 1'b0;
            mac_read_valid           <= 1'b0;
            weight_read_data         <= {DATA_WIDTH{1'b0}};
            aggregate_read_data      <= {ACC_WIDTH{1'b0}};
            mac_accumulator <= {ACC_WIDTH{1'b0}};
            for (feature_clear_idx = 0;
                 feature_clear_idx < FEATURE_DIM;
                 feature_clear_idx = feature_clear_idx + 1)
                aggregate_feature[feature_clear_idx] <=
                    {ACC_WIDTH{1'b0}};
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        node_idx   <= {NODE_IDX_W{1'b0}};
                        hidden_idx <= {HID_IDX_W{1'b0}};
                        state      <= ST_CLEAR_AGG;
                    end
                end

                ST_CLEAR_AGG: begin
                    for (feature_clear_idx = 0;
                         feature_clear_idx < FEATURE_DIM;
                         feature_clear_idx = feature_clear_idx + 1)
                        aggregate_feature[feature_clear_idx] <=
                            {ACC_WIDTH{1'b0}};
                    aggregate_neighbor_issue <= {NODE_IDX_W{1'b0}};
                    aggregate_feature_issue  <= {FEAT_IDX_W{1'b0}};
                    aggregate_all_issued     <= 1'b0;
                    aggregate_read_valid     <= 1'b0;
                    state                    <= ST_AGG_RUN;
                end

                ST_AGG_RUN: begin
                    if (aggregate_read_valid &&
                        aggregate_read_adjacency)
                        aggregate_feature[aggregate_read_feature] <=
                            aggregate_feature[aggregate_read_feature] +
                            aggregate_feature_value;

                    if (!aggregate_all_issued) begin
                        feature_read_data <=
                            feature_memory[aggregate_feature_element >> 1];
                        aggregate_read_half <=
                            aggregate_feature_element[0];
                        aggregate_read_feature <= aggregate_feature_issue;
                        aggregate_read_adjacency <=
                            aggregate_issue_adjacency;
                        aggregate_read_valid <= 1'b1;

                        if (aggregate_feature_issue == FEATURE_DIM-1) begin
                            aggregate_feature_issue <=
                                {FEAT_IDX_W{1'b0}};
                            if (aggregate_neighbor_issue == MAX_NODES-1)
                                aggregate_all_issued <= 1'b1;
                            else
                                aggregate_neighbor_issue <=
                                    aggregate_neighbor_issue + 1'b1;
                        end else begin
                            aggregate_feature_issue <=
                                aggregate_feature_issue + 1'b1;
                        end
                    end else if (aggregate_read_valid) begin
                        aggregate_read_valid <= 1'b0;
                    end else begin
                        hidden_idx <= {HID_IDX_W{1'b0}};
                        state      <= ST_MAC_INIT;
                    end
                end

                ST_MAC_INIT: begin
                    mac_feature_issue <= {FEAT_IDX_W{1'b0}};
                    mac_all_issued    <= 1'b0;
                    mac_read_valid    <= 1'b0;
                    mac_accumulator   <= {ACC_WIDTH{1'b0}};
                    state             <= ST_MAC_RUN;
                end

                ST_MAC_RUN: begin
                    if (!mac_all_issued) begin
                        weight_read_data <= weight_memory[
                            mac_feature_issue*HIDDEN_DIM + hidden_idx
                        ];
                        aggregate_read_data <=
                            aggregate_feature[mac_feature_issue];
                        mac_read_valid <= 1'b1;
                        if (mac_feature_issue == FEATURE_DIM-1)
                            mac_all_issued <= 1'b1;
                        else
                            mac_feature_issue <= mac_feature_issue + 1'b1;
                    end

                    if (mac_read_valid) begin
                        mac_accumulator <= mac_next;
                    end

                    if (mac_read_valid && mac_all_issued) begin
                        mac_read_valid <= 1'b0;
                        if (output_element_addr[0])
                            output_memory[output_element_addr >> 1][31:16] <=
                                quantized_mac;
                        else
                            output_memory[output_element_addr >> 1][15:0] <=
                                quantized_mac;

                        if (hidden_idx == HIDDEN_DIM-1) begin
                            if (node_idx == MAX_NODES-1) begin
                                state <= ST_DONE;
                            end else begin
                                node_idx   <= node_idx + 1'b1;
                                hidden_idx <= {HID_IDX_W{1'b0}};
                                state      <= ST_CLEAR_AGG;
                            end
                        end else begin
                            hidden_idx <= hidden_idx + 1'b1;
                            state      <= ST_MAC_INIT;
                        end
                    end
                end

                ST_DONE: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    genvar node_gen;
    genvar hidden_gen;
    generate
        if (PACKED_IO != 0) begin : gen_packed_output
            for (node_gen = 0;
                 node_gen < MAX_NODES;
                 node_gen = node_gen + 1) begin : gen_pack_node
                for (hidden_gen = 0;
                     hidden_gen < HIDDEN_DIM;
                     hidden_gen = hidden_gen + 1) begin : gen_pack_hidden
                    localparam integer ELEMENT =
                        node_gen*HIDDEN_DIM + hidden_gen;
                    assign node_features_out[
                        ELEMENT*DATA_WIDTH +: DATA_WIDTH
                    ] = ELEMENT[0]
                        ? output_memory[ELEMENT/2][31:16]
                        : output_memory[ELEMENT/2][15:0];
                end
            end
        end else begin : gen_no_packed_output
            assign node_features_out =
                {MAX_NODES*HIDDEN_DIM*DATA_WIDTH{1'b0}};
        end
    endgenerate

    assign busy  = (state != ST_IDLE);
    assign valid = (state == ST_DONE);

endmodule
