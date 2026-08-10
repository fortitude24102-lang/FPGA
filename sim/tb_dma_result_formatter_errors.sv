`timescale 1ns/1ps

module tb_dma_result_formatter_errors;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;
    reg batch_valid = 0;
    wire batch_ready;
    reg [31:0] batch_id = 32'h55667788;
    reg [31:0] expected_task_count = 1;
    reg [7:0] header_status = 0;
    reg [31:0] output_capacity_words = 40;
    reg result_valid = 0;
    wire result_ready, result_reject;
    reg [31:0] result_job_id = 7;
    reg [7:0] result_task_id = 1;
    reg [23:0] result_status = 0;
    reg [31:0] result_words = 20;
    reg [63:0] result_compute_cycles = 64'h0000000200000001;
    reg [31:0] result_item_count = 1;
    reg [31:0] result_user_tag = 32'hFACE0007;
    reg [31:0] result_detail = 0;
    reg result_data_valid = 0;
    wire result_data_ready;
    reg [31:0] result_data = 0;
    reg finish_valid = 0;
    wire finish_ready;
    reg [31:0] finish_completed_count = 1;
    reg [31:0] finish_error_count = 1;
    reg [31:0] finish_batch_status = 0;
    reg [31:0] finish_first_error_job_id = 7;
    reg [31:0] finish_detail = 0;
    wire [127:0] m_data;
    wire [15:0] m_keep;
    wire m_valid;
    reg m_ready = 1;
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

    reg [31:0] expected [0:23];
    integer output_index = 0;
    integer lane;
    integer lane_count;

    always @(posedge clk) begin
        if (!resetn) begin
            output_index <= 0;
        end else if (m_valid && m_ready) begin
            lane_count = 0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (m_keep[lane*4 +: 4] == 4'hF) begin
                    if (m_data[lane*32 +: 32] !== expected[output_index + lane_count]) begin
                        $display("FAIL overflow output word=%0d got=%08x expected=%08x",
                                 output_index + lane_count,
                                 m_data[lane*32 +: 32],
                                 expected[output_index + lane_count]);
                        $fatal(1);
                    end
                    lane_count = lane_count + 1;
                end
            end
            if (m_last !== (output_index + lane_count == 24)) begin
                $display("FAIL overflow TLAST position");
                $fatal(1);
            end
            if (m_last && m_keep != 16'hFFFF) begin
                $display("FAIL overflow final keep=%04x", m_keep);
                $fatal(1);
            end
            output_index <= output_index + lane_count;
        end
    end

    initial begin
        expected[0]=32'h4D4F4C52; expected[1]=32'h00080001;
        expected[2]=32'h55667788; expected[3]=1;
        expected[4]=0; expected[5]=40; expected[6]=0; expected[7]=0;
        expected[8]=7; expected[9]=32'h00000701;
        expected[10]=0; expected[11]=32'h00000001;
        expected[12]=32'h00000002; expected[13]=1;
        expected[14]=32'hFACE0007; expected[15]=20;
        expected[16]=32'h4D4F4C45; expected[17]=32'h55667788;
        expected[18]=1; expected[19]=1; expected[20]=24;
        expected[21]=0; expected[22]=7; expected[23]=0;

        repeat (5) @(posedge clk);
        resetn = 1;
        @(negedge clk);
        batch_valid = 1;
        while (!batch_ready) @(negedge clk);
        @(negedge clk);
        batch_valid = 0;

        result_valid = 1;
        while (!result_ready) @(negedge clk);
        if (!result_reject) begin
            $display("FAIL oversized result was not rejected before payload");
            $fatal(1);
        end
        @(negedge clk);
        result_valid = 0;

        finish_valid = 1;
        while (!finish_ready) @(negedge clk);
        @(negedge clk);
        finish_valid = 0;

        repeat (500) begin
            @(posedge clk);
            if (output_index == 24) begin
                $display("PASS result overflow converted to zero-payload error record");
                $finish;
            end
        end
        $display("FAIL overflow formatter timeout output=%0d", output_index);
        $fatal(1);
    end
endmodule
