`timescale 1ns/1ps

module tb_dma_backend_shared_overlap;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_index = 0;
    wire payload_last = (payload_index == 2079);
    wire done_valid;
    wire [31:0] done_result_words;
    wire result_valid;
    wire [31:0] result_data;
    wire tanimoto_start;
    wire fingerprint_we;
    wire fingerprint_db_select;
    wire [4:0] fingerprint_addr;
    wire [31:0] fingerprint_wdata;

    reg [3:0] core_countdown = 0;
    wire tanimoto_busy = (core_countdown != 0);
    wire tanimoto_valid = (core_countdown == 1);
    integer cycle_count = 0;
    integer boundary_cycle = -1;
    integer result_count = 0;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(8'd0), .task_flags(32'h00000400),
        .task_item_count(32'd64),
        .task_user_tag(32'd0),
        .task_sequence(6'd0),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(32'hffff_ffff), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(1'b1), .done_status(),
        .done_result_words(done_result_words), .done_detail(),
        .result_valid(result_valid), .result_ready(1'b1),
        .result_data(result_data), .abort(1'b0),
        .tanimoto_start(tanimoto_start),
        .fingerprint_we(fingerprint_we),
        .fingerprint_db_select(fingerprint_db_select),
        .fingerprint_addr(fingerprint_addr),
        .fingerprint_wdata(fingerprint_wdata),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(32'h00010000),
        .gnn_start(), .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'd0), .gnn_busy(1'b0), .gnn_valid(1'b0),
        .admet_start(), .descriptor_we(), .descriptor_addr(),
        .descriptor_wdata(), .admet_busy(1'b0), .admet_valid(1'b0),
        .admet_predictions(64'd0)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            core_countdown <= 0;
        end else if (tanimoto_start) begin
            if (core_countdown != 0)
                $fatal(1, "core restarted while busy");
            core_countdown <= 5;
        end else if (core_countdown != 0) begin
            core_countdown <= core_countdown - 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (payload_valid && payload_ready) begin
                if (boundary_cycle >= 0) begin
                    if (cycle_count - boundary_cycle > 3)
                        $fatal(1, "candidate refill gap=%0d cycles",
                               cycle_count - boundary_cycle);
                    boundary_cycle = -1;
                end
                if (payload_index >= 63 && payload_index[4:0] == 31 &&
                    payload_index != 2079)
                    boundary_cycle = cycle_count;
                payload_index <= payload_index + 1'b1;
                if (payload_last)
                    payload_valid <= 1'b0;
            end
            if (done_valid && done_result_words != 64)
                $fatal(1, "result word count=%0d", done_result_words);
            if (result_valid) begin
                if (result_data != 32'h00010000)
                    $fatal(1, "result[%0d]=%08x", result_count, result_data);
                result_count <= result_count + 1;
                if (result_count == 63) begin
                    $display("PASS shared Tanimoto overlaps core latency with next candidate");
                    $finish;
                end
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
        repeat (10000) @(posedge clk);
        $fatal(1, "timeout payload=%0d results=%0d", payload_index,
               result_count);
    end
endmodule
