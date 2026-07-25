`timescale 1ns / 1ps

// Tanimoto similarity accelerator.
//
// similarity = popcount(query_fp & db_fp) / popcount(query_fp | db_fp)
//
// The result is unsigned Q16.16.  The design is vendor independent: a
// balanced popcount tree is followed by a 27-cycle restoring divider.  A
// start pulse is accepted only while busy is low.  query_fp and db_fp are
// sampled by the combinational popcount tree on the accepting clock edge.
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

    localparam ST_IDLE = 2'd0;
    localparam ST_DIV  = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0] state;

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

    wire [5:0] intersection_count_32 [0:31];
    wire [5:0] union_count_32        [0:31];
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
            assign intersection_count_32[group_idx] =
                popcount32(intersection_bits[group_idx*32 +: 32]);
            assign union_count_32[group_idx] =
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

    // Restoring divider.  The numerator has 11 integer bits and 16
    // fractional bits.  Its quotient is therefore the required Q16.16 value.
    reg [26:0] numerator;
    reg [10:0] denominator;
    reg [11:0] remainder;
    reg [26:0] quotient;
    reg [4:0]  bit_index;
    reg [31:0] result_reg;

    wire [11:0] shifted_remainder =
        {remainder[10:0], numerator[bit_index]};
    wire subtract_denominator =
        shifted_remainder >= {1'b0, denominator};
    wire [11:0] next_remainder =
        subtract_denominator
            ? shifted_remainder - {1'b0, denominator}
            : shifted_remainder;
    wire [26:0] quotient_with_current_bit =
        subtract_denominator
            ? (quotient | (27'd1 << bit_index))
            : quotient;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            numerator   <= 27'd0;
            denominator <= 11'd0;
            remainder   <= 12'd0;
            quotient    <= 27'd0;
            bit_index   <= 5'd0;
            result_reg  <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (union_count == 0) begin
                            result_reg <= 32'd0;
                            state      <= ST_DONE;
                        end else begin
                            numerator   <= {intersection_count, 16'd0};
                            denominator <= union_count;
                            remainder   <= 12'd0;
                            quotient    <= 27'd0;
                            bit_index   <= 5'd26;
                            state       <= ST_DIV;
                        end
                    end
                end

                ST_DIV: begin
                    remainder <= next_remainder;
                    quotient  <= quotient_with_current_bit;
                    if (bit_index == 0) begin
                        result_reg <= {5'd0, quotient_with_current_bit};
                        state      <= ST_DONE;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                    end
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
