`timescale 1ns / 1ps

// AXI4-Lite wrapper and scheduler for the three accelerator blocks.
//
// Register map (byte addresses):
//   0x0000 control: bit0=start, bits[2:1]=task, bit8=clear status
//   0x0004 status : bit0=busy, bit1=done, bit2=error, bits[5:4]=task
//   0x0008 DMA test mode: 0=normal, 1=loopback, 2=MM2S sink, 3=S2MM source
//   0x000c DMA test source length in 128-bit beats
//   0x0100-0x017c query fingerprint (32 x 32-bit words)
//   0x0180-0x01fc database fingerprint (32 x 32-bit words)
//   0x0200          Tanimoto result, unsigned Q16.16
//   0x0300-0x0324 descriptors (10 words, two signed Q8.8 values/word)
//   0x0340-0x034c ADMET results (one Q8.8 value/word)
//   0x0400/0x0404 GNN weight data / commit(address in bits[12:0])
//   0x0410/0x0414 ADMET config data / commit
//                     commit bits[1:0]=model, [3:2]=layer, [19:4]=address
//   0x1000-0x1138 GNN adjacency matrix (79 words)
//   0x2000-0x38fc GNN input features (1600 words)
//   0x4000-0x71fc GNN output features (3200 words, read-only)
//
// Task IDs: 0=Tanimoto, 1=GNN, 2=ADMET, 3=sequential pipeline.
module accelerator_fingerprint_bank (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          we,
    input  wire [4:0]    waddr,
    input  wire [31:0]   wdata,
    input  wire [3:0]    wstrb,
    output wire [1023:0] packed_data
);
    genvar word_index;
    generate
        for (word_index = 0; word_index < 32;
             word_index = word_index + 1) begin : gen_word
            reg [31:0] value;
            integer byte_index;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    value <= 32'd0;
                else if (we && waddr == word_index)
                    for (byte_index = 0; byte_index < 4;
                         byte_index = byte_index + 1)
                        if (wstrb[byte_index])
                            value[byte_index*8 +: 8] <=
                                wdata[byte_index*8 +: 8];
            end
            assign packed_data[word_index*32 +: 32] = value;
        end
    endgenerate
endmodule

module generator_accelerator_top #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 18,
    parameter integer MAX_NODES          = 50,
    parameter integer FEATURE_DIM        = 64,
    parameter integer HIDDEN_DIM         = 128,
    parameter integer DATA_WIDTH         = 16
)(
    input  wire                            s_axi_aclk,
    input  wire                            s_axi_aresetn,
    input  wire [2:0]                      s_axi_awprot,
    input  wire [2:0]                      s_axi_arprot,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire                            s_axi_awvalid,
    output wire                            s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                            s_axi_wvalid,
    output wire                            s_axi_wready,
    output reg  [1:0]                      s_axi_bresp,
    output reg                             s_axi_bvalid,
    input  wire                            s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire                            s_axi_arvalid,
    output wire                            s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output reg  [1:0]                      s_axi_rresp,
    output reg                             s_axi_rvalid,
    input  wire                            s_axi_rready,

    input  wire [127:0]                    s_axis_job_tdata,
    input  wire [15:0]                     s_axis_job_tkeep,
    input  wire                            s_axis_job_tvalid,
    output wire                            s_axis_job_tready,
    input  wire                            s_axis_job_tlast,
    output wire [127:0]                    m_axis_result_tdata,
    output wire [15:0]                     m_axis_result_tkeep,
    output wire                            m_axis_result_tvalid,
    input  wire                            m_axis_result_tready,
    output wire                            m_axis_result_tlast,
    output wire [2:0]                      engine_busy,
    output wire [2:0]                      engine_start,
    output wire [2:0]                      engine_done,
    output wire [6:0]                      debug_queue_occupancy,
    output wire [5:0]                      debug_active_sequence
);

    localparam integer GNN_FEATURE_BITS =
        MAX_NODES*FEATURE_DIM*DATA_WIDTH;
    localparam integer GNN_ADJ_BITS = MAX_NODES*MAX_NODES;
    localparam integer GNN_OUTPUT_BITS =
        MAX_NODES*HIDDEN_DIM*DATA_WIDTH;
    localparam integer GNN_FEATURE_WORDS =
        (MAX_NODES*FEATURE_DIM+1)/2;
    localparam integer GNN_ADJ_WORDS =
        (MAX_NODES*MAX_NODES+31)/32;
    localparam integer GNN_OUTPUT_WORDS =
        (MAX_NODES*HIDDEN_DIM+1)/2;
    localparam integer GNN_FEATURE_ADDR_W =
        (GNN_FEATURE_WORDS <= 1) ? 1 : $clog2(GNN_FEATURE_WORDS);
    localparam integer GNN_ADJ_ADDR_W =
        (GNN_ADJ_WORDS <= 1) ? 1 : $clog2(GNN_ADJ_WORDS);
    localparam integer GNN_OUTPUT_ADDR_W =
        (GNN_OUTPUT_WORDS <= 1) ? 1 : $clog2(GNN_OUTPUT_WORDS);
    localparam integer GNN_WEIGHT_ADDR_W =
        $clog2(FEATURE_DIM*HIDDEN_DIM);

    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CONTROL      = 18'h00000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS       = 18'h00004;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DMA_TEST_MODE= 18'h00008;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DMA_TEST_BEATS=18'h0000c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_QUERY_BASE   = 18'h00100;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DB_BASE      = 18'h00180;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TANI_RESULT  = 18'h00200;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DESC_BASE    = 18'h00300;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ADMET_BASE   = 18'h00340;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GNN_WDATA    = 18'h00400;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GNN_WCOMMIT  = 18'h00404;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ADMET_WDATA  = 18'h00410;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ADMET_COMMIT = 18'h00414;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ADJ_BASE     = 18'h01000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_FEATURE_BASE = 18'h02000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GNN_OUT_BASE = 18'h04000;

    wire [1023:0] query_fingerprint_bank0;
    wire [1023:0] query_fingerprint_bank1;
    wire [1023:0] database_fingerprint_bank0;
    wire [1023:0] database_fingerprint_bank1;
    wire [1023:0] query_fingerprint;
    wire [1023:0] database_fingerprint;
    reg [2*20*DATA_WIDTH-1:0] descriptor_buffer;

    reg [C_S_AXI_ADDR_WIDTH-1:0] held_awaddr;
    reg [C_S_AXI_DATA_WIDTH-1:0] held_wdata;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] held_wstrb;
    reg aw_held;
    reg w_held;

    reg command_start;
    reg command_clear;
    reg [1:0] command_task;
    reg [1:0] dma_test_mode;
    reg [31:0] dma_test_beats;
    reg [31:0] dma_test_source_index;
    reg [DATA_WIDTH-1:0] gnn_weight_data_reg;
    reg [DATA_WIDTH-1:0] admet_weight_data_reg;
    reg gnn_weight_we;
    reg [GNN_WEIGHT_ADDR_W-1:0] gnn_weight_addr;
    reg gnn_feature_we;
    reg [GNN_FEATURE_ADDR_W-1:0] gnn_feature_addr;
    reg [31:0] gnn_feature_wdata;
    reg [3:0] gnn_feature_wstrb;
    reg gnn_adjacency_we;
    reg [GNN_ADJ_ADDR_W-1:0] gnn_adjacency_addr;
    reg [31:0] gnn_adjacency_wdata;
    reg [3:0] gnn_adjacency_wstrb;
    reg admet_cfg_we;
    reg [1:0] admet_cfg_model;
    reg [1:0] admet_cfg_layer;
    reg [15:0] admet_cfg_addr;
    reg legacy_query_we;
    reg legacy_db_we;
    reg [4:0] legacy_fingerprint_addr;
    reg [31:0] legacy_fingerprint_wdata;
    reg [3:0] legacy_fingerprint_wstrb;
    wire dma_active;
    wire dma_fingerprint_we;
    wire dma_fingerprint_db_select;
    wire [4:0] dma_fingerprint_addr;
    wire [31:0] dma_fingerprint_wdata;
    wire dma_tanimoto_input_write_bank;
    wire dma_tanimoto_input_run_bank;
    wire dma_gnn_input_write_bank;
    wire dma_gnn_input_run_bank;
    wire dma_admet_input_write_bank;
    wire dma_admet_input_run_bank;

    wire dma_tani_write_allowed = !tanimoto_busy ||
        dma_tanimoto_input_write_bank != dma_tanimoto_input_run_bank;
    wire dma_query_write = dma_active && dma_fingerprint_we &&
                           !dma_fingerprint_db_select && dma_tani_write_allowed;
    wire dma_db_write = dma_active && dma_fingerprint_we &&
                        dma_fingerprint_db_select && dma_tani_write_allowed;
    accelerator_fingerprint_bank u_query_bank0 (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .we((dma_query_write && !dma_tanimoto_input_write_bank) ||
            legacy_query_we),
        .waddr(dma_query_write ? dma_fingerprint_addr :
                                 legacy_fingerprint_addr),
        .wdata(dma_query_write ? dma_fingerprint_wdata :
                                 legacy_fingerprint_wdata),
        .wstrb(dma_query_write ? 4'hf : legacy_fingerprint_wstrb),
        .packed_data(query_fingerprint_bank0)
    );
    accelerator_fingerprint_bank u_query_bank1 (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .we(dma_query_write && dma_tanimoto_input_write_bank),
        .waddr(dma_fingerprint_addr), .wdata(dma_fingerprint_wdata),
        .wstrb(4'hf), .packed_data(query_fingerprint_bank1)
    );
    accelerator_fingerprint_bank u_database_bank0 (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .we((dma_db_write && !dma_tanimoto_input_write_bank) || legacy_db_we),
        .waddr(dma_db_write ? dma_fingerprint_addr :
                              legacy_fingerprint_addr),
        .wdata(dma_db_write ? dma_fingerprint_wdata :
                              legacy_fingerprint_wdata),
        .wstrb(dma_db_write ? 4'hf : legacy_fingerprint_wstrb),
        .packed_data(database_fingerprint_bank0)
    );
    accelerator_fingerprint_bank u_database_bank1 (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .we(dma_db_write && dma_tanimoto_input_write_bank),
        .waddr(dma_fingerprint_addr), .wdata(dma_fingerprint_wdata),
        .wstrb(4'hf), .packed_data(database_fingerprint_bank1)
    );
    assign query_fingerprint = dma_active && dma_tanimoto_input_run_bank ?
        query_fingerprint_bank1 : query_fingerprint_bank0;
    assign database_fingerprint = dma_active && dma_tanimoto_input_run_bank ?
        database_fingerprint_bank1 : database_fingerprint_bank0;

    assign s_axi_awready = !aw_held && !s_axi_bvalid;
    assign s_axi_wready  = !w_held && !s_axi_bvalid;
    reg [1:0] gnn_read_wait;
    reg gnn_output_re;
    reg [GNN_OUTPUT_ADDR_W-1:0] gnn_output_addr;
    wire [31:0] gnn_output_rdata;

    assign s_axi_arready = !s_axi_rvalid && (gnn_read_wait == 0);

    integer byte_lane;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            held_awaddr          <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            held_wdata           <= {C_S_AXI_DATA_WIDTH{1'b0}};
            held_wstrb           <= {C_S_AXI_DATA_WIDTH/8{1'b0}};
            aw_held              <= 1'b0;
            w_held               <= 1'b0;
            s_axi_bresp          <= 2'b00;
            s_axi_bvalid         <= 1'b0;
            command_start        <= 1'b0;
            command_clear        <= 1'b0;
            command_task         <= 2'd0;
            dma_test_mode        <= 2'd0;
            dma_test_beats       <= 32'd0;
            dma_test_source_index<= 32'd0;
            gnn_weight_data_reg  <= {DATA_WIDTH{1'b0}};
            admet_weight_data_reg<= {DATA_WIDTH{1'b0}};
            gnn_weight_we        <= 1'b0;
            gnn_weight_addr      <= {GNN_WEIGHT_ADDR_W{1'b0}};
            gnn_feature_we       <= 1'b0;
            gnn_feature_addr     <= {GNN_FEATURE_ADDR_W{1'b0}};
            gnn_feature_wdata    <= 32'd0;
            gnn_feature_wstrb    <= 4'd0;
            gnn_adjacency_we     <= 1'b0;
            gnn_adjacency_addr   <= {GNN_ADJ_ADDR_W{1'b0}};
            gnn_adjacency_wdata  <= 32'd0;
            gnn_adjacency_wstrb  <= 4'd0;
            admet_cfg_we         <= 1'b0;
            admet_cfg_model      <= 2'd0;
            admet_cfg_layer      <= 2'd0;
            admet_cfg_addr       <= 16'd0;
            legacy_query_we      <= 1'b0;
            legacy_db_we         <= 1'b0;
            legacy_fingerprint_addr <= 5'd0;
            legacy_fingerprint_wdata <= 32'd0;
            legacy_fingerprint_wstrb <= 4'd0;
            descriptor_buffer    <= {2*20*DATA_WIDTH{1'b0}};
        end else begin
            command_start <= 1'b0;
            command_clear <= 1'b0;
            gnn_weight_we <= 1'b0;
            gnn_feature_we <= 1'b0;
            gnn_adjacency_we <= 1'b0;
            admet_cfg_we  <= 1'b0;
            legacy_query_we <= 1'b0;
            legacy_db_we <= 1'b0;

            if (dma_test_mode == 2'd3 && m_axis_result_tready &&
                dma_test_source_index < dma_test_beats)
                dma_test_source_index <= dma_test_source_index + 32'd1;

            if (s_axi_awready && s_axi_awvalid) begin
                held_awaddr <= s_axi_awaddr;
                aw_held     <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                held_wdata <= s_axi_wdata;
                held_wstrb <= s_axi_wstrb;
                w_held     <= 1'b1;
            end

            if (aw_held && w_held && !s_axi_bvalid) begin
                if (held_awaddr == ADDR_CONTROL) begin
                    command_task  <= held_wdata[2:1];
                    command_start <= held_wdata[0];
                    command_clear <= held_wdata[8];
                end else if (held_awaddr == ADDR_DMA_TEST_MODE) begin
                    dma_test_mode <= held_wdata[1:0];
                    dma_test_source_index <= 32'd0;
                end else if (held_awaddr == ADDR_DMA_TEST_BEATS) begin
                    dma_test_beats <= held_wdata;
                end else if (held_awaddr >= ADDR_QUERY_BASE &&
                             held_awaddr < ADDR_QUERY_BASE + 128) begin
                    legacy_query_we <= 1'b1;
                    legacy_fingerprint_addr <=
                        (held_awaddr-ADDR_QUERY_BASE) >> 2;
                    legacy_fingerprint_wdata <= held_wdata;
                    legacy_fingerprint_wstrb <= held_wstrb;
                end else if (held_awaddr >= ADDR_DB_BASE &&
                             held_awaddr < ADDR_DB_BASE + 128) begin
                    legacy_db_we <= 1'b1;
                    legacy_fingerprint_addr <=
                        (held_awaddr-ADDR_DB_BASE) >> 2;
                    legacy_fingerprint_wdata <= held_wdata;
                    legacy_fingerprint_wstrb <= held_wstrb;
                end else if (held_awaddr >= ADDR_DESC_BASE &&
                             held_awaddr < ADDR_DESC_BASE + 40) begin
                    for (byte_lane = 0;
                         byte_lane < C_S_AXI_DATA_WIDTH/8;
                         byte_lane = byte_lane + 1)
                        if (held_wstrb[byte_lane])
                            descriptor_buffer[
                                (held_awaddr-ADDR_DESC_BASE)*8 +
                                byte_lane*8 +: 8
                            ] <= held_wdata[byte_lane*8 +: 8];
                end else if (held_awaddr == ADDR_GNN_WDATA) begin
                    gnn_weight_data_reg <= held_wdata[DATA_WIDTH-1:0];
                end else if (held_awaddr == ADDR_GNN_WCOMMIT) begin
                    gnn_weight_addr <=
                        held_wdata[GNN_WEIGHT_ADDR_W-1:0];
                    gnn_weight_we <= 1'b1;
                end else if (held_awaddr == ADDR_ADMET_WDATA) begin
                    admet_weight_data_reg <= held_wdata[DATA_WIDTH-1:0];
                end else if (held_awaddr == ADDR_ADMET_COMMIT) begin
                    admet_cfg_model <= held_wdata[1:0];
                    admet_cfg_layer <= held_wdata[3:2];
                    admet_cfg_addr  <= held_wdata[19:4];
                    admet_cfg_we    <= 1'b1;
                end else if (held_awaddr >= ADDR_ADJ_BASE &&
                             held_awaddr < ADDR_ADJ_BASE +
                                 ((GNN_ADJ_BITS+7)/8)) begin
                    gnn_adjacency_addr <=
                        (held_awaddr-ADDR_ADJ_BASE) >> 2;
                    gnn_adjacency_wdata <= held_wdata;
                    gnn_adjacency_wstrb <= held_wstrb;
                    gnn_adjacency_we <= 1'b1;
                end else if (held_awaddr >= ADDR_FEATURE_BASE &&
                             held_awaddr < ADDR_FEATURE_BASE +
                                 (GNN_FEATURE_BITS/8)) begin
                    gnn_feature_addr <=
                        (held_awaddr-ADDR_FEATURE_BASE) >> 2;
                    gnn_feature_wdata <= held_wdata;
                    gnn_feature_wstrb <= held_wstrb;
                    gnn_feature_we <= 1'b1;
                end

                aw_held      <= 1'b0;
                w_held       <= 1'b0;
                s_axi_bresp  <= 2'b00;
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (dma_active && dma_descriptor_we)
                descriptor_buffer[(dma_admet_input_write_bank*20 +
                                   dma_descriptor_addr)*DATA_WIDTH +:
                                  DATA_WIDTH] <= dma_descriptor_wdata;
        end
    end

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_LOAD    = 3'd1;
    localparam [2:0] ST_EXECUTE = 3'd2;
    localparam [2:0] ST_OUTPUT  = 3'd3;
    localparam [2:0] ST_DONE    = 3'd4;

    reg [2:0] scheduler_state;
    reg [1:0] current_task;
    reg [1:0] pipeline_phase;
    reg done_sticky;
    reg error_sticky;
    reg tanimoto_start;
    reg gnn_start;
    reg admet_start;

    wire tanimoto_busy;
    wire tanimoto_valid;
    wire [31:0] tanimoto_similarity;
    wire gnn_busy;
    wire gnn_valid;
    wire admet_busy;
    wire admet_valid;
    wire [DATA_WIDTH-1:0] logp;
    wire [DATA_WIDTH-1:0] oral_bioavailability;
    wire [DATA_WIDTH-1:0] herg_ic50;
    wire [DATA_WIDTH-1:0] bbb_permeability;
    wire [4*DATA_WIDTH-1:0] admet_predictions;

    wire dma_legacy_reject;
    wire dma_tanimoto_start;
    wire dma_gnn_start;
    wire dma_gnn_feature_we;
    wire [GNN_FEATURE_ADDR_W-1:0] dma_gnn_feature_addr;
    wire [31:0] dma_gnn_feature_wdata;
    wire [3:0] dma_gnn_feature_wstrb;
    wire dma_gnn_adjacency_we;
    wire [GNN_ADJ_ADDR_W-1:0] dma_gnn_adjacency_addr;
    wire [31:0] dma_gnn_adjacency_wdata;
    wire [3:0] dma_gnn_adjacency_wstrb;
    wire dma_gnn_output_re;
    wire [GNN_OUTPUT_ADDR_W-1:0] dma_gnn_output_addr;
    wire dma_gnn_weight_we;
    wire [GNN_WEIGHT_ADDR_W-1:0] dma_gnn_weight_addr;
    wire [DATA_WIDTH-1:0] dma_gnn_weight_wdata;
    wire dma_admet_start;
    wire dma_descriptor_we;
    wire [4:0] dma_descriptor_addr;
    wire [DATA_WIDTH-1:0] dma_descriptor_wdata;
    wire dma_admet_cfg_we;
    wire [1:0] dma_admet_cfg_model;
    wire [1:0] dma_admet_cfg_layer;
    wire [15:0] dma_admet_cfg_addr;
    wire [DATA_WIDTH-1:0] dma_admet_cfg_wdata;
    wire dma_weight_cfg_bank;
    wire dma_weight_run_bank;

    wire core_tanimoto_start = dma_active ? dma_tanimoto_start : tanimoto_start;
    wire core_gnn_start = dma_active ? dma_gnn_start : gnn_start;
    wire core_gnn_feature_we = dma_active ? dma_gnn_feature_we : gnn_feature_we;
    wire [GNN_FEATURE_ADDR_W-1:0] core_gnn_feature_addr =
        dma_active ? dma_gnn_feature_addr : gnn_feature_addr;
    wire [31:0] core_gnn_feature_wdata =
        dma_active ? dma_gnn_feature_wdata : gnn_feature_wdata;
    wire [3:0] core_gnn_feature_wstrb =
        dma_active ? dma_gnn_feature_wstrb : gnn_feature_wstrb;
    wire core_gnn_adjacency_we =
        dma_active ? dma_gnn_adjacency_we : gnn_adjacency_we;
    wire [GNN_ADJ_ADDR_W-1:0] core_gnn_adjacency_addr =
        dma_active ? dma_gnn_adjacency_addr : gnn_adjacency_addr;
    wire [31:0] core_gnn_adjacency_wdata =
        dma_active ? dma_gnn_adjacency_wdata : gnn_adjacency_wdata;
    wire [3:0] core_gnn_adjacency_wstrb =
        dma_active ? dma_gnn_adjacency_wstrb : gnn_adjacency_wstrb;
    wire core_gnn_output_re = dma_active ? dma_gnn_output_re : gnn_output_re;
    wire [GNN_OUTPUT_ADDR_W-1:0] core_gnn_output_addr =
        dma_active ? dma_gnn_output_addr : gnn_output_addr;
    wire core_admet_start = dma_active ? dma_admet_start : admet_start;
    wire core_gnn_input_write_bank = dma_active ?
        dma_gnn_input_write_bank : 1'b0;
    wire core_gnn_input_run_bank = dma_active ?
        dma_gnn_input_run_bank : 1'b0;
    wire core_gnn_weight_we = dma_active ? dma_gnn_weight_we : gnn_weight_we;
    wire [GNN_WEIGHT_ADDR_W-1:0] core_gnn_weight_addr =
        dma_active ? dma_gnn_weight_addr : gnn_weight_addr;
    wire [DATA_WIDTH-1:0] core_gnn_weight_wdata =
        dma_active ? dma_gnn_weight_wdata : gnn_weight_data_reg;
    wire core_admet_cfg_we = dma_active ? dma_admet_cfg_we : admet_cfg_we;
    wire [1:0] core_admet_cfg_model =
        dma_active ? dma_admet_cfg_model : admet_cfg_model;
    wire [1:0] core_admet_cfg_layer =
        dma_active ? dma_admet_cfg_layer : admet_cfg_layer;
    wire [15:0] core_admet_cfg_addr =
        dma_active ? dma_admet_cfg_addr : admet_cfg_addr;
    wire [DATA_WIDTH-1:0] core_admet_cfg_wdata =
        dma_active ? dma_admet_cfg_wdata : admet_weight_data_reg;
    wire core_weight_cfg_bank =
        dma_active ? dma_weight_cfg_bank : dma_weight_run_bank;
    wire core_weight_run_bank = dma_weight_run_bank;

    tanimoto_accelerator u_tanimoto (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(core_tanimoto_start),
        .query_fp(query_fingerprint),
        .db_fp(database_fingerprint),
        .busy(tanimoto_busy),
        .valid(tanimoto_valid),
        .similarity(tanimoto_similarity)
    );

    gnn_message_passing #(
        .MAX_NODES(MAX_NODES),
        .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH),
        .PACKED_IO(0)
    ) u_gnn (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(core_gnn_start),
        .input_write_bank(core_gnn_input_write_bank),
        .input_run_bank(core_gnn_input_run_bank),
        .node_features_in({GNN_FEATURE_BITS{1'b0}}),
        .adjacency_in({GNN_ADJ_BITS{1'b0}}),
        .node_features_out(),
        .feature_we(core_gnn_feature_we),
        .feature_word_addr(core_gnn_feature_addr),
        .feature_wdata(core_gnn_feature_wdata),
        .feature_wstrb(core_gnn_feature_wstrb),
        .adjacency_we(core_gnn_adjacency_we),
        .adjacency_word_addr(core_gnn_adjacency_addr),
        .adjacency_wdata(core_gnn_adjacency_wdata),
        .adjacency_wstrb(core_gnn_adjacency_wstrb),
        .output_re(core_gnn_output_re),
        .output_word_addr(core_gnn_output_addr),
        .output_rdata(gnn_output_rdata),
        .weight_we(core_gnn_weight_we),
        .weight_addr(core_gnn_weight_addr),
        .weight_wdata(core_gnn_weight_wdata),
        .cfg_bank(core_weight_cfg_bank),
        .run_bank(core_weight_run_bank),
        .busy(gnn_busy),
        .valid(gnn_valid)
    );

    admet_predictor #(
        .DESCRIPTOR_DIM(20),
        .HIDDEN_DIM(10),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_admet (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(core_admet_start),
        .descriptors(dma_active && dma_admet_input_run_bank ?
                     descriptor_buffer[20*DATA_WIDTH +: 20*DATA_WIDTH] :
                     descriptor_buffer[0 +: 20*DATA_WIDTH]),
        .cfg_we(core_admet_cfg_we),
        .cfg_model(core_admet_cfg_model),
        .cfg_layer(core_admet_cfg_layer),
        .cfg_addr(core_admet_cfg_addr),
        .cfg_wdata(core_admet_cfg_wdata),
        .cfg_bank(core_weight_cfg_bank),
        .run_bank(core_weight_run_bank),
        .busy(admet_busy),
        .valid(admet_valid),
        .logp(logp),
        .oral_bioavailability(oral_bioavailability),
        .herg_ic50(herg_ic50),
        .bbb_permeability(bbb_permeability),
        .predictions(admet_predictions)
    );

    wire dma_batch_valid;
    wire dma_batch_ready;
    wire [31:0] dma_batch_id;
    wire [31:0] dma_batch_task_count;
    wire [31:0] dma_batch_total_words;
    wire [31:0] dma_batch_flags;
    wire [31:0] dma_batch_max_result_words;
    wire [7:0] dma_batch_status;
    wire [31:0] dma_batch_detail;
    wire dma_task_valid;
    wire dma_task_ready;
    wire [31:0] dma_task_job_id;
    wire [7:0] dma_task_id;
    wire [31:0] dma_task_flags;
    wire [31:0] dma_task_payload_words;
    wire [31:0] dma_task_result_capacity_words;
    wire [31:0] dma_task_item_count;
    wire [31:0] dma_task_user_tag;
    wire [31:0] dma_task_timeout_cycles;
    wire [7:0] dma_task_status;
    wire [31:0] dma_task_detail;
    wire dma_payload_valid;
    wire dma_payload_ready;
    wire [31:0] dma_payload_data;
    wire dma_payload_last;
    wire dma_end_valid;
    wire dma_end_ready;
    wire [7:0] dma_end_status;
    wire [31:0] dma_end_detail;
    wire [31:0] dma_observed_words;
    wire normal_job_tready;

    dma_task_queue_frontend u_dma_frontend (
        .aclk(s_axi_aclk),
        .aresetn(s_axi_aresetn),
        .s_axis_job_tdata(s_axis_job_tdata),
        .s_axis_job_tkeep(s_axis_job_tkeep),
        .s_axis_job_tvalid(s_axis_job_tvalid && (dma_test_mode == 2'd0)),
        .s_axis_job_tready(normal_job_tready),
        .s_axis_job_tlast(s_axis_job_tlast),
        .batch_valid(dma_batch_valid),
        .batch_ready(dma_batch_ready),
        .batch_id(dma_batch_id),
        .batch_task_count(dma_batch_task_count),
        .batch_total_words(dma_batch_total_words),
        .batch_flags(dma_batch_flags),
        .batch_max_result_words(dma_batch_max_result_words),
        .batch_status(dma_batch_status),
        .batch_detail(dma_batch_detail),
        .task_valid(dma_task_valid),
        .task_ready(dma_task_ready),
        .task_job_id(dma_task_job_id),
        .task_id(dma_task_id),
        .task_flags(dma_task_flags),
        .task_payload_words(dma_task_payload_words),
        .task_result_capacity_words(dma_task_result_capacity_words),
        .task_item_count(dma_task_item_count),
        .task_user_tag(dma_task_user_tag),
        .task_timeout_cycles(dma_task_timeout_cycles),
        .task_status(dma_task_status),
        .task_detail(dma_task_detail),
        .payload_valid(dma_payload_valid),
        .payload_ready(dma_payload_ready),
        .payload_data(dma_payload_data),
        .payload_last(dma_payload_last),
        .batch_end_valid(dma_end_valid),
        .batch_end_ready(dma_end_ready),
        .batch_end_status(dma_end_status),
        .batch_end_detail(dma_end_detail),
        .batch_observed_words(dma_observed_words)
    );

    wire fmt_batch_valid;
    wire fmt_batch_ready;
    wire [31:0] fmt_batch_id;
    wire [31:0] fmt_expected_task_count;
    wire [7:0] fmt_header_status;
    wire [31:0] fmt_output_capacity_words;
    wire fmt_result_valid;
    wire fmt_result_ready;
    wire fmt_result_reject;
    wire [31:0] fmt_result_job_id;
    wire [7:0] fmt_result_task_id;
    wire [23:0] fmt_result_status;
    wire [31:0] fmt_result_words;
    wire [63:0] fmt_result_compute_cycles;
    wire [31:0] fmt_result_item_count;
    wire [31:0] fmt_result_user_tag;
    wire [31:0] fmt_result_detail;
    wire fmt_result_data_valid;
    wire fmt_result_data_ready;
    wire [31:0] fmt_result_data;
    wire fmt_finish_valid;
    wire fmt_finish_ready;
    wire [31:0] fmt_finish_completed_count;
    wire [31:0] fmt_finish_error_count;
    wire [31:0] fmt_finish_batch_status;
    wire [31:0] fmt_finish_first_error_job_id;
    wire [31:0] fmt_finish_detail;
    wire [127:0] normal_result_tdata;
    wire [15:0] normal_result_tkeep;
    wire normal_result_tvalid;
    wire normal_result_tlast;

    wire backend_task_valid;
    wire backend_task_ready;
    wire [7:0] backend_task_id;
    wire [31:0] backend_task_flags;
    wire [31:0] backend_task_item_count;
    wire [31:0] backend_task_user_tag;
    wire [31:0] backend_task_timeout_cycles;
    wire [5:0] backend_task_sequence;
    wire backend_payload_valid;
    wire backend_payload_ready;
    wire [31:0] backend_payload_data;
    wire backend_payload_last;
    wire backend_done_valid;
    wire backend_done_ready;
    wire [23:0] backend_done_status;
    wire [31:0] backend_done_result_words;
    wire [31:0] backend_done_detail;
    wire [5:0] backend_done_sequence;
    wire backend_result_valid;
    wire backend_result_ready;
    wire [31:0] backend_result_data;
    wire backend_abort;

    dma_task_queue u_dma_queue (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .in_batch_valid(dma_batch_valid), .in_batch_ready(dma_batch_ready),
        .in_batch_id(dma_batch_id),
        .in_batch_task_count(dma_batch_task_count),
        .in_batch_flags(dma_batch_flags),
        .in_batch_max_result_words(dma_batch_max_result_words),
        .in_batch_status(dma_batch_status), .in_batch_detail(dma_batch_detail),
        .in_task_valid(dma_task_valid), .in_task_ready(dma_task_ready),
        .in_task_job_id(dma_task_job_id), .in_task_id(dma_task_id),
        .in_task_flags(dma_task_flags),
        .in_task_payload_words(dma_task_payload_words),
        .in_task_result_capacity_words(dma_task_result_capacity_words),
        .in_task_item_count(dma_task_item_count),
        .in_task_user_tag(dma_task_user_tag),
        .in_task_timeout_cycles(dma_task_timeout_cycles),
        .in_task_status(dma_task_status), .in_task_detail(dma_task_detail),
        .in_payload_valid(dma_payload_valid),
        .in_payload_ready(dma_payload_ready),
        .in_payload_data(dma_payload_data), .in_payload_last(dma_payload_last),
        .in_end_valid(dma_end_valid), .in_end_ready(dma_end_ready),
        .in_end_status(dma_end_status), .in_end_detail(dma_end_detail),
        .fmt_batch_valid(fmt_batch_valid), .fmt_batch_ready(fmt_batch_ready),
        .fmt_batch_id(fmt_batch_id),
        .fmt_expected_task_count(fmt_expected_task_count),
        .fmt_header_status(fmt_header_status),
        .fmt_output_capacity_words(fmt_output_capacity_words),
        .fmt_result_valid(fmt_result_valid), .fmt_result_ready(fmt_result_ready),
        .fmt_result_reject(fmt_result_reject),
        .fmt_result_job_id(fmt_result_job_id),
        .fmt_result_task_id(fmt_result_task_id),
        .fmt_result_status(fmt_result_status), .fmt_result_words(fmt_result_words),
        .fmt_result_compute_cycles(fmt_result_compute_cycles),
        .fmt_result_item_count(fmt_result_item_count),
        .fmt_result_user_tag(fmt_result_user_tag),
        .fmt_result_detail(fmt_result_detail),
        .fmt_result_data_valid(fmt_result_data_valid),
        .fmt_result_data_ready(fmt_result_data_ready),
        .fmt_result_data(fmt_result_data),
        .fmt_finish_valid(fmt_finish_valid), .fmt_finish_ready(fmt_finish_ready),
        .fmt_finish_completed_count(fmt_finish_completed_count),
        .fmt_finish_error_count(fmt_finish_error_count),
        .fmt_finish_batch_status(fmt_finish_batch_status),
        .fmt_finish_first_error_job_id(fmt_finish_first_error_job_id),
        .fmt_finish_detail(fmt_finish_detail),
        .backend_task_valid(backend_task_valid),
        .backend_task_ready(backend_task_ready),
        .backend_task_id(backend_task_id), .backend_task_flags(backend_task_flags),
        .backend_task_item_count(backend_task_item_count),
        .backend_task_user_tag(backend_task_user_tag),
        .backend_task_timeout_cycles(backend_task_timeout_cycles),
        .backend_task_sequence(backend_task_sequence),
        .backend_payload_valid(backend_payload_valid),
        .backend_payload_ready(backend_payload_ready),
        .backend_payload_data(backend_payload_data),
        .backend_payload_last(backend_payload_last),
        .backend_done_valid(backend_done_valid),
        .backend_done_ready(backend_done_ready),
        .backend_done_status(backend_done_status),
        .backend_done_result_words(backend_done_result_words),
        .backend_done_detail(backend_done_detail),
        .backend_done_sequence(backend_done_sequence),
        .backend_result_valid(backend_result_valid),
        .backend_result_ready(backend_result_ready),
        .backend_result_data(backend_result_data), .backend_abort(backend_abort),
        .legacy_active(scheduler_state != ST_IDLE),
        .legacy_start(command_start), .legacy_reject(dma_legacy_reject),
        .dma_active(dma_active),
        .debug_queue_occupancy(debug_queue_occupancy),
        .debug_active_sequence(debug_active_sequence)
    );

    dma_result_formatter u_dma_formatter (
        .aclk(s_axi_aclk), .aresetn(s_axi_aresetn),
        .batch_valid(fmt_batch_valid), .batch_ready(fmt_batch_ready),
        .batch_id(fmt_batch_id), .expected_task_count(fmt_expected_task_count),
        .header_status(fmt_header_status),
        .output_capacity_words(fmt_output_capacity_words),
        .result_valid(fmt_result_valid), .result_ready(fmt_result_ready),
        .result_reject(fmt_result_reject), .result_job_id(fmt_result_job_id),
        .result_task_id(fmt_result_task_id), .result_status(fmt_result_status),
        .result_words(fmt_result_words),
        .result_compute_cycles(fmt_result_compute_cycles),
        .result_item_count(fmt_result_item_count),
        .result_user_tag(fmt_result_user_tag), .result_detail(fmt_result_detail),
        .result_data_valid(fmt_result_data_valid),
        .result_data_ready(fmt_result_data_ready), .result_data(fmt_result_data),
        .finish_valid(fmt_finish_valid), .finish_ready(fmt_finish_ready),
        .finish_completed_count(fmt_finish_completed_count),
        .finish_error_count(fmt_finish_error_count),
        .finish_batch_status(fmt_finish_batch_status),
        .finish_first_error_job_id(fmt_finish_first_error_job_id),
        .finish_detail(fmt_finish_detail),
        .m_axis_result_tdata(normal_result_tdata),
        .m_axis_result_tkeep(normal_result_tkeep),
        .m_axis_result_tvalid(normal_result_tvalid),
        .m_axis_result_tready(m_axis_result_tready &&
                              (dma_test_mode == 2'd0)),
        .m_axis_result_tlast(normal_result_tlast)
    );

    wire dma_test_source_valid = (dma_test_mode == 2'd3) &&
                                 (dma_test_source_index < dma_test_beats);
    wire [127:0] dma_test_source_data = {4{dma_test_source_index}};
    wire dma_test_source_last = dma_test_source_valid &&
        (dma_test_source_index + 32'd1 == dma_test_beats);

    assign s_axis_job_tready =
        (dma_test_mode == 2'd0) ? normal_job_tready :
        (dma_test_mode == 2'd1) ? m_axis_result_tready :
        (dma_test_mode == 2'd2);
    assign m_axis_result_tdata =
        (dma_test_mode == 2'd1) ? s_axis_job_tdata :
        (dma_test_mode == 2'd3) ? dma_test_source_data : normal_result_tdata;
    assign m_axis_result_tkeep =
        (dma_test_mode == 2'd1) ? s_axis_job_tkeep :
        (dma_test_mode == 2'd3) ? 16'hffff : normal_result_tkeep;
    assign m_axis_result_tvalid =
        (dma_test_mode == 2'd1) ? s_axis_job_tvalid :
        (dma_test_mode == 2'd3) ? dma_test_source_valid :
        (dma_test_mode == 2'd0) ? normal_result_tvalid : 1'b0;
    assign m_axis_result_tlast =
        (dma_test_mode == 2'd1) ? s_axis_job_tlast :
        (dma_test_mode == 2'd3) ? dma_test_source_last : normal_result_tlast;

    dma_accelerator_backend #(
        .MAX_NODES(MAX_NODES), .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM), .DATA_WIDTH(DATA_WIDTH)
    ) u_dma_backend (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .task_valid(backend_task_valid), .task_ready(backend_task_ready),
        .task_id(backend_task_id), .task_flags(backend_task_flags),
        .task_item_count(backend_task_item_count),
        .task_user_tag(backend_task_user_tag),
        .task_sequence(backend_task_sequence),
        .payload_valid(backend_payload_valid),
        .payload_ready(backend_payload_ready),
        .payload_data(backend_payload_data), .payload_last(backend_payload_last),
        .done_valid(backend_done_valid), .done_ready(backend_done_ready),
        .done_status(backend_done_status),
        .done_result_words(backend_done_result_words),
        .done_detail(backend_done_detail),
        .done_sequence(backend_done_sequence),
        .result_valid(backend_result_valid), .result_ready(backend_result_ready),
        .result_data(backend_result_data), .abort(backend_abort),
        .engine_busy(engine_busy), .engine_start(engine_start),
        .engine_done(engine_done),
        .tanimoto_start(dma_tanimoto_start),
        .fingerprint_we(dma_fingerprint_we),
        .fingerprint_db_select(dma_fingerprint_db_select),
        .fingerprint_addr(dma_fingerprint_addr),
        .fingerprint_wdata(dma_fingerprint_wdata),
        .tanimoto_input_write_bank(dma_tanimoto_input_write_bank),
        .tanimoto_input_run_bank(dma_tanimoto_input_run_bank),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(tanimoto_similarity),
        .gnn_start(dma_gnn_start),
        .gnn_input_write_bank(dma_gnn_input_write_bank),
        .gnn_input_run_bank(dma_gnn_input_run_bank),
        .gnn_feature_we(dma_gnn_feature_we),
        .gnn_feature_addr(dma_gnn_feature_addr),
        .gnn_feature_wdata(dma_gnn_feature_wdata),
        .gnn_feature_wstrb(dma_gnn_feature_wstrb),
        .gnn_adjacency_we(dma_gnn_adjacency_we),
        .gnn_adjacency_addr(dma_gnn_adjacency_addr),
        .gnn_adjacency_wdata(dma_gnn_adjacency_wdata),
        .gnn_adjacency_wstrb(dma_gnn_adjacency_wstrb),
        .gnn_output_re(dma_gnn_output_re),
        .gnn_output_addr(dma_gnn_output_addr),
        .gnn_output_rdata(gnn_output_rdata), .gnn_busy(gnn_busy),
        .gnn_valid(gnn_valid),
        .gnn_weight_we(dma_gnn_weight_we),
        .gnn_weight_addr(dma_gnn_weight_addr),
        .gnn_weight_wdata(dma_gnn_weight_wdata),
        .admet_start(dma_admet_start),
        .admet_input_write_bank(dma_admet_input_write_bank),
        .admet_input_run_bank(dma_admet_input_run_bank),
        .descriptor_we(dma_descriptor_we),
        .descriptor_addr(dma_descriptor_addr),
        .descriptor_wdata(dma_descriptor_wdata),
        .admet_busy(admet_busy), .admet_valid(admet_valid),
        .admet_predictions(admet_predictions),
        .admet_cfg_we(dma_admet_cfg_we),
        .admet_cfg_model(dma_admet_cfg_model),
        .admet_cfg_layer(dma_admet_cfg_layer),
        .admet_cfg_addr(dma_admet_cfg_addr),
        .admet_cfg_wdata(dma_admet_cfg_wdata),
        .weight_cfg_bank(dma_weight_cfg_bank),
        .weight_run_bank(dma_weight_run_bank)
    );

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            scheduler_state <= ST_IDLE;
            current_task     <= 2'd0;
            pipeline_phase   <= 2'd0;
            done_sticky      <= 1'b0;
            error_sticky     <= 1'b0;
            tanimoto_start   <= 1'b0;
            gnn_start        <= 1'b0;
            admet_start      <= 1'b0;
        end else begin
            tanimoto_start <= 1'b0;
            gnn_start      <= 1'b0;
            admet_start    <= 1'b0;

            if (command_clear) begin
                done_sticky  <= 1'b0;
                error_sticky <= 1'b0;
            end
            if (command_start &&
                (scheduler_state != ST_IDLE || dma_active || dma_legacy_reject))
                error_sticky <= 1'b1;

            case (scheduler_state)
                ST_IDLE: begin
                    if (command_start && !dma_active && !dma_legacy_reject) begin
                        current_task   <= command_task;
                        pipeline_phase <= 2'd0;
                        done_sticky    <= 1'b0;
                        error_sticky   <= 1'b0;
                        scheduler_state <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    case (current_task)
                        2'd0: tanimoto_start <= 1'b1;
                        2'd1: gnn_start      <= 1'b1;
                        2'd2: admet_start    <= 1'b1;
                        2'd3: tanimoto_start <= 1'b1;
                        default: ;
                    endcase
                    scheduler_state <= ST_EXECUTE;
                end

                ST_EXECUTE: begin
                    case (current_task)
                        2'd0: if (tanimoto_valid)
                            scheduler_state <= ST_OUTPUT;
                        2'd1: if (gnn_valid)
                            scheduler_state <= ST_OUTPUT;
                        2'd2: if (admet_valid)
                            scheduler_state <= ST_OUTPUT;
                        2'd3: begin
                            if (pipeline_phase == 0 && tanimoto_valid) begin
                                gnn_start      <= 1'b1;
                                pipeline_phase <= 2'd1;
                            end else if (pipeline_phase == 1 &&
                                         gnn_valid) begin
                                admet_start    <= 1'b1;
                                pipeline_phase <= 2'd2;
                            end else if (pipeline_phase == 2 &&
                                         admet_valid) begin
                                scheduler_state <= ST_OUTPUT;
                            end
                        end
                        default: scheduler_state <= ST_OUTPUT;
                    endcase
                end

                ST_OUTPUT: scheduler_state <= ST_DONE;

                ST_DONE: begin
                    done_sticky      <= 1'b1;
                    scheduler_state <= ST_IDLE;
                end

                default: scheduler_state <= ST_IDLE;
            endcase
        end
    end

    reg [31:0] read_data_mux;
    always @(*) begin
        read_data_mux = 32'd0;
        if (s_axi_araddr == ADDR_STATUS) begin
            read_data_mux[0]   = (scheduler_state != ST_IDLE);
            read_data_mux[1]   = done_sticky;
            read_data_mux[2]   = error_sticky;
            read_data_mux[5:4] = current_task;
        end else if (s_axi_araddr == ADDR_DMA_TEST_MODE) begin
            read_data_mux = {30'd0, dma_test_mode};
        end else if (s_axi_araddr == ADDR_DMA_TEST_BEATS) begin
            read_data_mux = dma_test_beats;
        end else if (s_axi_araddr >= ADDR_QUERY_BASE &&
                     s_axi_araddr < ADDR_QUERY_BASE + 128) begin
            read_data_mux = query_fingerprint[
                (s_axi_araddr-ADDR_QUERY_BASE)*8 +: 32
            ];
        end else if (s_axi_araddr >= ADDR_DB_BASE &&
                     s_axi_araddr < ADDR_DB_BASE + 128) begin
            read_data_mux = database_fingerprint[
                (s_axi_araddr-ADDR_DB_BASE)*8 +: 32
            ];
        end else if (s_axi_araddr == ADDR_TANI_RESULT) begin
            read_data_mux = tanimoto_similarity;
        end else if (s_axi_araddr >= ADDR_DESC_BASE &&
                     s_axi_araddr < ADDR_DESC_BASE + 40) begin
            read_data_mux = descriptor_buffer[
                (s_axi_araddr-ADDR_DESC_BASE)*8 +: 32
            ];
        end else if (s_axi_araddr >= ADDR_ADMET_BASE &&
                     s_axi_araddr < ADDR_ADMET_BASE + 16) begin
            case ((s_axi_araddr-ADDR_ADMET_BASE) >> 2)
                0: read_data_mux = {{(32-DATA_WIDTH){1'b0}}, logp};
                1: read_data_mux =
                    {{(32-DATA_WIDTH){1'b0}}, oral_bioavailability};
                2: read_data_mux = {{(32-DATA_WIDTH){1'b0}}, herg_ic50};
                3: read_data_mux =
                    {{(32-DATA_WIDTH){1'b0}}, bbb_permeability};
                default: read_data_mux = 32'd0;
            endcase
        end
    end

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_rdata  <= 32'd0;
            s_axi_rresp  <= 2'b00;
            s_axi_rvalid <= 1'b0;
            gnn_read_wait <= 2'd0;
            gnn_output_re <= 1'b0;
            gnn_output_addr <= {GNN_OUTPUT_ADDR_W{1'b0}};
        end else begin
            gnn_output_re <= 1'b0;
            if (s_axi_arready && s_axi_arvalid) begin
                if (s_axi_araddr >= ADDR_GNN_OUT_BASE &&
                    s_axi_araddr < ADDR_GNN_OUT_BASE +
                        (GNN_OUTPUT_BITS/8)) begin
                    gnn_output_addr <=
                        (s_axi_araddr-ADDR_GNN_OUT_BASE) >> 2;
                    gnn_output_re <= 1'b1;
                    gnn_read_wait <= 2'd2;
                end else begin
                    s_axi_rdata  <= read_data_mux;
                    s_axi_rresp  <= 2'b00;
                    s_axi_rvalid <= 1'b1;
                end
            end else if (gnn_read_wait != 0) begin
                gnn_read_wait <= gnn_read_wait - 1'b1;
                if (gnn_read_wait == 1) begin
                    s_axi_rdata  <= gnn_output_rdata;
                    s_axi_rresp  <= 2'b00;
                    s_axi_rvalid <= 1'b1;
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
