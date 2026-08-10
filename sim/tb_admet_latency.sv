`timescale 1ns / 1ps

module tb_admet_latency;
    localparam int DESCRIPTOR_DIM = 20;
    localparam int HIDDEN_DIM = 10;
    localparam int DATA_WIDTH = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    wire valid;

    always #5 clk = ~clk;

    admet_predictor #(
        .DESCRIPTOR_DIM(DESCRIPTOR_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .descriptors({DESCRIPTOR_DIM*DATA_WIDTH{1'b0}}),
        .cfg_we(1'b0),
        .cfg_model(2'b00),
        .cfg_layer(2'b00),
        .cfg_addr(16'd0),
        .cfg_wdata({DATA_WIDTH{1'b0}}),
        .busy(),
        .valid(valid),
        .logp(),
        .oral_bioavailability(),
        .herg_ic50(),
        .bbb_permeability(),
        .predictions()
    );

    initial begin
        int elapsed;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        elapsed = 0;
        while (!valid && elapsed < 1000) begin
            @(posedge clk);
            #1;
            elapsed++;
        end
        if (!valid)
            $fatal(1, "ADMET default-size latency timeout");

        $display("ADMET default-size latency: %0d cycles", elapsed);
        if (elapsed >= 100)
            $fatal(1, "ADMET latency target failed: %0d cycles >= 100",
                   elapsed);
        $display("PASS ADMET latency target: %0d cycles < 100", elapsed);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global ADMET latency testbench timeout");
    end
endmodule
