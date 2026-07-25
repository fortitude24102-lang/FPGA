`timescale 1ns / 1ps

module tb_gnn;
    localparam int MAX_NODES   = 3;
    localparam int FEATURE_DIM = 2;
    localparam int HIDDEN_DIM  = 2;
    localparam int DATA_WIDTH  = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [MAX_NODES*FEATURE_DIM*DATA_WIDTH-1:0] node_features_in = '0;
    logic [MAX_NODES*MAX_NODES-1:0] adjacency_in = '0;
    logic weight_we = 1'b0;
    logic [$clog2(FEATURE_DIM*HIDDEN_DIM)-1:0] weight_addr = '0;
    logic [DATA_WIDTH-1:0] weight_wdata = '0;
    wire busy;
    wire valid;
    wire [MAX_NODES*HIDDEN_DIM*DATA_WIDTH-1:0] node_features_out;

    int errors = 0;
    int checks = 0;

    always #5 clk = ~clk;

    gnn_message_passing #(
        .MAX_NODES(MAX_NODES),
        .FEATURE_DIM(FEATURE_DIM),
        .HIDDEN_DIM(HIDDEN_DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .node_features_in(node_features_in),
        .adjacency_in(adjacency_in),
        .feature_we(1'b0),
        .feature_word_addr(2'd0),
        .feature_wdata(32'd0),
        .feature_wstrb(4'd0),
        .adjacency_we(1'b0),
        .adjacency_word_addr(1'd0),
        .adjacency_wdata(32'd0),
        .adjacency_wstrb(4'd0),
        .output_re(1'b0),
        .output_word_addr(2'd0),
        .output_rdata(),
        .weight_we(weight_we),
        .weight_addr(weight_addr),
        .weight_wdata(weight_wdata),
        .busy(busy),
        .valid(valid),
        .node_features_out(node_features_out)
    );

    function automatic logic [15:0] q8_8(input real value);
        int scaled;
        begin
            scaled = $rtoi(value * 256.0);
            return scaled[15:0];
        end
    endfunction

    task automatic set_feature(input int node, input int feature, input real value);
        node_features_in[(node*FEATURE_DIM+feature)*DATA_WIDTH +: DATA_WIDTH]
            = q8_8(value);
    endtask

    task automatic set_edge(input int destination, input int source);
        adjacency_in[destination*MAX_NODES+source] = 1'b1;
    endtask

    task automatic write_weight(
        input int feature,
        input int hidden,
        input real value
    );
        begin
            @(negedge clk);
            weight_addr = feature*HIDDEN_DIM + hidden;
            weight_wdata = q8_8(value);
            weight_we = 1'b1;
            @(negedge clk);
            weight_we = 1'b0;
        end
    endtask

    task automatic check_output(
        input int node,
        input int hidden,
        input real expected_value
    );
        logic [15:0] actual;
        logic [15:0] expected;
        int difference;
        begin
            checks++;
            actual = node_features_out[
                (node*HIDDEN_DIM+hidden)*DATA_WIDTH +: DATA_WIDTH
            ];
            expected = q8_8(expected_value);
            difference = (actual > expected)
                ? actual - expected : expected - actual;
            if (difference > 1) begin
                errors++;
                $error("node=%0d hidden=%0d got=%0.4f expected=%0.4f",
                       node, hidden, $signed(actual)/256.0,
                       expected_value);
            end else begin
                $display("PASS node=%0d hidden=%0d value=%0.4f",
                         node, hidden, $signed(actual)/256.0);
            end
        end
    endtask

    initial begin
        int elapsed;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Weight matrix, indexed as weight[feature][hidden]:
        //   hidden 0 = [1.0, -1.0]
        //   hidden 1 = [0.5,  2.0]
        write_weight(0, 0,  1.0);
        write_weight(0, 1,  0.5);
        write_weight(1, 0, -1.0);
        write_weight(1, 1,  2.0);

        // Node features:
        //   node 0 = [ 1, 2]
        //   node 1 = [ 3, 4]
        //   node 2 = [-1, 1]
        set_feature(0, 0,  1.0);
        set_feature(0, 1,  2.0);
        set_feature(1, 0,  3.0);
        set_feature(1, 1,  4.0);
        set_feature(2, 0, -1.0);
        set_feature(2, 1,  1.0);

        // Destination 0 aggregates nodes 0 and 1.
        // Destination 1 aggregates node 2.
        // Destination 2 has no neighbors.
        set_edge(0, 0);
        set_edge(0, 1);
        set_edge(1, 2);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        elapsed = 0;
        while (!valid && elapsed < 200) begin
            @(posedge clk);
            #1;
            elapsed++;
        end
        if (!valid)
            $fatal(1, "GNN timeout after %0d cycles", elapsed);
        if (elapsed >= 200)
            errors++;
        else
            $display("GNN completed in %0d cycles", elapsed);

        check_output(0, 0,  0.0);
        check_output(0, 1, 14.0);
        check_output(1, 0,  0.0);
        check_output(1, 1,  1.5);
        check_output(2, 0,  0.0);
        check_output(2, 1,  0.0);

        $display("GNN summary: %0d checks, %0d errors", checks, errors);
        if (errors != 0)
            $fatal(1, "GNN regression failed");
        $display("ALL GNN TESTS PASSED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global GNN testbench timeout");
    end
endmodule
