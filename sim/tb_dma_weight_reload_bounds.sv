`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_dma_weight_reload_bounds;
    localparam [7:0] RELOAD_TASK_ID = `MOL_DMA_TASK_WEIGHT_RELOAD;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg [31:0] task_user_tag = 0;
    reg [5:0] task_sequence = 0;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_data = 0;
    reg payload_last = 1'b0;
    wire done_valid;
    wire [23:0] done_status;
    wire [31:0] done_detail;
    wire [5:0] done_sequence;
    wire result_valid;
    wire [31:0] result_data;
    wire gnn_weight_we;
    wire admet_cfg_we;
    wire weight_run_bank;

    integer write_count = 0;
    integer case_id = 0;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(RELOAD_TASK_ID), .task_flags(32'd0),
        .task_item_count(32'd1), .task_user_tag(task_user_tag),
        .task_sequence(task_sequence),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(1'b1),
        .done_status(done_status), .done_result_words(),
        .done_detail(done_detail), .done_sequence(done_sequence),
        .result_valid(result_valid), .result_ready(1'b1),
        .result_data(result_data), .abort(1'b0),
        .tanimoto_start(), .fingerprint_we(), .fingerprint_db_select(),
        .fingerprint_addr(), .fingerprint_wdata(), .tanimoto_busy(1'b0),
        .tanimoto_valid(1'b0), .tanimoto_similarity(32'd0),
        .gnn_start(), .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(), .gnn_output_rdata(32'd0),
        .gnn_busy(1'b0), .gnn_valid(1'b0),
        .gnn_weight_we(gnn_weight_we), .gnn_weight_addr(),
        .gnn_weight_wdata(), .admet_start(), .descriptor_we(),
        .descriptor_addr(), .descriptor_wdata(), .admet_busy(1'b0),
        .admet_valid(1'b0), .admet_predictions(64'd0),
        .admet_cfg_we(admet_cfg_we), .admet_cfg_model(),
        .admet_cfg_layer(), .admet_cfg_addr(), .admet_cfg_wdata(),
        .weight_cfg_bank(), .weight_run_bank(weight_run_bank)
    );

    always @(posedge clk)
        if (gnn_weight_we || admet_cfg_we)
            write_count <= write_count + 1;

    task automatic send_word(input integer index, input bit is_last);
        reg [15:0] low_half;
        reg [15:0] high_half;
        begin
            @(negedge clk);
            low_half = index*2;
            high_half = index*2+1;
            payload_data = {high_half, low_half};
            payload_last = is_last;
            payload_valid = 1'b1;
            while (payload_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            payload_valid = 1'b0;
            payload_last = 1'b0;
        end
    endtask

    task automatic run_bad_length(
        input integer word_count,
        input [31:0] expected_crc,
        input [5:0] seq,
        input [8*8-1:0] label
    );
        integer index;
        integer writes_before;
        begin
            writes_before = write_count;
            task_user_tag = expected_crc;
            task_sequence = seq;
            @(negedge clk);
            task_valid = 1'b1;
            while (task_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            task_valid = 1'b0;
            for (index = 0; index < word_count; index = index + 1)
                send_word(index, index == word_count-1);
            repeat (20000) begin
                @(posedge clk);
                if (result_valid) begin
                    if (done_sequence !== seq ||
                        done_status !== `MOL_DMA_STATUS_INTERNAL_ERROR ||
                        done_detail !== expected_crc || result_data !== 32'd0 ||
                        weight_run_bank !== 1'b0)
                        $fatal(1, "%0s length error committed status=%h detail=%h epoch=%0d bank=%b",
                               label, done_status, done_detail, result_data,
                               weight_run_bank);
                    if (write_count-writes_before > 9076)
                        $fatal(1, "%0s wrote %0d halfwords past fixed image",
                               label, write_count-writes_before);
                    @(posedge clk);
                    disable run_bad_length;
                end
            end
            $fatal(1, "%0s length-error timeout", label);
        end
    endtask

    initial begin
        if (!$value$plusargs("CASE=%d", case_id))
            case_id = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        if (case_id == 0 || case_id == 1)
            run_bad_length(10, 32'h68ec_24b5, 6'd1, "early");
        if (case_id == 0 || case_id == 2)
            run_bad_length(4539, 32'h4297_8f5e, 6'd2, "late");
        $display("PASS early/late reload length rejection and fixed write bound");
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "weight reload bounds global timeout");
    end
endmodule
