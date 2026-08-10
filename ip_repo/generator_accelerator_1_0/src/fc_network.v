`timescale 1ns / 1ps

// Parameterized, single-hidden-layer fully connected network.
//
// Numeric format: signed Q8.8 by default.  The hidden layer uses ReLU.
// OUTPUT_SIGMOID selects either a piecewise-linear sigmoid (1) or ReLU (0)
// for the output layer.  One multiplier is reused for all MAC operations.
module fc_network #(
    parameter integer INPUT_DIM      = 20,
    parameter integer HIDDEN_DIM     = 10,
    parameter integer OUTPUT_DIM     = 1,
    parameter integer DATA_WIDTH     = 16,
    parameter integer FRAC_BITS      = 8,
    parameter integer ACC_WIDTH      = 48,
    parameter integer OUTPUT_SIGMOID = 1,
    parameter integer HIDDEN_LANES   = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [INPUT_DIM*DATA_WIDTH-1:0] inputs,

    // Configuration port.  cfg_layer selects:
    //   0: input-to-hidden weights, address=input*HIDDEN+hidden
    //   1: hidden biases,          address=hidden
    //   2: hidden-to-output weights,address=hidden*OUTPUT+output
    //   3: output biases,          address=output
    input  wire        cfg_we,
    input  wire [1:0]  cfg_layer,
    input  wire [15:0] cfg_addr,
    input  wire [DATA_WIDTH-1:0] cfg_wdata,

    output wire busy,
    output wire valid,
    output wire [OUTPUT_DIM*DATA_WIDTH-1:0] outputs
);

    localparam integer INPUT_IDX_W =
        (INPUT_DIM <= 1) ? 1 : $clog2(INPUT_DIM);
    localparam integer HIDDEN_IDX_W =
        (HIDDEN_DIM <= 1) ? 1 : $clog2(HIDDEN_DIM);
    localparam integer OUTPUT_IDX_W =
        (OUTPUT_DIM <= 1) ? 1 : $clog2(OUTPUT_DIM);

    localparam [2:0] ST_IDLE         = 3'd0;
    localparam [2:0] ST_HIDDEN_INIT  = 3'd1;
    localparam [2:0] ST_HIDDEN_MAC   = 3'd2;
    localparam [2:0] ST_HIDDEN_ACT   = 3'd3;
    localparam [2:0] ST_OUTPUT_INIT  = 3'd4;
    localparam [2:0] ST_OUTPUT_MAC   = 3'd5;
    localparam [2:0] ST_OUTPUT_ACT   = 3'd6;
    localparam [2:0] ST_DONE         = 3'd7;

    reg [2:0] state;
    reg [INPUT_IDX_W-1:0] input_idx;
    reg [HIDDEN_IDX_W-1:0] hidden_idx;
    reg [HIDDEN_IDX_W-1:0] hidden_base;
    reg [OUTPUT_IDX_W-1:0] output_idx;
    reg signed [ACC_WIDTH-1:0] accumulator;
    reg signed [ACC_WIDTH-1:0] hidden_accumulator
        [0:HIDDEN_LANES-1];
    reg hidden_mac_valid;
    reg hidden_all_issued;
    reg signed [DATA_WIDTH-1:0] hidden_input_reg;
    reg signed [DATA_WIDTH-1:0] hidden_weight_reg
        [0:HIDDEN_LANES-1];

    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] hidden_weights
        [0:INPUT_DIM*HIDDEN_DIM-1];
    reg signed [DATA_WIDTH-1:0] hidden_biases [0:HIDDEN_DIM-1];
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] output_weights
        [0:HIDDEN_DIM*OUTPUT_DIM-1];
    reg signed [DATA_WIDTH-1:0] output_biases [0:OUTPUT_DIM-1];

    reg signed [DATA_WIDTH-1:0] hidden_values [0:HIDDEN_DIM-1];
    reg [DATA_WIDTH-1:0] output_values [0:OUTPUT_DIM-1];

    wire signed [DATA_WIDTH-1:0] selected_input =
        inputs[input_idx*DATA_WIDTH +: DATA_WIDTH];
    wire signed [DATA_WIDTH-1:0] selected_hidden_value =
        hidden_values[hidden_idx];
    wire signed [DATA_WIDTH-1:0] selected_output_weight =
        output_weights[hidden_idx*OUTPUT_DIM + output_idx];

    wire signed [2*DATA_WIDTH-1:0] output_product =
        selected_hidden_value * selected_output_weight;
    wire signed [ACC_WIDTH-1:0] output_mac_next =
        accumulator + output_product;

    function [DATA_WIDTH-1:0] relu_quantize;
        input signed [ACC_WIDTH-1:0] value_q16;
        reg signed [ACC_WIDTH-1:0] shifted_value;
        reg signed [ACC_WIDTH-1:0] maximum_value;
        begin
            shifted_value = value_q16 >>> FRAC_BITS;
            maximum_value = (1 << (DATA_WIDTH-1)) - 1;
            if (value_q16 <= 0)
                relu_quantize = {DATA_WIDTH{1'b0}};
            else if (shifted_value > maximum_value)
                relu_quantize = {1'b0, {(DATA_WIDTH-1){1'b1}}};
            else
                relu_quantize = shifted_value[DATA_WIDTH-1:0];
        end
    endfunction

    // Piecewise-linear sigmoid for signed Q8.8 input and Q8.8 output.
    // Knot points: -8, -4, -2, -1, 0, 1, 2, 4, 8.
    function [DATA_WIDTH-1:0] sigmoid_q8_8;
        input signed [DATA_WIDTH-1:0] x;
        integer xi;
        integer yi;
        begin
            xi = x;
            if (xi <= -2048)
                yi = 0;
            else if (xi < -1024)
                yi = ((xi + 2048) * 5) >>> 10;
            else if (xi < -512)
                yi = 5 + (((xi + 1024) * 25) >>> 9);
            else if (xi < -256)
                yi = 30 + (((xi + 512) * 39) >>> 8);
            else if (xi < 0)
                yi = 69 + (((xi + 256) * 59) >>> 8);
            else if (xi < 256)
                yi = 128 + ((xi * 59) >>> 8);
            else if (xi < 512)
                yi = 187 + (((xi - 256) * 39) >>> 8);
            else if (xi < 1024)
                yi = 226 + (((xi - 512) * 25) >>> 9);
            else if (xi < 2048)
                yi = 251 + (((xi - 1024) * 5) >>> 10);
            else
                yi = 256;
            sigmoid_q8_8 = yi[DATA_WIDTH-1:0];
        end
    endfunction

    function [DATA_WIDTH-1:0] output_activation;
        input signed [ACC_WIDTH-1:0] value_q16;
        reg signed [DATA_WIDTH-1:0] value_q8;
        reg signed [ACC_WIDTH-1:0] shifted_value;
        begin
            shifted_value = value_q16 >>> FRAC_BITS;
            if (OUTPUT_SIGMOID != 0) begin
                if (shifted_value <= -2048)
                    output_activation = {DATA_WIDTH{1'b0}};
                else if (shifted_value >= 2048)
                    output_activation =
                        {{(DATA_WIDTH-9){1'b0}}, 9'd256};
                else begin
                    value_q8 = shifted_value[DATA_WIDTH-1:0];
                    output_activation = sigmoid_q8_8(value_q8);
                end
            end else begin
                output_activation = relu_quantize(value_q16);
            end
        end
    endfunction

    always @(posedge clk) begin
        if (cfg_we && state == ST_IDLE) begin
            case (cfg_layer)
                2'd0: if (cfg_addr < INPUT_DIM*HIDDEN_DIM)
                    hidden_weights[cfg_addr] <= cfg_wdata;
                2'd1: if (cfg_addr < HIDDEN_DIM)
                    hidden_biases[cfg_addr] <= cfg_wdata;
                2'd2: if (cfg_addr < HIDDEN_DIM*OUTPUT_DIM)
                    output_weights[cfg_addr] <= cfg_wdata;
                2'd3: if (cfg_addr < OUTPUT_DIM)
                    output_biases[cfg_addr] <= cfg_wdata;
                default: ;
            endcase
        end
    end

    integer lane_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            input_idx   <= {INPUT_IDX_W{1'b0}};
            hidden_idx  <= {HIDDEN_IDX_W{1'b0}};
            hidden_base <= {HIDDEN_IDX_W{1'b0}};
            output_idx  <= {OUTPUT_IDX_W{1'b0}};
            accumulator <= {ACC_WIDTH{1'b0}};
            hidden_mac_valid <= 1'b0;
            hidden_all_issued <= 1'b0;
            hidden_input_reg <= {DATA_WIDTH{1'b0}};
            for (lane_idx = 0; lane_idx < HIDDEN_LANES;
                 lane_idx = lane_idx + 1) begin
                hidden_accumulator[lane_idx] <= {ACC_WIDTH{1'b0}};
                hidden_weight_reg[lane_idx] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        hidden_base <= {HIDDEN_IDX_W{1'b0}};
                        state       <= ST_HIDDEN_INIT;
                    end
                end

                ST_HIDDEN_INIT: begin
                    input_idx <= {INPUT_IDX_W{1'b0}};
                    hidden_mac_valid <= 1'b0;
                    hidden_all_issued <= 1'b0;
                    for (lane_idx = 0; lane_idx < HIDDEN_LANES;
                         lane_idx = lane_idx + 1) begin
                        if (hidden_base + lane_idx < HIDDEN_DIM)
                            hidden_accumulator[lane_idx] <=
                                $signed({
                                    {(ACC_WIDTH-DATA_WIDTH){
                                        hidden_biases[hidden_base + lane_idx]
                                            [DATA_WIDTH-1]
                                    }},
                                    hidden_biases[hidden_base + lane_idx]
                                }) <<< FRAC_BITS;
                        else
                            hidden_accumulator[lane_idx] <=
                                {ACC_WIDTH{1'b0}};
                    end
                    state <= ST_HIDDEN_MAC;
                end

                ST_HIDDEN_MAC: begin
                    // Accumulate the previously registered weight/input pair.
                    // This removes the LUTRAM-address -> RAM -> DSP ->
                    // accumulator path that was the final 100 MHz violation.
                    if (hidden_mac_valid)
                        for (lane_idx = 0; lane_idx < HIDDEN_LANES;
                             lane_idx = lane_idx + 1)
                            if (hidden_base + lane_idx < HIDDEN_DIM)
                                hidden_accumulator[lane_idx] <=
                                    hidden_accumulator[lane_idx] +
                                    $signed(hidden_input_reg) *
                                    $signed(hidden_weight_reg[lane_idx]);

                    if (!hidden_all_issued) begin
                        hidden_input_reg <= selected_input;
                        for (lane_idx = 0; lane_idx < HIDDEN_LANES;
                             lane_idx = lane_idx + 1)
                            if (hidden_base + lane_idx < HIDDEN_DIM)
                                hidden_weight_reg[lane_idx] <=
                                    hidden_weights[
                                        input_idx*HIDDEN_DIM + hidden_base +
                                        lane_idx
                                    ];
                            else
                                hidden_weight_reg[lane_idx] <=
                                    {DATA_WIDTH{1'b0}};
                        hidden_mac_valid <= 1'b1;
                        if (input_idx == INPUT_DIM-1)
                            hidden_all_issued <= 1'b1;
                        else
                            input_idx <= input_idx + 1'b1;
                    end else if (hidden_mac_valid) begin
                        hidden_mac_valid <= 1'b0;
                    end else begin
                        state <= ST_HIDDEN_ACT;
                    end
                end

                // Four hidden neurons are accumulated in parallel by default.
                // Keeping activation in its own cycle preserves the 100 MHz
                // timing boundary after the final MAC.
                ST_HIDDEN_ACT: begin
                    for (lane_idx = 0; lane_idx < HIDDEN_LANES;
                         lane_idx = lane_idx + 1)
                        if (hidden_base + lane_idx < HIDDEN_DIM)
                            hidden_values[hidden_base + lane_idx] <=
                                relu_quantize(
                                    hidden_accumulator[lane_idx]);
                    if (hidden_base + HIDDEN_LANES >= HIDDEN_DIM) begin
                        output_idx <= {OUTPUT_IDX_W{1'b0}};
                        state      <= ST_OUTPUT_INIT;
                    end else begin
                        hidden_base <= hidden_base + HIDDEN_LANES;
                        state       <= ST_HIDDEN_INIT;
                    end
                end

                ST_OUTPUT_INIT: begin
                    hidden_idx  <= {HIDDEN_IDX_W{1'b0}};
                    accumulator <=
                        $signed({
                            {(ACC_WIDTH-DATA_WIDTH){
                                output_biases[output_idx][DATA_WIDTH-1]
                            }},
                            output_biases[output_idx]
                        }) <<< FRAC_BITS;
                    state <= ST_OUTPUT_MAC;
                end

                ST_OUTPUT_MAC: begin
                    accumulator <= output_mac_next;
                    if (hidden_idx == HIDDEN_DIM-1) begin
                        state <= ST_OUTPUT_ACT;
                    end else begin
                        hidden_idx <= hidden_idx + 1'b1;
                    end
                end

                // The piecewise sigmoid contains arithmetic and saturation
                // logic.  Register the completed MAC before entering it so
                // the implementation does not build two DSP48s in series.
                ST_OUTPUT_ACT: begin
                    output_values[output_idx] <=
                        output_activation(accumulator);
                    if (output_idx == OUTPUT_DIM-1) begin
                        state <= ST_DONE;
                    end else begin
                        output_idx <= output_idx + 1'b1;
                        state      <= ST_OUTPUT_INIT;
                    end
                end

                ST_DONE: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    genvar output_gen;
    generate
        for (output_gen = 0;
             output_gen < OUTPUT_DIM;
             output_gen = output_gen + 1) begin : gen_pack_output
            assign outputs[output_gen*DATA_WIDTH +: DATA_WIDTH] =
                output_values[output_gen];
        end
    endgenerate

    assign busy  = (state != ST_IDLE);
    assign valid = (state == ST_DONE);

endmodule
