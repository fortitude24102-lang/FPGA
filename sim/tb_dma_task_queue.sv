`timescale 1ns/1ps

module tb_dma_task_queue;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg in_batch_valid = 0;
    wire in_batch_ready;
    reg [31:0] in_batch_id = 0;
    reg [31:0] in_batch_task_count = 0;
    reg [31:0] in_batch_flags = 0;
    reg [31:0] in_batch_max_result_words = 0;
    reg [7:0] in_batch_status = 0;
    reg [31:0] in_batch_detail = 0;
    reg in_task_valid = 0;
    wire in_task_ready;
    reg [31:0] in_task_job_id = 0;
    reg [7:0] in_task_id = 0;
    reg [31:0] in_task_flags = 0;
    reg [31:0] in_task_payload_words = 0;
    reg [31:0] in_task_result_capacity_words = 0;
    reg [31:0] in_task_item_count = 0;
    reg [31:0] in_task_user_tag = 0;
    reg [31:0] in_task_timeout_cycles = 0;
    reg [7:0] in_task_status = 0;
    reg [31:0] in_task_detail = 0;
    reg in_payload_valid = 0;
    wire in_payload_ready;
    reg [31:0] in_payload_data = 0;
    reg in_payload_last = 0;
    reg in_end_valid = 0;
    wire in_end_ready;
    reg [7:0] in_end_status = 0;
    reg [31:0] in_end_detail = 0;

    wire fmt_batch_valid;
    reg fmt_batch_ready = 1;
    wire [31:0] fmt_batch_id, fmt_expected_task_count;
    wire [7:0] fmt_header_status;
    wire [31:0] fmt_output_capacity_words;
    wire fmt_result_valid;
    reg fmt_result_ready = 0;
    reg fmt_result_reject = 0;
    wire [31:0] fmt_result_job_id;
    wire [7:0] fmt_result_task_id;
    wire [23:0] fmt_result_status;
    wire [31:0] fmt_result_words;
    wire [63:0] fmt_result_compute_cycles;
    wire [31:0] fmt_result_item_count, fmt_result_user_tag, fmt_result_detail;
    wire fmt_result_data_valid;
    reg fmt_result_data_ready = 0;
    wire [31:0] fmt_result_data;
    wire fmt_finish_valid;
    reg fmt_finish_ready = 1;
    wire [31:0] fmt_finish_completed_count, fmt_finish_error_count;
    wire [31:0] fmt_finish_batch_status, fmt_finish_first_error_job_id;
    wire [31:0] fmt_finish_detail;

    wire backend_task_valid;
    reg backend_task_ready = 1;
    wire [7:0] backend_task_id;
    wire [31:0] backend_task_flags, backend_task_item_count;
    wire [31:0] backend_task_timeout_cycles;
    wire [5:0] backend_task_sequence;
    wire backend_payload_valid;
    reg backend_payload_ready = 0;
    wire [31:0] backend_payload_data;
    wire backend_payload_last;
    reg backend_done_valid = 0;
    wire backend_done_ready;
    reg [23:0] backend_done_status = 0;
    reg [31:0] backend_done_result_words = 0;
    reg [31:0] backend_done_detail = 0;
    reg [5:0] backend_done_sequence = 0;
    reg backend_result_valid = 0;
    wire backend_result_ready;
    reg [31:0] backend_result_data = 0;
    wire backend_abort;

    reg legacy_active = 0;
    reg legacy_start = 0;
    wire legacy_reject, dma_active;

    dma_task_queue #(.DEFAULT_TIMEOUT_CYCLES(100)) dut (
        .clk(clk), .rst_n(resetn),
        .in_batch_valid(in_batch_valid), .in_batch_ready(in_batch_ready),
        .in_batch_id(in_batch_id), .in_batch_task_count(in_batch_task_count),
        .in_batch_flags(in_batch_flags),
        .in_batch_max_result_words(in_batch_max_result_words),
        .in_batch_status(in_batch_status), .in_batch_detail(in_batch_detail),
        .in_task_valid(in_task_valid), .in_task_ready(in_task_ready),
        .in_task_job_id(in_task_job_id), .in_task_id(in_task_id),
        .in_task_flags(in_task_flags),
        .in_task_payload_words(in_task_payload_words),
        .in_task_result_capacity_words(in_task_result_capacity_words),
        .in_task_item_count(in_task_item_count),
        .in_task_user_tag(in_task_user_tag),
        .in_task_timeout_cycles(in_task_timeout_cycles),
        .in_task_status(in_task_status), .in_task_detail(in_task_detail),
        .in_payload_valid(in_payload_valid), .in_payload_ready(in_payload_ready),
        .in_payload_data(in_payload_data), .in_payload_last(in_payload_last),
        .in_end_valid(in_end_valid), .in_end_ready(in_end_ready),
        .in_end_status(in_end_status), .in_end_detail(in_end_detail),
        .fmt_batch_valid(fmt_batch_valid), .fmt_batch_ready(fmt_batch_ready),
        .fmt_batch_id(fmt_batch_id),
        .fmt_expected_task_count(fmt_expected_task_count),
        .fmt_header_status(fmt_header_status),
        .fmt_output_capacity_words(fmt_output_capacity_words),
        .fmt_result_valid(fmt_result_valid), .fmt_result_ready(fmt_result_ready),
        .fmt_result_reject(fmt_result_reject),
        .fmt_result_job_id(fmt_result_job_id),
        .fmt_result_task_id(fmt_result_task_id),
        .fmt_result_status(fmt_result_status),
        .fmt_result_words(fmt_result_words),
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
        .backend_result_data(backend_result_data),
        .backend_abort(backend_abort),
        .legacy_active(legacy_active), .legacy_start(legacy_start),
        .legacy_reject(legacy_reject), .dma_active(dma_active)
    );

    integer cycle_count = 0;
    integer result_records = 0;
    integer result_data_index = 0;
    integer finish_events = 0;
    integer legacy_reject_events = 0;
    integer backend_abort_events = 0;
    integer phase = 0;
    integer i;
    integer backend_task_events = 0;
    reg [31:0] current_result_job = 0;
    reg [31:0] expected_result_words = 0;

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            fmt_result_ready <= 0;
            fmt_result_data_ready <= 0;
            backend_payload_ready <= 0;
            result_records <= 0;
            result_data_index <= 0;
            finish_events <= 0;
            legacy_reject_events <= 0;
            backend_abort_events <= 0;
            backend_task_events <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            fmt_result_ready <= (cycle_count[2:0] != 3'd2);
            fmt_result_data_ready <= (cycle_count[2:0] != 3'd5);
            backend_payload_ready <= (cycle_count[2:0] != 3'd3);
            if (legacy_reject) legacy_reject_events <= legacy_reject_events + 1;
            if (backend_abort) backend_abort_events <= backend_abort_events + 1;
            if (backend_task_valid && backend_task_ready) begin
                backend_task_events <= backend_task_events + 1;
                backend_done_sequence <= backend_task_sequence;
            end
            if (fmt_batch_valid && fmt_batch_ready) begin
                if (phase == 0) begin
                    if (fmt_batch_id != 32'hBA7C0004 ||
                        fmt_expected_task_count != 4 || fmt_header_status != 0 ||
                        fmt_output_capacity_words != 256)
                        $fatal(1);
                end else if (phase == 1) begin
                    if (fmt_batch_id != 32'hBA7C0001 ||
                        fmt_expected_task_count != 1 || fmt_header_status != 0)
                        $fatal(1);
                end else if (phase == 2) begin
                    if (fmt_batch_id != 32'hBA7C0040 ||
                        fmt_expected_task_count != 64 || fmt_header_status != 0 ||
                        fmt_output_capacity_words != 1024)
                        $fatal(1);
                end else if (phase == 3) begin
                    if (fmt_batch_id != 32'hBA7C0E01 ||
                        fmt_expected_task_count != 1 || fmt_header_status != 0)
                        $fatal(1);
                end else begin
                    if (fmt_batch_id != 32'hBA7C0F01 ||
                        fmt_expected_task_count != 1 || fmt_header_status != 0)
                        $fatal(1);
                end
            end
            if (fmt_result_valid && fmt_result_ready) begin
                if (phase == 0) begin
                    if (fmt_result_job_id != 32'h100 + result_records ||
                        fmt_result_task_id != result_records[7:0] ||
                        fmt_result_status != 0 ||
                        fmt_result_words != result_records + 1 ||
                        fmt_result_item_count != 1 ||
                        fmt_result_user_tag != 32'hA0000000 + result_records)
                        $fatal(1);
                end else if (phase == 1) begin
                    if (fmt_result_job_id != 32'h200 || fmt_result_task_id != 1 ||
                        fmt_result_status != 8 || fmt_result_words != 0 ||
                        fmt_result_compute_cycles != 2) begin
                        $display("FAIL timeout result status=%0d words=%0d cycles=%0d",
                                 fmt_result_status, fmt_result_words,
                                 fmt_result_compute_cycles);
                        $fatal(1);
                    end
                end else if (phase == 2) begin
                    if (fmt_result_job_id != 32'h300 + (result_records - 5) ||
                        fmt_result_task_id != ((result_records - 5) & 3) ||
                        fmt_result_status != 0 || fmt_result_words != 1 ||
                        fmt_result_user_tag != 32'hA0000300 + (result_records - 5))
                        $fatal(1);
                end else if (phase == 3) begin
                    if (fmt_result_job_id != 32'h400 || fmt_result_task_id != 9 ||
                        fmt_result_status != 4 || fmt_result_words != 0 ||
                        fmt_result_compute_cycles != 0 ||
                        fmt_result_detail != 32'hBAD00009)
                        $fatal(1);
                end else begin
                    if (fmt_result_job_id != 32'h500 || fmt_result_task_id != 2 ||
                        fmt_result_status != 0 || fmt_result_words != 3)
                        $fatal(1);
                end
                current_result_job <= fmt_result_job_id;
                expected_result_words <= fmt_result_words;
                result_data_index <= 0;
                result_records <= result_records + 1;
            end
            if ((phase == 0) && fmt_result_data_valid && fmt_result_data_ready) begin
                if (fmt_result_data !==
                    (32'hD0000000 + ((current_result_job - 32'h100) << 4) +
                     result_data_index)) begin
                    $display("FAIL queued result data job=%08x index=%0d data=%08x",
                             current_result_job, result_data_index, fmt_result_data);
                    $fatal(1);
                end
                result_data_index <= result_data_index + 1;
            end
            if ((phase == 2) && fmt_result_data_valid && fmt_result_data_ready) begin
                if (fmt_result_data !==
                    (32'hE0000000 + (current_result_job - 32'h300)))
                    $fatal(1);
            end
            if ((phase == 4) && fmt_result_data_valid) begin
                $display("FAIL rejected backend payload leaked to formatter");
                $fatal(1);
            end
            if (fmt_finish_valid && fmt_finish_ready) begin
                if (phase == 0) begin
                    if (fmt_finish_completed_count != 4 ||
                        fmt_finish_error_count != 0 || fmt_finish_batch_status != 0 ||
                        fmt_finish_first_error_job_id != 32'hFFFFFFFF)
                        $fatal(1);
                end else if (phase == 1) begin
                    if (fmt_finish_completed_count != 1 ||
                        fmt_finish_error_count != 1 || fmt_finish_batch_status != 0 ||
                        fmt_finish_first_error_job_id != 32'h200)
                        $fatal(1);
                end else if (phase == 2) begin
                    if (fmt_finish_completed_count != 64 ||
                        fmt_finish_error_count != 0 || fmt_finish_batch_status != 0 ||
                        fmt_finish_first_error_job_id != 32'hFFFFFFFF)
                        $fatal(1);
                end else if (phase == 3) begin
                    if (fmt_finish_completed_count != 1 ||
                        fmt_finish_error_count != 1 || fmt_finish_batch_status != 0 ||
                        fmt_finish_first_error_job_id != 32'h400)
                        $fatal(1);
                end else begin
                    if (fmt_finish_completed_count != 1 ||
                        fmt_finish_error_count != 1 || fmt_finish_batch_status != 0 ||
                        fmt_finish_first_error_job_id != 32'h500)
                        $fatal(1);
                end
                finish_events <= finish_events + 1;
            end
        end
    end

    task automatic send_batch;
        begin
            @(negedge clk);
            in_batch_id = 32'hBA7C0004;
            in_batch_task_count = 4;
            in_batch_flags = 0;
            in_batch_max_result_words = 256;
            in_batch_status = 0;
            in_batch_valid = 1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 0;
        end
    endtask

    task automatic send_rejected_result_batch;
        integer discard_index;
        begin
            @(negedge clk);
            in_batch_id = 32'hBA7C0F01;
            in_batch_task_count = 1;
            in_batch_flags = 0;
            in_batch_max_result_words = 24;
            in_batch_status = 0;
            in_batch_valid = 1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 0;
            in_task_job_id = 32'h500;
            in_task_id = 2;
            in_task_flags = 0;
            in_task_payload_words = 1;
            in_task_result_capacity_words = 3;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA0000500;
            in_task_timeout_cycles = 20;
            in_task_status = 0;
            in_task_detail = 0;
            in_task_valid = 1;
            while (!in_task_ready) @(negedge clk);
            @(negedge clk);
            in_task_valid = 0;
            while (!backend_task_valid) @(negedge clk);
            @(negedge clk);
            in_payload_data = 32'hCF000500;
            in_payload_last = 1;
            in_payload_valid = 1;
            while (!in_payload_ready) @(negedge clk);
            @(negedge clk);
            in_payload_valid = 0;
            in_payload_last = 0;
            fmt_result_reject = 1;
            backend_done_status = 0;
            backend_done_result_words = 3;
            backend_done_detail = 0;
            backend_done_valid = 1;
            while (!backend_done_ready) @(negedge clk);
            @(negedge clk);
            backend_done_valid = 0;
            for (discard_index = 0; discard_index < 3;
                 discard_index = discard_index + 1) begin
                backend_result_data = 32'hEF000000 + discard_index;
                backend_result_valid = 1;
                while (!backend_result_ready) @(negedge clk);
                @(negedge clk);
                backend_result_valid = 0;
            end
            while (!fmt_result_valid) @(negedge clk);
            @(negedge clk);
            fmt_result_reject = 0;
            while (!in_task_ready) @(negedge clk);
            in_end_status = 0;
            in_end_detail = 0;
            in_end_valid = 1;
            while (!in_end_ready) @(negedge clk);
            @(negedge clk);
            in_end_valid = 0;
        end
    endtask

    task automatic send_frontend_error_batch;
        begin
            @(negedge clk);
            in_batch_id = 32'hBA7C0E01;
            in_batch_task_count = 1;
            in_batch_flags = 0;
            in_batch_max_result_words = 64;
            in_batch_status = 0;
            in_batch_valid = 1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 0;
            in_task_job_id = 32'h400;
            in_task_id = 9;
            in_task_flags = 0;
            in_task_payload_words = 0;
            in_task_result_capacity_words = 0;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA0000400;
            in_task_timeout_cycles = 0;
            in_task_status = 4;
            in_task_detail = 32'hBAD00009;
            in_task_valid = 1;
            while (!in_task_ready) @(negedge clk);
            @(negedge clk);
            in_task_valid = 0;
            in_end_status = 0;
            in_end_detail = 0;
            in_end_valid = 1;
            while (!in_end_ready) @(negedge clk);
            @(negedge clk);
            in_end_valid = 0;
        end
    endtask

    task automatic send_stress_task;
        input integer task_number;
        begin
            in_task_job_id = 32'h300 + task_number;
            in_task_id = task_number & 3;
            in_task_flags = 0;
            in_task_payload_words = 1;
            in_task_result_capacity_words = 1;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA0000300 + task_number;
            in_task_timeout_cycles = 20;
            in_task_status = 0;
            in_task_detail = 0;
            in_task_valid = 1;
            while (!in_task_ready) @(negedge clk);
            @(negedge clk);
            in_task_valid = 0;
            while (!backend_task_valid) @(negedge clk);
            @(negedge clk);
            in_payload_data = 32'hCE000000 + task_number;
            in_payload_last = 1;
            in_payload_valid = 1;
            while (!in_payload_ready) @(negedge clk);
            @(negedge clk);
            in_payload_valid = 0;
            in_payload_last = 0;
            backend_done_status = 0;
            backend_done_result_words = 1;
            backend_done_detail = 0;
            backend_done_valid = 1;
            while (!backend_done_ready) @(negedge clk);
            @(negedge clk);
            backend_done_valid = 0;
            backend_result_data = 32'hE0000000 + task_number;
            backend_result_valid = 1;
            while (!backend_result_ready) @(negedge clk);
            @(negedge clk);
            backend_result_valid = 0;
            while (!in_task_ready) @(negedge clk);
        end
    endtask

    task automatic send_stress_batch;
        integer stress_index;
        begin
            @(negedge clk);
            in_batch_id = 32'hBA7C0040;
            in_batch_task_count = 64;
            in_batch_flags = 0;
            in_batch_max_result_words = 1024;
            in_batch_status = 0;
            in_batch_valid = 1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 0;
            for (stress_index = 0; stress_index < 64;
                 stress_index = stress_index + 1)
                send_stress_task(stress_index);
            in_end_status = 0;
            in_end_detail = 0;
            in_end_valid = 1;
            while (!in_end_ready) @(negedge clk);
            @(negedge clk);
            in_end_valid = 0;
        end
    endtask

    task automatic send_timeout_batch;
        begin
            @(negedge clk);
            in_batch_id = 32'hBA7C0001;
            in_batch_task_count = 1;
            in_batch_flags = 0;
            in_batch_max_result_words = 64;
            in_batch_status = 0;
            in_batch_valid = 1;
            while (!in_batch_ready) @(negedge clk);
            @(negedge clk);
            in_batch_valid = 0;

            in_task_job_id = 32'h200;
            in_task_id = 1;
            in_task_flags = 0;
            in_task_payload_words = 1;
            in_task_result_capacity_words = 1;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA0000200;
            in_task_timeout_cycles = 2;
            in_task_status = 0;
            in_task_detail = 0;
            in_task_valid = 1;
            while (!in_task_ready) @(negedge clk);
            @(negedge clk);
            in_task_valid = 0;
            while (!backend_task_valid) @(negedge clk);
            @(negedge clk);
            in_payload_data = 32'hCC000200;
            in_payload_last = 1;
            in_payload_valid = 1;
            while (!in_payload_ready) @(negedge clk);
            @(negedge clk);
            in_payload_valid = 0;
            in_payload_last = 0;

            in_end_status = 0;
            in_end_detail = 0;
            in_end_valid = 1;
            while (!in_end_ready) @(negedge clk);
            @(negedge clk);
            in_end_valid = 0;
        end
    endtask

    task automatic send_task;
        input integer task_number;
        integer payload_index;
        integer result_index;
        begin
            in_task_job_id = 32'h100 + task_number;
            in_task_id = task_number;
            in_task_flags = 0;
            in_task_payload_words = 3;
            in_task_result_capacity_words = task_number + 1;
            in_task_item_count = 1;
            in_task_user_tag = 32'hA0000000 + task_number;
            in_task_timeout_cycles = 50;
            in_task_status = 0;
            in_task_detail = 0;
            in_task_valid = 1;
            while (!in_task_ready) @(negedge clk);
            @(negedge clk);
            in_task_valid = 0;

            while (!backend_task_valid) @(negedge clk);
            if (backend_task_id != task_number || backend_task_item_count != 1)
                $fatal(1);
            @(negedge clk);
            for (payload_index = 0; payload_index < 3; payload_index = payload_index + 1) begin
                in_payload_data = 32'hC0000000 + task_number*16 + payload_index;
                in_payload_last = (payload_index == 2);
                in_payload_valid = 1;
                #1;
                while (!in_payload_ready) @(negedge clk);
                if (!backend_payload_valid || backend_payload_data != in_payload_data ||
                    backend_payload_last != in_payload_last) begin
                    $display("PAYLOAD_BOUNDARY task=%0d idx=%0d in_valid=%0b in_ready=%0b backend_valid=%0b backend_ready=%0b in_data=%08x backend_data=%08x in_last=%0b backend_last=%0b",
                             task_number, payload_index, in_payload_valid,
                             in_payload_ready, backend_payload_valid,
                             backend_payload_ready, in_payload_data,
                             backend_payload_data, in_payload_last,
                             backend_payload_last);
                    $fatal(1);
                end
                @(negedge clk);
                in_payload_valid = 0;
                in_payload_last = 0;
            end

            repeat (task_number + 1) @(negedge clk);
            backend_done_status = 0;
            backend_done_result_words = task_number + 1;
            backend_done_detail = 0;
            backend_done_valid = 1;
            while (!backend_done_ready) @(negedge clk);
            @(negedge clk);
            backend_done_valid = 0;
            for (result_index = 0; result_index < task_number + 1;
                 result_index = result_index + 1) begin
                backend_result_data = 32'hD0000000 + task_number*16 + result_index;
                backend_result_valid = 1;
                while (!backend_result_ready) @(negedge clk);
                @(negedge clk);
                backend_result_valid = 0;
            end
            while (!in_task_ready) @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        send_batch();
        legacy_start = 1;
        @(negedge clk);
        legacy_start = 0;
        send_task(0);
        send_task(1);
        send_task(2);
        send_task(3);
        in_end_status = 0;
        in_end_detail = 0;
        in_end_valid = 1;
        while (!in_end_ready) @(negedge clk);
        @(negedge clk);
        in_end_valid = 0;
        while (!(finish_events == 1 && !dma_active)) @(posedge clk);
        if (result_records != 4 || legacy_reject_events != 1) $fatal(1);
        $display("PASS DMA task queue mixed 0/1/2/3 batch");

        phase = 1;
        send_timeout_batch();
        i = 0;
        while (!(finish_events == 2 && !dma_active) && (i < 200)) begin
            @(posedge clk);
            i = i + 1;
        end
        if (i == 200 || backend_abort_events != 1 || result_records != 5) begin
            $display("FAIL timeout batch did not finish aborts=%0d records=%0d finish=%0d",
                     backend_abort_events, result_records, finish_events);
            $fatal(1);
        end
        $display("PASS DMA task queue timeout and recovery");

        phase = 2;
        send_stress_batch();
        i = 0;
        while (!(finish_events == 3 && !dma_active) && (i < 1000)) begin
            @(posedge clk);
            i = i + 1;
        end
        if (i == 1000 || result_records != 69 || backend_abort_events != 1) begin
            $display("FAIL 64-task stress records=%0d finish=%0d active=%0b",
                     result_records, finish_events, dma_active);
            $fatal(1);
        end
        $display("PASS DMA task queue 64-task stress batch");

        phase = 3;
        send_frontend_error_batch();
        i = 0;
        while (!(finish_events == 4 && !dma_active) && (i < 300)) begin
            @(posedge clk);
            i = i + 1;
        end
        if (i == 300 || result_records != 70 || backend_task_events != 69) begin
            $display("FAIL frontend-error bypass records=%0d finish=%0d backend_tasks=%0d",
                     result_records, finish_events, backend_task_events);
            $fatal(1);
        end
        $display("PASS DMA task queue frontend-error bypass");

        phase = 4;
        send_rejected_result_batch();
        i = 0;
        while (!(finish_events == 5 && !dma_active) && (i < 300)) begin
            @(posedge clk);
            i = i + 1;
        end
        if (i == 300 || result_records != 71 || backend_task_events != 70) begin
            $display("FAIL rejected-result discard records=%0d finish=%0d backend_tasks=%0d",
                     result_records, finish_events, backend_task_events);
            $fatal(1);
        end
        $display("PASS DMA task queue rejected-result discard");
        $finish;
    end
endmodule
