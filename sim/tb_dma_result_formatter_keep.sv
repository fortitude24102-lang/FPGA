`timescale 1ns/1ps

module tb_dma_result_formatter_keep;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;
    reg batch_valid = 0;
    wire batch_ready;
    reg [31:0] batch_id = 0;
    reg [31:0] expected_task_count = 1;
    reg [7:0] header_status = 0;
    reg [31:0] output_capacity_words = 128;
    reg result_valid = 0;
    wire result_ready, result_reject;
    reg [31:0] result_job_id = 1;
    reg [7:0] result_task_id = 0;
    reg [23:0] result_status = 0;
    reg [31:0] result_words = 0;
    reg [63:0] result_compute_cycles = 1;
    reg [31:0] result_item_count = 1;
    reg [31:0] result_user_tag = 0;
    reg [31:0] result_detail = 0;
    reg result_data_valid = 0;
    wire result_data_ready;
    reg [31:0] result_data = 0;
    reg finish_valid = 0;
    wire finish_ready;
    reg [31:0] finish_completed_count = 1;
    reg [31:0] finish_error_count = 0;
    reg [31:0] finish_batch_status = 0;
    reg [31:0] finish_first_error_job_id = 32'hFFFFFFFF;
    reg [31:0] finish_detail = 0;
    wire [127:0] m_data;
    wire [15:0] m_keep;
    wire m_valid;
    reg m_ready = 0;
    wire m_last;

    dma_result_formatter dut (
        .aclk(clk), .aresetn(resetn),
        .batch_valid(batch_valid), .batch_ready(batch_ready),
        .batch_id(batch_id), .expected_task_count(expected_task_count),
        .header_status(header_status),
        .output_capacity_words(output_capacity_words),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_reject(result_reject), .result_job_id(result_job_id),
        .result_task_id(result_task_id), .result_status(result_status),
        .result_words(result_words), .result_compute_cycles(result_compute_cycles),
        .result_item_count(result_item_count), .result_user_tag(result_user_tag),
        .result_detail(result_detail), .result_data_valid(result_data_valid),
        .result_data_ready(result_data_ready), .result_data(result_data),
        .finish_valid(finish_valid), .finish_ready(finish_ready),
        .finish_completed_count(finish_completed_count),
        .finish_error_count(finish_error_count),
        .finish_batch_status(finish_batch_status),
        .finish_first_error_job_id(finish_first_error_job_id),
        .finish_detail(finish_detail),
        .m_axis_result_tdata(m_data), .m_axis_result_tkeep(m_keep),
        .m_axis_result_tvalid(m_valid), .m_axis_result_tready(m_ready),
        .m_axis_result_tlast(m_last)
    );

    integer cycle_count = 0;
    integer batches_seen = 0;
    integer words_in_batch = 0;
    integer lane;
    integer valid_words;
    reg [15:0] expected_final_keep [1:4];

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            batches_seen <= 0;
            words_in_batch <= 0;
            m_ready <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            m_ready <= (cycle_count[2:0] != 3'd2);
            if (m_valid && m_ready) begin
                valid_words = 0;
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (m_keep[lane*4 +: 4] == 4'hF)
                        valid_words = valid_words + 1;
                    else if (m_keep[lane*4 +: 4] != 0) begin
                        $display("FAIL malformed keep=%04x", m_keep);
                        $fatal(1);
                    end
                if (m_last) begin
                    if (m_keep != expected_final_keep[batches_seen + 1] ||
                        words_in_batch + valid_words != 25 + batches_seen) begin
                        $display("FAIL batch %0d final keep=%04x words=%0d",
                                 batches_seen + 1, m_keep,
                                 words_in_batch + valid_words);
                        $fatal(1);
                    end
                    batches_seen <= batches_seen + 1;
                    words_in_batch <= 0;
                end else begin
                    words_in_batch <= words_in_batch + valid_words;
                end
            end
        end
    end

    task automatic send_small_batch;
        input integer payload_words;
        integer payload_index;
        begin
            batch_id = payload_words;
            result_words = payload_words;
            result_user_tag = payload_words;
            batch_valid = 1;
            while (!batch_ready) @(negedge clk);
            @(negedge clk);
            batch_valid = 0;
            result_valid = 1;
            while (!result_ready) @(negedge clk);
            if (result_reject) $fatal(1);
            @(negedge clk);
            result_valid = 0;
            for (payload_index = 0; payload_index < payload_words;
                 payload_index = payload_index + 1) begin
                result_data = 32'h44000000 + payload_index;
                result_data_valid = 1;
                while (!result_data_ready) @(negedge clk);
                @(negedge clk);
                result_data_valid = 0;
            end
            finish_valid = 1;
            while (!finish_ready) @(negedge clk);
            @(negedge clk);
            finish_valid = 0;
            while (!batch_ready) @(negedge clk);
        end
    endtask

    initial begin
        expected_final_keep[1] = 16'h000F;
        expected_final_keep[2] = 16'h00FF;
        expected_final_keep[3] = 16'h0FFF;
        expected_final_keep[4] = 16'hFFFF;
        repeat (5) @(posedge clk);
        resetn = 1;
        @(negedge clk);
        send_small_batch(1);
        send_small_batch(2);
        send_small_batch(3);
        send_small_batch(4);
        repeat (100) @(posedge clk);
        if (batches_seen != 4) begin
            $display("FAIL saw %0d/4 formatter batches", batches_seen);
            $fatal(1);
        end
        $display("PASS formatter 1/2/3/4-word final TKEEP and restart");
        $finish;
    end
endmodule
