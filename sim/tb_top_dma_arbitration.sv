`timescale 1ns/1ps

module tb_top_dma_arbitration;
    logic clk = 0;
    logic rst_n = 0;
    logic [17:0] awaddr = 0;
    logic awvalid = 0;
    wire awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wvalid = 0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    logic bready = 0;
    logic [17:0] araddr = 0;
    logic arvalid = 0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    logic rready = 0;
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
    logic [31:0] words [0:79];
    integer output_words = 0;
    integer lane;
    integer beat;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(18),
        .MAX_NODES(2), .FEATURE_DIM(2), .HIDDEN_DIM(2)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awprot(3'b0), .s_axi_arprot(3'b0),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
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
            awaddr = address; awvalid = 1;
            wdata = value; wstrb = 4'hf; wvalid = 1; bready = 1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0;
            while (!bvalid) @(negedge clk);
            @(negedge clk);
            bready = 0;
        end
    endtask

    task automatic axi_read(input [17:0] address, output [31:0] value);
        begin
            @(negedge clk);
            araddr = address; arvalid = 1; rready = 1;
            while (!arready) @(negedge clk);
            @(negedge clk);
            arvalid = 0;
            while (!rvalid) @(negedge clk);
            value = rdata;
            @(negedge clk);
            rready = 0;
        end
    endtask

    task automatic prepare_packet(input [31:0] batch_id);
        begin
            words[0] = 32'h4d4f4c51; words[1] = 32'h00080001;
            words[2] = batch_id; words[3] = 1; words[4] = 80;
            words[5] = 0; words[6] = 64; words[7] = 0;
            words[8] = batch_id; words[9] = 0; words[10] = 64;
            words[11] = 1; words[12] = 1; words[13] = batch_id + 1;
            words[14] = 100000; words[15] = 0;
            for (lane = 0; lane < 64; lane = lane + 1)
                words[16+lane] = 32'hffff_ffff;
        end
    endtask

    task automatic send_beat(input integer beat_index);
        begin
            @(negedge clk);
            s_data = {words[beat_index*4+3], words[beat_index*4+2],
                      words[beat_index*4+1], words[beat_index*4]};
            s_keep = 16'hffff;
            s_last = (beat_index == 19);
            s_valid = 1;
            while (!s_ready) @(negedge clk);
            @(negedge clk);
            s_valid = 0; s_last = 0;
        end
    endtask

    task automatic wait_response;
        begin
            repeat (20000) begin
                @(posedge clk);
                if (output_words == 25) begin
                    disable wait_response;
                end
            end
            $fatal(1, "timeout waiting for response: %0d words", output_words);
        end
    endtask

    always @(posedge clk)
        if (rst_n && m_valid && m_ready)
            for (lane = 0; lane < 4; lane = lane + 1)
                if (m_keep[lane*4 +: 4] == 4'hf)
                    output_words = output_words + 1;

    initial begin
        logic [31:0] status;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // A running legacy GNN owns the cores. The DMA frontend may absorb its
        // two header beats plus one elastic beat, but must then hold back.
        prepare_packet(32'h70000001);
        axi_write(18'h00000, 32'h00000003);
        send_beat(0);
        send_beat(1);
        send_beat(2);
        repeat (2) @(posedge clk);
        if (s_ready !== 1'b0 || dut.dma_active !== 1'b0)
            $fatal(1, "DMA was not held behind active legacy task");
        status = 0;
        while (!status[1]) axi_read(18'h00004, status);
        for (beat = 3; beat < 20; beat = beat + 1) send_beat(beat);
        wait_response();
        $display("PASS legacy execution backpressures DMA batch admission");

        // Hold the result channel so the DMA batch remains active, then issue
        // a legacy start. It must set sticky legacy error and not alter DMA.
        output_words = 0;
        prepare_packet(32'h70000002);
        m_ready = 0;
        for (beat = 0; beat < 20; beat = beat + 1) send_beat(beat);
        wait (dut.dma_active === 1'b1);
        axi_write(18'h00000, 32'h00000001);
        axi_read(18'h00004, status);
        if (!status[2])
            $fatal(1, "legacy start during DMA did not set sticky error");
        m_ready = 1;
        wait_response();
        if (dut.tanimoto_similarity !== 32'h00010000)
            $fatal(1, "DMA result corrupted by rejected legacy command");
        $display("PASS legacy start rejected without corrupting active DMA batch");
        $display("ALL TOP DMA ARBITRATION TESTS PASSED");
        $finish;
    end
endmodule
