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
    reg done_ready = 1'b0;
    reg result_ready = 1'b0;

    wire done_valid;
    wire [23:0] done_status;
    wire [31:0] done_result_words;
    wire [31:0] done_detail;
    wire [5:0] done_sequence;
    wire result_valid;
    wire [31:0] result_data;
    wire [2:0] engine_busy;
    wire [2:0] engine_start;
    wire [2:0] engine_done;

    reg release_core_valid = 1'b1;
    reg overlap_seen = 0;
    reg [2:0] seen_start = 0;
    reg [2:0] seen_done = 0;
    reg [6:0] tanimoto_countdown = 0;
    reg [6:0] gnn_countdown = 0;
    reg [6:0] admet_countdown = 0;
    reg [6:0] tanimoto_delay = 5;
    reg [6:0] gnn_delay = 60;
    reg [6:0] admet_delay = 20;
    integer tanimoto_launch_count = 0;
    integer phase = 0;
    reg [31:0] tanimoto_similarity = 0;

    wire tanimoto_busy = tanimoto_countdown != 0;
    wire tanimoto_valid = release_core_valid && tanimoto_countdown == 1;
    wire gnn_busy = gnn_countdown != 0;
    wire gnn_valid = release_core_valid && gnn_countdown == 1;
    wire admet_busy = admet_countdown != 0;
    wire admet_valid = release_core_valid && admet_countdown == 1;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(task_id), .task_flags(32'd0),
        .task_item_count(task_item_count), .task_sequence(task_sequence),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_status(done_status), .done_result_words(done_result_words),
        .done_detail(done_detail), .done_sequence(done_sequence),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .abort(1'b0),
        .engine_busy(engine_busy), .engine_start(engine_start),
        .engine_done(engine_done),
        .tanimoto_start(), .fingerprint_we(), .fingerprint_db_select(),
        .fingerprint_addr(), .fingerprint_wdata(),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(tanimoto_similarity),
        .gnn_start(), .gnn_feature_we(), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'h474e_4e31),
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
            tanimoto_launch_count <= 0;
            tanimoto_similarity <= 0;
            overlap_seen <= 0;
            seen_start <= 0;
            seen_done <= 0;
        end else begin
            if (&engine_busy)
                overlap_seen <= 1'b1;
            seen_start <= seen_start | engine_start;
            seen_done <= seen_done | engine_done;

            if (engine_start[0]) begin
                tanimoto_countdown <= tanimoto_delay;
                tanimoto_launch_count <= tanimoto_launch_count + 1;
                tanimoto_similarity <= 32'h7400_0000 |
                                       (tanimoto_launch_count + 1);
            end else if (tanimoto_countdown > 1) begin
                tanimoto_countdown <= tanimoto_countdown - 1'b1;
            end else if (tanimoto_valid) begin
                tanimoto_countdown <= 0;
            end

            if (engine_start[1])
                gnn_countdown <= gnn_delay;
            else if (gnn_countdown > 1)
                gnn_countdown <= gnn_countdown - 1'b1;
            else if (gnn_valid)
                gnn_countdown <= 0;

            if (engine_start[2])
                admet_countdown <= admet_delay;
            else if (admet_countdown > 1)
                admet_countdown <= admet_countdown - 1'b1;
            else if (admet_valid)
                admet_countdown <= 0;
        end
    end

    task reset_backend;
        begin
            task_valid = 0;
            payload_valid = 0;
            payload_last = 0;
            done_ready = 0;
            result_ready = 0;
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    task submit_task;
        input [7:0] id;
        input [5:0] seq;
        input integer payload_words;
        integer word_index;
        begin
            @(negedge clk);
            task_id = id;
            task_sequence = seq;
            task_item_count = 1;
            task_valid = 1'b1;
            #1;
            while (!task_ready) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            @(negedge clk);
            task_valid = 1'b0;
            payload_valid = 1'b1;
            for (word_index = 0; word_index < payload_words;
                 word_index = word_index + 1) begin
                payload_data = {id, seq, word_index[17:0]};
                payload_last = word_index + 1 == payload_words;
                #1;
                while (!payload_ready) begin
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
                @(negedge clk);
            end
            payload_valid = 1'b0;
            payload_last = 1'b0;
        end
    endtask

    task accept_metadata;
        input [5:0] seq;
        input [31:0] words;
        input integer stall_cycles;
        reg [23:0] held_status;
        reg [31:0] held_words;
        reg [31:0] held_detail;
        reg [5:0] held_sequence;
        integer stall_index;
        begin
            do @(posedge clk); while (done_valid !== 1'b1);
            if (done_sequence !== seq || done_status !== 24'd0 ||
                done_result_words !== words || done_detail !== 32'd0)
                $fatal(1, "metadata seq=%0d status=%h words=%0d detail=%h",
                       done_sequence, done_status, done_result_words,
                       done_detail);
            held_status = done_status;
            held_words = done_result_words;
            held_detail = done_detail;
            held_sequence = done_sequence;
            for (stall_index = 0; stall_index < stall_cycles;
                 stall_index = stall_index + 1) begin
                @(posedge clk);
                if (done_valid !== 1'b1 || done_status !== held_status ||
                    done_result_words !== held_words ||
                    done_detail !== held_detail ||
                    done_sequence !== held_sequence)
                    $fatal(1, "metadata changed under backpressure");
            end
            @(negedge clk);
            done_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            done_ready = 1'b0;
        end
    endtask

    task drain_one_result;
        input [5:0] seq;
        input [31:0] expected;
        input integer stall_cycles;
        integer stall_index;
        reg [31:0] held_data;
        begin
            do @(posedge clk); while (result_valid !== 1'b1);
            if (result_data !== expected || done_sequence !== seq)
                $fatal(1, "result seq=%0d data=%h expected seq=%0d data=%h",
                       done_sequence, result_data, seq, expected);
            held_data = result_data;
            for (stall_index = 0; stall_index < stall_cycles;
                 stall_index = stall_index + 1) begin
                @(posedge clk);
                if (result_valid !== 1'b1 || result_data !== held_data ||
                    done_sequence !== seq)
                    $fatal(1, "result/source changed under backpressure");
            end
            @(negedge clk);
            result_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            result_ready = 1'b0;
        end
    endtask

    task drain_admet_results;
        input [5:0] seq;
        integer word_index;
        begin
            @(negedge clk);
            result_ready = 1'b1;
            for (word_index = 1; word_index <= 4;
                 word_index = word_index + 1) begin
                while (result_valid !== 1'b1)
                    @(negedge clk);
                if (result_data !== word_index || done_sequence !== seq)
                    $fatal(1, "ADMET result seq=%0d word=%0d data=%h",
                           done_sequence, word_index, result_data);
                @(posedge clk);
                @(negedge clk);
            end
            result_ready = 1'b0;
        end
    endtask

    initial begin
        reset_backend();
        phase = 1;

        // Independent completion order plus metadata and result backpressure.
        release_core_valid = 1;
        tanimoto_delay = 5;
        admet_delay = 20;
        gnn_delay = 60;
        submit_task(`MOL_DMA_TASK_GNN, 6'd10, 1);
        submit_task(`MOL_DMA_TASK_ADMET, 6'd11, 20);
        submit_task(`MOL_DMA_TASK_TANIMOTO, 6'd12, 1);
        phase = 11;
        repeat (2) @(posedge clk);
        if (!overlap_seen)
            $fatal(1, "engines never overlapped busy=%03b", engine_busy);

        accept_metadata(6'd12, 1, 3);
        phase = 12;
        drain_one_result(6'd12, 32'h7400_0001, 12);
        phase = 13;
        if (seen_done[2] !== 1'b1)
            $fatal(1, "ADMET did not finish while Tanimoto result stalled");
        accept_metadata(6'd11, 4, 2);
        phase = 14;
        drain_admet_results(6'd11);
        phase = 15;
        accept_metadata(6'd10, 1, 2);
        phase = 16;
        drain_one_result(6'd10, 32'h474e_4e31, 2);
        phase = 17;
        if (seen_start !== 3'b111 || seen_done !== 3'b111)
            $fatal(1, "engine events start=%03b done=%03b",
                   seen_start, seen_done);

        // A zero-word completion retires at metadata acceptance without a
        // phantom result transfer or a permanently busy lane.
        submit_task(`MOL_DMA_TASK_TANIMOTO, 6'd20, 1);
        phase = 2;
        do @(posedge clk); while (done_valid !== 1'b1);
        force dut.tani_lane.result_words_reg = 0;
        accept_metadata(6'd20, 0, 2);
        release dut.tani_lane.result_words_reg;
        repeat (3) @(posedge clk);
        if (done_valid !== 1'b0 || result_valid !== 1'b0 ||
            engine_busy[0] !== 1'b0)
            $fatal(1, "zero-word completion did not retire");

        // Make all three completions pending together. Round-robin starts at
        // Tanimoto, then must service GNN before ADMET. Replenishing Tanimoto
        // while GNN is stalled must not let it jump ahead of ADMET.
        reset_backend();
        phase = 3;
        release_core_valid = 0;
        tanimoto_delay = 6;
        gnn_delay = 6;
        admet_delay = 6;
        submit_task(`MOL_DMA_TASK_ADMET, 6'd30, 20);
        submit_task(`MOL_DMA_TASK_GNN, 6'd31, 1);
        submit_task(`MOL_DMA_TASK_TANIMOTO, 6'd32, 1);
        wait (tanimoto_countdown == 1 && gnn_countdown == 1 &&
              admet_countdown == 1);
        release_core_valid = 1;
        repeat (3) @(posedge clk);

        accept_metadata(6'd32, 1, 1);
        phase = 4;
        drain_one_result(6'd32, 32'h7400_0001, 1);
        submit_task(`MOL_DMA_TASK_TANIMOTO, 6'd33, 1);
        accept_metadata(6'd31, 1, 1);
        drain_one_result(6'd31, 32'h474e_4e31, 8);
        accept_metadata(6'd30, 4, 1);
        drain_admet_results(6'd30);
        accept_metadata(6'd33, 1, 1);
        drain_one_result(6'd33, 32'h7400_0002, 1);

        $display("PASS parallel DMA backpressure, fairness and zero-word retirement");
        $finish;
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1, "timeout phase=%0d task=%0d ready=%b route=%0d payload=%b/%b/%b index=%0d lanes=%b/%b/%b busy=%03b owner=%0d counts=%0d/%0d/%0d",
               phase, task_id, task_ready, dut.ingress_route,
               payload_valid, payload_ready, payload_last,
               dut.admet_lane.payload_index,
               dut.tani_task_ready,
               dut.gnn_task_ready_i, dut.admet_task_ready_i,
               engine_busy, dut.completion_owner,
               tanimoto_countdown, gnn_countdown, admet_countdown);
    end
endmodule
