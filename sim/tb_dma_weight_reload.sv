`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_dma_weight_reload;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_index = 0;
    wire payload_last =
        (payload_index == `MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD-1);
    wire [15:0] payload_low = {payload_index[14:0], 1'b0};
    wire [15:0] payload_high = payload_low + 1'b1;
    wire [31:0] payload_data = {payload_high, payload_low};

    wire done_valid;
    wire [31:0] done_result_words;
    wire result_valid;
    wire [31:0] result_data;

    wire gnn_weight_we;
    wire [12:0] gnn_weight_addr;
    wire [15:0] gnn_weight_wdata;
    wire admet_cfg_we;
    wire [1:0] admet_cfg_model;
    wire [1:0] admet_cfg_layer;
    wire [15:0] admet_cfg_addr;
    wire [15:0] admet_cfg_wdata;

    integer gnn_write_count = 0;
    integer admet_write_count = 0;
    reg [12:0] first_gnn_addr = 0;
    reg [15:0] first_gnn_data = 0;
    reg [12:0] last_gnn_addr = 0;
    reg [15:0] last_gnn_data = 0;
    reg [1:0] last_admet_model = 0;
    reg [1:0] last_admet_layer = 0;
    reg [15:0] last_admet_addr = 0;
    reg [15:0] last_admet_data = 0;
    reg [31:0] seen_epoch = 0;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(8'hFE), .task_flags(32'd0),
        .task_item_count(32'd1),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(1'b1), .done_status(),
        .done_result_words(done_result_words), .done_detail(),
        .result_valid(result_valid), .result_ready(1'b1),
        .result_data(result_data), .abort(1'b0),
        .tanimoto_start(), .fingerprint_we(),
        .fingerprint_db_select(), .fingerprint_addr(),
        .fingerprint_wdata(), .tanimoto_busy(1'b0),
        .tanimoto_valid(1'b0), .tanimoto_similarity(32'd0),
        .gnn_start(), .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(), .gnn_output_rdata(32'd0),
        .gnn_busy(1'b0), .gnn_valid(1'b0),
        .gnn_weight_we(gnn_weight_we),
        .gnn_weight_addr(gnn_weight_addr),
        .gnn_weight_wdata(gnn_weight_wdata),
        .admet_start(), .descriptor_we(), .descriptor_addr(),
        .descriptor_wdata(), .admet_busy(1'b0), .admet_valid(1'b0),
        .admet_predictions(64'd0),
        .admet_cfg_we(admet_cfg_we),
        .admet_cfg_model(admet_cfg_model),
        .admet_cfg_layer(admet_cfg_layer),
        .admet_cfg_addr(admet_cfg_addr),
        .admet_cfg_wdata(admet_cfg_wdata)
    );

    always @(posedge clk) begin
        if (rst_n) begin
            if (payload_valid && payload_ready) begin
                payload_index <= payload_index + 1'b1;
                if (payload_last)
                    payload_valid <= 1'b0;
            end
            if (gnn_weight_we) begin
                if (gnn_write_count == 0) begin
                    first_gnn_addr <= gnn_weight_addr;
                    first_gnn_data <= gnn_weight_wdata;
                end
                last_gnn_addr <= gnn_weight_addr;
                last_gnn_data <= gnn_weight_wdata;
                gnn_write_count <= gnn_write_count + 1;
            end
            if (admet_cfg_we) begin
                last_admet_model <= admet_cfg_model;
                last_admet_layer <= admet_cfg_layer;
                last_admet_addr <= admet_cfg_addr;
                last_admet_data <= admet_cfg_wdata;
                admet_write_count <= admet_write_count + 1;
            end
            if (done_valid && done_result_words != 1)
                $fatal(1, "reload result size=%0d", done_result_words);
            if (result_valid) begin
                seen_epoch <= result_data;
                if (gnn_write_count != 8192 ||
                    first_gnn_addr != 0 || first_gnn_data != 16'd0 ||
                    last_gnn_addr != 8191 || last_gnn_data != 16'd8191)
                    $fatal(1, "GNN reload ordering mismatch count=%0d", gnn_write_count);
                if (admet_write_count != 884 ||
                    last_admet_model != 3 || last_admet_layer != 3 ||
                    last_admet_addr != 0 || last_admet_data != 16'd9075)
                    $fatal(1, "ADMET reload ordering mismatch count=%0d", admet_write_count);
                if (result_data != 1)
                    $fatal(1, "reload epoch=%0d", result_data);
                $display("PASS DMA weight reload writes 9076 Q8.8 values epoch=%0d",
                         result_data);
                $finish;
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        task_valid = 1'b1;
        do @(posedge clk); while (!task_ready);
        task_valid = 1'b0;
        payload_valid = 1'b1;
        repeat (30000) @(posedge clk);
        $fatal(1, "reload timeout payload=%0d gnn=%0d admet=%0d epoch=%0d",
               payload_index, gnn_write_count, admet_write_count, seen_epoch);
    end
endmodule
