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
    reg [31:0] in_task_payload_words = 1;
    reg [31:0] in_task_result_capacity_words = 0;
    reg [31:0] in_task_item_count = 1;
    reg [31:0] in_task_user_tag = 0;
    reg [31:0] in_task_timeout_cycles = 100000;
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
    wire backend_abort;

    dma_task_queue #(.DEFAULT_TIMEOUT_CYCLES(32'd100000)) dut (
        .clk(clk), .rst_n(resetn),
        .in_batch_valid(in_batch_valid), .in_batch_ready(in_batch_ready),
        .in_batch_id(in_batch_id), .in_batch_task_count(in_batch_task_count),
        .in_batch_flags(32'd0),
        .in_batch_max_result_words(in_batch_max_result_words),
        .in_batch_status(8'd0), .in_batch_detail(32'd0),
        .in_task_valid(in_task_valid), .in_task_ready(in_task_ready),
        .in_task_job_id(in_task_job_id), .in_task_id(in_task_id),
        .in_task_flags(in_task_flags),
        .in_task_payload_words(in_task_payload_words),
        .in_task_result_capacity_words(in_task_result_capacity_words),
        .in_task_item_count(in_task_item_count),
        .in_task_user_tag(in_task_user_tag),
        .in_task_timeout_cycles(in_task_timeout_cycles),
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
        .backend_result_data(backend_result_data), .backend_abort(backend_abort),
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
    integer cycle_watchdog = 0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            cycle_watchdog <= 0;
        else begin
            cycle_watchdog <= cycle_watchdog + 1;
            if (cycle_watchdog > 200000)
                $fatal(1, "global watchdog phase=%0d batch=%0d ingress=%0d retire=%0d occupancy=%0d done=%b/%b fmt=%b complete=%b running=%b direct=%b exclusive=%b guard=%b",
                       phase, dut.batch_state, dut.ingress_state,
                       dut.retire_state, dut.occupancy,
                       backend_done_valid, backend_done_ready,
                       fmt_result_valid, dut.entry_complete[dut.retire_ptr],
                       dut.entry_running[dut.retire_ptr],
                       dut.entry_direct[dut.retire_ptr],
                       dut.direct_exclusive, dut.abort_guard);
        end
    end

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
            if ((phase <= 1) && backend_task_valid && backend_task_ready) begin
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

            if ((phase == 0) && in_task_valid && in_task_ready &&
                in_task_job_id == 32'h51000040) begin
                if (!first_retired)
                    $fatal(1, "65th task was accepted before an entry retired");
                task65_accepted <= 1'b1;
            end

            if ((phase <= 1) && fmt_result_valid && fmt_result_ready) begin
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

            if ((phase <= 1) && fmt_result_data_valid &&
                fmt_result_data_ready) begin
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

            if ((phase <= 1) && fmt_finish_valid) begin
                if (phase == 0) begin
                    if (fmt_finish_completed_count !== 64 ||
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
            #1;
            while (in_end_ready !== 1'b1) @(negedge clk);
            @(posedge clk);
            #1;
            in_end_valid = 1'b0;
        end
    endtask

    task automatic recovery_reset;
        input integer case_number;
        begin
            @(negedge clk);
            resetn = 1'b0;
            phase = 10 + case_number;
            in_batch_valid = 1'b0;
            in_task_valid = 1'b0;
            in_payload_valid = 1'b0;
            in_payload_last = 1'b0;
            in_end_valid = 1'b0;
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            backend_task_ready = 1'b1;
            backend_payload_ready = 1'b1;
            backend_done_valid = 1'b0;
            backend_done_status = 24'd0;
            backend_done_result_words = 32'd0;
            backend_done_detail = 32'd0;
            backend_done_sequence = 6'd0;
            backend_result_valid = 1'b0;
            backend_result_data = 32'd0;
            repeat (4) @(negedge clk);
            resetn = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic allocate_recovery_task;
        input integer ordinal;
        input [7:0] requested_id;
        input [31:0] requested_flags;
        input [31:0] requested_items;
        input [31:0] requested_capacity;
        input [31:0] requested_timeout;
        input [31:0] requested_payload_words;
        integer wait_cycles;
        begin
            @(negedge clk);
            in_task_job_id = 32'h53000000 + ordinal;
            in_task_id = requested_id;
            in_task_flags = requested_flags;
            in_task_payload_words = requested_payload_words;
            in_task_result_capacity_words = requested_capacity;
            in_task_item_count = requested_items;
            in_task_user_tag = 32'hA6000000 + ordinal;
            in_task_timeout_cycles = requested_timeout;
            in_task_valid = 1'b1;
            #1;
            wait_cycles = 0;
            while ((in_task_ready !== 1'b1) && (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "recovery task %0d header remained backpressured",
                       ordinal);
            @(negedge clk);
            in_task_valid = 1'b0;
        end
    endtask

    task automatic dispatch_recovery_payload;
        input integer ordinal;
        input integer payload_words;
        integer word_index;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((backend_task_valid !== 1'b1) &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "recovery task %0d never dispatched ingress=%0d seq=%0d pool=%b exclusive=%b",
                       ordinal, dut.ingress_state, dut.ingress_sequence,
                       dut.pool_valid, dut.direct_exclusive);
            if (backend_task_sequence !== ordinal[5:0])
                $fatal(1, "recovery task %0d got sequence %0d", ordinal,
                       backend_task_sequence);
            @(negedge clk);
            for (word_index = 0; word_index < payload_words;
                 word_index = word_index + 1) begin
                in_payload_data = 32'hC3000000 | (ordinal << 8) | word_index;
                in_payload_last = (word_index + 1 == payload_words);
                in_payload_valid = 1'b1;
                wait_cycles = 0;
                while ((in_payload_ready !== 1'b1) &&
                       (wait_cycles < 2000)) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles == 2000)
                    $fatal(1, "recovery payload %0d/%0d remained backpressured",
                           ordinal, word_index);
                @(negedge clk);
                in_payload_valid = 1'b0;
                in_payload_last = 1'b0;
            end
        end
    endtask

    task automatic submit_recovery_task;
        input integer ordinal;
        input [7:0] requested_id;
        input [31:0] requested_flags;
        input [31:0] requested_items;
        input [31:0] requested_capacity;
        input [31:0] requested_timeout;
        input [31:0] requested_payload_words;
        begin
            allocate_recovery_task(ordinal, requested_id, requested_flags,
                                   requested_items, requested_capacity,
                                   requested_timeout, requested_payload_words);
            dispatch_recovery_payload(ordinal, requested_payload_words);
        end
    endtask

    task automatic raw_completion;
        input [5:0] seq;
        input [23:0] status;
        input integer word_count;
        input [31:0] detail;
        input [31:0] data_base;
        integer word_index;
        integer wait_cycles;
        begin
            @(negedge clk);
            backend_done_sequence = seq;
            backend_done_status = status;
            backend_done_result_words = word_count;
            backend_done_detail = detail;
            backend_done_valid = 1'b1;
            #1;
            wait_cycles = 0;
            while ((backend_done_ready !== 1'b1) &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "raw completion %0d remained backpressured", seq);
            @(negedge clk);
            backend_done_valid = 1'b0;
            for (word_index = 0; word_index < word_count;
                 word_index = word_index + 1) begin
                backend_result_data = data_base + word_index;
                backend_result_valid = 1'b1;
                wait_cycles = 0;
                while ((backend_result_ready !== 1'b1) &&
                       (wait_cycles < 2000)) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles == 2000)
                    $fatal(1, "raw result %0d/%0d remained backpressured",
                           seq, word_index);
                @(negedge clk);
                backend_result_valid = 1'b0;
            end
        end
    endtask

    task automatic expect_recovery_result;
        input [31:0] expected_job;
        input [23:0] expected_status;
        input integer expected_word_count;
        input [31:0] expected_data_base;
        integer word_index;
        integer wait_cycles;
        begin
            fmt_result_ready = 1'b0;
            wait_cycles = 0;
            while ((fmt_result_valid !== 1'b1) &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "result %08x header never appeared", expected_job);
            if (fmt_result_job_id !== expected_job ||
                fmt_result_status !== expected_status ||
                fmt_result_words !== expected_word_count)
                $fatal(1, "result %08x metadata got job=%08x status=%0d words=%0d",
                       expected_job, fmt_result_job_id, fmt_result_status,
                       fmt_result_words);
            @(negedge clk);
            fmt_result_ready = 1'b1;
            @(negedge clk);
            fmt_result_ready = 1'b0;
            for (word_index = 0; word_index < expected_word_count;
                 word_index = word_index + 1) begin
                fmt_result_data_ready = 1'b0;
                wait_cycles = 0;
                while ((fmt_result_data_valid !== 1'b1) &&
                       (wait_cycles < 2000)) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles == 2000)
                    $fatal(1, "result %08x data %0d never appeared",
                           expected_job, word_index);
                if (fmt_result_data !== expected_data_base + word_index)
                    $fatal(1, "result %08x data mixed at %0d: %08x",
                           expected_job, word_index, fmt_result_data);
                @(negedge clk);
                fmt_result_data_ready = 1'b1;
                @(negedge clk);
                fmt_result_data_ready = 1'b0;
            end
        end
    endtask

    task automatic wait_recovery_finish;
        input integer expected_completed;
        input integer expected_errors;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((fmt_finish_valid !== 1'b1) && (wait_cycles < 4000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 4000)
                $fatal(1, "recovery batch never finished occupancy=%0d batch=%0d ingress=%0d retire=%0d ptr=%0d end=%b valid=%b dispatched=%b running=%b complete=%b buffer=%b",
                       dut.occupancy, dut.batch_state, dut.ingress_state,
                       dut.retire_state, dut.retire_ptr, dut.end_pending,
                       dut.entry_valid[dut.retire_ptr],
                       dut.entry_dispatched[dut.retire_ptr],
                       dut.entry_running[dut.retire_ptr],
                       dut.entry_complete[dut.retire_ptr],
                       dut.entry_has_buffer[dut.retire_ptr]);
            if (fmt_finish_completed_count !== expected_completed ||
                fmt_finish_error_count !== expected_errors)
                $fatal(1, "recovery finish got completed=%0d errors=%0d",
                       fmt_finish_completed_count, fmt_finish_error_count);
            @(negedge clk);
        end
    endtask

    task automatic recovery_case_a;
        integer wait_cycles;
        begin
            recovery_reset(1);
            start_batch(32'h5C0BA001, 5, 128);
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 100000, 1);
            submit_recovery_task(1, `MOL_DMA_TASK_GNN, 0, 1, 1,
                                 100000, 1);
            submit_recovery_task(2, `MOL_DMA_TASK_ADMET, 0, 1, 1,
                                 100000, 1);
            submit_recovery_task(3, `MOL_DMA_TASK_PIPELINE, 0, 1, 1,
                                 100000, 1);
            raw_completion(1, 0, 1, 0, 32'hA1000100);
            raw_completion(2, 0, 1, 0, 32'hA1000200);
            raw_completion(3, 0, 1, 0, 32'hA1000300);
            if (dut.pool_valid[3:0] !== 4'b1111)
                $fatal(1, "A: four dispatched small tasks did not own four slots");

            backend_task_ready = 1'b0;
            allocate_recovery_task(4, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                   100000, 1);
            repeat (4) @(negedge clk);
            if (backend_task_valid !== 1'b1)
                $fatal(1, "A RED: fifth younger small task could not use its reserved slot");
            backend_task_ready = 1'b1;
            dispatch_recovery_payload(4, 1);
            raw_completion(4, 0, 1, 0, 32'hA1000400);
            raw_completion(0, 0, 1, 0, 32'hA1000000);
            fmt_result_ready = 1'b1;
            fmt_result_data_ready = 1'b1;
            end_batch();
            wait_recovery_finish(5, 0);
            $display("PASS recovery A: reserved slots break completion-owner deadlock");
        end
    endtask

    task automatic recovery_case_b;
        integer wait_cycles;
        begin
            recovery_reset(2);
            start_batch(32'h5C0BB003, 3, 128);
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 24, 1);
            submit_recovery_task(1, `MOL_DMA_TASK_GNN, 0, 1, 1,
                                 100000, 1);
            raw_completion(1, 0, 1, 0, 32'hB1000100);
            wait_cycles = 0;
            while ((backend_abort !== 1'b1) && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 200)
                $fatal(1, "B: older task did not time out");
            submit_recovery_task(2, `MOL_DMA_TASK_ADMET, 0, 1, 1,
                                 100000, 1);
            raw_completion(2, 0, 1, 0, 32'hB2000200);
            expect_recovery_result(32'h53000000,
                                   `MOL_DMA_STATUS_TASK_TIMEOUT, 0, 0);
            expect_recovery_result(32'h53000001, 0, 1, 32'hB1000100);
            expect_recovery_result(32'h53000002, 0, 1, 32'hB2000200);
            end_batch();
            wait_recovery_finish(3, 1);
            $display("PASS recovery B: timeout preserves completed result buffers");
        end
    endtask

    task automatic recovery_case_c;
        integer wait_cycles;
        begin
            recovery_reset(3);
            start_batch(32'h5C0BC002, 2, 128);
            fmt_result_ready = 1'b1;
            fmt_result_data_ready = 1'b1;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 18, 1);
            allocate_recovery_task(1, `MOL_DMA_TASK_GNN, 0, 1, 1,
                                   100000, 3);
            wait_cycles = 0;
            while ((backend_task_valid !== 1'b1) && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 200)
                $fatal(1, "C: partial-ingress task never dispatched");
            @(negedge clk);
            in_payload_data = 32'hC3000100;
            in_payload_last = 1'b0;
            in_payload_valid = 1'b1;
            while (in_payload_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            in_payload_valid = 1'b0;
            backend_payload_ready = 1'b0;
            wait_cycles = 0;
            while ((backend_abort !== 1'b1) && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 200)
                $fatal(1, "C: concurrent running task did not time out");
            if (in_payload_ready !== 1'b1)
                $fatal(1, "C RED: timeout left partial ingress tied to aborted backend");
            in_payload_data = 32'hC3000101;
            in_payload_last = 1'b0;
            in_payload_valid = 1'b1;
            @(negedge clk);
            in_payload_data = 32'hC3000102;
            in_payload_last = 1'b1;
            @(negedge clk);
            in_payload_valid = 1'b0;
            in_payload_last = 1'b0;
            backend_payload_ready = 1'b1;
            end_batch();
            wait_recovery_finish(2, 2);
            $display("PASS recovery C: abort drains partial ingress and finishes batch");
        end
    endtask

    task automatic recovery_case_d;
        integer word_index;
        integer wait_cycles;
        begin
            recovery_reset(4);
            start_batch(32'h5C0BD002, 2, 4096);
            submit_recovery_task(0, `MOL_DMA_TASK_GNN,
                                 `MOL_DMA_FLAG_FULL_GNN_OUTPUT, 1, 3200,
                                 100000, 1);
            @(negedge clk);
            in_task_job_id = 32'h53000001;
            in_task_id = `MOL_DMA_TASK_TANIMOTO;
            in_task_flags = 0;
            in_task_payload_words = 1;
            in_task_result_capacity_words = 1;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA6000001;
            in_task_timeout_cycles = 6;
            in_task_valid = 1'b1;
            #1;
            if (in_task_ready !== 1'b0)
                $fatal(1, "D RED: younger task entered while FULL direct was active");

            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            backend_done_sequence = 0;
            backend_done_status = 0;
            backend_done_result_words = 3200;
            backend_done_detail = 0;
            backend_done_valid = 1'b1;
            #1;
            while (backend_done_ready !== 1'b1) @(negedge clk);
            @(negedge clk);
            backend_done_valid = 1'b0;
            repeat (12) begin
                @(negedge clk);
                if (backend_abort !== 1'b0)
                    $fatal(1, "D: FULL stream was aborted during header backpressure");
            end
            if (fmt_result_valid !== 1'b1 || fmt_result_words !== 3200)
                $fatal(1, "D: FULL header was not held under backpressure");
            fmt_result_ready = 1'b1;
            @(negedge clk);
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b1;
            for (word_index = 0; word_index < 3200;
                 word_index = word_index + 1) begin
                @(negedge clk);
                backend_result_data = 32'hD4000000 + word_index;
                backend_result_valid = 1'b1;
                wait_cycles = 0;
                while ((backend_result_ready !== 1'b1) &&
                       (wait_cycles < 2000)) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles == 2000)
                    $fatal(1, "D: FULL data stalled at word %0d", word_index);
                @(posedge clk);
                #1;
                backend_result_valid = 1'b0;
            end
            backend_task_ready = 1'b0;
            wait_cycles = 0;
            while ((in_task_ready !== 1'b1) && (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "D: queue did not reopen after FULL retirement");
            @(posedge clk);
            #1;
            in_task_valid = 1'b0;
            backend_task_ready = 1'b1;
            dispatch_recovery_payload(1, 1);
            raw_completion(1, 0, 1, 0, 32'hD4001000);
            fmt_result_ready = 1'b1;
            fmt_result_data_ready = 1'b1;
            end_batch();
            wait_recovery_finish(2, 0);
            $display("PASS recovery D: FULL is exclusive through retirement");
        end
    endtask

    task automatic recovery_case_e;
        integer wait_cycles;
        begin
            recovery_reset(5);
            start_batch(32'h5C0BE002, 2, 128);
            fmt_result_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 100000, 1);
            submit_recovery_task(1, `MOL_DMA_TASK_ADMET, 0, 1, 1,
                                 100000, 1);
            @(negedge clk);
            backend_done_sequence = 0;
            backend_done_status = 0;
            backend_done_result_words = 300;
            backend_done_detail = 32'hBAD00300;
            backend_done_valid = 1'b1;
            #1;
            wait_cycles = 0;
            while ((backend_done_ready !== 1'b1) && (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "E: malformed large completion was not consumed");
            @(negedge clk);
            backend_done_valid = 1'b0;
            if (backend_abort !== 1'b1)
                $fatal(1, "E RED: malformed >256 completion became an unbounded direct stream");
            expect_recovery_result(32'h53000000,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            expect_recovery_result(32'h53000001,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            end_batch();
            wait_recovery_finish(2, 2);
            $display("PASS recovery E: malformed completion aborts all backend owners deterministically");
        end
    endtask

    task automatic recovery_case_f;
        reg [6:0] held_occupancy;
        begin
            recovery_reset(6);
            start_batch(32'h5C0BF001, 1, 128);
            fmt_result_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 100000, 1);
            held_occupancy = dut.occupancy;
            @(negedge clk);
            backend_done_valid = 1'b1;
            backend_done_sequence = 6'bxxxxxx;
            backend_done_result_words = 1;
            backend_done_status = 0;
            backend_done_detail = 0;
            #1;
            if (backend_done_ready !== 1'b0)
                $fatal(1, "F RED: unknown completion sequence did not fail closed");
            backend_done_sequence = 0;
            backend_done_result_words = 32'hxxxxxxxx;
            #1;
            if (backend_done_ready !== 1'b0)
                $fatal(1, "F RED: unknown completion size did not fail closed");
            backend_done_result_words = 1;
            backend_done_status = 24'hxxxxxx;
            #1;
            if (backend_done_ready !== 1'b0 ||
                dut.occupancy !== held_occupancy)
                $fatal(1, "F RED: unknown metadata mutated scoreboard state");
            backend_done_valid = 1'b0;
            backend_done_status = 0;
            backend_done_sequence = 0;
            backend_done_result_words = 1;
            raw_completion(0, 0, 1, 0, 32'hF6000000);
            expect_recovery_result(32'h53000000, 0, 1, 32'hF6000000);
            @(negedge clk);
            backend_done_valid = 1'b1;
            backend_done_sequence = 0;
            #1;
            if (backend_done_ready !== 1'b0 || dut.entry_valid[0] !== 1'b0)
                $fatal(1, "F: late retired completion reacquired sequence ownership");
            backend_done_valid = 1'b0;
            end_batch();
            wait_recovery_finish(1, 0);
            $display("PASS recovery F: completion interface is four-state safe");
        end
    endtask

    task automatic recovery_case_r1;
        begin
            recovery_reset(7);
            start_batch(32'h5C0B7002, 2, 128);
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 100000, 1);

            backend_task_ready = 1'b0;
            allocate_recovery_task(1, `MOL_DMA_TASK_ADMET, 0, 1, 1,
                                   100000, 1);
            if (dut.ingress_state !== 2'd1 ||
                backend_task_valid !== 1'b1)
                $fatal(1, "R1 setup: younger descriptor was not waiting in DISPATCH");

            @(negedge clk);
            backend_done_sequence = 0;
            backend_done_status = 0;
            backend_done_result_words = 300;
            backend_done_detail = 32'hBAD07001;
            backend_done_valid = 1'b1;
            backend_task_ready = 1'b1;
            #1;
            if (backend_done_ready !== 1'b1 ||
                backend_task_valid !== 1'b1)
                $fatal(1, "R1 setup: malformed done and dispatch did not coincide");
            @(posedge clk);
            #1;
            backend_done_valid = 1'b0;
            backend_task_ready = 1'b0;

            if (backend_abort !== 1'b1 ||
                dut.entry_complete[1] !== 1'b1 ||
                dut.entry_result_status[1] !==
                    `MOL_DMA_STATUS_INTERNAL_ERROR ||
                dut.entry_has_buffer[1] !== 1'b0 ||
                dut.pool_valid[1] !== 1'b0)
                $fatal(1, "R1 RED: same-cycle dispatched entry escaped protocol abort");
            if (dut.ingress_state !== 2'd3 || in_payload_ready !== 1'b1)
                $fatal(1, "R1: aborted descriptor did not locally drain its frame");

            @(negedge clk);
            in_payload_data = 32'hC3700100;
            in_payload_last = 1'b1;
            in_payload_valid = 1'b1;
            @(posedge clk);
            #1;
            in_payload_valid = 1'b0;
            in_payload_last = 1'b0;
            if (dut.ingress_state !== 2'd0)
                $fatal(1, "R1: local descriptor drain did not return to IDLE");

            expect_recovery_result(32'h53000000,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            expect_recovery_result(32'h53000001,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            end_batch();
            wait_recovery_finish(2, 2);
            $display("PASS recovery R1: protocol abort owns same-cycle dispatch");
        end
    endtask

    task automatic recovery_case_r2;
        integer wait_cycles;
        begin
            recovery_reset(8);
            start_batch(32'h5C0B8002, 2, 128);
            fmt_result_ready = 1'b0;
            fmt_result_data_ready = 1'b0;
            submit_recovery_task(0, `MOL_DMA_TASK_TANIMOTO, 0, 1, 1,
                                 100000, 1);

            allocate_recovery_task(1, `MOL_DMA_TASK_ADMET, 0, 1, 1,
                                   100000, 1);
            wait_cycles = 0;
            while ((backend_task_valid !== 1'b1) &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 2000)
                $fatal(1, "R2 setup: younger descriptor never dispatched");
            @(posedge clk);
            #1;
            if (dut.ingress_state !== 2'd2)
                $fatal(1, "R2 setup: younger task did not enter PAYLOAD");

            @(negedge clk);
            in_payload_data = 32'hC3800100;
            in_payload_last = 1'b1;
            in_payload_valid = 1'b1;
            backend_done_sequence = 0;
            backend_done_status = 0;
            backend_done_result_words = 300;
            backend_done_detail = 32'hBAD08001;
            backend_done_valid = 1'b1;
            #1;
            if (in_payload_ready !== 1'b1 ||
                backend_done_ready !== 1'b1)
                $fatal(1, "R2 setup: payload_last and malformed done did not coincide");
            @(posedge clk);
            #1;
            in_payload_valid = 1'b0;
            in_payload_last = 1'b0;
            backend_done_valid = 1'b0;

            if (backend_abort !== 1'b1 ||
                dut.entry_complete[1] !== 1'b1 ||
                dut.entry_result_status[1] !==
                    `MOL_DMA_STATUS_INTERNAL_ERROR)
                $fatal(1, "R2: same-cycle payload owner escaped protocol abort");
            if (dut.ingress_state !== 2'd0 ||
                in_payload_ready !== 1'b0)
                $fatal(1, "R2 RED: accepted payload_last left a phantom drain");

            expect_recovery_result(32'h53000000,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            expect_recovery_result(32'h53000001,
                                   `MOL_DMA_STATUS_INTERNAL_ERROR, 0, 0);
            end_batch();
            wait_recovery_finish(2, 2);
            $display("PASS recovery R2: accepted payload_last ends abort drain");
        end
    endtask

    task automatic run_recovery_case;
        input integer case_number;
        begin
            case (case_number)
                1: recovery_case_a();
                2: recovery_case_b();
                3: recovery_case_c();
                4: recovery_case_d();
                5: recovery_case_e();
                6: recovery_case_f();
                7: recovery_case_r1();
                8: recovery_case_r2();
                default: $fatal(1, "unknown recovery case %0d", case_number);
            endcase
        end
    endtask

    integer i;
    integer prior_finish;
    integer selected_recovery_case;
    initial begin
        selected_recovery_case = 0;
        i = $value$plusargs("CASE=%d", selected_recovery_case);
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        if (selected_recovery_case != 0) begin
            run_recovery_case(selected_recovery_case);
            $finish;
        end

        start_batch(32'h5C0B0040, 64, 2048);
        for (i = 0; i < 64; i = i + 1)
            submit_task(i, 0, expected_words(i));
        if (dispatch_count != 64)
            $fatal(1, "only %0d of 64 tasks dispatched before completion",
                   dispatch_count);
        if (dut.pool_valid !== {64{1'b1}})
            $fatal(1, "64 dispatched small tasks did not each reserve a slot");

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

        while (in_task_ready !== 1'b1) @(negedge clk);
        in_task_valid = 1'b0;

        for (i = 2; i < 64; i = i + 2) begin
            send_completion(i + 1,
                            (i + 1 == 7) ? 24'h000004 : 24'd0,
                            expected_words(i + 1),
                            (i + 1 == 7) ? 32'hBADD0007 : 32'd0,
                            i + 1);
            send_completion(i, 0, expected_words(i), 0, i);
        end
        end_batch();

        prior_finish = finish_count;
        while (finish_count == prior_finish) @(negedge clk);
        while (!in_batch_ready) @(negedge clk);
        if (result_headers != 64 || !first_retired)
            $fatal(1, "ordered retirement produced %0d of 64 headers",
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
        #1;
        while (backend_done_ready !== 1'b1) @(negedge clk);
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
        @(posedge clk);
        #1;
        backend_result_valid = 1'b0;
        for (i = 1; i < 3200; i = i + 1) begin
            @(negedge clk);
            backend_result_data = 32'hE1000000 + i;
            backend_result_valid = 1'b1;
            while (!backend_result_ready) @(negedge clk);
            @(posedge clk);
            #1;
            backend_result_valid = 1'b0;
        end
        end_batch();
        prior_finish = finish_count;
        while (finish_count == prior_finish) @(negedge clk);
        if (result_headers != 1 || result_data_index != 3200)
            $fatal(1, "FULL direct result did not retire completely");
        $display("PASS oldest one-item FULL direct streaming and backpressure");
        for (i = 1; i <= 8; i = i + 1)
            run_recovery_case(i);
        $display("ALL SCOREBOARD RECOVERY TESTS PASSED");
        $finish;
    end
endmodule
