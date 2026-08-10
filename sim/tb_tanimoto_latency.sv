`timescale 1ns / 1ps

module tb_tanimoto_latency;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1023:0] query_fp = '0;
    logic [1023:0] db_fp = '0;
    wire busy;
    wire valid;
    wire [31:0] similarity;

    always #5 clk = ~clk;

    tanimoto_accelerator dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .query_fp(query_fp),
        .db_fp(db_fp),
        .busy(busy),
        .valid(valid),
        .similarity(similarity)
    );

    task automatic measure_case(
        input logic [1023:0] query_value,
        input logic [1023:0] db_value,
        input int expected_cycles,
        input string case_name
    );
        int cycles;
        begin
            while (busy) @(posedge clk);
            @(negedge clk);
            query_fp = query_value;
            db_fp = db_value;
            start = 1'b1;
            cycles = 0;
            do begin
                @(posedge clk);
                #1;
                cycles++;
                if (cycles > 64)
                    $fatal(1, "%s timed out", case_name);
                if (cycles == 1)
                    start = 1'b0;
            end while (!valid);

            if (cycles != expected_cycles)
                $fatal(1, "%s latency=%0d, expected=%0d",
                       case_name, cycles, expected_cycles);
            $display("PASS Tanimoto %-12s latency: %0d cycles = %0.4f us at 100 MHz",
                     case_name, cycles, cycles / 100.0);
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        measure_case({1024{1'b1}}, {1024{1'b1}}, 5, "reciprocal");
        measure_case(1024'd0, 1024'd0, 3, "empty-union");
        $display("ALL TANIMOTO LATENCY TESTS PASSED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global Tanimoto latency testbench timeout");
    end
endmodule
