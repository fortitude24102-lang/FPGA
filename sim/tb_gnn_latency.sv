`timescale 1ns / 1ps

module tb_gnn_latency;
    localparam int MAX_NODES = 50;
    localparam int FEATURE_DIM = 64;
    localparam int HIDDEN_DIM = 128;
    localparam int DATA_WIDTH = 16;
    // 13.4706 ms Python baseline / 10x target at 100 MHz.
    localparam int MAX_CYCLES_AT_100MHZ = 134_705;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    wire busy;
    wire valid;

    always #5 clk = ~clk;

    gnn_message_passing #(
        .MAX_NODES(MAX_NODES),
        .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH),
        .PACKED_IO(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .input_write_bank(1'b0),
        .input_run_bank(1'b0),
        .node_features_in(
            {MAX_NODES*FEATURE_DIM*DATA_WIDTH{1'b0}}
        ),
        .adjacency_in({MAX_NODES*MAX_NODES{1'b0}}),
        .node_features_out(),
        .feature_we(1'b0),
        .feature_word_addr(11'd0),
        .feature_wdata(32'd0),
        .feature_wstrb(4'd0),
        .adjacency_we(1'b0),
        .adjacency_word_addr(7'd0),
        .adjacency_wdata(32'd0),
        .adjacency_wstrb(4'd0),
        .output_re(1'b0),
        .output_word_addr(12'd0),
        .output_rdata(),
        .weight_we(1'b0),
        .weight_addr(13'd0),
        .weight_wdata(16'd0),
        .busy(busy),
        .valid(valid)
    );

    initial begin
        int cycles;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (!valid && cycles <= MAX_CYCLES_AT_100MHZ) begin
            @(posedge clk);
            #1;
            cycles++;
        end
        if (!valid)
            $fatal(1,
                "Default GNN exceeded %0d cycles (10x speedup target)",
                MAX_CYCLES_AT_100MHZ);

        $display(
            "PASS default GNN latency: %0d cycles = %0.4f ms at 100 MHz",
            cycles, cycles / 100000.0
        );
        $finish;
    end

    initial begin
        #12000000;
        $fatal(1, "Global default GNN latency timeout");
    end
endmodule
