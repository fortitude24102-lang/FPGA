`timescale 1ns/1ps

module tb_dma_task_queue_frontend_tasks;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg [127:0] s_data = 0;
    reg [15:0] s_keep = 0;
    reg s_valid = 0;
    wire s_ready;
    reg s_last = 0;
    wire batch_valid;
    reg batch_ready = 1;
    wire [31:0] batch_id, batch_task_count, batch_total_words;
    wire [31:0] batch_flags, batch_max_result_words, batch_detail;
    wire [7:0] batch_status;
    wire task_valid;
    reg task_ready = 1;
    wire [31:0] task_job_id, task_flags, task_payload_words;
    wire [31:0] task_result_capacity_words, task_item_count, task_user_tag;
    wire [31:0] task_timeout_cycles, task_detail;
    wire [7:0] task_id, task_status;
    wire payload_valid;
    reg payload_ready = 0;
    wire [31:0] payload_data;
    wire payload_last;
    wire batch_end_valid;
    reg batch_end_ready = 1;
    wire [7:0] batch_end_status;
    wire [31:0] batch_end_detail, batch_observed_words;

    dma_task_queue_frontend dut (
        .aclk(clk), .aresetn(resetn),
        .s_axis_job_tdata(s_data), .s_axis_job_tkeep(s_keep),
        .s_axis_job_tvalid(s_valid), .s_axis_job_tready(s_ready),
        .s_axis_job_tlast(s_last),
        .batch_valid(batch_valid), .batch_ready(batch_ready),
        .batch_id(batch_id), .batch_task_count(batch_task_count),
        .batch_total_words(batch_total_words), .batch_flags(batch_flags),
        .batch_max_result_words(batch_max_result_words),
        .batch_status(batch_status), .batch_detail(batch_detail),
        .task_valid(task_valid), .task_ready(task_ready),
        .task_job_id(task_job_id), .task_id(task_id), .task_flags(task_flags),
        .task_payload_words(task_payload_words),
        .task_result_capacity_words(task_result_capacity_words),
        .task_item_count(task_item_count), .task_user_tag(task_user_tag),
        .task_timeout_cycles(task_timeout_cycles),
        .task_status(task_status), .task_detail(task_detail),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .batch_end_valid(batch_end_valid), .batch_end_ready(batch_end_ready),
        .batch_end_status(batch_end_status), .batch_end_detail(batch_end_detail),
        .batch_observed_words(batch_observed_words)
    );

    reg [31:0] words [0:55999];
    integer i, b, cycle_count;
    integer batch_events, task_events, payload_events, end_events;
    reg [7:0] seen_task_id, seen_task_status, seen_batch_status, seen_end_status;

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            payload_ready <= 0;
            batch_events <= 0;
            task_events <= 0;
            payload_events <= 0;
            end_events <= 0;
            seen_task_id <= 8'hFF;
            seen_task_status <= 8'hFF;
            seen_batch_status <= 8'hFF;
            seen_end_status <= 8'hFF;
        end else begin
            cycle_count <= cycle_count + 1;
            payload_ready <= (cycle_count[2:0] != 3'b011);
            if (batch_valid && batch_ready) begin
                batch_events <= batch_events + 1;
                seen_batch_status <= batch_status;
            end
            if (task_valid && task_ready) begin
                task_events <= task_events + 1;
                seen_task_id <= task_id;
                seen_task_status <= task_status;
            end
            if (payload_valid && payload_ready) begin
                if (payload_data !== (32'h70000000 + payload_events)) begin
                    $display("FAIL payload value index=%0d got=%08x", payload_events,
                             payload_data);
                    $fatal(1);
                end
                if (payload_last !== (payload_events + 1 == task_payload_words)) begin
                    $display("FAIL payload_last index=%0d", payload_events);
                    $fatal(1);
                end
                payload_events <= payload_events + 1;
            end
            if (batch_end_valid && batch_end_ready) begin
                end_events <= end_events + 1;
                seen_end_status <= batch_end_status;
            end
        end
    end

    task automatic run_valid_task;
        input [7:0] requested_task_id;
        input [31:0] requested_flags;
        input integer requested_payload_words;
        input integer requested_result_words;
        input integer requested_item_count;
        input [7:0] expected_task_status;
        input [8*24-1:0] name;
        integer total_words;
        integer beat_count;
        integer remaining;
        integer timeout;
        begin
            @(negedge clk);
            resetn = 0;
            s_valid = 0;
            s_last = 0;
            repeat (4) @(negedge clk);
            for (i = 0; i < 56000; i = i + 1)
                words[i] = 0;
            total_words = 16 + requested_payload_words;
            words[0] = 32'h4D4F4C51;
            words[1] = 32'h00080001;
            words[2] = 32'h10000000 + requested_task_id;
            words[3] = 1;
            words[4] = total_words;
            words[5] = 0;
            words[6] = 24 + requested_result_words;
            words[7] = 0;
            words[8] = 32'h20 + requested_task_id;
            words[9] = requested_flags | requested_task_id;
            words[10] = requested_payload_words;
            words[11] = requested_result_words;
            words[12] = requested_item_count;
            words[13] = 32'h90000000 + requested_task_id;
            words[14] = 0;
            words[15] = 0;
            for (i = 0; i < requested_payload_words; i = i + 1)
                words[16 + i] = 32'h70000000 + i;

            resetn = 1;
            repeat (2) @(negedge clk);
            beat_count = (total_words + 3) / 4;
            for (b = 0; b < beat_count; b = b + 1) begin
                remaining = total_words - b*4;
                s_data = {words[b*4 + 3], words[b*4 + 2],
                          words[b*4 + 1], words[b*4 + 0]};
                if (remaining >= 4) s_keep = 16'hFFFF;
                else if (remaining == 3) s_keep = 16'h0FFF;
                else if (remaining == 2) s_keep = 16'h00FF;
                else s_keep = 16'h000F;
                s_last = (b == beat_count - 1);
                s_valid = 1;
                while (!s_ready) @(negedge clk);
                @(negedge clk);
                s_valid = 0;
                s_last = 0;
            end

            timeout = 0;
            while ((end_events == 0) && (timeout < 20000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(posedge clk);
            if (timeout == 20000 || batch_events != 1 || task_events != 1 ||
                payload_events != (expected_task_status == 0 ?
                                   requested_payload_words : 0) ||
                end_events != 1 ||
                seen_batch_status != 0 ||
                seen_task_status != expected_task_status ||
                seen_end_status != 0 || seen_task_id != requested_task_id) begin
                $display("FAIL %0s: event=%0d/%0d/%0d/%0d status=%0d/%0d/%0d id=%0d",
                         name, batch_events, task_events, payload_events, end_events,
                         seen_batch_status, seen_task_status, seen_end_status,
                         seen_task_id);
                $fatal(1);
            end
            $display("PASS %0s payload=%0d", name, requested_payload_words);
        end
    endtask

    initial begin
        run_valid_task(0, 32'h00000000, 64, 1, 1, 0, "Tanimoto pair");
        run_valid_task(1, 32'h00000000, 1679, 1, 1, 0, "GNN summary");
        run_valid_task(1, 32'h00000000, 3358, 2, 2, 0, "GNN two summaries");
        run_valid_task(1, 32'h00000000, 53728, 32, 32, 0, "GNN max batch");
        run_valid_task(1, 32'h00000000, 55407, 33, 33, 6, "GNN rejects 33");
        run_valid_task(2, 32'h00000000, 60, 12, 3, 0, "ADMET three items");
        run_valid_task(3, 32'h00000200, 1763, 6, 1, 0, "Pipeline intermediate");
        run_valid_task(3, 32'h00000000, 3526, 8, 2, 0, "Pipeline two summaries");
        run_valid_task(3, 32'h00000000, 28208, 64, 16, 0, "Pipeline max batch");
        run_valid_task(3, 32'h00000000, 29971, 68, 17, 6,
                       "Pipeline rejects 17");
        run_valid_task(3, 32'h00000300, 1763, 3205, 1, 0,
                       "Pipeline FULL precedence");
        run_valid_task(3, 32'h00000100, 3526, 6410, 2, 0,
                       "Pipeline batched FULL shape");
        run_valid_task(8'hFE, 32'h00000000, 4538, 1, 1, 0, "Weight reload");
        $display("ALL DMA FRONTEND TASK SHAPE TESTS PASSED");
        $finish;
    end
endmodule
