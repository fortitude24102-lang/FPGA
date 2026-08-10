`timescale 1ns / 1ps

// Tanimoto similarity accelerator.
//
// similarity = popcount(query_fp & db_fp) / popcount(query_fp | db_fp)
//
// The result is unsigned Q16.16.  A 1025-entry reciprocal ROM replaces the
// former 27-cycle restoring divider.  The ROM stores ceil(2^32 / union), then
// an 11x32 multiply and a 16-bit shift produce the Q16.16 quotient.  The
// reciprocal approximation differs from exact integer division by at most
// one output LSB for the complete 0..1024 population-count domain.
module tanimoto_accelerator (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [1023:0] query_fp,
    input  wire [1023:0] db_fp,
    output wire          busy,
    output wire          valid,
    output wire [31:0]   similarity
);

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_SUM    = 3'd1;
    localparam [2:0] ST_LOOKUP = 3'd2;
    localparam [2:0] ST_MULT   = 3'd3;
    localparam [2:0] ST_RESULT = 3'd4;
    localparam [2:0] ST_DONE   = 3'd5;

    reg [2:0] state;

    function [5:0] popcount32;
        input [31:0] value;
        integer bit_idx;
        begin
            popcount32 = 6'd0;
            for (bit_idx = 0; bit_idx < 32; bit_idx = bit_idx + 1)
                popcount32 = popcount32 + value[bit_idx];
        end
    endfunction

    wire [1023:0] intersection_bits = query_fp & db_fp;
    wire [1023:0] union_bits        = query_fp | db_fp;

    wire [5:0] intersection_count_32_comb [0:31];
    wire [5:0] union_count_32_comb        [0:31];
    reg  [5:0] intersection_count_32 [0:31];
    reg  [5:0] union_count_32        [0:31];
    wire [6:0] intersection_count_64 [0:15];
    wire [6:0] union_count_64        [0:15];
    wire [7:0] intersection_count_128[0:7];
    wire [7:0] union_count_128       [0:7];
    wire [8:0] intersection_count_256[0:3];
    wire [8:0] union_count_256       [0:3];
    wire [9:0] intersection_count_512[0:1];
    wire [9:0] union_count_512       [0:1];
    wire [10:0] intersection_count;
    wire [10:0] union_count;

    genvar group_idx;
    generate
        for (group_idx = 0; group_idx < 32; group_idx = group_idx + 1) begin : gen_count32
            assign intersection_count_32_comb[group_idx] =
                popcount32(intersection_bits[group_idx*32 +: 32]);
            assign union_count_32_comb[group_idx] =
                popcount32(union_bits[group_idx*32 +: 32]);
        end
        for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin : gen_count64
            assign intersection_count_64[group_idx] =
                intersection_count_32[group_idx*2] +
                intersection_count_32[group_idx*2+1];
            assign union_count_64[group_idx] =
                union_count_32[group_idx*2] +
                union_count_32[group_idx*2+1];
        end
        for (group_idx = 0; group_idx < 8; group_idx = group_idx + 1) begin : gen_count128
            assign intersection_count_128[group_idx] =
                intersection_count_64[group_idx*2] +
                intersection_count_64[group_idx*2+1];
            assign union_count_128[group_idx] =
                union_count_64[group_idx*2] +
                union_count_64[group_idx*2+1];
        end
        for (group_idx = 0; group_idx < 4; group_idx = group_idx + 1) begin : gen_count256
            assign intersection_count_256[group_idx] =
                intersection_count_128[group_idx*2] +
                intersection_count_128[group_idx*2+1];
            assign union_count_256[group_idx] =
                union_count_128[group_idx*2] +
                union_count_128[group_idx*2+1];
        end
        for (group_idx = 0; group_idx < 2; group_idx = group_idx + 1) begin : gen_count512
            assign intersection_count_512[group_idx] =
                intersection_count_256[group_idx*2] +
                intersection_count_256[group_idx*2+1];
            assign union_count_512[group_idx] =
                union_count_256[group_idx*2] +
                union_count_256[group_idx*2+1];
        end
    endgenerate

    assign intersection_count =
        intersection_count_512[0] + intersection_count_512[1];
    assign union_count = union_count_512[0] + union_count_512[1];

    integer count_group;
    always @(posedge clk) begin
        if (state == ST_IDLE && start) begin
            for (count_group = 0; count_group < 32;
                 count_group = count_group + 1) begin
                intersection_count_32[count_group] <=
                    intersection_count_32_comb[count_group];
                union_count_32[count_group] <= union_count_32_comb[count_group];
            end
        end
    end

    // Distributed ROM keeps lookup asynchronous and avoids consuming an
    // extra block-RAM read cycle.  Entry 1 saturates because 2^32 does not fit
    // in 32 bits; that case is exactly one Q16.16 LSB low and is permitted by
    // the numerical acceptance tolerance.
    (* rom_style = "distributed" *)
    reg [31:0] reciprocal_rom [0:1024];
    integer reciprocal_index;
    initial begin
        reciprocal_rom[0] = 32'd0;
        reciprocal_rom[1] = 32'hffff_ffff;
        for (reciprocal_index = 2; reciprocal_index <= 1024;
             reciprocal_index = reciprocal_index + 1)
            reciprocal_rom[reciprocal_index] =
                (64'h1_0000_0000 + reciprocal_index - 1) /
                reciprocal_index;
    end

    reg [10:0] intersection_count_reg;
    reg [10:0] union_count_reg;
    reg [31:0] reciprocal_reg;
    reg [10:0] multiplier_intersection_reg;
    reg [42:0] quotient_product_reg;
    reg [31:0] result_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                       <= ST_IDLE;
            intersection_count_reg      <= 11'd0;
            union_count_reg             <= 11'd0;
            reciprocal_reg              <= 32'd0;
            multiplier_intersection_reg <= 11'd0;
            quotient_product_reg        <= 43'd0;
            result_reg                  <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start)
                        state <= ST_SUM;
                end

                ST_SUM: begin
                    intersection_count_reg <= intersection_count;
                    union_count_reg        <= union_count;
                    state                  <= ST_LOOKUP;
                end

                ST_LOOKUP: begin
                    if (union_count_reg == 0) begin
                        result_reg <= 32'd0;
                        state      <= ST_DONE;
                    end else begin
                        reciprocal_reg <= reciprocal_rom[union_count_reg];
                        multiplier_intersection_reg <= intersection_count_reg;
                        state <= ST_MULT;
                    end
                end

                ST_MULT: begin
                    quotient_product_reg <=
                        multiplier_intersection_reg * reciprocal_reg;
                    state <= ST_RESULT;
                end

                ST_RESULT: begin
                    result_reg <= quotient_product_reg[42:16];
                    state      <= ST_DONE;
                end

                ST_DONE: state <= ST_IDLE;
                default: state <= ST_IDLE;
            endcase
        end
    end

    assign busy       = (state != ST_IDLE);
    assign valid      = (state == ST_DONE);
    assign similarity = result_reg;

endmodule
