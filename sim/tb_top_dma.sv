`timescale 1ns/1ps

module tb_top_dma;
    localparam int ADDR_WIDTH = 18;
    localparam int REQUEST_WORDS = 80;
    localparam int RESPONSE_WORDS = 25;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [127:0] s_data = '0;
    logic [15:0] s_keep = '0;
    logic s_valid = 1'b0;
    wire s_ready;
    logic s_last = 1'b0;
    wire [127:0] m_data;
    wire [15:0] m_keep;
    wire m_valid;
    logic m_ready = 1'b1;
    wire m_last;
    wire [6:0] debug_queue_occupancy;
    wire [5:0] debug_active_sequence;
    logic saw_queued_task = 1'b0;

    logic [31:0] request [0:REQUEST_WORDS-1];
    logic [31:0] response [0:RESPONSE_WORDS-1];
    integer response_count = 0;
    integer beat;
    integer lane;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(ADDR_WIDTH),
        .MAX_NODES(2),
        .FEATURE_DIM(2),
        .HIDDEN_DIM(2)
    ) dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awprot(3'b000),
        .s_axi_arprot(3'b000),
        .s_axi_awaddr(18'd0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b1),
        .s_axi_araddr(18'd0),
        .s_axi_arvalid(1'b0),
        .s_axi_arready(),
        .s_axi_rdata(),
        .s_axi_rresp(),
        .s_axi_rvalid(),
        .s_axi_rready(1'b1),
        .s_axis_job_tdata(s_data),
        .s_axis_job_tkeep(s_keep),
        .s_axis_job_tvalid(s_valid),
        .s_axis_job_tready(s_ready),
        .s_axis_job_tlast(s_last),
        .m_axis_result_tdata(m_data),
        .m_axis_result_tkeep(m_keep),
        .m_axis_result_tvalid(m_valid),
        .m_axis_result_tready(m_ready),
        .m_axis_result_tlast(m_last),
        .debug_queue_occupancy(debug_queue_occupancy),
        .debug_active_sequence(debug_active_sequence),
        .lcd_pixel_clk(1'b0), .lcd_aresetn(1'b0),
        .lcd_clock_locked(1'b0)
    );

    task automatic send_request;
        begin
            for (beat = 0; beat < REQUEST_WORDS/4; beat = beat + 1) begin
                @(negedge clk);
                s_data = {request[beat*4+3], request[beat*4+2],
                          request[beat*4+1], request[beat*4]};
                s_keep = 16'hffff;
                s_last = (beat == REQUEST_WORDS/4-1);
                s_valid = 1'b1;
                while (!s_ready) @(negedge clk);
                @(negedge clk);
                s_valid = 1'b0;
                s_last = 1'b0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && debug_queue_occupancy != 0) begin
            saw_queued_task <= 1'b1;
            if (debug_active_sequence !== 6'd0)
                $fatal(1, "first queued task has wrong active sequence %0d",
                       debug_active_sequence);
        end
        if (rst_n && m_valid && m_ready) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                if (m_keep[lane*4 +: 4] == 4'hf) begin
                    if (response_count >= RESPONSE_WORDS)
                        $fatal(1, "too many response words");
                    response[response_count] = m_data[lane*32 +: 32];
                    response_count = response_count + 1;
                end
            if (m_last && response_count != RESPONSE_WORDS)
                $fatal(1, "TLAST after %0d words", response_count);
        end
    end

    initial begin
        request[0] = 32'h4d4f4c51;
        request[1] = 32'h00080001;
        request[2] = 32'h11223344;
        request[3] = 1;
        request[4] = REQUEST_WORDS;
        request[5] = 0;
        request[6] = 64;
        request[7] = 0;
        request[8] = 32'h0000002a;
        request[9] = 0;
        request[10] = 64;
        request[11] = 1;
        request[12] = 1;
        request[13] = 32'hcafebabe;
        request[14] = 1000;
        request[15] = 0;
        for (lane = 0; lane < 64; lane = lane + 1)
            request[16+lane] = 32'hffff_ffff;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        send_request();
        repeat (5000) begin
            @(posedge clk);
            if (response_count == RESPONSE_WORDS) begin
                if (!saw_queued_task || debug_queue_occupancy !== 0)
                    $fatal(1, "debug queue probes missed task or did not retire");
                if (response[0] !== 32'h4d4f4c52 ||
                    response[2] !== 32'h11223344 ||
                    response[8] !== 32'h0000002a ||
                    response[9] !== 32'h00000000 ||
                    response[10] !== 1 ||
                    response[16] !== 32'h00010000 ||
                    response[17] !== 32'h4d4f4c45 ||
                    response[18] !== 32'h11223344 ||
                    response[19] !== 1 || response[20] !== 0 ||
                    response[21] !== RESPONSE_WORDS) begin
                    for (lane = 0; lane < 32; lane = lane + 1) begin
                        if (dut.query_fingerprint[lane*32 +: 32] !== 32'hffff_ffff)
                            $display("query mismatch word %0d=%08x", lane,
                                     dut.query_fingerprint[lane*32 +: 32]);
                        if (dut.database_fingerprint[lane*32 +: 32] !== 32'hffff_ffff)
                            $display("db mismatch word %0d=%08x", lane,
                                     dut.database_fingerprint[lane*32 +: 32]);
                    end
                    $fatal(1, "DMA pair response mismatch: h0=%08x bid=%08x job=%08x ts=%08x rw=%0d data=%08x trailer=%08x total=%0d q0=%08x q31=%08x d0=%08x d31=%08x",
                           response[0], response[2], response[8], response[9],
                           response[10], response[16], response[17], response[21],
                           dut.query_fingerprint[31:0],
                           dut.query_fingerprint[1023:992],
                           dut.database_fingerprint[31:0],
                           dut.database_fingerprint[1023:992]);
                end
                $display("PASS top DMA Tanimoto pair through real core");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for DMA response (%0d words)", response_count);
    end
endmodule
