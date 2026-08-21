`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_dma_backend_parallel;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg [7:0] task_id = 0;
    reg [5:0] task_sequence = 0;
    reg [31:0] task_item_count = 1;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_data = 0;
    reg payload_last = 1'b0;

    wire done_valid;
    wire [5:0] done_sequence;
    wire [31:0] done_result_words;
    wire result_valid;
    wire [2:0] engine_busy;
    wire [2:0] engine_start;
    wire [2:0] engine_done;
    reg overlap_seen = 0;
    reg [2:0] seen_start = 0;
    reg [2:0] seen_done = 0;

    reg [6:0] tanimoto_countdown = 0;
    reg [6:0] gnn_countdown = 0;
    reg [6:0] admet_countdown = 0;

    wire tanimoto_busy = tanimoto_countdown != 0;
    wire tanimoto_valid = tanimoto_countdown == 1;
    wire gnn_busy = gnn_countdown != 0;
    wire gnn_valid = gnn_countdown == 1;
    wire admet_busy = admet_countdown != 0;
    wire admet_valid = admet_countdown == 1;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(task_id), .task_flags(32'd0),
        .task_item_count(task_item_count), .task_sequence(task_sequence),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(1'b1), .done_status(),
        .done_result_words(done_result_words), .done_detail(),
        .done_sequence(done_sequence),
        .result_valid(result_valid), .result_ready(1'b1), .result_data(),
        .abort(1'b0), .engine_busy(engine_busy),
        .engine_start(engine_start), .engine_done(engine_done),
        .tanimoto_start(), .fingerprint_we(), .fingerprint_db_select(),
        .fingerprint_addr(), .fingerprint_wdata(),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(32'h0001_0000),
        .gnn_start(), .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'h474e_4e00),
        .gnn_busy(gnn_busy), .gnn_valid(gnn_valid),
        .gnn_weight_we(), .gnn_weight_addr(), .gnn_weight_wdata(),
        .admet_start(), .descriptor_we(), .descriptor_addr(),
        .descriptor_wdata(), .admet_busy(admet_busy),
        .admet_valid(admet_valid), .admet_predictions(64'h0004_0003_0002_0001),
        .admet_cfg_we(), .admet_cfg_model(), .admet_cfg_layer(),
        .admet_cfg_addr(), .admet_cfg_wdata()
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            tanimoto_countdown <= 0;
            gnn_countdown <= 0;
            admet_countdown <= 0;
            overlap_seen <= 0;
            seen_start <= 0;
            seen_done <= 0;
        end else begin
            if (&engine_busy)
                overlap_seen <= 1'b1;
            seen_start <= seen_start | engine_start;
            seen_done <= seen_done | engine_done;
            if (engine_start[0]) tanimoto_countdown <= 7'd5;
            else if (tanimoto_countdown != 0)
                tanimoto_countdown <= tanimoto_countdown - 1'b1;
            if (engine_start[1]) gnn_countdown <= 7'd60;
            else if (gnn_countdown != 0)
                gnn_countdown <= gnn_countdown - 1'b1;
            if (engine_start[2]) admet_countdown <= 7'd20;
            else if (admet_countdown != 0)
                admet_countdown <= admet_countdown - 1'b1;
        end
    end

    task submit_task;
        input [7:0] id;
        input [5:0] seq;
        input integer payload_words;
        integer word_index;
        begin
            task_id = id;
            task_sequence = seq;
            task_item_count = 1;
            task_valid = 1'b1;
            do @(posedge clk); while (!task_ready);
            task_valid = 1'b0;
            payload_valid = 1'b1;
            for (word_index = 0; word_index < payload_words;
                 word_index = word_index + 1) begin
                payload_data = {id, seq, word_index[17:0]};
                payload_last = word_index + 1 == payload_words;
                do @(posedge clk); while (!payload_ready);
            end
            payload_valid = 1'b0;
            payload_last = 1'b0;
        end
    endtask

    task expect_completion;
        input [5:0] seq;
        integer words;
        begin
            do @(posedge clk); while (!done_valid);
            if (done_sequence != seq)
                $fatal(1, "completion sequence=%0d expected=%0d",
                       done_sequence, seq);
            words = done_result_words;
            if (words == 0)
                $fatal(1, "completion sequence=%0d has no result", seq);
            do @(posedge clk); while (done_valid);
            while (words != 0) begin
                @(posedge clk);
                if (result_valid)
                    words = words - 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        submit_task(`MOL_DMA_TASK_GNN, 6'd10, 1);
        submit_task(`MOL_DMA_TASK_ADMET, 6'd11, 20);
        submit_task(`MOL_DMA_TASK_TANIMOTO, 6'd12, 1);

        repeat (2) begin
            @(posedge clk);
        end
        if (!overlap_seen)
            $fatal(1, "engines never overlapped busy=%03b", engine_busy);

        expect_completion(6'd12);
        expect_completion(6'd11);
        expect_completion(6'd10);
        if (seen_start != 3'b111 || seen_done != 3'b111)
            $fatal(1, "engine events start=%03b done=%03b",
                   seen_start, seen_done);
        $display("PASS independent DMA engines overlap and retain sequence tags");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "timeout busy=%03b overlap=%0d", engine_busy, overlap_seen);
    end
endmodule
