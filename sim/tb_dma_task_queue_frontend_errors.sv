`timescale 1ns/1ps

module tb_dma_task_queue_frontend_errors;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg [127:0] s_data = 128'd0;
    reg [15:0] s_keep = 16'd0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg s_last = 1'b0;

    wire batch_valid;
    reg batch_ready = 1'b1;
    wire [31:0] batch_id;
    wire [31:0] batch_task_count;
    wire [31:0] batch_total_words;
    wire [31:0] batch_flags;
    wire [31:0] batch_max_result_words;
    wire [7:0] batch_status;
    wire [31:0] batch_detail;
    wire task_valid;
    reg task_ready = 1'b1;
    wire [31:0] task_job_id;
    wire [7:0] task_id;
    wire [31:0] task_flags;
    wire [31:0] task_payload_words;
    wire [31:0] task_result_capacity_words;
    wire [31:0] task_item_count;
    wire [31:0] task_user_tag;
    wire [31:0] task_timeout_cycles;
    wire [7:0] task_status;
    wire [31:0] task_detail;
    wire payload_valid;
    reg payload_ready = 1'b1;
    wire [31:0] payload_data;
    wire payload_last;
    wire batch_end_valid;
    reg batch_end_ready = 1'b1;
    wire [7:0] batch_end_status;
    wire [31:0] batch_end_detail;
    wire [31:0] batch_observed_words;

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

    reg [31:0] words [0:127];
    integer i;
    integer b;
    integer batch_events;
    integer task_events;
    integer payload_events;
    integer end_events;
    reg [7:0] seen_batch_status;
    reg [7:0] seen_task_status;
    reg [7:0] seen_end_status;
    reg [7:0] task_status_history [0:3];

    localparam [7:0] OK               = 8'd0;
    localparam [7:0] BAD_MAGIC        = 8'd1;
    localparam [7:0] BAD_VERSION      = 8'd2;
    localparam [7:0] BAD_LENGTH       = 8'd3;
    localparam [7:0] BAD_TASK         = 8'd4;
    localparam [7:0] BAD_FLAGS        = 8'd5;
    localparam [7:0] BAD_ITEM_COUNT   = 8'd6;
    localparam [7:0] RESULT_OVERFLOW  = 8'd7;
    localparam [7:0] STREAM_TRUNCATED = 8'd10;

    always @(posedge clk) begin
        if (!resetn) begin
            batch_events <= 0;
            task_events <= 0;
            payload_events <= 0;
            end_events <= 0;
            seen_batch_status <= 8'hFF;
            seen_task_status <= 8'hFF;
            seen_end_status <= 8'hFF;
        end else begin
            if (batch_valid && batch_ready) begin
                batch_events <= batch_events + 1;
                seen_batch_status <= batch_status;
            end
            if (task_valid && task_ready) begin
                task_status_history[task_events] <= task_status;
                task_events <= task_events + 1;
                seen_task_status <= task_status;
            end
            if (payload_valid && payload_ready)
                payload_events <= payload_events + 1;
            if (batch_end_valid && batch_end_ready) begin
                end_events <= end_events + 1;
                seen_end_status <= batch_end_status;
            end
        end
    end

    task automatic reset_case;
        begin
            @(negedge clk);
            resetn = 1'b0;
            s_valid = 1'b0;
            s_last = 1'b0;
            batch_ready = 1'b1;
            task_ready = 1'b1;
            batch_end_ready = 1'b1;
            repeat (4) @(negedge clk);
            resetn = 1'b1;
            repeat (2) @(negedge clk);
            for (i = 0; i < 128; i = i + 1)
                words[i] = 32'd0;
        end
    endtask

    task automatic fill_batch_header;
        input [31:0] magic;
        input [31:0] version_header;
        input [31:0] task_count;
        input [31:0] total_words;
        input [31:0] flags;
        input [31:0] reserved;
        begin
            words[0] = magic;
            words[1] = version_header;
            words[2] = 32'h55AA0001;
            words[3] = task_count;
            words[4] = total_words;
            words[5] = flags;
            words[6] = 32'd256;
            words[7] = reserved;
        end
    endtask

    task automatic fill_task;
        input [31:0] task_and_flags;
        input [31:0] payload_words;
        input [31:0] result_capacity;
        input [31:0] item_count;
        begin
            words[8] = 32'h00000077;
            words[9] = task_and_flags;
            words[10] = payload_words;
            words[11] = result_capacity;
            words[12] = item_count;
            words[13] = 32'hABCD1234;
            words[14] = 32'd0;
            words[15] = 32'd0;
            for (i = 0; i < payload_words && (16 + i) < 128; i = i + 1)
                words[16 + i] = 32'h60000000 + i;
        end
    endtask

    task automatic send_words;
        input integer word_count;
        input integer assert_tlast;
        input [15:0] forced_last_keep;
        integer beat_count;
        integer remaining;
        begin
            beat_count = (word_count + 3) / 4;
            for (b = 0; b < beat_count; b = b + 1) begin
                remaining = word_count - b*4;
                @(negedge clk);
                s_data = {words[b*4 + 3], words[b*4 + 2],
                          words[b*4 + 1], words[b*4 + 0]};
                if (remaining >= 4)
                    s_keep = 16'hFFFF;
                else if (remaining == 3)
                    s_keep = 16'h0FFF;
                else if (remaining == 2)
                    s_keep = 16'h00FF;
                else
                    s_keep = 16'h000F;
                if ((b == beat_count - 1) && (forced_last_keep != 16'd0))
                    s_keep = forced_last_keep;
                s_last = assert_tlast && (b == beat_count - 1);
                s_valid = 1'b1;
                while (!s_ready)
                    @(negedge clk);
                @(negedge clk);
                s_valid = 1'b0;
                s_last = 1'b0;
            end
        end
    endtask

    task automatic expect_case;
        input [8*40-1:0] name;
        input integer expect_task;
        input [7:0] expected_batch;
        input [7:0] expected_task;
        input [7:0] expected_end;
        integer timeout;
        begin
            timeout = 0;
            while ((end_events == 0) && (timeout < 1000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(posedge clk);
            if (timeout == 1000) begin
                $display("FAIL %0s: timeout", name);
                $fatal(1);
            end
            if (batch_events != 1 || task_events != expect_task || end_events != 1 ||
                seen_batch_status !== expected_batch || seen_end_status !== expected_end ||
                (expect_task && (seen_task_status !== expected_task))) begin
                $display("FAIL %0s: counts=%0d/%0d/%0d status=%0d/%0d/%0d",
                         name, batch_events, task_events, end_events,
                         seen_batch_status, seen_task_status, seen_end_status);
                $fatal(1);
            end
            $display("PASS %0s", name);
        end
    endtask

    initial begin
        reset_case();
        batch_ready = 1'b0;
        fill_batch_header(32'hDEADBEEF, 32'h00080001, 1, 8, 0, 0);
        send_words(8, 1, 0);
        repeat (10) @(posedge clk);
        if (end_events != 0) begin
            $display("FAIL bad magic: batch_end preceded blocked batch metadata");
            $fatal(1);
        end
        batch_ready = 1'b1;
        expect_case("bad magic", 0, BAD_MAGIC, 0, BAD_MAGIC);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080002, 1, 8, 0, 0);
        send_words(8, 1, 0);
        expect_case("bad version", 0, BAD_VERSION, 0, BAD_VERSION);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 8, 0, 0);
        send_words(8, 1, 16'hF0FF);
        expect_case("header illegal tkeep", 0, STREAM_TRUNCATED, 0,
                    STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 0, 8, 0, 0);
        send_words(8, 1, 0);
        expect_case("zero task count", 0, BAD_LENGTH, 0, BAD_LENGTH);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 65, 8, 0, 0);
        send_words(8, 1, 0);
        expect_case("large task count", 0, BAD_LENGTH, 0, BAD_LENGTH);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 8, 0, 1);
        send_words(8, 1, 0);
        expect_case("batch reserved", 0, BAD_FLAGS, 0, BAD_FLAGS);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 8, 0, 0);
        words[6] = 32'd23;
        send_words(8, 1, 0);
        expect_case("batch result headers overflow", 0, RESULT_OVERFLOW, 0,
                    RESULT_OVERFLOW);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 18, 0, 0);
        fill_task(32'd9, 2, 1, 1);
        send_words(18, 1, 0);
        expect_case("unknown task", 1, OK, BAD_TASK, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 17, 0, 0);
        fill_task(32'd9, 1, 1, 1);
        send_words(17, 1, 0);
        expect_case("one-word final beat", 1, OK, BAD_TASK, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 16, 0, 0);
        fill_task(32'd9, 0, 1, 1);
        send_words(16, 1, 0);
        expect_case("zero-payload invalid task", 1, OK, BAD_TASK, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'h00000800, 64, 1, 1);
        send_words(80, 1, 0);
        expect_case("unknown task flag", 1, OK, BAD_FLAGS, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'd0, 64, 1, 2);
        send_words(80, 1, 0);
        expect_case("bad item count", 1, OK, BAD_ITEM_COUNT, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 79, 0, 0);
        fill_task(32'd0, 63, 1, 1);
        send_words(79, 1, 0);
        expect_case("bad payload length", 1, OK, BAD_LENGTH, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'd0, 64, 0, 1);
        send_words(80, 1, 0);
        expect_case("result overflow", 1, OK, RESULT_OVERFLOW, OK);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 4553, 0, 0);
        fill_task(32'h000000FE, 4537, 1, 1);
        send_words(16, 1, 0);
        expect_case("reload bad payload length", 1, OK, BAD_LENGTH,
                    STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 4554, 0, 0);
        fill_task(32'h000001FE, 4538, 1, 1);
        send_words(16, 1, 0);
        expect_case("reload bad flags", 1, OK, BAD_FLAGS,
                    STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 4554, 0, 0);
        fill_task(32'h000000FE, 4538, 1, 2);
        send_words(16, 1, 0);
        expect_case("reload bad item count", 1, OK, BAD_ITEM_COUNT,
                    STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'd0, 64, 1, 1);
        send_words(16, 1, 0);
        expect_case("early tlast", 1, OK, OK, STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'd0, 64, 1, 1);
        send_words(80, 0, 0);
        repeat (5) @(posedge clk);
        if (end_events != 0 || !s_ready) begin
            $display("FAIL late tlast: frontend ended before draining to TLAST");
            $fatal(1);
        end
        @(negedge clk);
        s_data = 128'h00000004000000030000000200000001;
        s_keep = 16'hFFFF;
        s_last = 1'b1;
        s_valid = 1'b1;
        while (!s_ready)
            @(negedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        s_last = 1'b0;
        expect_case("late tlast drained", 1, OK, OK, BAD_LENGTH);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 1, 80, 0, 0);
        fill_task(32'd0, 64, 1, 1);
        send_words(80, 1, 16'hF0FF);
        expect_case("illegal tkeep", 1, OK, OK, STREAM_TRUNCATED);

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 2, 89, 1, 0);
        words[6] = 32'd128;
        fill_task(32'd9, 1, 1, 1);
        words[16] = 32'hDEAD0001;
        words[17] = 32'h00000088;
        words[18] = 32'd0;
        words[19] = 32'd64;
        words[20] = 32'd1;
        words[21] = 32'd1;
        words[22] = 32'h1234ABCD;
        words[23] = 32'd0;
        words[24] = 32'd0;
        for (i = 0; i < 64; i = i + 1)
            words[25 + i] = 32'h81000000 + i;
        send_words(89, 1, 0);
        begin : wait_continue_case
            integer timeout;
            timeout = 0;
            while ((end_events == 0) && (timeout < 2000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(posedge clk);
            if (timeout == 2000 || batch_events != 1 || task_events != 2 ||
                payload_events != 64 || end_events != 1 ||
                task_status_history[0] != BAD_TASK ||
                task_status_history[1] != OK || seen_end_status != OK) begin
                $display("FAIL continue-on-error: event=%0d/%0d/%0d/%0d status=%0d/%0d/%0d",
                         batch_events, task_events, payload_events, end_events,
                         task_status_history[0], task_status_history[1], seen_end_status);
                $fatal(1);
            end
            $display("PASS continue-on-error advances to next task");
        end

        reset_case();
        fill_batch_header(32'h4D4F4C51, 32'h00080001, 2, 89, 0, 0);
        words[6] = 32'd128;
        fill_task(32'd9, 1, 1, 1);
        words[16] = 32'hDEAD0001;
        words[17] = 32'h00000088;
        words[18] = 32'd0;
        words[19] = 32'd64;
        words[20] = 32'd1;
        words[21] = 32'd1;
        words[22] = 32'h1234ABCD;
        words[23] = 32'd0;
        words[24] = 32'd0;
        for (i = 0; i < 64; i = i + 1)
            words[25 + i] = 32'h82000000 + i;
        send_words(89, 1, 0);
        begin : wait_stop_case
            integer timeout;
            timeout = 0;
            while ((end_events == 0) && (timeout < 2000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(posedge clk);
            if (timeout == 2000 || batch_events != 1 || task_events != 1 ||
                payload_events != 0 || end_events != 1 ||
                task_status_history[0] != BAD_TASK || seen_end_status != OK) begin
                $display("FAIL stop-on-error: event=%0d/%0d/%0d/%0d status=%0d/%0d",
                         batch_events, task_events, payload_events, end_events,
                         task_status_history[0], seen_end_status);
                $fatal(1);
            end
            $display("PASS stop-on-error drains remaining tasks");
        end

        $display("ALL DMA FRONTEND ERROR TESTS PASSED");
        $finish;
    end
endmodule
