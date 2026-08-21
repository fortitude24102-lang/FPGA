`timescale 1ns / 1ps

module tb_admet;
    localparam int DESCRIPTOR_DIM = 20;
    localparam int HIDDEN_DIM = 2;
    localparam int DATA_WIDTH = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [DESCRIPTOR_DIM*DATA_WIDTH-1:0] descriptors = '0;
    logic cfg_we = 1'b0;
    logic [1:0] cfg_model = '0;
    logic [1:0] cfg_layer = '0;
    logic [15:0] cfg_addr = '0;
    logic [DATA_WIDTH-1:0] cfg_wdata = '0;
    wire busy;
    wire valid;
    wire [DATA_WIDTH-1:0] logp;
    wire [DATA_WIDTH-1:0] oral_bioavailability;
    wire [DATA_WIDTH-1:0] herg_ic50;
    wire [DATA_WIDTH-1:0] bbb_permeability;
    wire [4*DATA_WIDTH-1:0] predictions;

    int errors = 0;

    always #5 clk = ~clk;

    admet_predictor #(
        .DESCRIPTOR_DIM(DESCRIPTOR_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .descriptors(descriptors),
        .cfg_we(cfg_we),
        .cfg_model(cfg_model),
        .cfg_layer(cfg_layer),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_bank(1'b0), .run_bank(1'b0),
        .busy(busy),
        .valid(valid),
        .logp(logp),
        .oral_bioavailability(oral_bioavailability),
        .herg_ic50(herg_ic50),
        .bbb_permeability(bbb_permeability),
        .predictions(predictions)
    );

    function automatic logic [15:0] q8_8(input real value);
        int scaled;
        begin
            scaled = $rtoi(value * 256.0);
            return scaled[15:0];
        end
    endfunction

    task automatic configure(
        input int model,
        input logic [1:0] layer,
        input int address,
        input real value
    );
        begin
            @(negedge clk);
            cfg_model = model[1:0];
            cfg_layer = layer;
            cfg_addr = address;
            cfg_wdata = q8_8(value);
            cfg_we = 1'b1;
            @(negedge clk);
            cfg_we = 1'b0;
        end
    endtask

    initial begin
        int model;
        int address;
        int elapsed;
        int expected;
        int difference;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (model = 0; model < 4; model++) begin
            for (address = 0;
                 address < DESCRIPTOR_DIM*HIDDEN_DIM;
                 address++)
                configure(model, 2'd0, address, 0.0);
            for (address = 0; address < HIDDEN_DIM; address++)
                configure(model, 2'd1, address, 0.0);
            for (address = 0; address < HIDDEN_DIM; address++)
                configure(model, 2'd2, address, 0.0);
            configure(model, 2'd3, 0, 0.0);

            // descriptor0 -> hidden0 -> output
            configure(model, 2'd0, 0, 1.0);
            configure(model, 2'd2, 0, 1.0);
        end

        descriptors = '0;
        descriptors[0 +: DATA_WIDTH] = q8_8(1.0);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        elapsed = 0;
        while (!valid && elapsed < 500) begin
            @(posedge clk);
            #1;
            elapsed++;
        end
        if (!valid)
            $fatal(1, "ADMET timeout");

        expected = 187; // sigmoid(1.0) in the piecewise Q8.8 LUT
        for (model = 0; model < 4; model++) begin
            difference =
                (predictions[model*DATA_WIDTH +: DATA_WIDTH] > expected)
                ? predictions[model*DATA_WIDTH +: DATA_WIDTH] - expected
                : expected - predictions[model*DATA_WIDTH +: DATA_WIDTH];
            if (difference > 1) begin
                errors++;
                $error("model %0d got=%0d expected=%0d",
                       model,
                       predictions[model*DATA_WIDTH +: DATA_WIDTH],
                       expected);
            end else begin
                $display("PASS ADMET model %0d output=%0.4f",
                         model,
                         predictions[model*DATA_WIDTH +: DATA_WIDTH]/256.0);
            end
        end

        if (errors != 0)
            $fatal(1, "ADMET regression failed");
        $display("ALL ADMET TESTS PASSED in %0d cycles", elapsed);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Global ADMET testbench timeout");
    end
endmodule
