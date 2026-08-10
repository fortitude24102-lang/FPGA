`timescale 1ns / 1ps

// Four parallel 20 -> 10 -> 1 fully connected ADMET predictors.
// All descriptors, weights and outputs use signed Q8.8 except that sigmoid
// outputs are naturally in the range 0.0 to 1.0.
module admet_predictor #(
    parameter integer DESCRIPTOR_DIM = 20,
    parameter integer HIDDEN_DIM     = 10,
    parameter integer DATA_WIDTH     = 16,
    parameter integer FRAC_BITS      = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [DESCRIPTOR_DIM*DATA_WIDTH-1:0] descriptors,

    // Configuration is routed to one of the four models.
    input  wire        cfg_we,
    input  wire [1:0]  cfg_model,
    input  wire [1:0]  cfg_layer,
    input  wire [15:0] cfg_addr,
    input  wire [DATA_WIDTH-1:0] cfg_wdata,

    output wire busy,
    output wire valid,
    output wire [DATA_WIDTH-1:0] logp,
    output wire [DATA_WIDTH-1:0] oral_bioavailability,
    output wire [DATA_WIDTH-1:0] herg_ic50,
    output wire [DATA_WIDTH-1:0] bbb_permeability,
    output wire [4*DATA_WIDTH-1:0] predictions
);

    wire [3:0] model_busy;
    wire [3:0] model_valid;
    wire [4*DATA_WIDTH-1:0] model_output_bus;

    genvar model_idx;
    generate
        for (model_idx = 0; model_idx < 4; model_idx = model_idx + 1) begin : gen_model
            fc_network #(
                .INPUT_DIM(DESCRIPTOR_DIM),
                .HIDDEN_DIM(HIDDEN_DIM),
                .OUTPUT_DIM(1),
                .DATA_WIDTH(DATA_WIDTH),
                .FRAC_BITS(FRAC_BITS),
                .OUTPUT_SIGMOID(1)
            ) u_fc_network (
                .clk(clk),
                .rst_n(rst_n),
                .start(start),
                .inputs(descriptors),
                .cfg_we(cfg_we && (cfg_model == model_idx)),
                .cfg_layer(cfg_layer),
                .cfg_addr(cfg_addr),
                .cfg_wdata(cfg_wdata),
                .busy(model_busy[model_idx]),
                .valid(model_valid[model_idx]),
                .outputs(
                    model_output_bus[
                        model_idx*DATA_WIDTH +: DATA_WIDTH
                    ]
                )
            );
        end
    endgenerate

    assign logp = model_output_bus[0*DATA_WIDTH +: DATA_WIDTH];
    assign oral_bioavailability =
        model_output_bus[1*DATA_WIDTH +: DATA_WIDTH];
    assign herg_ic50 =
        model_output_bus[2*DATA_WIDTH +: DATA_WIDTH];
    assign bbb_permeability =
        model_output_bus[3*DATA_WIDTH +: DATA_WIDTH];
    assign predictions = model_output_bus;

    assign busy  = |model_busy;
    assign valid = &model_valid;

endmodule
