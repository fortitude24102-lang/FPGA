`timescale 1ns/1ps

module tb_tanimoto_stream_batch;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start = 0;
    reg abort = 0;
    reg [6:0] item_count = 0;
    reg payload_valid = 0;
    wire payload_ready;
    reg [31:0] payload_data = 0;
    reg payload_last = 0;
    wire result_valid;
    reg result_ready = 0;
    wire [31:0] result_data;
    wire result_last;
    wire busy, done, error;
    wire core_start;
    wire [1023:0] core_query_fp, core_db_fp;
    wire core_busy, core_valid;
    wire [31:0] core_similarity;

    tanimoto_stream_batch dut (
        .clk(clk), .rst_n(resetn), .start(start), .abort(abort),
        .item_count(item_count),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .result_last(result_last),
        .busy(busy), .done(done), .error(error),
        .core_start(core_start), .core_query_fp(core_query_fp),
        .core_db_fp(core_db_fp), .core_busy(core_busy),
        .core_valid(core_valid), .core_similarity(core_similarity)
    );

    tanimoto_accelerator core (
        .clk(clk), .rst_n(resetn), .start(core_start),
        .query_fp(core_query_fp), .db_fp(core_db_fp),
        .busy(core_busy), .valid(core_valid), .similarity(core_similarity)
    );

    reg [31:0] payload [0:2079];
    reg [31:0] expected [0:63];
    reg [1023:0] query_bits;
    reg [1023:0] candidate_bits;
    integer cycle_count = 0;
    integer results_seen;
    integer total_payload_words;
    integer i, j, word_index;
    reg [31:0] lfsr;
    reg watch_stale_result = 0;
    reg stale_result_seen = 0;

    function [31:0] reference_similarity;
        input [1023:0] query_value;
        input [1023:0] candidate_value;
        integer bit_index;
        integer intersection_count;
        integer union_count;
        reg [63:0] reciprocal;
        reg [63:0] product;
        begin
            intersection_count = 0;
            union_count = 0;
            for (bit_index = 0; bit_index < 1024; bit_index = bit_index + 1) begin
                if (query_value[bit_index] && candidate_value[bit_index])
                    intersection_count = intersection_count + 1;
                if (query_value[bit_index] || candidate_value[bit_index])
                    union_count = union_count + 1;
            end
            if (union_count == 0) begin
                reference_similarity = 0;
            end else begin
                if (union_count == 1)
                    reciprocal = 64'h00000000FFFFFFFF;
                else
                    reciprocal = (64'd4294967296 + union_count - 1) / union_count;
                product = intersection_count * reciprocal;
                reference_similarity = product >> 16;
            end
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0;
            result_ready <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            result_ready <= (cycle_count[3:0] != 4'h5) &&
                            (cycle_count[3:0] != 4'h6) &&
                            (cycle_count[3:0] != 4'hC);
            if (watch_stale_result && result_valid)
                stale_result_seen <= 1;
        end
    end

    task automatic build_batch;
        input integer count;
        input [31:0] seed;
        begin
            lfsr = seed;
            query_bits = 0;
            for (word_index = 0; word_index < 32; word_index = word_index + 1) begin
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                if ((count == 1) && (word_index < 32))
                    payload[word_index] = 32'hA5A5A5A5 ^ word_index;
                else
                    payload[word_index] = lfsr;
                query_bits[word_index*32 +: 32] = payload[word_index];
            end
            for (j = 0; j < count; j = j + 1) begin
                candidate_bits = 0;
                for (word_index = 0; word_index < 32; word_index = word_index + 1) begin
                    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                    if ((count == 1) || ((count == 2) && (j == 0)))
                        payload[32 + j*32 + word_index] = payload[word_index];
                    else if ((count == 2) && (j == 1))
                        payload[32 + j*32 + word_index] = ~payload[word_index];
                    else
                        payload[32 + j*32 + word_index] = lfsr ^ (j * 32'h01010101);
                    candidate_bits[word_index*32 +: 32] =
                        payload[32 + j*32 + word_index];
                end
                expected[j] = reference_similarity(query_bits, candidate_bits);
            end
            total_payload_words = 32 + 32*count;
        end
    endtask

    task automatic run_batch;
        input integer count;
        input [31:0] seed;
        integer timeout;
        begin
            build_batch(count, seed);
            results_seen = 0;
            @(negedge clk);
            item_count = count;
            start = 1;
            @(negedge clk);
            start = 0;
            fork
                begin : payload_sender
                    for (i = 0; i < total_payload_words; i = i + 1) begin
                        payload_data = payload[i];
                        payload_last = (i == total_payload_words - 1);
                        payload_valid = 1;
                        while (!payload_ready) @(negedge clk);
                        @(negedge clk);
                        payload_valid = 0;
                        payload_last = 0;
                        if ((i % 13) == 4) @(negedge clk);
                    end
                end
                begin : result_receiver
                    timeout = 0;
                    while ((results_seen < count) && (timeout < 50000)) begin
                        @(posedge clk);
                        timeout = timeout + 1;
                        if (result_valid && result_ready) begin
                            if (result_data !== expected[results_seen] ||
                                result_last !== (results_seen == count - 1)) begin
                                $display("FAIL N=%0d result[%0d]=%08x expected=%08x last=%0b",
                                         count, results_seen, result_data,
                                         expected[results_seen], result_last);
                                $fatal(1);
                            end
                            results_seen = results_seen + 1;
                        end
                    end
                    if (timeout == 50000) begin
                        $display("FAIL N=%0d result timeout", count);
                        $fatal(1);
                    end
                end
            join
            timeout = 0;
            while (busy && timeout < 1000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (busy || error || results_seen != count) begin
                $display("FAIL N=%0d completion busy=%0b error=%0b results=%0d",
                         count, busy, error, results_seen);
                $fatal(1);
            end
            $display("PASS shared-query Tanimoto N=%0d", count);
        end
    endtask

    task automatic test_error_and_abort_recovery;
        begin
            @(negedge clk);
            item_count = 1;
            start = 1;
            @(negedge clk);
            start = 0;
            payload_data = 32'h12345678;
            payload_last = 1;
            payload_valid = 1;
            while (!payload_ready) @(negedge clk);
            @(negedge clk);
            payload_valid = 0;
            payload_last = 0;
            repeat (5) @(posedge clk);
            if (!error || busy || result_valid) begin
                $display("FAIL early TLAST recovery error=%0b busy=%0b result=%0b",
                         error, busy, result_valid);
                $fatal(1);
            end

            @(negedge clk);
            abort = 1;
            @(negedge clk);
            abort = 0;
            item_count = 1;
            start = 1;
            @(negedge clk);
            start = 0;
            for (i = 0; i < 10; i = i + 1) begin
                payload_data = i;
                payload_valid = 1;
                while (!payload_ready) @(negedge clk);
                @(negedge clk);
                payload_valid = 0;
            end
            abort = 1;
            @(negedge clk);
            abort = 0;
            repeat (2) @(posedge clk);
            if (busy || error || result_valid) begin
                $display("FAIL abort recovery error=%0b busy=%0b result=%0b",
                         error, busy, result_valid);
                $fatal(1);
            end

            @(negedge clk);
            item_count = 0;
            start = 1;
            @(negedge clk);
            start = 0;
            @(posedge clk);
            if (!error || busy) begin
                $display("FAIL zero item_count validation error=%0b busy=%0b",
                         error, busy);
                $fatal(1);
            end
            abort = 1;
            @(negedge clk);
            abort = 0;
            $display("PASS Tanimoto stream error and abort recovery");
        end
    endtask

    task automatic test_abort_ignores_late_core_result;
        begin
            build_batch(1, 32'h0BADCAFE);
            stale_result_seen = 0;
            @(negedge clk);
            item_count = 1;
            start = 1;
            @(negedge clk);
            start = 0;
            for (i = 0; i < total_payload_words; i = i + 1) begin
                payload_data = payload[i];
                payload_last = (i == total_payload_words - 1);
                payload_valid = 1;
                while (!payload_ready) @(negedge clk);
                @(negedge clk);
                payload_valid = 0;
                payload_last = 0;
            end
            while (!core_busy) @(posedge clk);
            watch_stale_result = 1;
            @(negedge clk);
            abort = 1;
            @(negedge clk);
            abort = 0;
            repeat (20) @(posedge clk);
            watch_stale_result = 0;
            if (stale_result_seen || busy || error) begin
                $display("FAIL late core result after abort stale=%0b busy=%0b error=%0b",
                         stale_result_seen, busy, error);
                $fatal(1);
            end
            $display("PASS abort ignores late core result");
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        run_batch(1, 32'h13579BDF);
        run_batch(2, 32'h2468ACE1);
        run_batch(64, 32'h1ACEB00C);
        test_error_and_abort_recovery();
        test_abort_ignores_late_core_result();
        $display("ALL TANIMOTO STREAM BATCH TESTS PASSED");
        $finish;
    end
endmodule
