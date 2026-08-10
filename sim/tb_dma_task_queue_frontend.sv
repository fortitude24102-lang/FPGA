`timescale 1ns/1ps

module tb_dma_task_queue_frontend;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg  [127:0] s_axis_job_tdata = 128'd0;
    reg   [15:0] s_axis_job_tkeep = 16'd0;
    reg          s_axis_job_tvalid = 1'b0;
    wire         s_axis_job_tready;
    reg          s_axis_job_tlast = 1'b0;

    wire         batch_valid;
    reg          batch_ready = 1'b0;
    wire [31:0]  batch_id;
    wire [31:0]  batch_task_count;
    wire [31:0]  batch_total_words;
    wire [31:0]  batch_flags;
    wire [31:0]  batch_max_result_words;
    wire [7:0]   batch_status;
    wire [31:0]  batch_detail;

    wire         task_valid;
    reg          task_ready = 1'b0;
    wire [31:0]  task_job_id;
    wire [7:0]   task_id;
    wire [31:0]  task_flags;
    wire [31:0]  task_payload_words;
    wire [31:0]  task_result_capacity_words;
    wire [31:0]  task_item_count;
    wire [31:0]  task_user_tag;
    wire [31:0]  task_timeout_cycles;
    wire [7:0]   task_status;
    wire [31:0]  task_detail;

    wire         payload_valid;
    reg          payload_ready = 1'b0;
    wire [31:0]  payload_data;
    wire         payload_last;

    wire         batch_end_valid;
    reg          batch_end_ready = 1'b0;
    wire [7:0]   batch_end_status;
    wire [31:0]  batch_end_detail;
    wire [31:0]  batch_observed_words;

    dma_task_queue_frontend dut (
        .aclk(clk),
        .aresetn(resetn),
        .s_axis_job_tdata(s_axis_job_tdata),
        .s_axis_job_tkeep(s_axis_job_tkeep),
        .s_axis_job_tvalid(s_axis_job_tvalid),
        .s_axis_job_tready(s_axis_job_tready),
        .s_axis_job_tlast(s_axis_job_tlast),
        .batch_valid(batch_valid),
        .batch_ready(batch_ready),
        .batch_id(batch_id),
        .batch_task_count(batch_task_count),
        .batch_total_words(batch_total_words),
        .batch_flags(batch_flags),
        .batch_max_result_words(batch_max_result_words),
        .batch_status(batch_status),
        .batch_detail(batch_detail),
        .task_valid(task_valid),
        .task_ready(task_ready),
        .task_job_id(task_job_id),
        .task_id(task_id),
        .task_flags(task_flags),
        .task_payload_words(task_payload_words),
        .task_result_capacity_words(task_result_capacity_words),
        .task_item_count(task_item_count),
        .task_user_tag(task_user_tag),
        .task_timeout_cycles(task_timeout_cycles),
        .task_status(task_status),
        .task_detail(task_detail),
        .payload_valid(payload_valid),
        .payload_ready(payload_ready),
        .payload_data(payload_data),
        .payload_last(payload_last),
        .batch_end_valid(batch_end_valid),
        .batch_end_ready(batch_end_ready),
        .batch_end_status(batch_end_status),
        .batch_end_detail(batch_end_detail),
        .batch_observed_words(batch_observed_words)
    );

    reg [31:0] request_words [0:79];
    integer index;
    integer beat;
    integer cycle_count = 0;
    integer batch_events = 0;
    integer task_events = 0;
    integer payload_events = 0;
    integer batch_end_events = 0;
    integer errors = 0;

    task automatic send_valid_tanimoto_batch;
        begin
            request_words[0] = 32'h4D4F4C51;
            request_words[1] = 32'h00080001;
            request_words[2] = 32'h12345678;
            request_words[3] = 32'd1;
            request_words[4] = 32'd80;
            request_words[5] = 32'd0;
            request_words[6] = 32'd128;
            request_words[7] = 32'd0;

            request_words[8]  = 32'h0000002A;
            request_words[9]  = 32'h00000000;
            request_words[10] = 32'd64;
            request_words[11] = 32'd1;
            request_words[12] = 32'd1;
            request_words[13] = 32'hCAFEBABE;
            request_words[14] = 32'd12345;
            request_words[15] = 32'd0;
            for (index = 0; index < 64; index = index + 1)
                request_words[16 + index] = 32'hA5000000 + index;

            for (beat = 0; beat < 20; beat = beat + 1) begin
                @(negedge clk);
                s_axis_job_tdata  = {request_words[beat*4 + 3],
                                     request_words[beat*4 + 2],
                                     request_words[beat*4 + 1],
                                     request_words[beat*4 + 0]};
                s_axis_job_tkeep  = 16'hFFFF;
                s_axis_job_tlast  = (beat == 19);
                s_axis_job_tvalid = 1'b1;
                while (!s_axis_job_tready)
                    @(negedge clk);
                @(negedge clk);
                s_axis_job_tvalid = 1'b0;
                s_axis_job_tlast  = 1'b0;
                repeat (beat % 3) @(negedge clk);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            batch_ready <= 1'b0;
            task_ready <= 1'b0;
            payload_ready <= 1'b0;
            batch_end_ready <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            batch_ready <= (cycle_count > 100) && (cycle_count[1:0] != 2'b00);
            task_ready <= (cycle_count[2:0] != 3'b010);
            payload_ready <= (cycle_count[2:0] != 3'b101);
            batch_end_ready <= (cycle_count[1:0] == 2'b11);

            if (batch_valid && batch_ready) begin
                batch_events <= batch_events + 1;
                if (batch_id !== 32'h12345678 ||
                    batch_task_count !== 32'd1 ||
                    batch_total_words !== 32'd80 ||
                    batch_flags !== 32'd0 ||
                    batch_max_result_words !== 32'd128 ||
                    batch_status !== 8'd0 || batch_detail !== 32'd0) begin
                    $display("FAIL batch metadata");
                    errors <= errors + 1;
                end
            end

            if (task_valid && task_ready) begin
                if (batch_events == 0) begin
                    $display("FAIL task published before batch handshake");
                    $fatal(1);
                end
                task_events <= task_events + 1;
                if (task_job_id !== 32'h0000002A || task_id !== 8'd0 ||
                    task_flags !== 32'd0 || task_payload_words !== 32'd64 ||
                    task_result_capacity_words !== 32'd1 ||
                    task_item_count !== 32'd1 ||
                    task_user_tag !== 32'hCAFEBABE ||
                    task_timeout_cycles !== 32'd12345 ||
                    task_status !== 8'd0 || task_detail !== 32'd0) begin
                    $display("FAIL task metadata");
                    errors <= errors + 1;
                end
            end

            if (payload_valid && payload_ready) begin
                if (payload_data !== (32'hA5000000 + payload_events)) begin
                    $display("FAIL payload[%0d]: got %08x", payload_events, payload_data);
                    errors <= errors + 1;
                end
                if (payload_last !== (payload_events == 63)) begin
                    $display("FAIL payload_last[%0d]=%0b", payload_events, payload_last);
                    errors <= errors + 1;
                end
                payload_events <= payload_events + 1;
            end

            if (batch_end_valid && batch_end_ready) begin
                batch_end_events <= batch_end_events + 1;
                if (batch_end_status !== 8'd0 || batch_end_detail !== 32'd0 ||
                    batch_observed_words !== 32'd80) begin
                    $display("FAIL batch end status=%0d detail=%08x words=%0d",
                             batch_end_status, batch_end_detail, batch_observed_words);
                    errors <= errors + 1;
                end
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        fork
            send_valid_tanimoto_batch();
            begin
                repeat (3000) begin
                    @(posedge clk);
                    if (batch_end_events == 1) begin
                        if (batch_events != 1 || task_events != 1 ||
                            payload_events != 64 || errors != 0) begin
                            $display("FAIL summary batch=%0d task=%0d payload=%0d errors=%0d",
                                     batch_events, task_events, payload_events, errors);
                            $fatal(1);
                        end
                        $display("PASS DMA frontend valid batch with backpressure");
                        $finish;
                    end
                end
                $display("FAIL timeout waiting for batch_end");
                $fatal(1);
            end
        join
    end
endmodule
