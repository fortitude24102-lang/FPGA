`timescale 1ns/1ps

module tb_dma_frontend_throughput;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg [31:0] words [0:79];
    reg [4:0] source_beat = 0;
    reg source_valid = 0;
    wire source_ready;
    integer cycle_count = 0;
    integer previous_payload_beat_cycle = -1;
    integer payload_words_seen = 0;

    wire batch_valid;
    wire task_valid;
    wire payload_valid;
    wire [31:0] payload_data;
    wire payload_last;
    wire batch_end_valid;
    wire [7:0] observed_batch_status;
    wire [7:0] observed_task_status;
    wire [7:0] observed_end_status;
    wire [31:0] observed_task_count;
    wire [31:0] observed_total_words;

    wire [127:0] source_data = {
        words[source_beat*4 + 3], words[source_beat*4 + 2],
        words[source_beat*4 + 1], words[source_beat*4 + 0]
    };

    dma_task_queue_frontend dut (
        .aclk(clk), .aresetn(resetn),
        .s_axis_job_tdata(source_data),
        .s_axis_job_tkeep(16'hffff),
        .s_axis_job_tvalid(source_valid),
        .s_axis_job_tready(source_ready),
        .s_axis_job_tlast(source_beat == 19),
        .batch_valid(batch_valid), .batch_ready(1'b1),
        .batch_id(), .batch_task_count(observed_task_count),
        .batch_total_words(observed_total_words),
        .batch_flags(), .batch_max_result_words(),
        .batch_status(observed_batch_status),
        .batch_detail(),
        .task_valid(task_valid), .task_ready(1'b1),
        .task_job_id(), .task_id(), .task_flags(), .task_payload_words(),
        .task_result_capacity_words(), .task_item_count(), .task_user_tag(),
        .task_timeout_cycles(), .task_status(observed_task_status),
        .task_detail(),
        .payload_valid(payload_valid), .payload_ready(1'b1),
        .payload_data(payload_data), .payload_last(payload_last),
        .batch_end_valid(batch_end_valid), .batch_end_ready(1'b1),
        .batch_end_status(observed_end_status), .batch_end_detail(),
        .batch_observed_words()
    );

    integer i;
    initial begin
        words[0] = 32'h4d4f4c51;
        words[1] = 32'h00080001;
        words[2] = 32'h13572468;
        words[3] = 1;
        words[4] = 80;
        words[5] = 0;
        words[6] = 128;
        words[7] = 0;
        words[8] = 7;
        words[9] = 0;
        words[10] = 64;
        words[11] = 1;
        words[12] = 1;
        words[13] = 32'h55aa55aa;
        words[14] = 1000;
        words[15] = 0;
        for (i = 0; i < 64; i = i + 1)
            words[16+i] = 32'h90000000 + i;

        repeat (5) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        source_valid = 1'b1;
        repeat (500) begin
            @(posedge clk);
            if (batch_end_valid) begin
                if (source_beat != 20 || payload_words_seen != 64) begin
                    $display("FAIL throughput completion beats=%0d words=%0d batch=%0d task=%0d end=%0d",
                             source_beat, payload_words_seen,
                             observed_batch_status, observed_task_status,
                             observed_end_status);
                    $fatal(1);
                end
                $display("PASS DMA frontend accepts full payload beats every four cycles");
                $finish;
            end
        end
        $display("FAIL throughput timeout");
        $fatal(1);
    end

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (source_valid && source_ready) begin
                /* Beats 4..19 contain the 64-word payload.  After the first
                 * payload beat, a four-lane unpacker must accept each next
                 * full beat exactly four clocks later, with no refill bubble. */
                /* Beat 5 follows the task-metadata handshake.  From beat 6
                 * onward the payload path is in steady state and must refill
                 * every four clocks. */
                if (source_beat >= 6 &&
                    cycle_count - previous_payload_beat_cycle != 4) begin
                    $display("FAIL payload beat %0d gap=%0d expected=4",
                             source_beat,
                             cycle_count - previous_payload_beat_cycle);
                    $fatal(1);
                end
                if (source_beat >= 4)
                    previous_payload_beat_cycle <= cycle_count;
                source_beat <= source_beat + 1'b1;
                if (source_beat == 19)
                    source_valid <= 1'b0;
            end
            if (payload_valid) begin
                if (payload_data != 32'h90000000 + payload_words_seen) begin
                    $display("FAIL payload word %0d got=%08x",
                             payload_words_seen, payload_data);
                    $fatal(1);
                end
                if (payload_last != (payload_words_seen == 63)) begin
                    $display("FAIL payload_last at word %0d", payload_words_seen);
                    $fatal(1);
                end
                payload_words_seen <= payload_words_seen + 1;
            end
        end
    end
endmodule
