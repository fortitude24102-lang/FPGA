`timescale 1ns / 1ps

module tb_top;
    localparam int ADDR_WIDTH = 18;

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
    logic bready = 1'b0;
    logic [ADDR_WIDTH-1:0] araddr = '0;
    logic arvalid = 1'b0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    logic rready = 1'b0;

    always #5 clk = ~clk;

    generator_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(ADDR_WIDTH),
        .MAX_NODES(2),
        .FEATURE_DIM(2),
        .HIDDEN_DIM(2)
    ) dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
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
        .s_axi_rready(rready)
    );

    task automatic axi_write(input logic [ADDR_WIDTH-1:0] address,
                             input logic [31:0] value);
        begin
            @(negedge clk);
            awaddr = address;
            awvalid = 1'b1;
            wdata = value;
            wstrb = 4'hf;
            wvalid = 1'b1;
            bready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            awvalid = 1'b0;
            wvalid = 1'b0;
            while (!bvalid) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            bready = 1'b0;
            if (bresp != 2'b00)
                $fatal(1, "AXI write response error at 0x%05x", address);
        end
    endtask

    task automatic axi_read(input logic [ADDR_WIDTH-1:0] address,
                            output logic [31:0] value);
        begin
            @(negedge clk);
            araddr = address;
            arvalid = 1'b1;
            rready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) begin
                @(posedge clk);
                #1;
            end
            value = rdata;
            if (rresp != 2'b00)
                $fatal(1, "AXI read response error at 0x%05x", address);
            @(posedge clk);
            #1;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    initial begin
        int word_idx;
        int polls;
        logic [31:0] status;
        logic [31:0] result;
        logic [31:0] gnn_word0;
        logic [31:0] gnn_word1;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (word_idx = 0; word_idx < 32; word_idx++) begin
            axi_write(18'h00100 + word_idx*4, 32'hffff_ffff);
            axi_write(18'h00180 + word_idx*4, 32'hffff_ffff);
        end

        // task=0 (Tanimoto), start=1
        axi_write(18'h00000, 32'h0000_0001);

        status = 32'd0;
        polls = 0;
        while (!status[1] && polls < 100) begin
            axi_read(18'h00004, status);
            polls++;
        end
        if (!status[1])
            $fatal(1, "Top-level task did not complete");
        if (status[2])
            $fatal(1, "Top-level error flag was set");

        axi_read(18'h00200, result);
        if (result !== 32'h0001_0000)
            $fatal(1, "Tanimoto result got=0x%08x expected=0x00010000",
                   result);

        $display("PASS AXI-Lite Tanimoto task, result=0x%08x polls=%0d",
                 result, polls);

        // Load a 2x2 GNN identical to tb_gnn through AXI-Lite.
        // weight[feature][hidden] = [[1.0, 0.5], [-1.0, 2.0]]
        axi_write(18'h00400, 32'h0000_0100);
        axi_write(18'h00404, 32'd0);
        axi_write(18'h00400, 32'h0000_0080);
        axi_write(18'h00404, 32'd1);
        axi_write(18'h00400, 32'h0000_ff00);
        axi_write(18'h00404, 32'd2);
        axi_write(18'h00400, 32'h0000_0200);
        axi_write(18'h00404, 32'd3);

        // node0=[1,2], node1=[3,4].
        axi_write(18'h02000, 32'h0200_0100);
        axi_write(18'h02004, 32'h0400_0300);
        // row0 aggregates nodes 0 and 1; row1 has no neighbors.
        axi_write(18'h01000, 32'h0000_0003);

        // Clear status, then start task=1 (control bits[2:1]=1).
        axi_write(18'h00000, 32'h0000_0100);
        axi_write(18'h00000, 32'h0000_0003);
        status = 32'd0;
        polls = 0;
        while (!status[1] && polls < 100) begin
            axi_read(18'h00004, status);
            polls++;
        end
        if (!status[1] || status[2])
            $fatal(1, "Top-level GNN task failed, status=0x%08x", status);

        axi_read(18'h04000, gnn_word0);
        axi_read(18'h04004, gnn_word1);
        if (gnn_word0 !== 32'h0e00_0000 || gnn_word1 !== 32'h0000_0000)
            $fatal(1,
                "GNN readback got=[0x%08x,0x%08x], expected=[0x0e000000,0]",
                gnn_word0, gnn_word1);
        $display("PASS AXI-Lite GNN task and synchronous BRAM readback");

        $display("ALL TOP-LEVEL TESTS PASSED");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "Global top-level testbench timeout");
    end
endmodule
