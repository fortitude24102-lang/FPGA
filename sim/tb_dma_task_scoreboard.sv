`timescale 1ns/1ps

`include "mol_dma_protocol.vh"

module tb_dma_task_scoreboard;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg in_batch_valid = 1'b0;
    wire in_batch_ready;
    reg [31:0] in_batch_id = 0;
    reg [31:0] in_batch_task_count = 0;
    reg [31:0] in_batch_max_result_words = 0;
    reg in_task_valid = 1'b0;
    wire in_task_ready;
    reg [31:0] in_task_job_id = 0;
    reg [7:0] in_task_id = 0;
    reg [31:0] in_task_flags = 0;
    reg [31:0] in_task_result_capacity_words = 0;
    reg [31:0] in_task_user_tag = 0;
    reg in_payload_valid = 1'b0;
    wire in_payload_ready;
    reg [31:0] in_payload_data = 0;
    reg in_payload_last = 1'b0;
    reg in_end_valid = 1'b0;
    wire in_end_ready;

    wire fmt_result_valid;
    reg fmt_result_ready = 1'b1;
    wire [31:0] fmt_result_job_id;
    wire [7:0] fmt_result_task_id;
    wire [23:0] fmt_result_status;
    wire [31:0] fmt_result_words;
    wire [31:0] fmt_result_user_tag;
    wire [31:0] fmt_result_detail;
    wire fmt_result_data_valid;
    reg fmt_result_data_ready = 1'b1;
    wire [31:0] fmt_result_data;
    wire fmt_finish_valid;
    wire [31:0] fmt_finish_completed_count;
    wire [31:0] fmt_finish_error_count;
    wire [31:0] fmt_finish_first_error_job_id;

    wire backend_task_valid;
    reg backend_task_ready = 1'b1;
    wire [7:0] backend_task_id;
    wire [5:0] backend_task_sequence;
    wire backend_payload_valid;
    reg backend_payload_ready = 1'b1;
    reg backend_done_valid = 1'b0;
    wire backend_done_ready;
    reg [23:0] backend_done_status = 0;
    reg [31:0] backend_done_result_words = 0;
    reg [31:0] backend_done_detail = 0;
    reg [5:0] backend_done_sequence = 0;
    reg backend_result_valid = 1'b0;
    wire backend_result_ready;
    reg [31:0] backend_result_data = 0;

    dma_task_queue #(.DEFAULT_TIMEOUT_CYCLES(32'd100000)) dut (
        .clk(clk), .rst_n(resetn),
        .in_batch_valid(in_batch_valid), .in_batch_ready(in_batch_ready),
        .in_batch_id(in_batch_id), .in_batch_task_count(in_batch_task_count),
        .in_batch_flags(32'd0),
        .in_batch_max_result_words(in_batch_max_result_words),
        .in_batch_status(8'd0), .in_batch_detail(32'd0),
        .in_task_valid(in_task_valid), .in_task_ready(in_task_ready),
        .in_task_job_id(in_task_job_id), .in_task_id(in_task_id),
        .in_task_flags(in_task_flags), .in_task_payload_words(32'd1),
        .in_task_result_capacity_words(in_task_result_capacity_words),
        .in_task_item_count(32'd1), .in_task_user_tag(in_task_user_tag),
        .in_task_timeout_cycles(32'd100000),
        .in_task_status(8'd0), .in_task_detail(32'd0),
        .in_payload_valid(in_payload_valid), .in_payload_ready(in_payload_ready),
        .in_payload_data(in_payload_data), .in_payload_last(in_payload_last),
        .in_end_valid(in_end_valid), .in_end_ready(in_end_ready),
        .in_end_status(8'd0), .in_end_detail(32'd0),
        .fmt_batch_valid(), .fmt_batch_ready(1'b1), .fmt_batch_id(),
        .fmt_expected_task_count(), .fmt_header_status(),
        .fmt_output_capacity_words(),
        .fmt_result_valid(fmt_result_valid), .fmt_result_ready(fmt_result_ready),
        .fmt_result_reject(1'b0), .fmt_result_job_id(fmt_result_job_id),
        .fmt_result_task_id(fmt_result_task_id),
        .fmt_result_status(fmt_result_status),
        .fmt_result_words(fmt_result_words), .fmt_result_compute_cycles(),
        .fmt_result_item_count(), .fmt_result_user_tag(fmt_result_user_tag),
        .fmt_result_detail(fmt_result_detail),
        .fmt_result_data_valid(fmt_result_data_valid),
        .fmt_result_data_ready(fmt_result_data_ready),
        .fmt_result_data(fmt_result_data),
        .fmt_finish_valid(fmt_finish_valid), .fmt_finish_ready(1'b1),
        .fmt_finish_completed_count(fmt_finish_completed_count),
        .fmt_finish_error_count(fmt_finish_error_count),
        .fmt_finish_batch_status(),
        .fmt_finish_first_error_job_id(fmt_finish_first_error_job_id),
        .fmt_finish_detail(),
        .backend_task_valid(backend_task_valid),
        .backend_task_ready(backend_task_ready),
        .backend_task_id(backend_task_id), .backend_task_flags(),
        .backend_task_item_count(), .backend_task_timeout_cycles(),
        .backend_task_sequence(backend_task_sequence),
        .backend_payload_valid(backend_payload_valid),
        .backend_payload_ready(backend_payload_ready), .backend_payload_data(),
        .backend_payload_last(),
        .backend_done_valid(backend_done_valid),
        .backend_done_ready(backend_done_ready),
        .backend_done_status(backend_done_status),
        .backend_done_result_words(backend_done_result_words),
        .backend_done_detail(backend_done_detail),
        .backend_done_sequence(backend_done_sequence),
        .backend_result_valid(backend_result_valid),
        .backend_result_ready(backend_result_ready),
        .backend_result_data(backend_result_data), .backend_abort(),
        .legacy_active(1'b0), .legacy_start(1'b0), .legacy_reject(),
        .dma_active()
    );

    function automatic [31:0] expected_words;
        input integer ordinal;
        begin
            if (ordinal == 7)
                expected_words = 0;
            else if ((ordinal & 3) >= 2)
                expected_words = 4;
            else
                expected_words = 1;
        end
    endfunction

    function automatic [31:0] expected_data;
        input integer ordinal;
        input integer word_index;
        begin
            expected_data = 32'hD0000000 | (ordinal << 8) | word_index;
        end
    endfunction

    integer phase = 0;
    integer dispatch_count = 0;
    integer result_headers = 0;
    integer result_data_index = 0;
    integer active_result_ordinal = -1;
    integer finish_count = 0;
    reg first_retired = 1'b0;
    reg task65_accepted = 1'b0;

    always @(posedge clk) begin
        if (!resetn) begin
            dispatch_count <= 0;
            result_headers <= 0;
            result_data_index <= 0;
            active_result_ordinal <= -1;
            finish_count <= 0;
            first_retired <= 1'b0;
            task65_accepted <= 1'b0;
        end else begin
            if (backend_task_valid && backend_task_ready) begin
                if ((phase == 0 &&
                     (backend_task_sequence !== dispatch_count[5:0] ||
                      backend_task_id !== (dispatch_count & 3))) ||
                    (phase != 0 &&
                     (backend_task_sequence !== 0 ||
                      backend_task_id !== `MOL_DMA_TASK_GNN)))
                    $fatal(1, "dispatch tag/content mismatch at %0d: seq=%0d id=%0d",
                           dispatch_count, backend_task_sequence, backend_task_id);
                dispatch_count <= dispatch_count + 1;
            end

            if (in_task_valid && in_task_ready && in_task_job_id == 32'h51000040) begin
                if (!first_retired)
                    $fatal(1, "65th task was accepted before an entry retired");
                task65_accepted <= 1'b1;
            end

            if (fmt_result_valid && fmt_result_ready) begin
                if (phase == 0) begin
                    if (fmt_result_job_id !== (32'h51000000 + result_headers) ||
                        fmt_result_task_id !== (result_headers & 3) ||
                        fmt_result_words !== expected_words(result_headers) ||
                        fmt_result_user_tag !==
                            ((32'h51000000 + result_headers) ^ 32'hA5000000) ||
                        fmt_result_status !== (result_headers == 7 ? 24'h000004 : 24'd0) ||
                        fmt_result_detail !==
                            (result_headers == 7 ? 32'hBADD0007 : 32'd0))
                        $fatal(1, "ordered result metadata mismatch at ordinal %0d",
                               result_headers);
                    active_result_ordinal <= result_headers;
                    result_data_index <= 0;
                    result_headers <= result_headers + 1;
                end else begin
                    if (fmt_result_job_id !== 32'h52000000 ||
                        fmt_result_task_id !== `MOL_DMA_TASK_GNN ||
                        fmt_result_status !== 0 || fmt_result_words !== 3200)
                        $fatal(1, "FULL direct result metadata mismatch");
                    active_result_ordinal <= 65;
                    result_data_index <= 0;
                    result_headers <= result_headers + 1;
                end
            end

            if (fmt_result_data_valid && fmt_result_data_ready) begin
                if (phase == 0) begin
                    if (fmt_result_data !==
                        expected_data(active_result_ordinal, result_data_index))
                        $fatal(1, "result content mixed: ordinal=%0d word=%0d got=%08x",
                               active_result_ordinal, result_data_index,
                               fmt_result_data);
                    if (active_result_ordinal == 0 && result_data_index == 0)
                        first_retired <= 1'b1;
                end else if (fmt_result_data !==
                             (32'hE1000000 + result_data_index)) begin
                    $fatal(1, "FULL direct result mismatch word=%0d got=%08x",
                           result_data_index, fmt_result_data);
                end
                result_data_index <= result_data_index + 1;
            end

            if (fmt_finish_valid) begin
                if (phase == 0) begin
                    if (fmt_finish_completed_count !== 65 ||
                        fmt_finish_error_count !== 1 ||
                        fmt_finish_first_error_job_id !== 32'h51000007)
                        $fatal(1, "scoreboard finish counters are wrong");
                end else if (fmt_finish_completed_count !== 1 ||
                             fmt_finish_error_count !== 0) begin
                    $fatal(1, "FULL direct batch finish counters are wrong");
                end
                finish_count <= finish_count + 1;
            end
        end
    end

    task automatic start_batch;
        input [31:0] batch_id;
        input [31:0] task_count;
        input [31:0] max_result_words;
        begin
            @(negedge clk);
            in_batch_id = batch_id;
            in_batch_task_count = task_count;
            in_batch_max_result_words = max_result_words;
            in_batch_valid = 1'b1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 1'b0;
        end
    endtask

    task automatic submit_task;
        input integer ordinal;
        input [31:0] flags;
        input [31:0] result_capacity;
        integer wait_cycles;
        begin
            in_task_job_id = (phase == 0) ?
                             (32'h51000000 + ordinal) : 32'h52000000;
            in_task_id = (phase == 0) ? (ordinal & 3) : `MOL_DMA_TASK_GNN;
            in_task_flags = flags;
            in_task_result_capacity_words = result_capacity;
            in_task_user_tag = in_task_job_id ^ 32'hA5000000;
            in_task_valid = 1'b1;
            wait_cycles = 0;
            while (!in_task_ready && wait_cycles < 500) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 500)
                $fatal(1, "task %0d was not accepted", ordinal);
            @(negedge clk);
            in_task_valid = 1'b0;

            wait_cycles = 0;
            while (!backend_task_valid && wait_cycles < 500) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 500)
                $fatal(1, "task %0d was accepted but never dispatched", ordinal);
            @(negedge clk);

            in_payload_data = 32'hC0000000 + ordinal;
            in_payload_last = 1'b1;
            in_payload_valid = 1'b1;
            while (!in_payload_ready) @(negedge clk);
            @(negedge clk);
            in_payload_valid = 1'b0;
            in_payload_last = 1'b0;
        end
    endtask

    task automatic send_completion;
        input [5:0] seq;
        input [23:0] status;
        input integer word_count;
        input [31:0] detail;
        input integer ordinal;
        integer word_index;
        integer wait_cycles;
        begin
            backend_done_sequence = seq;
            backend_done_status = status;
            backend_done_result_words = word_count;
            backend_done_detail = detail;
            backend_done_valid = 1'b1;
            #1;
            wait_cycles = 0;
            while (!backend_done_ready && wait_cycles < 1000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 1000)
                $fatal(1, "completion sequence %0d remained backpressured", seq);
            @(negedge clk);
            backend_done_valid = 1'b0;

            if (word_count != 0 && backend_done_ready)
                $fatal(1, "done channel did not backpressure during result capture");
            for (word_index = 0; word_index < word_count; word_index = word_index + 1) begin
                backend_result_data = (phase == 0) ?
                                      expected_data(ordinal, word_index) :
                                      (32'hE1000000 + word_index);
                backend_result_valid = 1'b1;
                wait_cycles = 0;
                while (!backend_result_ready && wait_cycles < 1000) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles == 1000)
                    $fatal(1, "result sequence %0d word %0d remained backpressured",
                           seq, word_index);
                @(negedge clk);
                backend_result_valid = 1'b0;
            end
        end
    endtask

    task automatic end_batch;
        begin
            in_end_valid = 1'b1;
            while (!in_end_ready) @(negedge clk);
            @(negedge clk);
            in_end_valid = 1'b0;
        end
    endtask

    integer i;
    integer prior_finish;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;

        start_batch(32'h5C0B0041, 65, 2048);
        for (i = 0; i < 64; i = i + 1)
            submit_task(i, 0, expected_words(i));
        if (dispatch_count != 64)
            $fatal(1, "only %0d of 64 tasks dispatched before completion",
                   dispatch_count);

        in_task_job_id = 32'h51000040;
        in_task_id = 0;
        in_task_flags = 0;
        in_task_result_capacity_words = 1;
        in_task_user_tag = 32'h51000040 ^ 32'hA5000000;
        in_task_valid = 1'b1;
        repeat (5) begin
            @(negedge clk);
            if (in_task_ready)
                $fatal(1, "65th task was not backpressured at occupancy 64");
        end

        send_completion(6'd1, 0, expected_words(1), 0, 1);
        repeat (3) begin
            @(negedge clk);
            if (in_task_ready || fmt_result_valid)
                $fatal(1, "out-of-order sequence 1 retired before sequence 0");
        end

        fmt_result_ready = 1'b0;
        send_completion(6'd0, 0, expected_words(0), 0, 0);
        repeat (3) begin
            @(negedge clk);
            if (!fmt_result_valid || fmt_result_job_id !== 32'h51000000 ||
                in_task_ready)
                $fatal(1, "oldest result header/backpressure was not stable");
        end
        fmt_result_data_ready = 1'b0;
        fmt_result_ready = 1'b1;
        @(negedge clk);
        repeat (3) begin
            @(negedge clk);
            if (!fmt_result_data_valid ||
                fmt_result_data !== expected_data(0, 0) || in_task_ready)
                $fatal(1, "buffered result/backpressure was not stable");
        end
        fmt_result_data_ready = 1'b1;

        while (!task65_accepted) @(negedge clk);
        in_task_valid = 1'b0;
        while (!backend_task_valid) @(negedge clk);
        @(negedge clk);
        in_payload_data = 32'hC0000040;
        in_payload_last = 1'b1;
        in_payload_valid = 1'b1;
        while (!in_payload_ready) @(negedge clk);
        @(negedge clk);
        in_payload_valid = 1'b0;
        in_payload_last = 1'b0;

        for (i = 2; i < 64; i = i + 2) begin
            send_completion(i + 1,
                            (i + 1 == 7) ? 24'h000004 : 24'd0,
                            expected_words(i + 1),
                            (i + 1 == 7) ? 32'hBADD0007 : 32'd0,
                            i + 1);
            send_completion(i, 0, expected_words(i), 0, i);
        end
        send_completion(6'd0, 0, 1, 0, 64);
        end_batch();

        prior_finish = finish_count;
        while (finish_count == prior_finish) @(negedge clk);
        while (!in_batch_ready) @(negedge clk);
        if (result_headers != 65 || !first_retired)
            $fatal(1, "ordered retirement produced %0d of 65 headers",
                   result_headers);
        $display("PASS 64-entry occupancy, 65th backpressure and ordered retirement");

        phase = 1;
        dispatch_count = 0;
        result_headers = 0;
        start_batch(32'h5C0B0F01, 1, 4096);
        submit_task(0, `MOL_DMA_FLAG_FULL_GNN_OUTPUT, 3200);
        fmt_result_ready = 1'b0;
        backend_done_sequence = 0;
        backend_done_status = 0;
        backend_done_result_words = 3200;
        backend_done_detail = 0;
        backend_done_valid = 1'b1;
        while (!backend_done_ready) @(negedge clk);
        @(negedge clk);
        backend_done_valid = 1'b0;
        backend_result_data = 32'hE1000000;
        backend_result_valid = 1'b1;
        repeat (3) begin
            @(negedge clk);
            if (backend_result_ready)
                $fatal(1, "large FULL result was buffered instead of oldest-direct");
        end
        fmt_result_data_ready = 1'b0;
        fmt_result_ready = 1'b1;
        @(negedge clk);
        repeat (3) begin
            @(negedge clk);
            if (backend_result_ready || !fmt_result_data_valid ||
                fmt_result_data !== 32'hE1000000)
                $fatal(1, "FULL direct result ignored formatter backpressure");
        end
        fmt_result_data_ready = 1'b1;
        @(negedge clk);
        backend_result_valid = 1'b0;
        for (i = 1; i < 3200; i = i + 1) begin
            backend_result_data = 32'hE1000000 + i;
            backend_result_valid = 1'b1;
            while (!backend_result_ready) @(negedge clk);
            @(negedge clk);
            backend_result_valid = 1'b0;
        end
        end_batch();
        prior_finish = finish_count;
        while (finish_count == prior_finish) @(negedge clk);
        if (result_headers != 1 || result_data_index != 3200)
            $fatal(1, "FULL direct result did not retire completely");
        $display("PASS oldest one-item FULL direct streaming and backpressure");
        $finish;
    end
endmodule
