`timescale 1ns / 1ps

// AXI4-Lite wrapper and scheduler for the three accelerator blocks.
//
// Register map (byte addresses):
//   0x0000 control: bit0=start, bits[2:1]=task, bit8=clear status
//   0x0004 status : bit0=busy, bit1=done, bit2=error, bits[5:4]=task
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
    input  wire                            s_axi_rready
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

    reg [1023:0] query_fingerprint;
    reg [1023:0] database_fingerprint;
    reg [20*DATA_WIDTH-1:0] descriptor_buffer;

    reg [C_S_AXI_ADDR_WIDTH-1:0] held_awaddr;
    reg [C_S_AXI_DATA_WIDTH-1:0] held_wdata;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] held_wstrb;
    reg aw_held;
    reg w_held;

    reg command_start;
    reg command_clear;
    reg [1:0] command_task;
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
            query_fingerprint    <= 1024'd0;
            database_fingerprint <= 1024'd0;
            descriptor_buffer    <= {20*DATA_WIDTH{1'b0}};
        end else begin
            command_start <= 1'b0;
            command_clear <= 1'b0;
            gnn_weight_we <= 1'b0;
            gnn_feature_we <= 1'b0;
            gnn_adjacency_we <= 1'b0;
            admet_cfg_we  <= 1'b0;

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
                end else if (held_awaddr >= ADDR_QUERY_BASE &&
                             held_awaddr < ADDR_QUERY_BASE + 128) begin
                    for (byte_lane = 0;
                         byte_lane < C_S_AXI_DATA_WIDTH/8;
                         byte_lane = byte_lane + 1)
                        if (held_wstrb[byte_lane])
                            query_fingerprint[
                                (held_awaddr-ADDR_QUERY_BASE)*8 +
                                byte_lane*8 +: 8
                            ] <= held_wdata[byte_lane*8 +: 8];
                end else if (held_awaddr >= ADDR_DB_BASE &&
                             held_awaddr < ADDR_DB_BASE + 128) begin
                    for (byte_lane = 0;
                         byte_lane < C_S_AXI_DATA_WIDTH/8;
                         byte_lane = byte_lane + 1)
                        if (held_wstrb[byte_lane])
                            database_fingerprint[
                                (held_awaddr-ADDR_DB_BASE)*8 +
                                byte_lane*8 +: 8
                            ] <= held_wdata[byte_lane*8 +: 8];
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

    tanimoto_accelerator u_tanimoto (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .start(tanimoto_start),
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
        .start(gnn_start),
        .node_features_in({GNN_FEATURE_BITS{1'b0}}),
        .adjacency_in({GNN_ADJ_BITS{1'b0}}),
        .node_features_out(),
        .feature_we(gnn_feature_we),
        .feature_word_addr(gnn_feature_addr),
        .feature_wdata(gnn_feature_wdata),
        .feature_wstrb(gnn_feature_wstrb),
        .adjacency_we(gnn_adjacency_we),
        .adjacency_word_addr(gnn_adjacency_addr),
        .adjacency_wdata(gnn_adjacency_wdata),
        .adjacency_wstrb(gnn_adjacency_wstrb),
        .output_re(gnn_output_re),
        .output_word_addr(gnn_output_addr),
        .output_rdata(gnn_output_rdata),
        .weight_we(gnn_weight_we),
        .weight_addr(gnn_weight_addr),
        .weight_wdata(gnn_weight_data_reg),
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
        .start(admet_start),
        .descriptors(descriptor_buffer),
        .cfg_we(admet_cfg_we),
        .cfg_model(admet_cfg_model),
        .cfg_layer(admet_cfg_layer),
        .cfg_addr(admet_cfg_addr),
        .cfg_wdata(admet_weight_data_reg),
        .busy(admet_busy),
        .valid(admet_valid),
        .logp(logp),
        .oral_bioavailability(oral_bioavailability),
        .herg_ic50(herg_ic50),
        .bbb_permeability(bbb_permeability),
        .predictions(admet_predictions)
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
            if (command_start && scheduler_state != ST_IDLE)
                error_sticky <= 1'b1;

            case (scheduler_state)
                ST_IDLE: begin
                    if (command_start) begin
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
