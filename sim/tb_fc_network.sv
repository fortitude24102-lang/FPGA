`timescale 1ns / 1ps

module tb_fc_network;
    localparam int INPUT_DIM  = 2;
    localparam int HIDDEN_DIM = 2;
    localparam int OUTPUT_DIM = 1;
    localparam int DATA_WIDTH = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [INPUT_DIM*DATA_WIDTH-1:0] inputs = '0;
    logic cfg_we = 1'b0;
    logic [1:0] cfg_layer = '0;
    logic [15:0] cfg_addr = '0;
    logic [DATA_WIDTH-1:0] cfg_wdata = '0;
    wire busy;
    wire valid;
    wire [OUTPUT_DIM*DATA_WIDTH-1:0] outputs;

    int errors = 0;

    always #5 clk = ~clk;

    fc_network #(
        .INPUT_DIM(INPUT_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .OUTPUT_DIM(OUTPUT_DIM),
        .OUTPUT_SIGMOID(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .inputs(inputs),
        .cfg_we(cfg_we),
        .cfg_layer(cfg_layer),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .busy(busy),
        .valid(valid),
        .outputs(outputs)
    );

    function automatic logic [15:0] q8_8(input real value);
        int scaled;
        begin
            scaled = $rtoi(value * 256.0);
            return scaled[15:0];
        end
    endfunction

    task automatic configure(
        input logic [1:0] layer,
        input int address,
        input real value
    );
        begin
            @(negedge clk);
            cfg_layer = layer;
            cfg_addr = address;
            cfg_wdata = q8_8(value);
            cfg_we = 1'b1;
            @(negedge clk);
            cfg_we = 1'b0;
        end
    endtask

    task automatic run_and_check(
        input string case_name,
        input real input0,
        input real input1,
        input int expected_q8
    );
        int elapsed;
        int difference;
        begin
            inputs[0*DATA_WIDTH +: DATA_WIDTH] = q8_8(input0);
            inputs[1*DATA_WIDTH +: DATA_WIDTH] = q8_8(input1);
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            elapsed = 0;
            while (!valid && elapsed < 100) begin
                @(posedge clk);
                #1;
                elapsed++;
            end
            if (!valid)
                $fatal(1, "%s timed out", case_name);

            difference = (outputs[15:0] > expected_q8)
                ? outputs[15:0] - expected_q8
                : expected_q8 - outputs[15:0];
            if (difference > 1) begin
                errors++;
                $error("%s got=%0d expected=%0d",
                       case_name, outputs[15:0], expected_q8);
            end else begin
                $display("PASS %-24s output=%0.4f cycles=%0d",
                         case_name, outputs[15:0]/256.0, elapsed);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Hidden layer is the identity transform.
        configure(2'd0, 0, 1.0); // input0 -> hidden0
        configure(2'd0, 1, 0.0); // input0 -> hidden1
        configure(2'd0, 2, 0.0); // input1 -> hidden0
        configure(2'd0, 3, 1.0); // input1 -> hidden1
        configure(2'd1, 0, 0.0);
        configure(2'd1, 1, 0.0);

        // Output preactivation is hidden0 + hidden1.
        configure(2'd2, 0, 1.0);
        configure(2'd2, 1, 1.0);
        configure(2'd3, 0, 0.0);

        // ReLU([1,-2]) = [1,0], sigmoid(1) ~= 0.7305 (187/256).
        run_and_check("ReLU and sigmoid", 1.0, -2.0, 187);
        // ReLU([-1,-2]) = [0,0], sigmoid(0) = 0.5.
        run_and_check("zero sigmoid", -1.0, -2.0, 128);
        // A Q8.8 output bias must be promoted before the Q16.16 MAC.
        configure(2'd3, 0, 1.0);
        run_and_check("output bias scaling", -1.0, -2.0, 187);

        if (errors != 0)
            $fatal(1, "FC network regression failed");
        $display("ALL FC NETWORK TESTS PASSED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global FC testbench timeout");
    end
endmodule
