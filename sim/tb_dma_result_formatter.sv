`timescale 1ns/1ps

module tb_dma_result_formatter;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg batch_valid = 0;
    wire batch_ready;
    reg [31:0] batch_id = 0;
    reg [31:0] expected_task_count = 0;
    reg [7:0] header_status = 0;
    reg [31:0] output_capacity_words = 0;

    reg result_valid = 0;
    wire result_ready;
    wire result_reject;
    reg [31:0] result_job_id = 0;
    reg [7:0] result_task_id = 0;
    reg [23:0] result_status = 0;
    reg [31:0] result_words = 0;
    reg [63:0] result_compute_cycles = 0;
    reg [31:0] result_item_count = 0;
    reg [31:0] result_user_tag = 0;
    reg [31:0] result_detail = 0;

    reg result_data_valid = 0;
    wire result_data_ready;
    reg [31:0] result_data = 0;

    reg finish_valid = 0;
    wire finish_ready;
    reg [31:0] finish_completed_count = 0;
    reg [31:0] finish_error_count = 0;
    reg [31:0] finish_batch_status = 0;
    reg [31:0] finish_first_error_job_id = 0;
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
        .result_words(result_words),
        .result_compute_cycles(result_compute_cycles),
        .result_item_count(result_item_count), .result_user_tag(result_user_tag),
        .result_detail(result_detail),
        .result_data_valid(result_data_valid),
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

    localparam integer EXPECTED_WORDS = 3245;
    reg [31:0] expected [0:EXPECTED_WORDS-1];
    integer expected_index;
    integer output_index = 0;
    integer cycle_count = 0;
    integer i;
    integer p;
    integer valid_words;
    reg stalled = 0;
    reg [127:0] stalled_data;
    reg [15:0] stalled_keep;
    reg stalled_last;

    task automatic append_result_header;
        input [31:0] job;
        input [7:0] task_id_value;
        input [23:0] status_value;
        input [31:0] word_count;
        input [63:0] cycles;
        input [31:0] items;
        input [31:0] tag;
        input [31:0] detail;
        begin
            expected[expected_index + 0] = job;
            expected[expected_index + 1] = {status_value, task_id_value};
            expected[expected_index + 2] = word_count;
            expected[expected_index + 3] = cycles[31:0];
            expected[expected_index + 4] = cycles[63:32];
            expected[expected_index + 5] = items;
            expected[expected_index + 6] = tag;
            expected[expected_index + 7] = detail;
            expected_index = expected_index + 8;
        end
    endtask

    task automatic send_batch;
        begin
            @(negedge clk);
            batch_id = 32'h11223344;
            expected_task_count = 3;
            header_status = 0;
            output_capacity_words = 4000;
            batch_valid = 1;
            while (!batch_ready) @(negedge clk);
            @(negedge clk);
            batch_valid = 0;
        end
    endtask

    task automatic send_result;
        input [31:0] job;
        input [7:0] task_id_value;
        input [31:0] word_count;
        input [63:0] cycles;
        input [31:0] items;
        input [31:0] tag;
        input [31:0] payload_base;
        integer word_index;
        begin
            @(negedge clk);
            result_job_id = job;
            result_task_id = task_id_value;
            result_status = 0;
            result_words = word_count;
            result_compute_cycles = cycles;
            result_item_count = items;
            result_user_tag = tag;
            result_detail = 0;
            result_valid = 1;
            while (!result_ready) @(negedge clk);
            if (result_reject) begin
                $display("FAIL unexpected result rejection job=%0d", job);
                $fatal(1);
            end
            @(negedge clk);
            result_valid = 0;

            for (word_index = 0; word_index < word_count; word_index = word_index + 1) begin
                result_data = payload_base + word_index;
                result_data_valid = 1;
                while (!result_data_ready) @(negedge clk);
                @(negedge clk);
                result_data_valid = 0;
                if ((word_index % 11) == 3) @(negedge clk);
            end
        end
    endtask

    task automatic send_finish;
        begin
            @(negedge clk);
            finish_completed_count = 3;
            finish_error_count = 0;
            finish_batch_status = 0;
            finish_first_error_job_id = 32'hFFFFFFFF;
            finish_detail = 0;
            finish_valid = 1;
            while (!finish_ready) @(negedge clk);
            @(negedge clk);
            finish_valid = 0;
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            m_ready <= 0;
            output_index <= 0;
            stalled <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            m_ready <= (cycle_count[3:0] != 4'h3) &&
                       (cycle_count[3:0] != 4'h4) &&
                       (cycle_count[3:0] != 4'hD);

            if (stalled) begin
                if (!m_valid || m_data !== stalled_data || m_keep !== stalled_keep ||
                    m_last !== stalled_last) begin
                    $display("FAIL AXIS output changed while stalled");
                    $fatal(1);
                end
            end
            stalled <= m_valid && !m_ready;
            if (m_valid && !m_ready) begin
                stalled_data <= m_data;
                stalled_keep <= m_keep;
                stalled_last <= m_last;
            end

            if (m_valid && m_ready) begin
                valid_words = 0;
                for (p = 0; p < 4; p = p + 1) begin
                    if (m_keep[p*4 +: 4] == 4'hF) begin
                        if (output_index + valid_words >= EXPECTED_WORDS ||
                            m_data[p*32 +: 32] !== expected[output_index + valid_words]) begin
                            $display("FAIL output word %0d got=%08x expected=%08x",
                                     output_index + valid_words, m_data[p*32 +: 32],
                                     expected[output_index + valid_words]);
                            $fatal(1);
                        end
                        valid_words = valid_words + 1;
                    end else if (m_keep[p*4 +: 4] != 4'h0) begin
                        $display("FAIL non-word-granular TKEEP=%04x", m_keep);
                        $fatal(1);
                    end
                end
                if (m_last !== (output_index + valid_words == EXPECTED_WORDS)) begin
                    $display("FAIL TLAST at output word %0d", output_index + valid_words);
                    $fatal(1);
                end
                if (m_last && m_keep != 16'h000F) begin
                    $display("FAIL final TKEEP=%04x expected=000F", m_keep);
                    $fatal(1);
                end
                output_index <= output_index + valid_words;
            end
        end
    end

    initial begin
        expected_index = 0;
        expected[expected_index+0] = 32'h4D4F4C52;
        expected[expected_index+1] = 32'h00080001;
        expected[expected_index+2] = 32'h11223344;
        expected[expected_index+3] = 3;
        expected[expected_index+4] = 0;
        expected[expected_index+5] = 4000;
        expected[expected_index+6] = 0;
        expected[expected_index+7] = 0;
        expected_index = expected_index + 8;
        append_result_header(1, 0, 0, 1, 64'd5, 1, 32'hAAAA0001, 0);
        expected[expected_index] = 32'h00010000;
        expected_index = expected_index + 1;
        append_result_header(2, 2, 0, 4, 64'd10, 1, 32'hBBBB0002, 0);
        for (i = 0; i < 4; i = i + 1) begin
            expected[expected_index] = 32'h20000000 + i;
            expected_index = expected_index + 1;
        end
        append_result_header(3, 1, 0, 3200, 64'h0000000100000020,
                             1, 32'hCCCC0003, 0);
        for (i = 0; i < 3200; i = i + 1) begin
            expected[expected_index] = 32'h30000000 + i;
            expected_index = expected_index + 1;
        end
        expected[expected_index+0] = 32'h4D4F4C45;
        expected[expected_index+1] = 32'h11223344;
        expected[expected_index+2] = 3;
        expected[expected_index+3] = 0;
        expected[expected_index+4] = EXPECTED_WORDS;
        expected[expected_index+5] = 0;
        expected[expected_index+6] = 32'hFFFFFFFF;
        expected[expected_index+7] = 0;
        expected_index = expected_index + 8;
        if (expected_index != EXPECTED_WORDS) $fatal(1);

        repeat (5) @(posedge clk);
        resetn = 1;
        send_batch();
        send_result(1, 0, 1, 64'd5, 1, 32'hAAAA0001, 32'h00010000);
        send_result(2, 2, 4, 64'd10, 1, 32'hBBBB0002, 32'h20000000);
        send_result(3, 1, 3200, 64'h0000000100000020,
                    1, 32'hCCCC0003, 32'h30000000);
        send_finish();

        repeat (20000) begin
            @(posedge clk);
            if (output_index == EXPECTED_WORDS) begin
                $display("PASS DMA result formatter golden vector with backpressure");
                $finish;
            end
        end
        $display("FAIL formatter timeout output=%0d/%0d", output_index, EXPECTED_WORDS);
        $fatal(1);
    end
endmodule
