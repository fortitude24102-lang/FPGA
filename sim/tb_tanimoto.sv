`timescale 1ns / 1ps

module tb_tanimoto;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [1023:0] query_fp = '0;
    logic [1023:0] db_fp = '0;
    wire busy;
    wire valid;
    wire [31:0] similarity;

    int tests = 0;
    int errors = 0;

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

    function automatic logic [31:0] reference_tanimoto(
        input logic [1023:0] query_value,
        input logic [1023:0] db_value
    );
        int intersection_count;
        int union_count;
        int bit_idx;
        begin
            intersection_count = 0;
            union_count = 0;
            for (bit_idx = 0; bit_idx < 1024; bit_idx++) begin
                intersection_count += query_value[bit_idx] & db_value[bit_idx];
                union_count += query_value[bit_idx] | db_value[bit_idx];
            end
            if (union_count == 0)
                reference_tanimoto = 32'd0;
            else
                reference_tanimoto =
                    (intersection_count * 32'd65536) / union_count;
        end
    endfunction

    function automatic logic [1023:0] random_fingerprint();
        logic [1023:0] value;
        int word_idx;
        begin
            for (word_idx = 0; word_idx < 32; word_idx++)
                value[word_idx*32 +: 32] = $urandom;
            return value;
        end
    endfunction

    task automatic launch(
        input logic [1023:0] query_value,
        input logic [1023:0] db_value
    );
        begin
            while (busy) @(posedge clk);
            @(negedge clk);
            query_fp = query_value;
            db_fp = db_value;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_for_valid(input int timeout_cycles);
        int elapsed;
        begin
            elapsed = 0;
            while (!valid && elapsed < timeout_cycles) begin
                @(posedge clk);
                #1;
                elapsed++;
            end
            if (!valid) begin
                errors++;
                $error("Timeout waiting for valid after %0d cycles", elapsed);
            end
        end
    endtask

    task automatic run_case(
        input string case_name,
        input logic [1023:0] query_value,
        input logic [1023:0] db_value
    );
        logic [31:0] expected;
        int difference;
        begin
            tests++;
            expected = reference_tanimoto(query_value, db_value);
            launch(query_value, db_value);
            wait_for_valid(64);
            if (valid) begin
                difference = (similarity > expected)
                    ? similarity - expected : expected - similarity;
                if (difference > 1) begin
                    errors++;
                    $error("%s: got 0x%08x, expected 0x%08x, diff=%0d",
                           case_name, similarity, expected, difference);
                end else begin
                    $display("PASS %-24s result=%0.6f cycles<=64",
                             case_name, similarity / 65536.0);
                end
            end
            @(posedge clk);
        end
    endtask

    initial begin
        logic [1023:0] random_a;
        logic [1023:0] random_b;
        logic [31:0] expected_first;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_case("identical all ones", {1024{1'b1}}, {1024{1'b1}});
        run_case("disjoint patterns", {512{2'b10}}, {512{2'b01}});
        run_case("empty fingerprints", 1024'd0, 1024'd0);
        run_case("one empty input", {1024{1'b1}}, 1024'd0);

        random_a = random_fingerprint();
        random_b = random_fingerprint();
        run_case("random pair 1", random_a, random_b);
        random_a = random_fingerprint();
        random_b = random_fingerprint();
        run_case("random pair 2", random_a, random_b);

        // A start pulse while busy must not replace the accepted transaction.
        tests++;
        random_a = random_fingerprint();
        random_b = random_fingerprint();
        expected_first = reference_tanimoto(random_a, random_b);
        launch(random_a, random_b);
        repeat (4) @(posedge clk);
        @(negedge clk);
        query_fp = {1024{1'b1}};
        db_fp = {1024{1'b1}};
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait_for_valid(64);
        if (similarity !== expected_first) begin
            errors++;
            $error("busy rejection: accepted operation was overwritten");
        end else begin
            $display("PASS %-24s result=0x%08x",
                     "start ignored while busy", similarity);
        end

        repeat (3) @(posedge clk);
        $display("Tanimoto summary: %0d tests, %0d errors", tests, errors);
        if (errors != 0)
            $fatal(1, "Tanimoto regression failed");
        $display("ALL TANIMOTO TESTS PASSED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global Tanimoto testbench timeout");
    end
endmodule
