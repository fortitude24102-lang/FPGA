`timescale 1ns / 1ps

// One-read-port feature bank.  Sixteen independently addressed banks preserve
// the aggregate lanes while moving the double-buffered input store to BRAM.
module gnn_dist_bank #(
    parameter integer WIDTH = 16,
    parameter integer DEPTH = 256,
    parameter integer ADDR_WIDTH = 8
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [WIDTH-1:0]      wdata,
    input  wire [(WIDTH+7)/8-1:0] wstrb,
    input  wire                  re,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output wire [WIDTH-1:0]      rdata
);
`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .MEMORY_SIZE(WIDTH*DEPTH),
        .MEMORY_PRIMITIVE("block"),
        .CLOCKING_MODE("common_clock"),
        .WRITE_DATA_WIDTH_A(WIDTH),
        .BYTE_WRITE_WIDTH_A(8),
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .READ_DATA_WIDTH_B(WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .READ_LATENCY_B(1),
        .WRITE_MODE_B("read_first")
    ) memory (
        .clka(clk), .ena(we), .wea(wstrb), .addra(waddr), .dina(wdata),
        .clkb(clk), .enb(re), .addrb(raddr), .doutb(rdata),
        .rstb(1'b0), .regceb(1'b1), .sleep(1'b0),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0),
        .sbiterrb(), .dbiterrb()
    );
`else
    (* ram_style = "distributed" *)
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    reg [WIDTH-1:0] read_data;
    integer byte_lane;
    always @(posedge clk) begin
        if (we)
            for (byte_lane = 0; byte_lane < (WIDTH+7)/8;
                 byte_lane = byte_lane + 1)
                if (wstrb[byte_lane])
                    memory[waddr][byte_lane*8 +: 8] <=
                        wdata[byte_lane*8 +: 8];
        if (re)
            read_data <= memory[raddr];
    end
    assign rdata = read_data;
`endif
endmodule

// One-cycle synchronous weight bank.  The synthesis path uses an explicit
// block-memory primitive because the double-bank 512x16 memories otherwise
// consume more distributed RAM than XC7Z015 provides.
module gnn_weight_block_bank #(
    parameter integer WIDTH = 16,
    parameter integer DEPTH = 512,
    parameter integer ADDR_WIDTH = 9
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [WIDTH-1:0]      wdata,
    input  wire                  re,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output wire [WIDTH-1:0]      rdata
);
`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .MEMORY_SIZE(WIDTH*DEPTH),
        .MEMORY_PRIMITIVE("block"),
        .CLOCKING_MODE("common_clock"),
        .WRITE_DATA_WIDTH_A(WIDTH),
        .BYTE_WRITE_WIDTH_A(WIDTH),
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .READ_DATA_WIDTH_B(WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .READ_LATENCY_B(1),
        .WRITE_MODE_B("read_first")
    ) memory (
        .clka(clk), .ena(we), .wea(we), .addra(waddr), .dina(wdata),
        .clkb(clk), .enb(re), .addrb(raddr), .doutb(rdata),
        .rstb(1'b0), .regceb(1'b1), .sleep(1'b0),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0),
        .sbiterrb(), .dbiterrb()
    );
`else
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    reg [WIDTH-1:0] read_data;
    always @(posedge clk) begin
        if (we)
            memory[waddr] <= wdata;
        if (re)
            read_data <= memory[raddr];
    end
    assign rdata = read_data;
