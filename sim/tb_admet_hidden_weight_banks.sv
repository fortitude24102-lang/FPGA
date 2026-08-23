`timescale 1ns / 1ps

// Exercises the physical edges of the ADMET hidden-weight store: all four
// lane positions, address 199, and writes to an inactive bank while bank 0
// is executing.  The production reload/backpressure protocol is covered by
// tb_weight_bank_switch; this focused test keeps the arithmetic expectation
// small enough to identify a bank/address regression directly.
module tb_admet_hidden_weight_banks;
    localparam integer DESCRIPTOR_DIM = 20;
    localparam integer HIDDEN_DIM = 10;
    localparam integer DATA_WIDTH = 16;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [DESCRIPTOR_DIM*DATA_WIDTH-1:0] descriptors = '0;
    reg cfg_we = 1'b0;
    reg [1:0] cfg_model = '0;
    reg [1:0] cfg_layer = '0;
    reg [15:0] cfg_addr = '0;
    reg [DATA_WIDTH-1:0] cfg_wdata = '0;
    reg cfg_bank = 1'b0;
    reg run_bank = 1'b0;
    wire busy;
    wire valid;
    wire [4*DATA_WIDTH-1:0] predictions;

    always #5 clk = ~clk;

    admet_predictor #(
        .DESCRIPTOR_DIM(DESCRIPTOR_DIM), .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .descriptors(descriptors),
        .cfg_we(cfg_we), .cfg_model(cfg_model), .cfg_layer(cfg_layer),
        .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_bank(cfg_bank),
        .run_bank(run_bank), .busy(busy), .valid(valid), .logp(),
        .oral_bioavailability(), .herg_ic50(), .bbb_permeability(),
        .predictions(predictions)
    );

    task automatic configure(
        input integer bank, input integer model, input [1:0] layer,
        input integer address, input [15:0] value
    );
        begin
            @(negedge clk);
            cfg_bank = bank[0]; cfg_model = model[1:0]; cfg_layer = layer;
            cfg_addr = address[15:0]; cfg_wdata = value; cfg_we = 1'b1;
            @(negedge clk);
            cfg_we = 1'b0;
        end
    endtask

    task automatic launch_and_check(input integer bank, input [15:0] expected);
        integer model;
        integer elapsed;
        begin
            run_bank = bank[0];
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            elapsed = 0;
            while (!valid && elapsed < 500) begin
                @(posedge clk); elapsed = elapsed + 1;
            end
            if (!valid)
                $fatal(1, "ADMET bank %0d timed out", bank);
            for (model = 0; model < 4; model = model + 1)
                if (predictions[model*DATA_WIDTH +: DATA_WIDTH] != expected)
                    $fatal(1, "bank %0d model %0d got=%0d expected=%0d",
                           bank, model,
                           predictions[model*DATA_WIDTH +: DATA_WIDTH], expected);
            @(posedge clk);
        end
    endtask

    initial begin : test
        integer bank;
        integer model;
        integer address;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Deterministic double banks.  Four models use lanes 0..3 at input18;
        // model3 also executes the absolute final hidden-weight address 199.
        for (bank = 0; bank < 2; bank = bank + 1)
            for (model = 0; model < 4; model = model + 1) begin
                for (address = 0; address < 200; address = address + 1)
                    configure(bank, model, 2'd0, address, 16'd0);
                for (address = 0; address < 10; address = address + 1) begin
                    configure(bank, model, 2'd1, address, 16'd0);
                    configure(bank, model, 2'd2, address, 16'd0);
                end
                configure(bank, model, 2'd3, 0, 16'd0);
            end

        for (model = 0; model < 4; model = model + 1) begin
            configure(0, model, 2'd0, 180 + model, 16'd256);
            configure(0, model, 2'd2, model, 16'd256);
        end
        configure(0, 3, 2'd0, 199, 16'd256);
        configure(0, 3, 2'd2, 3, 16'd0);
        configure(0, 3, 2'd2, 9, 16'd256);
        descriptors = '0;
        descriptors[18*DATA_WIDTH +: DATA_WIDTH] = 16'd256;
        descriptors[19*DATA_WIDTH +: DATA_WIDTH] = 16'd256;

        // Inactive-bank programming deliberately happens while bank 0 is
        // executing.  It must not perturb the bank-0 prediction.
        @(negedge clk); run_bank = 1'b0; start = 1'b1;
        @(negedge clk); start = 1'b0;
        wait (busy);
        for (model = 0; model < 4; model = model + 1) begin
            configure(1, model, 2'd0, 180 + model, 16'd512);
            configure(1, model, 2'd2, model, 16'd256);
        end
        while (!valid) @(posedge clk);
        for (model = 0; model < 4; model = model + 1)
            if (predictions[model*DATA_WIDTH +: DATA_WIDTH] != 16'd187)
                $fatal(1, "bank0 overlap model %0d got=%0d", model,
                       predictions[model*DATA_WIDTH +: DATA_WIDTH]);
        @(posedge clk);

        // 2.0 Q8.8 activation maps to the next sigmoid knot (226/256).
        launch_and_check(1, 16'd226);
        $display("PASS ADMET hidden weights: four lanes, address 199, A/B overlap");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "ADMET hidden-weight bank test timeout");
    end
endmodule
