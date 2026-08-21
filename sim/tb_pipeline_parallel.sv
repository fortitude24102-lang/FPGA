`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_pipeline_parallel;
    localparam [7:0] PIPELINE_ID = `MOL_DMA_TASK_PIPELINE;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg task_valid = 1'b0;
    wire task_ready;
    reg [7:0] task_id = PIPELINE_ID;
    reg [31:0] task_flags = 0;
    reg [31:0] task_item_count = 2;
    reg payload_valid = 1'b0;
    wire payload_ready;
    reg [31:0] payload_data = 0;
    reg payload_last = 1'b0;
    reg done_ready = 1'b0;
    reg result_ready = 1'b0;
    reg abort = 1'b0;
    wire done_valid, result_valid;
    wire [23:0] done_status;
    wire [31:0] done_result_words, done_detail, result_data;
    wire [2:0] engine_start;
    wire fingerprint_we, gnn_feature_we, gnn_adjacency_we, descriptor_we;
    wire tani_write_bank, tani_run_bank;
    wire gnn_write_bank, gnn_run_bank;
    wire admet_write_bank, admet_run_bank;

    integer cycles = 0;
    integer launch_count = 0;
    integer tani_start_cycle [0:2];
    integer gnn_start_cycle [0:2];
    integer admet_start_cycle [0:2];
    integer tani_countdown = 0;
    integer gnn_countdown = 0;
    integer admet_countdown = 0;
    integer tani_delay = 2100;
    integer gnn_delay = 2300;
    integer admet_delay = 2500;
    integer tani_done_cycle = -1;
    integer gnn_done_cycle = -1;
    integer admet_done_cycle = -1;
    integer stranded_ready_cycles = 0;
    reg saw_tani_bank1_write = 0;
    reg saw_gnn_bank1_write = 0;
    reg saw_admet_bank1_write = 0;
    reg [63:0] prediction_value = 64'h0004_0003_0002_0001;

    wire tanimoto_busy = tani_countdown != 0;
    wire tanimoto_valid = tani_countdown == 1;
    wire gnn_busy = gnn_countdown != 0;
    wire gnn_valid = gnn_countdown == 1;
    wire admet_busy = admet_countdown != 0;
    wire admet_valid = admet_countdown == 1;

    dma_accelerator_backend dut (
        .clk(clk), .rst_n(rst_n),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_id(task_id), .task_flags(task_flags),
        .task_item_count(task_item_count), .task_user_tag(32'd0),
        .task_sequence(6'd7),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_status(done_status), .done_result_words(done_result_words),
        .done_detail(done_detail), .done_sequence(),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .abort(abort),
        .engine_busy(), .engine_start(engine_start), .engine_done(),
        .tanimoto_start(), .fingerprint_we(fingerprint_we),
        .fingerprint_db_select(), .fingerprint_addr(), .fingerprint_wdata(),
        .tanimoto_input_write_bank(tani_write_bank),
        .tanimoto_input_run_bank(tani_run_bank),
        .tanimoto_busy(tanimoto_busy), .tanimoto_valid(tanimoto_valid),
        .tanimoto_similarity(32'h1111_0001),
        .gnn_start(), .gnn_input_write_bank(gnn_write_bank),
        .gnn_input_run_bank(gnn_run_bank),
        .gnn_feature_we(gnn_feature_we), .gnn_feature_addr(),
        .gnn_feature_wdata(), .gnn_feature_wstrb(),
        .gnn_adjacency_we(gnn_adjacency_we), .gnn_adjacency_addr(),
        .gnn_adjacency_wdata(), .gnn_adjacency_wstrb(),
        .gnn_output_re(), .gnn_output_addr(),
        .gnn_output_rdata(32'h2222_0001),
        .gnn_busy(gnn_busy), .gnn_valid(gnn_valid),
        .gnn_weight_we(), .gnn_weight_addr(), .gnn_weight_wdata(),
        .admet_start(), .admet_input_write_bank(admet_write_bank),
        .admet_input_run_bank(admet_run_bank),
        .descriptor_we(descriptor_we), .descriptor_addr(),
        .descriptor_wdata(), .admet_busy(admet_busy),
        .admet_valid(admet_valid), .admet_predictions(prediction_value),
        .admet_cfg_we(), .admet_cfg_model(), .admet_cfg_layer(),
        .admet_cfg_addr(), .admet_cfg_wdata()
    );

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (!rst_n) begin
            launch_count <= 0;
            tani_countdown <= 0;
            gnn_countdown <= 0;
            admet_countdown <= 0;
            tani_done_cycle <= -1;
            gnn_done_cycle <= -1;
            admet_done_cycle <= -1;
            stranded_ready_cycles <= 0;
            saw_tani_bank1_write <= 0;
            saw_gnn_bank1_write <= 0;
            saw_admet_bank1_write <= 0;
        end else if (|engine_start) begin
            if (task_id == PIPELINE_ID && engine_start !== 3'b111)
                $fatal(1, "non-atomic Pipeline start %03b", engine_start);
            if (task_id == PIPELINE_ID && launch_count == 0 &&
                (!descriptor_we || admet_write_bank != admet_run_bank))
                $fatal(1, "final registered write tag missing on launch we=%b bank=%b/%b",
                       descriptor_we, admet_write_bank, admet_run_bank);
            tani_start_cycle[launch_count] <= cycles;
            gnn_start_cycle[launch_count] <= cycles;
            admet_start_cycle[launch_count] <= cycles;
            if (engine_start[0]) tani_countdown <= tani_delay;
            if (engine_start[1]) gnn_countdown <= gnn_delay;
            if (engine_start[2]) admet_countdown <= admet_delay;
            prediction_value <= launch_count == 0 ?
                64'h0004_0003_0002_0001 : 64'h000e_000d_000c_000b;
            launch_count <= launch_count + 1;
        end else begin
            if (tani_countdown != 0) tani_countdown <= tani_countdown - 1;
            if (gnn_countdown != 0) gnn_countdown <= gnn_countdown - 1;
            if (admet_countdown != 0) admet_countdown <= admet_countdown - 1;
        end

        if (tanimoto_valid) tani_done_cycle <= cycles;
        if (gnn_valid) gnn_done_cycle <= cycles;
        if (admet_valid) admet_done_cycle <= cycles;

        if ((dut.exclusive_lane.state == 4'd1 ||
             dut.exclusive_lane.state == 4'd4 ||
             dut.exclusive_lane.state == 4'd6) &&
            !dut.exclusive_lane.input_compute_running &&
            dut.exclusive_lane.input_bank_ready != 0)
            stranded_ready_cycles <= stranded_ready_cycles + 1;
        else
            stranded_ready_cycles <= 0;
        if (stranded_ready_cycles > 1)
            $fatal(1, "ready bank remained stranded without a running compute");

        if (tanimoto_busy && !engine_start[0] && fingerprint_we &&
            tani_write_bank == tani_run_bank)
            $fatal(1, "wrote active Tanimoto bank %0d", tani_run_bank);
        if (gnn_busy && !engine_start[1] &&
            (gnn_feature_we || gnn_adjacency_we) &&
            gnn_write_bank == gnn_run_bank)
            $fatal(1, "wrote active GNN bank %0d", gnn_run_bank);
        if (admet_busy && !engine_start[2] && descriptor_we &&
            admet_write_bank == admet_run_bank)
            $fatal(1, "wrote active ADMET bank %0d", admet_run_bank);

        if (tanimoto_busy && fingerprint_we && tani_write_bank)
            saw_tani_bank1_write <= 1'b1;
        if (gnn_busy && (gnn_feature_we || gnn_adjacency_we) && gnn_write_bank)
            saw_gnn_bank1_write <= 1'b1;
        if (admet_busy && descriptor_we && admet_write_bank)
            saw_admet_bank1_write <= 1'b1;
    end

    task reset_backend;
        begin
            rst_n = 1'b0;
            task_valid = 1'b0;
            payload_valid = 1'b0;
            payload_last = 1'b0;
            done_ready = 1'b0;
            result_ready = 1'b0;
            abort = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    task start_task;
        input integer items;
        begin
            task_item_count = items;
            task_valid = 1'b1;
            while (!task_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            task_valid = 1'b0;
        end
    endtask

    task send_word;
        input integer word_index;
        input integer total_words;
        begin
            payload_data = word_index;
            payload_last = word_index + 1 == total_words;
            payload_valid = 1'b1;
            while (!payload_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin : test
        integer word_index;
        integer result_index;
        reg [31:0] expected;
        reset_backend();
        task_id = PIPELINE_ID;
        task_flags = 0;
        tani_delay = 2100;
        gnn_delay = 2300;
        admet_delay = 2500;
        start_task(2);
        for (word_index = 0; word_index < 3526; word_index = word_index + 1)
            send_word(word_index, 3526);
        payload_valid = 1'b0;
        payload_last = 1'b0;

        wait (done_valid);
        if (done_result_words != 8 || launch_count != 2)
            $fatal(1, "metadata words=%0d launches=%0d",
                   done_result_words, launch_count);
        if (!saw_tani_bank1_write || !saw_gnn_bank1_write ||
            !saw_admet_bank1_write)
            $fatal(1, "inactive-bank writes missing tani/gnn/admet=%b/%b/%b",
                   saw_tani_bank1_write, saw_gnn_bank1_write,
                   saw_admet_bank1_write);
        if (tani_done_cycle == gnn_done_cycle ||
            tani_done_cycle == admet_done_cycle ||
            gnn_done_cycle == admet_done_cycle)
            $fatal(1, "core completions were not staggered %0d/%0d/%0d",
                   tani_done_cycle, gnn_done_cycle, admet_done_cycle);
        @(negedge clk);
        done_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        done_ready = 1'b0;

        for (result_index = 0; result_index < 8;
             result_index = result_index + 1) begin
            while (!result_valid) @(negedge clk);
            expected = result_index < 4 ? result_index + 1 : result_index + 7;
            if (result_data !== expected)
                $fatal(1, "result order index=%0d data=%h expected=%h",
                       result_index, result_data, expected);
            if (result_index == 4) repeat (5) @(negedge clk);
            result_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            result_ready = 1'b0;
        end

        // FULL N>1 is shape-valid at the frontend but rejected here before
        // any numerical core starts; no giant multi-item result RAM exists.
        reset_backend();
        task_id = PIPELINE_ID;
        task_flags = `MOL_DMA_FLAG_FULL_GNN_OUTPUT;
        start_task(2);
        for (word_index = 0; word_index < 3526; word_index = word_index + 1)
            send_word(word_index, 3526);
        payload_valid = 1'b0;
        payload_last = 1'b0;
        wait (done_valid);
        if (done_status != 24'd11 || done_detail != 32'h4655_4c4c ||
            done_result_words != 0 || launch_count != 0)
            $fatal(1, "batched FULL status=%h detail=%h words=%0d",
                   done_status, done_detail, done_result_words);

        // GNN FULL N>1 has the same deterministic service-layer rejection.
        reset_backend();
        task_id = `MOL_DMA_TASK_GNN;
        task_flags = `MOL_DMA_FLAG_FULL_GNN_OUTPUT;
        start_task(2);
        for (word_index = 0; word_index < 3358; word_index = word_index + 1)
            send_word(word_index, 3358);
        payload_valid = 1'b0;
        payload_last = 1'b0;
        wait (done_valid);
        if (done_status != 24'd11 || done_detail != 32'h4655_4c4c ||
            done_result_words != 0 || launch_count != 0)
            $fatal(1, "GNN batched FULL status=%h detail=%h words=%0d launches=%0d",
                   done_status, done_detail, done_result_words, launch_count);

        // Abort clears every ping-pong latch. Late core-valid pulses cannot
        // recreate a completion or a result.
        reset_backend();
        task_id = PIPELINE_ID;
        task_flags = 0;
        tani_delay = 10000;
        gnn_delay = 10000;
        admet_delay = 10000;
        start_task(1);
        for (word_index = 0; word_index < 1763; word_index = word_index + 1)
            send_word(word_index, 1763);
        payload_valid = 1'b0;
        payload_last = 1'b0;
        wait (launch_count == 1);
        @(negedge clk);
        abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        tani_countdown = 1;
        gnn_countdown = 1;
        admet_countdown = 1;
        repeat (5) @(posedge clk);
        if (done_valid || result_valid ||
            dut.exclusive_lane.input_compute_running ||
            dut.exclusive_lane.summary_capture_pending ||
            dut.exclusive_lane.pipeline_done_mask != 0 ||
            dut.exclusive_lane.input_bank_occupied != 0 ||
            dut.exclusive_lane.input_bank_ready != 0 ||
            dut.exclusive_lane.input_bank_loading ||
            dut.exclusive_lane.item_payload_index != 0 ||
            dut.exclusive_lane.loaded_items != 0 ||
            dut.exclusive_lane.completed_items != 0 ||
            dut.exclusive_lane.result_valid_reg)
            $fatal(1, "abort left ping-pong work live");

        // Complete item 0, then accept item 1's final word on the exact cycle
        // its summary capture retires. Item 1 must dispatch on a later cycle.
        reset_backend();
        task_id = PIPELINE_ID;
        task_flags = 0;
        tani_delay = 10000;
        gnn_delay = 10000;
        admet_delay = 10000;
        start_task(2);
        for (word_index = 0; word_index < 3525; word_index = word_index + 1)
            send_word(word_index, 3526);
        tani_countdown = 1;
        gnn_countdown = 1;
        admet_countdown = 1;
        wait (dut.exclusive_lane.summary_capture_pending);
        wait (dut.exclusive_lane.summary_capture_wait == 0);
        send_word(3525, 3526);
        payload_valid = 1'b0;
        payload_last = 1'b0;
        begin : race_dispatch_wait
            repeat (8) begin
                @(posedge clk);
                if (launch_count == 2)
                    disable race_dispatch_wait;
            end
        end
        if (launch_count != 2)
            $fatal(1, "ready bank was stranded by final-word/capture race");

        // A third item cannot overwrite either of two occupied banks.
        reset_backend();
        task_id = PIPELINE_ID;
        task_flags = 0;
        tani_delay = 10000;
        gnn_delay = 10000;
        admet_delay = 10000;
        start_task(3);
        for (word_index = 0; word_index < 3526; word_index = word_index + 1)
            send_word(word_index, 5289);
        payload_data = 32'hfeed_0000;
        payload_last = 1'b0;
        payload_valid = 1'b1;
        repeat (8) begin
            @(negedge clk);
            if (payload_ready)
                $fatal(1, "payload was not stalled with both banks occupied");
        end

        $display("PASS Pipeline atomic starts, ping-pong writes, order and backpressure");
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "timeout launches=%0d state=%0d loaded=%0d completed=%0d",
               launch_count, dut.exclusive_lane.state,
               dut.exclusive_lane.loaded_items,
               dut.exclusive_lane.completed_items);
    end
endmodule