`endif
endmodule

// Standard synchronous block-RAM bank for packed GNN output words.
module gnn_block_bank #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 400,
    parameter integer ADDR_WIDTH = 9
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [WIDTH-1:0]      wdata,
    input  wire                  re,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output reg  [WIDTH-1:0]      rdata
);
    (* ram_style = "block" *)
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    always @(posedge clk) begin
        if (we)
            memory[waddr] <= wdata;
        if (re)
            rdata <= memory[raddr];
    end
endmodule

// One GNN message-passing layer:
//   aggregate_i = sum(node_feature_j), for adjacency[i][j] == 1
//   output_i    = ReLU(aggregate_i * weight)
//
// Defaults process 16 aggregate features per clock and perform 16x2 signed
// multiplications per MAC clock.  PACKED_IO is retained for interface
// compatibility; production and verification use the banked 32-bit ports.
module gnn_message_passing #(
    parameter integer MAX_NODES         = 50,
    parameter integer FEATURE_DIM       = 64,
    parameter integer HIDDEN_DIM        = 128,
    parameter integer DATA_WIDTH        = 16,
    parameter integer FRAC_BITS         = 8,
    parameter integer ACC_WIDTH         = 48,
    parameter integer PACKED_IO         = 0,
    parameter integer AGG_FEATURE_LANES = 16,
    parameter integer HIDDEN_LANES      = 16,
    parameter integer MAC_FEATURE_LANES = 2
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire input_write_bank,
    input  wire input_run_bank,

    input  wire [MAX_NODES*FEATURE_DIM*DATA_WIDTH-1:0] node_features_in,
    input  wire [MAX_NODES*MAX_NODES-1:0] adjacency_in,
    output wire [MAX_NODES*HIDDEN_DIM*DATA_WIDTH-1:0] node_features_out,

    input  wire feature_we,
    input  wire [
        (((MAX_NODES*FEATURE_DIM+1)/2 <= 1)
            ? 1 : $clog2((MAX_NODES*FEATURE_DIM+1)/2))-1:0
    ] feature_word_addr,
    input  wire [31:0] feature_wdata,
    input  wire [3:0]  feature_wstrb,
    input  wire adjacency_we,
    input  wire [
        (((MAX_NODES*MAX_NODES+31)/32 <= 1)
            ? 1 : $clog2((MAX_NODES*MAX_NODES+31)/32))-1:0
    ] adjacency_word_addr,
    input  wire [31:0] adjacency_wdata,
    input  wire [3:0]  adjacency_wstrb,

    input  wire output_re,
    input  wire [
        (((MAX_NODES*HIDDEN_DIM+1)/2 <= 1)
            ? 1 : $clog2((MAX_NODES*HIDDEN_DIM+1)/2))-1:0
    ] output_word_addr,
    output reg [31:0] output_rdata,

    input  wire weight_we,
    input  wire [$clog2(FEATURE_DIM*HIDDEN_DIM)-1:0] weight_addr,
    input  wire [DATA_WIDTH-1:0] weight_wdata,
    input  wire cfg_bank,
    input  wire run_bank,
    output wire busy,
    output wire valid
);

    localparam integer AGG_LANES =
        (FEATURE_DIM < AGG_FEATURE_LANES) ? FEATURE_DIM : AGG_FEATURE_LANES;
    localparam integer HID_LANES =
        (HIDDEN_DIM < HIDDEN_LANES) ? HIDDEN_DIM : HIDDEN_LANES;
    localparam integer MAC_FEAT_LANES =
        (FEATURE_DIM < MAC_FEATURE_LANES) ? FEATURE_DIM : MAC_FEATURE_LANES;
    localparam integer AGG_GROUPS =
        (FEATURE_DIM + AGG_LANES - 1) / AGG_LANES;
    localparam integer HIDDEN_GROUPS =
        (HIDDEN_DIM + HID_LANES - 1) / HID_LANES;
    localparam integer MAC_FEATURE_GROUPS =
        (FEATURE_DIM + MAC_FEAT_LANES - 1) / MAC_FEAT_LANES;
    localparam integer FEATURE_BANK_DEPTH = MAX_NODES * AGG_GROUPS;
    localparam integer WEIGHT_BANK_DEPTH =
        HIDDEN_GROUPS * MAC_FEATURE_GROUPS;
    localparam integer OUTPUT_BANKS = (HID_LANES + 1) / 2;
    localparam integer OUTPUT_BANK_DEPTH = MAX_NODES * HIDDEN_GROUPS;
    localparam integer ADJACENCY_WORDS =
        (MAX_NODES*MAX_NODES+31)/32;
    localparam integer TOTAL_MAC_BANKS = HID_LANES * MAC_FEAT_LANES;

    localparam integer NODE_IDX_W =
        (MAX_NODES <= 1) ? 1 : $clog2(MAX_NODES);
    localparam integer FEAT_IDX_W =
        (FEATURE_DIM <= 1) ? 1 : $clog2(FEATURE_DIM);
    localparam integer HID_IDX_W =
        (HIDDEN_DIM <= 1) ? 1 : $clog2(HIDDEN_DIM);
    localparam integer AGG_GROUP_W =
        (AGG_GROUPS <= 1) ? 1 : $clog2(AGG_GROUPS);
    localparam integer HIDDEN_GROUP_W =
        (HIDDEN_GROUPS <= 1) ? 1 : $clog2(HIDDEN_GROUPS);
    localparam integer MAC_FEATURE_GROUP_W =
        (MAC_FEATURE_GROUPS <= 1) ? 1 : $clog2(MAC_FEATURE_GROUPS);
    localparam integer FEATURE_BANK_ADDR_W =
        (FEATURE_BANK_DEPTH <= 1) ? 1 : $clog2(FEATURE_BANK_DEPTH);
    localparam integer FEATURE_MEMORY_DEPTH = FEATURE_BANK_DEPTH * 2;
    localparam integer FEATURE_MEMORY_ADDR_W =
        (FEATURE_MEMORY_DEPTH <= 1) ? 1 : $clog2(FEATURE_MEMORY_DEPTH);
    localparam integer WEIGHT_BANK_ADDR_W =
        (WEIGHT_BANK_DEPTH <= 1) ? 1 : $clog2(WEIGHT_BANK_DEPTH);
    localparam integer WEIGHT_MEMORY_DEPTH = WEIGHT_BANK_DEPTH * 2;
    localparam integer WEIGHT_MEMORY_ADDR_W =
        (WEIGHT_MEMORY_DEPTH <= 1) ? 1 : $clog2(WEIGHT_MEMORY_DEPTH);
    localparam integer OUTPUT_BANK_ADDR_W =
        (OUTPUT_BANK_DEPTH <= 1) ? 1 : $clog2(OUTPUT_BANK_DEPTH);
    localparam integer FEATURE_ELEMENT_ADDR_W =
        (MAX_NODES*FEATURE_DIM <= 1)
            ? 1 : $clog2(MAX_NODES*FEATURE_DIM);
    localparam integer ADJACENCY_ELEMENT_ADDR_W =
        (MAX_NODES*MAX_NODES <= 1)
            ? 1 : $clog2(MAX_NODES*MAX_NODES);
    localparam integer ADJACENCY_WORD_ADDR_W =
        (ADJACENCY_WORDS <= 1) ? 1 : $clog2(ADJACENCY_WORDS);
    localparam integer ADJACENCY_MEMORY_DEPTH = ADJACENCY_WORDS * 2;
    localparam integer ADJACENCY_MEMORY_ADDR_W =
        (ADJACENCY_MEMORY_DEPTH <= 1) ? 1 :
        $clog2(ADJACENCY_MEMORY_DEPTH);
    localparam integer OUTPUT_BANK_IDX_W =
        (OUTPUT_BANKS <= 1) ? 1 : $clog2(OUTPUT_BANKS);
    localparam integer AGG_WIDTH = DATA_WIDTH +
        ((MAX_NODES <= 1) ? 0 : $clog2(MAX_NODES));
    localparam integer PRODUCT_WIDTH = AGG_WIDTH + DATA_WIDTH;

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_CLEAR_AGG = 3'd1;
    localparam [2:0] ST_AGG_RUN   = 3'd2;
    localparam [2:0] ST_MAC_INIT  = 3'd3;
    localparam [2:0] ST_MAC_RUN   = 3'd4;
    localparam [2:0] ST_MAC_WRITE = 3'd5;
    localparam [2:0] ST_DONE      = 3'd6;

    reg [2:0] state;
    reg [NODE_IDX_W-1:0] node_idx;
    reg [HIDDEN_GROUP_W-1:0] hidden_group_idx;

    // Packed ports are intentionally not used by the production banked path.
    assign node_features_out =
        {MAX_NODES*HIDDEN_DIM*DATA_WIDTH{1'b0}};
    wire unused_packed_inputs = ^node_features_in ^ ^adjacency_in ^ PACKED_IO;

    // External feature word maps to two adjacent Q8.8 elements and therefore
    // two distinct feature banks for all supported FEATURE_DIM >= 2 cases.
    wire [FEATURE_ELEMENT_ADDR_W-1:0] feature_load_element0 =
        feature_word_addr << 1;
    wire [FEATURE_ELEMENT_ADDR_W-1:0] feature_load_element1 =
        (feature_word_addr << 1) + 1'b1;
    wire [NODE_IDX_W-1:0] feature_load_node0 =
        feature_load_element0 / FEATURE_DIM;
    wire [NODE_IDX_W-1:0] feature_load_node1 =
        feature_load_element1 / FEATURE_DIM;
    wire [FEAT_IDX_W-1:0] feature_load_index0 =
        feature_load_element0 % FEATURE_DIM;
    wire [FEAT_IDX_W-1:0] feature_load_index1 =
        feature_load_element1 % FEATURE_DIM;
    wire [FEATURE_BANK_ADDR_W-1:0] feature_write_addr0 =
        feature_load_node0*AGG_GROUPS + feature_load_index0/AGG_LANES;
    wire [FEATURE_BANK_ADDR_W-1:0] feature_write_addr1 =
        feature_load_node1*AGG_GROUPS + feature_load_index1/AGG_LANES;

    reg [NODE_IDX_W-1:0] aggregate_neighbor_issue;
    reg [AGG_GROUP_W-1:0] aggregate_group_issue;
    wire [FEATURE_BANK_ADDR_W-1:0] feature_read_logical_addr =
        aggregate_neighbor_issue*AGG_GROUPS + aggregate_group_issue;
    wire [FEATURE_MEMORY_ADDR_W-1:0] feature_read_addr =
        feature_read_logical_addr +
        (active_input_bank ? FEATURE_BANK_DEPTH : 0);
    wire [AGG_LANES*DATA_WIDTH-1:0] feature_bank_rdata_bus;
    reg aggregate_all_issued;

    genvar feature_bank;
    generate
        for (feature_bank = 0; feature_bank < AGG_LANES;
             feature_bank = feature_bank + 1) begin : gen_feature_bank
            wire select_low =
                (feature_load_index0 % AGG_LANES) == feature_bank;
            wire select_high =
                (feature_load_index1 % AGG_LANES) == feature_bank &&
                feature_load_element1 < MAX_NODES*FEATURE_DIM;
            wire bank_we = feature_we &&
                (state == ST_IDLE || input_write_bank != active_input_bank) &&
                (select_low || select_high);
            wire [FEATURE_BANK_ADDR_W-1:0] bank_logical_waddr =
                select_low ? feature_write_addr0 : feature_write_addr1;
            wire [FEATURE_MEMORY_ADDR_W-1:0] bank_waddr =
                bank_logical_waddr +
                (input_write_bank ? FEATURE_BANK_DEPTH : 0);
            wire [DATA_WIDTH-1:0] bank_wdata =
                select_low ? feature_wdata[15:0] : feature_wdata[31:16];
            wire [1:0] bank_wstrb =
                select_low ? feature_wstrb[1:0] : feature_wstrb[3:2];
            gnn_dist_bank #(
                .WIDTH(DATA_WIDTH),
                .DEPTH(FEATURE_MEMORY_DEPTH),
                .ADDR_WIDTH(FEATURE_MEMORY_ADDR_W)
            ) bank (
                .clk(clk),
                .we(bank_we),
                .waddr(bank_waddr),
                .wdata(bank_wdata),
                .wstrb(bank_wstrb),
                .re((state == ST_AGG_RUN) && !aggregate_all_issued),
                .raddr(feature_read_addr),
                .rdata(feature_bank_rdata_bus[
                    feature_bank*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    reg active_input_bank;
    (* ram_style = "distributed" *)
    reg [31:0] adjacency_memory [0:ADJACENCY_MEMORY_DEPTH-1];
    wire [ADJACENCY_MEMORY_ADDR_W-1:0] adjacency_write_addr =
        adjacency_word_addr +
        (input_write_bank ? ADJACENCY_WORDS : 0);
    integer adjacency_byte_lane;
    always @(posedge clk) begin
        if (adjacency_we &&
            (state == ST_IDLE || input_write_bank != active_input_bank))
            for (adjacency_byte_lane = 0; adjacency_byte_lane < 4;
                 adjacency_byte_lane = adjacency_byte_lane + 1)
                if (adjacency_wstrb[adjacency_byte_lane])
                    adjacency_memory[adjacency_write_addr]
                        [adjacency_byte_lane*8 +: 8] <=
                            adjacency_wdata[adjacency_byte_lane*8 +: 8];
    end

    wire [FEAT_IDX_W-1:0] weight_load_feature =
        weight_addr / HIDDEN_DIM;
    wire [HID_IDX_W-1:0] weight_load_hidden =
        weight_addr % HIDDEN_DIM;
    wire [HIDDEN_GROUP_W-1:0] weight_load_hidden_group =
        weight_load_hidden / HID_LANES;
    wire [MAC_FEATURE_GROUP_W-1:0] weight_load_feature_group =
        weight_load_feature / MAC_FEAT_LANES;
    wire [WEIGHT_BANK_ADDR_W-1:0] weight_write_logical_addr =
        weight_load_hidden_group*MAC_FEATURE_GROUPS + weight_load_feature_group;
    wire [WEIGHT_MEMORY_ADDR_W-1:0] weight_write_addr =
        weight_write_logical_addr + (cfg_bank ? WEIGHT_BANK_DEPTH : 0);

    reg [MAC_FEATURE_GROUP_W-1:0] mac_feature_group_issue;
    wire [WEIGHT_BANK_ADDR_W-1:0] weight_read_logical_addr =
        hidden_group_idx*MAC_FEATURE_GROUPS + mac_feature_group_issue;
    wire [WEIGHT_MEMORY_ADDR_W-1:0] weight_read_addr =
        weight_read_logical_addr +
        (active_weight_bank ? WEIGHT_BANK_DEPTH : 0);
    wire [TOTAL_MAC_BANKS*DATA_WIDTH-1:0] weight_bank_rdata_bus;
    reg mac_all_issued;

    genvar weight_bank;
    generate
        for (weight_bank = 0; weight_bank < TOTAL_MAC_BANKS;
             weight_bank = weight_bank + 1) begin : gen_weight_bank
            localparam integer THIS_HIDDEN_LANE =
                weight_bank / MAC_FEAT_LANES;
            localparam integer THIS_FEATURE_LANE =
                weight_bank % MAC_FEAT_LANES;
            wire bank_we = weight_we &&
                (state == ST_IDLE || cfg_bank != active_weight_bank) &&
                (weight_load_hidden % HID_LANES) == THIS_HIDDEN_LANE &&
                (weight_load_feature % MAC_FEAT_LANES) == THIS_FEATURE_LANE;
            gnn_weight_block_bank #(
                .WIDTH(DATA_WIDTH),
                .DEPTH(WEIGHT_MEMORY_DEPTH),
                .ADDR_WIDTH(WEIGHT_MEMORY_ADDR_W)
            ) bank (
                .clk(clk),
                .we(bank_we),
                .waddr(weight_write_addr),
                .wdata(weight_wdata),
                .re((state == ST_MAC_RUN) && !mac_all_issued),
                .raddr(weight_read_addr),
                .rdata(weight_bank_rdata_bus[
                    weight_bank*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    reg active_weight_bank;
    reg signed [AGG_WIDTH-1:0] aggregate_feature [0:FEATURE_DIM-1];
    reg aggregate_memory_valid;
    reg aggregate_memory_adjacency;
    reg [AGG_GROUP_W-1:0] aggregate_memory_group;
    reg aggregate_read_valid;
    reg aggregate_read_adjacency;
    reg [AGG_GROUP_W-1:0] aggregate_read_group;
    reg [AGG_LANES*DATA_WIDTH-1:0] aggregate_feature_read_bus;
    wire [ADJACENCY_ELEMENT_ADDR_W-1:0] aggregate_adjacency_element =
        node_idx*MAX_NODES + aggregate_neighbor_issue;
    wire [ADJACENCY_WORD_ADDR_W-1:0] aggregate_adjacency_word =
        aggregate_adjacency_element / 32;
    wire [ADJACENCY_MEMORY_ADDR_W-1:0] aggregate_adjacency_addr =
        aggregate_adjacency_word +
        (active_input_bank ? ADJACENCY_WORDS : 0);
    wire aggregate_issue_adjacency =
        adjacency_memory[aggregate_adjacency_addr]
            [aggregate_adjacency_element % 32];

    reg mac_memory_valid;
    reg mac_read_valid;
    reg mac_product_valid;
    reg [MAC_FEAT_LANES*AGG_WIDTH-1:0] mac_aggregate_issue_bus;
    reg [TOTAL_MAC_BANKS*DATA_WIDTH-1:0] mac_weight_read_bus;
    reg [MAC_FEAT_LANES*AGG_WIDTH-1:0] mac_aggregate_read_bus;
    reg [TOTAL_MAC_BANKS*PRODUCT_WIDTH-1:0] mac_product_bus;
    reg signed [ACC_WIDTH-1:0] mac_accumulator [0:HID_LANES-1];

    wire signed [ACC_WIDTH-1:0] mac_increment [0:HID_LANES-1];
    genvar increment_lane;
    generate
        for (increment_lane = 0; increment_lane < HID_LANES;
             increment_lane = increment_lane + 1) begin : gen_mac_increment
            wire signed [PRODUCT_WIDTH-1:0] product0 =
                mac_product_bus[
                    (increment_lane*MAC_FEAT_LANES)*PRODUCT_WIDTH +:
                    PRODUCT_WIDTH];
            wire signed [ACC_WIDTH-1:0] product0_extended = {
                {(ACC_WIDTH-PRODUCT_WIDTH){product0[PRODUCT_WIDTH-1]}},
                product0
            };
            if (MAC_FEAT_LANES == 1) begin : gen_one_feature
                assign mac_increment[increment_lane] = product0_extended;
            end else begin : gen_two_features
                wire signed [PRODUCT_WIDTH-1:0] product1 =
                    mac_product_bus[
                        (increment_lane*MAC_FEAT_LANES+1)*PRODUCT_WIDTH +:
                        PRODUCT_WIDTH];
                wire signed [ACC_WIDTH-1:0] product1_extended = {
                    {(ACC_WIDTH-PRODUCT_WIDTH){product1[PRODUCT_WIDTH-1]}},
                    product1
                };
                assign mac_increment[increment_lane] =
                    product0_extended + product1_extended;
            end
        end
    endgenerate

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

    wire [DATA_WIDTH-1:0] quantized_mac [0:HID_LANES-1];
    genvar quantize_lane;
    generate
        for (quantize_lane = 0; quantize_lane < HID_LANES;
             quantize_lane = quantize_lane + 1) begin : gen_quantize
            assign quantized_mac[quantize_lane] =
                relu_quantize(mac_accumulator[quantize_lane]);
        end
    endgenerate

    wire [OUTPUT_BANK_ADDR_W-1:0] output_write_addr =
        node_idx*HIDDEN_GROUPS + hidden_group_idx;
    wire [OUTPUT_BANK_ADDR_W-1:0] output_read_addr =
        output_word_addr / OUTPUT_BANKS;
    wire [OUTPUT_BANKS*32-1:0] output_bank_rdata_bus;
    reg [OUTPUT_BANK_IDX_W-1:0] output_read_bank_reg;
    integer output_mux_bank;
    always @(*) begin
        output_rdata = 32'd0;
        for (output_mux_bank = 0; output_mux_bank < OUTPUT_BANKS;
             output_mux_bank = output_mux_bank + 1)
            if (output_read_bank_reg == output_mux_bank)
                output_rdata = output_bank_rdata_bus[
                    output_mux_bank*32 +: 32];
    end
    always @(posedge clk) begin
        if (output_re)
            output_read_bank_reg <= output_word_addr % OUTPUT_BANKS;
    end

    genvar output_bank;
    generate
        for (output_bank = 0; output_bank < OUTPUT_BANKS;
             output_bank = output_bank + 1) begin : gen_output_bank
            localparam integer LOW_LANE = output_bank*2;
            localparam integer HIGH_LANE = output_bank*2+1;
            wire valid_low =
                hidden_group_idx*HID_LANES + LOW_LANE < HIDDEN_DIM;
            wire valid_high =
                hidden_group_idx*HID_LANES + HIGH_LANE < HIDDEN_DIM;
            wire bank_we = state == ST_MAC_WRITE && valid_low;
            wire [31:0] bank_wdata = {
                valid_high ? quantized_mac[HIGH_LANE] : {DATA_WIDTH{1'b0}},
                quantized_mac[LOW_LANE]
            };
            wire bank_re = output_re &&
                (output_word_addr % OUTPUT_BANKS) == output_bank;
            gnn_block_bank #(
                .WIDTH(32),
                .DEPTH(OUTPUT_BANK_DEPTH),
                .ADDR_WIDTH(OUTPUT_BANK_ADDR_W)
            ) bank (
                .clk(clk),
                .we(bank_we),
                .waddr(output_write_addr),
                .wdata(bank_wdata),
                .re(bank_re),
                .raddr(output_read_addr),
                .rdata(output_bank_rdata_bus[output_bank*32 +: 32])
            );
        end
    endgenerate

    integer clear_feature;
    integer aggregate_lane;
    integer hidden_lane;
    integer mac_bank;
    integer mac_feature_lane;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                    <= ST_IDLE;
            active_input_bank        <= 1'b0;
            active_weight_bank       <= 1'b0;
            node_idx                 <= {NODE_IDX_W{1'b0}};
            hidden_group_idx         <= {HIDDEN_GROUP_W{1'b0}};
            aggregate_neighbor_issue <= {NODE_IDX_W{1'b0}};
            aggregate_group_issue    <= {AGG_GROUP_W{1'b0}};
            aggregate_all_issued     <= 1'b0;
            aggregate_memory_valid    <= 1'b0;
            aggregate_memory_adjacency <= 1'b0;
            aggregate_memory_group    <= {AGG_GROUP_W{1'b0}};
            aggregate_read_valid     <= 1'b0;
            aggregate_read_adjacency <= 1'b0;
            aggregate_read_group     <= {AGG_GROUP_W{1'b0}};
            mac_feature_group_issue  <= {MAC_FEATURE_GROUP_W{1'b0}};
            mac_all_issued           <= 1'b0;
            mac_memory_valid         <= 1'b0;
            mac_read_valid           <= 1'b0;
            mac_product_valid        <= 1'b0;
            for (clear_feature = 0; clear_feature < FEATURE_DIM;
                 clear_feature = clear_feature + 1)
                aggregate_feature[clear_feature] <= {AGG_WIDTH{1'b0}};
            for (hidden_lane = 0; hidden_lane < HID_LANES;
                 hidden_lane = hidden_lane + 1)
                mac_accumulator[hidden_lane] <= {ACC_WIDTH{1'b0}};
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        active_input_bank <= input_run_bank;
                        active_weight_bank <= run_bank;
                        node_idx         <= {NODE_IDX_W{1'b0}};
                        hidden_group_idx <= {HIDDEN_GROUP_W{1'b0}};
                        state            <= ST_CLEAR_AGG;
                    end
                end

                ST_CLEAR_AGG: begin
                    for (clear_feature = 0; clear_feature < FEATURE_DIM;
                         clear_feature = clear_feature + 1)
                        aggregate_feature[clear_feature] <=
                            {AGG_WIDTH{1'b0}};
                    aggregate_neighbor_issue <= {NODE_IDX_W{1'b0}};
                    aggregate_group_issue    <= {AGG_GROUP_W{1'b0}};
                    aggregate_all_issued     <= 1'b0;
                    aggregate_memory_valid    <= 1'b0;
                    aggregate_read_valid     <= 1'b0;
                    state                    <= ST_AGG_RUN;
                end

                ST_AGG_RUN: begin
                    if (aggregate_read_valid && aggregate_read_adjacency)
                        for (aggregate_lane = 0;
                             aggregate_lane < AGG_LANES;
                             aggregate_lane = aggregate_lane + 1)
                            if (aggregate_read_group*AGG_LANES +
                                aggregate_lane < FEATURE_DIM)
                                aggregate_feature[
                                    aggregate_read_group*AGG_LANES +
                                    aggregate_lane
                                ] <= aggregate_feature[
                                    aggregate_read_group*AGG_LANES +
                                    aggregate_lane
                                ] + $signed(aggregate_feature_read_bus[
                                    aggregate_lane*DATA_WIDTH +: DATA_WIDTH]);

                    if (aggregate_memory_valid) begin
                        aggregate_feature_read_bus <= feature_bank_rdata_bus;
                        aggregate_read_group <= aggregate_memory_group;
                        aggregate_read_adjacency <=
                            aggregate_memory_adjacency;
                        aggregate_read_valid <= 1'b1;
                    end else begin
                        aggregate_read_valid <= 1'b0;
                    end

                    if (!aggregate_all_issued) begin
                        aggregate_memory_group <= aggregate_group_issue;
                        aggregate_memory_adjacency <=
                            aggregate_issue_adjacency;
                        aggregate_memory_valid <= 1'b1;
                        if (aggregate_group_issue == AGG_GROUPS-1) begin
                            aggregate_group_issue <= {AGG_GROUP_W{1'b0}};
                            if (aggregate_neighbor_issue == MAX_NODES-1)
                                aggregate_all_issued <= 1'b1;
                            else
                                aggregate_neighbor_issue <=
                                    aggregate_neighbor_issue + 1'b1;
                        end else begin
                            aggregate_group_issue <=
                                aggregate_group_issue + 1'b1;
                        end
                    end else begin
                        aggregate_memory_valid <= 1'b0;
                    end

                    if (aggregate_all_issued && !aggregate_memory_valid &&
                        !aggregate_read_valid) begin
                        hidden_group_idx <= {HIDDEN_GROUP_W{1'b0}};
                        state <= ST_MAC_INIT;
                    end
                end

                ST_MAC_INIT: begin
                    mac_feature_group_issue <=
                        {MAC_FEATURE_GROUP_W{1'b0}};
                    mac_all_issued    <= 1'b0;
                    mac_memory_valid  <= 1'b0;
                    mac_read_valid    <= 1'b0;
                    mac_product_valid <= 1'b0;
                    for (hidden_lane = 0; hidden_lane < HID_LANES;
                         hidden_lane = hidden_lane + 1)
                        mac_accumulator[hidden_lane] <=
                            {ACC_WIDTH{1'b0}};
                    state <= ST_MAC_RUN;
                end

                ST_MAC_RUN: begin
                    if (!mac_all_issued) begin
                        for (mac_feature_lane = 0;
                             mac_feature_lane < MAC_FEAT_LANES;
                             mac_feature_lane = mac_feature_lane + 1)
                            if (mac_feature_group_issue*MAC_FEAT_LANES +
                                mac_feature_lane < FEATURE_DIM)
                                mac_aggregate_issue_bus[
                                    mac_feature_lane*AGG_WIDTH +: AGG_WIDTH] <=
                                    aggregate_feature[
                                        mac_feature_group_issue*
                                        MAC_FEAT_LANES + mac_feature_lane];
                            else
                                mac_aggregate_issue_bus[
                                    mac_feature_lane*AGG_WIDTH +: AGG_WIDTH] <=
                                    {AGG_WIDTH{1'b0}};
                        mac_memory_valid <= 1'b1;
                        if (mac_feature_group_issue ==
                            MAC_FEATURE_GROUPS-1)
                            mac_all_issued <= 1'b1;
                        else
                            mac_feature_group_issue <=
                                mac_feature_group_issue + 1'b1;
                    end else begin
                        mac_memory_valid <= 1'b0;
                    end

                    if (mac_memory_valid) begin
                        mac_weight_read_bus <= weight_bank_rdata_bus;
                        mac_aggregate_read_bus <= mac_aggregate_issue_bus;
                        mac_read_valid <= 1'b1;
                    end else begin
                        mac_read_valid <= 1'b0;
                    end

                    if (mac_read_valid) begin
                        for (mac_bank = 0; mac_bank < TOTAL_MAC_BANKS;
                             mac_bank = mac_bank + 1)
                            mac_product_bus[
                                mac_bank*PRODUCT_WIDTH +: PRODUCT_WIDTH] <=
                                $signed(mac_weight_read_bus[
                                    mac_bank*DATA_WIDTH +: DATA_WIDTH]) *
                                $signed(mac_aggregate_read_bus[
                                    (mac_bank % MAC_FEAT_LANES)*AGG_WIDTH +:
                                    AGG_WIDTH]);
                        mac_product_valid <= 1'b1;
                    end else begin
                        mac_product_valid <= 1'b0;
                    end

                    if (mac_product_valid)
                        for (hidden_lane = 0; hidden_lane < HID_LANES;
                             hidden_lane = hidden_lane + 1)
                            mac_accumulator[hidden_lane] <=
                                mac_accumulator[hidden_lane] +
                                mac_increment[hidden_lane];

                    if (mac_all_issued && !mac_memory_valid &&
                        !mac_read_valid &&
                        !mac_product_valid)
                        state <= ST_MAC_WRITE;
                end

                ST_MAC_WRITE: begin
                    if (hidden_group_idx == HIDDEN_GROUPS-1) begin
                        if (node_idx == MAX_NODES-1) begin
                            state <= ST_DONE;
                        end else begin
                            node_idx         <= node_idx + 1'b1;
                            hidden_group_idx <= {HIDDEN_GROUP_W{1'b0}};
                            state            <= ST_CLEAR_AGG;
                        end
                    end else begin
                        hidden_group_idx <= hidden_group_idx + 1'b1;
                        state <= ST_MAC_INIT;
                    end
                end

                ST_DONE: state <= ST_IDLE;
                default: state <= ST_IDLE;
            endcase
        end
    end

    assign busy  = (state != ST_IDLE);
    assign valid = (state == ST_DONE);

endmodule
