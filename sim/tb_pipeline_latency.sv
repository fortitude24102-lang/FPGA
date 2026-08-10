`timescale 1ns / 1ps

module tb_pipeline_latency;
    localparam int ADDR_WIDTH = 18;
    // 13.508615 ms Python baseline / 30x target at 100 MHz.
    localparam int MAX_PIPELINE_CYCLES = 45_028;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [ADDR_WIDTH-1:0] awaddr = '0;
    logic awvalid = 1'b0;
    wire awready;
    logic [31:0] wdata = '0;
    logic [3:0] wstrb = '0;
    logic wvalid = 1'b0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    logic bready = 1'b1;
    logic [ADDR_WIDTH-1:0] araddr = '0;
    logic arvalid = 1'b0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    logic rready = 1'b0;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awprot(3'b000),
        .s_axi_arprot(3'b000),
        .s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .s_axis_job_tdata(128'd0),
        .s_axis_job_tkeep(16'd0),
        .s_axis_job_tvalid(1'b0),
        .s_axis_job_tready(),
        .s_axis_job_tlast(1'b0),
        .m_axis_result_tdata(),
        .m_axis_result_tkeep(),
        .m_axis_result_tvalid(),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tlast()
    );

    initial begin
        int cycles;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Task 3: start=1 and task bits[2:1]=2'b11.
        @(negedge clk);
        awaddr = 18'h00000;
        awvalid = 1'b1;
        wdata = 32'h0000_0007;
        wstrb = 4'hf;
        wvalid = 1'b1;

        cycles = 0;
        while (!dut.done_sticky && cycles <= MAX_PIPELINE_CYCLES) begin
            @(posedge clk);
            #1;
            cycles++;
            if (cycles == 1) begin
                awvalid = 1'b0;
                wvalid = 1'b0;
            end
        end

        if (!dut.done_sticky)
            $fatal(1,
                "Pipeline exceeded %0d cycles (30x speedup target)",
                MAX_PIPELINE_CYCLES);
        if (dut.error_sticky)
            $fatal(1, "Pipeline set error status");

        $display(
            "PASS default Pipeline latency: %0d cycles = %0.4f ms at 100 MHz",
            cycles, cycles / 100000.0
        );
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Global Pipeline latency testbench timeout");
    end
endmodule
