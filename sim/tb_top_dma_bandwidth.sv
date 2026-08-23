`timescale 1ns/1ps

module tb_top_dma_bandwidth;
    logic clk = 0;
    logic rst_n = 0;
    logic [17:0] awaddr = 0;
    logic awvalid = 0;
    wire awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wvalid = 0;
    wire wready;
    wire bvalid;
    logic [127:0] s_data = 0;
    logic [15:0] s_keep = 0;
    logic s_valid = 0;
    wire s_ready;
    logic s_last = 0;
    wire [127:0] m_data;
    wire [15:0] m_keep;
    wire m_valid;
    logic m_ready = 1;
    wire m_last;
    integer beat;
    integer received;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(18), .MAX_NODES(2),
        .FEATURE_DIM(2), .HIDDEN_DIM(2)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awprot(3'd0), .s_axi_arprot(3'd0),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(), .s_axi_bvalid(bvalid),
        .s_axi_bready(1'b1), .s_axi_araddr(18'd0), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(),
        .s_axi_rvalid(), .s_axi_rready(1'b1),
        .s_axis_job_tdata(s_data), .s_axis_job_tkeep(s_keep),
        .s_axis_job_tvalid(s_valid), .s_axis_job_tready(s_ready),
        .s_axis_job_tlast(s_last), .m_axis_result_tdata(m_data),
        .m_axis_result_tkeep(m_keep), .m_axis_result_tvalid(m_valid),
        .m_axis_result_tready(m_ready), .m_axis_result_tlast(m_last),
        .lcd_pixel_clk(1'b0), .lcd_aresetn(1'b0),
        .lcd_clock_locked(1'b0)
    );

    task automatic axi_write(input [17:0] address, input [31:0] value);
        begin
            @(negedge clk);
            awaddr = address; wdata = value; wstrb = 4'hf;
            awvalid = 1; wvalid = 1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0; wstrb = 0;
            while (!bvalid) @(negedge clk);
        end
    endtask

    task automatic send_beat(input integer index, input integer total);
        begin
            @(negedge clk);
            s_data = {4{32'h1000_0000 + index}};
            s_keep = 16'hffff;
            s_last = (index == total-1);
            s_valid = 1;
            while (!s_ready) @(negedge clk);
            @(negedge clk);
            s_valid = 0; s_last = 0;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Mode 1: exact 128-bit loopback with backpressure and TLAST.
        axi_write(18'h00008, 1);
        fork
            begin
                for (beat = 0; beat < 4; beat = beat + 1)
                    send_beat(beat, 4);
            end
            begin
                received = 0;
                while (received < 4) begin
                    @(negedge clk);
                    m_ready = (received != 1);
                    if (received == 1) begin
                        @(negedge clk);
                        m_ready = 1;
                    end
                    if (m_valid && m_ready) begin
                        if (m_data !== {4{32'h1000_0000 + received}} ||
                            m_keep !== 16'hffff ||
                            m_last !== (received == 3))
                            $fatal(1, "loopback mismatch beat=%0d", received);
                        received = received + 1;
                    end
                end
            end
        join

        // Mode 2: MM2S sink must accept data and emit nothing.
        axi_write(18'h00008, 2);
        for (beat = 0; beat < 4; beat = beat + 1) begin
            send_beat(beat, 4);
            if (m_valid) $fatal(1, "sink mode emitted output");
        end

        // Mode 3: programmable S2MM source emits the requested beat count.
        axi_write(18'h0000c, 4);
        m_ready = 0;
        axi_write(18'h00008, 3);
        received = 0;
        @(negedge clk);
        m_ready = 1;
        while (received < 4) begin
            @(posedge clk);
            if (m_valid && m_ready) begin
                if (m_keep !== 16'hffff || m_last !== (received == 3) ||
                    m_data[31:0] !== received)
                    $fatal(1, "source mismatch beat=%0d data=%08x",
                           received, m_data[31:0]);
                received = received + 1;
            end
        end
        axi_write(18'h00008, 0);
        $display("PASS top DMA standalone MM2S sink, S2MM source and loopback modes");
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "timeout in DMA bandwidth mode test");
    end
endmodule
