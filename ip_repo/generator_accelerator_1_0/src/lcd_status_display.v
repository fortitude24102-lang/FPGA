`timescale 1ns/1ps

// Framebuffer-free 800x480 status dashboard for the ATK-MD0430R RGB panel.
// Multi-bit service values are sampled only at frame start so a displayed
// frame remains coherent while software updates the AXI-visible registers.
module lcd_status_display #(
    parameter integer POWER_UP_CYCLES = 660000,
    parameter integer DIAGNOSTIC_MODE = 0
)(
    input  wire        pixel_clk,
    input  wire        reset_n,
    input  wire        clock_locked,
    input  wire [2:0]  service_state,
    input  wire [1:0]  clock_profile,
    input  wire [2:0]  current_task,
    input  wire        activity_toggle,
    input  wire [15:0] temperature_q8_8,
    input  wire [15:0] vccint_mv,
    input  wire [15:0] vccaux_mv,
    input  wire [2:0]  engine_busy,
    input  wire [31:0] completed_count,
    input  wire [31:0] failed_count,
    input  wire [31:0] avg_latency_us,
    input  wire [31:0] latest_latency0_us,
    input  wire [31:0] latest_latency1_us,
    input  wire [31:0] latest_latency2_us,
    input  wire [31:0] latest_latency3_us,
    input  wire [15:0] speedup0_q8_8,
    input  wire [15:0] speedup1_q8_8,
    input  wire [15:0] speedup2_q8_8,
    input  wire [15:0] speedup3_q8_8,
    input  wire [31:0] batch_completed,
    input  wire [31:0] batch_total,
    output reg  [23:0] lcd_rgb,
    output reg         lcd_hs,
    output reg         lcd_vs,
    output reg         lcd_de,
    output wire        lcd_clk,
    output wire        lcd_rst,
    output wire        lcd_bl
);
    localparam integer H_SYNC   = 48;
    localparam integer H_BACK   = 88;
    localparam integer H_ACTIVE = 800;
    localparam integer H_FRONT  = 40;
    localparam integer H_TOTAL  = H_SYNC + H_BACK + H_ACTIVE + H_FRONT;
    localparam integer V_SYNC   = 3;
    localparam integer V_BACK   = 32;
    localparam integer V_ACTIVE = 480;
    localparam integer V_FRONT  = 13;
    localparam integer V_TOTAL  = V_SYNC + V_BACK + V_ACTIVE + V_FRONT;

    localparam [23:0] COLOR_BG       = 24'h07111f;
    localparam [23:0] COLOR_PANEL    = 24'h10243a;
    localparam [23:0] COLOR_HEADER   = 24'h0a2b4c;
    localparam [23:0] COLOR_TEXT     = 24'he6f3ff;
    localparam [23:0] COLOR_MUTED    = 24'h76a2bf;
    localparam [23:0] COLOR_GREEN    = 24'h19d37e;
    localparam [23:0] COLOR_RED      = 24'hff4d67;
    localparam [23:0] COLOR_AMBER    = 24'hffbf47;
    localparam [23:0] COLOR_CYAN     = 24'h25c7e8;
    localparam [23:0] COLOR_PURPLE   = 24'h9b7cff;
    localparam [23:0] COLOR_BAR_BG   = 24'h253d52;

    reg [31:0] power_count;
    reg panel_ready;
    reg [9:0] h_count;
    reg [9:0] v_count;
    reg [5:0] live_frame;
    reg [3:0] activity_frames;
    reg activity_seen;

    reg [2:0]  snap_service_state;
    reg [1:0]  snap_clock_profile;
    reg [2:0]  snap_current_task;
    reg [15:0] snap_temperature_q8_8;
    reg [15:0] snap_vccint_mv;
    reg [15:0] snap_vccaux_mv;
    reg [2:0]  snap_engine_busy;
    reg [31:0] snap_completed_count;
    reg [31:0] snap_failed_count;
    reg [31:0] snap_avg_latency_us;
    reg [31:0] snap_latest_latency0_us;
    reg [31:0] snap_latest_latency1_us;
    reg [31:0] snap_latest_latency2_us;
    reg [31:0] snap_latest_latency3_us;
    reg [15:0] snap_speedup0_q8_8;
    reg [15:0] snap_speedup1_q8_8;
    reg [15:0] snap_speedup2_q8_8;
    reg [15:0] snap_speedup3_q8_8;
    reg [31:0] snap_batch_completed;
    reg [31:0] snap_batch_total;
    reg [39:0] bcd_temperature;
    reg [39:0] bcd_vccint;
    reg [39:0] bcd_vccaux;
    reg [39:0] bcd_completed;
    reg [39:0] bcd_failed;
    reg [39:0] bcd_avg_latency;
    reg [39:0] bcd_latency0;
    reg [39:0] bcd_latency1;
    reg [39:0] bcd_latency2;
    reg [39:0] bcd_latency3;
    reg [39:0] bcd_speedup0;
    reg [39:0] bcd_speedup1;
    reg [39:0] bcd_speedup2;
    reg [39:0] bcd_speedup3;
    reg [39:0] bcd_batch_completed;
    reg [39:0] bcd_batch_total;
    reg [3:0] convert_index;
    reg [5:0] convert_bit;
    reg [39:0] convert_work;
    reg convert_active;
    reg [31:0] convert_value;
    reg [39:0] convert_adjusted;
    integer convert_digit;

    wire pixel_hs = panel_ready ? (h_count >= H_SYNC) : 1'b1;
    wire pixel_vs = panel_ready ? (v_count >= V_SYNC) : 1'b1;
    wire pixel_de = panel_ready &&
                     h_count >= H_SYNC + H_BACK &&
                     h_count <  H_SYNC + H_BACK + H_ACTIVE &&
                     v_count >= V_SYNC + V_BACK &&
                     v_count <  V_SYNC + V_BACK + V_ACTIVE;

    assign lcd_clk = pixel_clk;
    assign lcd_rst = panel_ready;
    assign lcd_bl  = 1'b1;

    wire [9:0] active_x = h_count - (H_SYNC + H_BACK);
    wire [8:0] active_y = v_count - (V_SYNC + V_BACK);
    wire [6:0] text_col = {1'b0, active_x[9:4]};
    wire [4:0] text_row = {1'b0, active_y[8:5]};
    wire [2:0] glyph_y = active_y[4:2];
    wire [9:0] live_marker_x = 10'd520 +
                               ((10'd12-activity_frames) << 3);

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n || !clock_locked) begin
            power_count <= 32'd0;
            panel_ready <= 1'b0;
        end else if (!panel_ready) begin
            if (POWER_UP_CYCLES <= 1 || power_count == POWER_UP_CYCLES-1) begin
                panel_ready <= 1'b1;
                power_count <= power_count;
            end else begin
                power_count <= power_count + 32'd1;
            end
        end
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
            live_frame <= 6'd0;
            activity_frames <= 4'd0;
            activity_seen <= 1'b0;
        end else if (!clock_locked || !panel_ready) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
            live_frame <= 6'd0;
            activity_frames <= 4'd0;
            activity_seen <= activity_toggle;
        end else if (h_count == H_TOTAL-1) begin
            h_count <= 10'd0;
            if (v_count == V_TOTAL-1) begin
                v_count <= 10'd0;
                live_frame <= live_frame + 1'b1;
                if (activity_toggle != activity_seen) begin
                    activity_seen <= activity_toggle;
                    activity_frames <= 4'd12;
                end else if (activity_frames != 0) begin
                    activity_frames <= activity_frames - 1'b1;
                end
            end else begin
                v_count <= v_count + 10'd1;
            end
        end else begin
            h_count <= h_count + 10'd1;
        end
    end

    always @* begin
        case (convert_index)
            4'd0: convert_value = snap_temperature_q8_8 >> 8;
            4'd1: convert_value = snap_vccint_mv;
            4'd2: convert_value = snap_vccaux_mv;
            4'd3: convert_value = snap_completed_count;
            4'd4: convert_value = snap_failed_count;
            4'd5: convert_value = snap_avg_latency_us;
            4'd6: convert_value = snap_latest_latency0_us;
            4'd7: convert_value = snap_latest_latency1_us;
            4'd8: convert_value = snap_latest_latency2_us;
            4'd9: convert_value = snap_latest_latency3_us;
            4'd10: convert_value = snap_speedup0_q8_8 >> 8;
            4'd11: convert_value = snap_speedup1_q8_8 >> 8;
            4'd12: convert_value = snap_speedup2_q8_8 >> 8;
            4'd13: convert_value = snap_speedup3_q8_8 >> 8;
            4'd14: convert_value = snap_batch_completed;
            default: convert_value = snap_batch_total;
        endcase
        convert_adjusted = convert_work;
        for (convert_digit = 0; convert_digit < 10;
             convert_digit = convert_digit + 1)
            if (convert_work[convert_digit*4 +: 4] >= 5)
                convert_adjusted[convert_digit*4 +: 4] =
                    convert_work[convert_digit*4 +: 4] + 3;
    end

    wire [39:0] convert_shifted =
        {convert_adjusted[38:0], convert_value[convert_bit]};

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            bcd_temperature <= 40'd0;
            bcd_vccint <= 40'd0;
            bcd_vccaux <= 40'd0;
            bcd_completed <= 40'd0;
            bcd_failed <= 40'd0;
            bcd_avg_latency <= 40'd0;
            bcd_latency0 <= 40'd0;
            bcd_latency1 <= 40'd0;
            bcd_latency2 <= 40'd0;
            bcd_latency3 <= 40'd0;
            bcd_speedup0 <= 40'd0;
            bcd_speedup1 <= 40'd0;
            bcd_speedup2 <= 40'd0;
            bcd_speedup3 <= 40'd0;
            bcd_batch_completed <= 40'd0;
            bcd_batch_total <= 40'd0;
            convert_index <= 4'd0;
            convert_bit <= 6'd31;
            convert_work <= 40'd0;
            convert_active <= 1'b0;
        end else if (panel_ready && h_count == 0 && v_count == 0) begin
            convert_index <= 4'd0;
            convert_bit <= 6'd31;
            convert_work <= 40'd0;
            convert_active <= 1'b1;
        end else if (convert_active) begin
            if (convert_bit == 0) begin
                case (convert_index)
                    4'd0: bcd_temperature <= convert_shifted;
                    4'd1: bcd_vccint <= convert_shifted;
                    4'd2: bcd_vccaux <= convert_shifted;
                    4'd3: bcd_completed <= convert_shifted;
                    4'd4: bcd_failed <= convert_shifted;
                    4'd5: bcd_avg_latency <= convert_shifted;
                    4'd6: bcd_latency0 <= convert_shifted;
                    4'd7: bcd_latency1 <= convert_shifted;
                    4'd8: bcd_latency2 <= convert_shifted;
                    4'd9: bcd_latency3 <= convert_shifted;
                    4'd10: bcd_speedup0 <= convert_shifted;
                    4'd11: bcd_speedup1 <= convert_shifted;
                    4'd12: bcd_speedup2 <= convert_shifted;
                    4'd13: bcd_speedup3 <= convert_shifted;
                    4'd14: bcd_batch_completed <= convert_shifted;
                    default: bcd_batch_total <= convert_shifted;
                endcase
                if (convert_index == 15) begin
                    convert_active <= 1'b0;
                end else begin
                    convert_index <= convert_index + 1'b1;
                    convert_bit <= 6'd31;
                    convert_work <= 40'd0;
                end
            end else begin
                convert_work <= convert_shifted;
                convert_bit <= convert_bit - 1'b1;
            end
        end
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            snap_service_state <= 3'd0;
            snap_clock_profile <= 2'd0;
            snap_current_task <= 3'd7;
            snap_temperature_q8_8 <= 16'd0;
            snap_vccint_mv <= 16'd0;
            snap_vccaux_mv <= 16'd0;
            snap_engine_busy <= 3'd0;
            snap_completed_count <= 32'd0;
            snap_failed_count <= 32'd0;
            snap_avg_latency_us <= 32'd0;
            snap_latest_latency0_us <= 32'd0;
            snap_latest_latency1_us <= 32'd0;
            snap_latest_latency2_us <= 32'd0;
            snap_latest_latency3_us <= 32'd0;
            snap_speedup0_q8_8 <= 16'd0;
            snap_speedup1_q8_8 <= 16'd0;
            snap_speedup2_q8_8 <= 16'd0;
            snap_speedup3_q8_8 <= 16'd0;
            snap_batch_completed <= 32'd0;
            snap_batch_total <= 32'd0;
        end else if (panel_ready && h_count == 0 && v_count == 0) begin
            snap_service_state <= service_state;
            snap_clock_profile <= clock_profile;
            snap_current_task <= current_task;
            snap_temperature_q8_8 <= temperature_q8_8;
            snap_vccint_mv <= vccint_mv;
            snap_vccaux_mv <= vccaux_mv;
            snap_engine_busy <= engine_busy;
            snap_completed_count <= completed_count;
            snap_failed_count <= failed_count;
            snap_avg_latency_us <= avg_latency_us;
            snap_latest_latency0_us <= latest_latency0_us;
            snap_latest_latency1_us <= latest_latency1_us;
            snap_latest_latency2_us <= latest_latency2_us;
            snap_latest_latency3_us <= latest_latency3_us;
            snap_speedup0_q8_8 <= speedup0_q8_8;
            snap_speedup1_q8_8 <= speedup1_q8_8;
            snap_speedup2_q8_8 <= speedup2_q8_8;
            snap_speedup3_q8_8 <= speedup3_q8_8;
            snap_batch_completed <= batch_completed;
            snap_batch_total <= batch_total;
        end
    end

    function [7:0] pick_char;
        input [8*32-1:0] text;
        input [5:0] length;
        input [5:0] index;
        begin
            if (index < length)
                pick_char = text[(length-index)*8-1 -: 8];
            else
                pick_char = 8'h20;
        end
    endfunction

    function [7:0] decimal_char;
        input [39:0] bcd_value;
        input [3:0] digits;
        input [3:0] index;
        integer exponent;
        reg [3:0] digit;
        reg nonzero_above;
        begin
            exponent = index < digits ? digits-index-1 : 0;
            digit = (bcd_value >> (exponent*4)) & 4'hf;
            nonzero_above = index >= digits ||
                            |(bcd_value >> ((exponent+1)*4));
            if (index >= digits)
                decimal_char = 8'h20;
            else if (!nonzero_above && digit == 0 && exponent != 0)
                decimal_char = 8'h20;
            else
                decimal_char = 8'h30 + digit;
        end
    endfunction

    function [7:0] fixed1_char;
        input [39:0] integer_bcd;
        input [15:0] value;
        input [3:0] index;
        reg [7:0] decimal_part;
        begin
            decimal_part = ((value & 16'h00ff) * 10) >> 8;
            if (index < 3)
                fixed1_char = decimal_char(integer_bcd, 3, index);
            else if (index == 3)
                fixed1_char = 8'h2e;
            else if (index == 4)
                fixed1_char = 8'h30 + decimal_part;
            else
                fixed1_char = 8'h20;
        end
    endfunction

    function [7:0] state_char;
        input [2:0] state;
        input [3:0] index;
        begin
            case (state)
                3'd0: state_char = pick_char("INIT", 4, index);
                3'd1: state_char = pick_char("READY", 5, index);
                3'd2: state_char = pick_char("BUSY", 4, index);
                3'd3: state_char = pick_char("RELOAD", 6, index);
                default: state_char = pick_char("FAULT", 5, index);
            endcase
        end
    endfunction

    function [7:0] task_char;
        input [2:0] task_id;
        input [3:0] index;
        begin
            case (task_id)
                3'd0: task_char = pick_char("TANIMOTO", 8, index);
                3'd1: task_char = pick_char("GNN", 3, index);
                3'd2: task_char = pick_char("ADMET", 5, index);
                3'd3: task_char = pick_char("PIPELINE", 8, index);
                3'd4: task_char = pick_char("RELOAD", 6, index);
                default: task_char = pick_char("IDLE", 4, index);
            endcase
        end
    endfunction

    function [39:0] bcd_latency_for_lane;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: bcd_latency_for_lane = bcd_latency0;
                2'd1: bcd_latency_for_lane = bcd_latency1;
                2'd2: bcd_latency_for_lane = bcd_latency2;
                default: bcd_latency_for_lane = bcd_latency3;
            endcase
        end
    endfunction

    function [39:0] bcd_speedup_for_lane;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: bcd_speedup_for_lane = bcd_speedup0;
                2'd1: bcd_speedup_for_lane = bcd_speedup1;
                2'd2: bcd_speedup_for_lane = bcd_speedup2;
                default: bcd_speedup_for_lane = bcd_speedup3;
            endcase
        end
    endfunction

    function [15:0] speedup_for_lane;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: speedup_for_lane = snap_speedup0_q8_8;
                2'd1: speedup_for_lane = snap_speedup1_q8_8;
                2'd2: speedup_for_lane = snap_speedup2_q8_8;
                default: speedup_for_lane = snap_speedup3_q8_8;
            endcase
        end
    endfunction

    function [7:0] screen_char;
        input [4:0] row;
        input [6:0] col;
        reg [1:0] lane;
        begin
            screen_char = 8'h20;
            case (row)
                5'd0: begin
                    if (col >= 2 && col < 25)
                        screen_char = pick_char("MOLRECOMMENDER Z15 FPGA", 23,
                                                col-2);
                    else if (col >= 43 && col < 49)
                        screen_char = state_char(snap_service_state, col-43);
                end
                5'd2: begin
                    if (col >= 2 && col < 6)
                        screen_char = pick_char("TASK", 4, col-2);
                    else if (col >= 7 && col < 15)
                        screen_char = task_char(snap_current_task, col-7);
                    else if (col >= 18 && col < 22)
                        screen_char = pick_char("TEMP", 4, col-18);
                    else if (col >= 23 && col < 28)
                        screen_char = fixed1_char(bcd_temperature,
                                                  snap_temperature_q8_8,
                                                  col-23);
                    else if (col == 28)
                        screen_char = "C";
                    else if (col >= 33 && col < 36)
                        screen_char = pick_char("CLK", 3, col-33);
                    else if (col >= 37 && col < 40)
                        screen_char = decimal_char(
                            snap_clock_profile == 0 ? 40'h0000000050 :
                            snap_clock_profile == 1 ? 40'h0000000100 :
                                                       40'h0000000150,
                                                   3, col-37);
                    else if (col >= 41 && col < 44)
                        screen_char = pick_char("MHZ", 3, col-41);
                    else if (snap_clock_profile == 2 && col >= 45 && col < 48)
                        screen_char = pick_char("EXP", 3, col-45);
                end
                5'd4: begin
                    if (col >= 2 && col < 6)
                        screen_char = pick_char("DONE", 4, col-2);
                    else if (col >= 7 && col < 13)
                        screen_char = decimal_char(bcd_completed, 6, col-7);
                    else if (col >= 16 && col < 20)
                        screen_char = pick_char("FAIL", 4, col-16);
                    else if (col >= 21 && col < 27)
                        screen_char = decimal_char(bcd_failed, 6, col-21);
                    else if (col >= 30 && col < 37)
                        screen_char = pick_char("AVG LAT", 7, col-30);
                    else if (snap_completed_count == 0 &&
                             col >= 38 && col < 40)
                        screen_char = "-";
                    else if (snap_completed_count != 0 &&
                             col >= 38 && col < 44)
                        screen_char = decimal_char(bcd_avg_latency, 6, col-38);
                    else if (col >= 45 && col < 47)
                        screen_char = pick_char("US", 2, col-45);
                end
                5'd6: begin
                    if (col >= 2 && col < 21)
                        screen_char = pick_char("FPGA SPEEDUP VS CPU", 19, col-2);
                end
                5'd7, 5'd9, 5'd11, 5'd13: begin
                    lane = row == 7 ? 0 : row == 9 ? 1 :
                           row == 11 ? 2 : 3;
                    if (col >= 2 && col < 10)
                        case (lane)
                            0: screen_char = pick_char("TANIMOTO", 8, col-2);
                            1: screen_char = pick_char("GNN", 3, col-2);
                            2: screen_char = pick_char("ADMET", 5, col-2);
                            default: screen_char = pick_char("PIPELINE", 8, col-2);
                        endcase
                    else if (col >= 34 && col < 39)
                        screen_char = fixed1_char(bcd_speedup_for_lane(lane),
                                                  speedup_for_lane(lane),
                                                  col-34);
                    else if (col == 39)
                        screen_char = "X";
                end
                5'd14: begin
                    if (col >= 2 && col < 7)
                        screen_char = pick_char("BATCH", 5, col-2);
                    else if (snap_batch_total == 0 && col >= 8 && col < 12)
                        screen_char = pick_char("IDLE", 4, col-8);
                    else if (snap_batch_total != 0 && col >= 8 && col < 14)
                        screen_char = decimal_char(bcd_batch_completed, 6,
                                                   col-8);
                    else if (snap_batch_total != 0 && col == 14)
                        screen_char = "/";
                    else if (snap_batch_total != 0 && col >= 15 && col < 21)
                        screen_char = decimal_char(bcd_batch_total, 6, col-15);
                end
                default: screen_char = 8'h20;
            endcase
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b11011;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                ".": glyph_row = row == 6 ? 5'b00100 : 5'b00000;
                "/": glyph_row = 5'b00001 << (6-row < 5 ? 6-row : 0);
                "-": glyph_row = row == 3 ? 5'b01110 : 5'b00000;
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    wire [7:0] selected_char = screen_char(text_row, text_col);
    wire [4:0] selected_row = glyph_row(selected_char, glyph_y);
    wire [3:0] cell_x = active_x[3:0];
    wire [2:0] enlarged_glyph_x = cell_x < 3 ? 0 :
                                  cell_x < 6 ? 1 :
                                  cell_x < 9 ? 2 :
                                  cell_x < 12 ? 3 : 4;
    wire font_pixel = cell_x < 15 && active_y[4:0] < 28 &&
                      selected_row[4-enlarged_glyph_x];

    function [23:0] diagnostic_color;
        input [9:0] x;
        begin
            case (x / 100)
                0: diagnostic_color = 24'hff0000;
                1: diagnostic_color = 24'h00ff00;
                2: diagnostic_color = 24'h0000ff;
                3: diagnostic_color = 24'hffffff;
                4: diagnostic_color = 24'h00ffff;
                5: diagnostic_color = 24'hff00ff;
                6: diagnostic_color = 24'hffff00;
                default: diagnostic_color = 24'h202020;
            endcase
        end
    endfunction

    reg [23:0] pixel_rgb;
    reg [23:0] pixel_rgb_pipe;
    reg pixel_hs_pipe;
    reg pixel_vs_pipe;
    reg pixel_de_pipe;
    reg [23:0] base_color;
    reg [23:0] text_color;
    reg [15:0] selected_speedup;
    reg [1:0] speed_lane;
    reg [9:0] speed_width;
    reg [4:0] progress_segment;
    reg progress_filled;

    always @* begin
        base_color = COLOR_BG;
        text_color = COLOR_TEXT;
        selected_speedup = 16'd0;
        speed_lane = 2'd0;
        speed_width = 10'd0;
        progress_segment = 5'd0;
        progress_filled = 1'b0;

        if (active_y < 10'd32)
            base_color = COLOR_HEADER;
        else if ((active_y >= 10'd48 && active_y < 10'd160) ||
                 (active_y >= 10'd176 && active_y < 10'd448) ||
                 (active_y >= 10'd448 && active_y < 10'd480))
            base_color = COLOR_PANEL;

        if (active_x >= 10'd672 && active_x < 10'd784 &&
            active_y >= 10'd2 && active_y < 10'd30)
            case (snap_service_state)
                3'd1: base_color = COLOR_GREEN;
                3'd2, 3'd3: base_color = COLOR_AMBER;
                3'd4: base_color = COLOR_RED;
                default: base_color = COLOR_MUTED;
            endcase

        if (snap_service_state != 0 &&
            active_x >= 10'd640 && active_x < 10'd654 &&
            active_y >= 10'd9 && active_y < 10'd23)
            base_color = live_frame[5] ? COLOR_GREEN : 24'h0b5f43;

        if (activity_frames != 0 && active_x >= live_marker_x &&
            active_x < live_marker_x + 10'd4 &&
            active_y >= 10'd20 && active_y < 10'd28)
            base_color = COLOR_CYAN;

        if (((active_y >= 10'd234 && active_y < 10'd246) ||
             (active_y >= 10'd298 && active_y < 10'd310) ||
             (active_y >= 10'd362 && active_y < 10'd374) ||
             (active_y >= 10'd426 && active_y < 10'd438)) &&
            active_x >= 10'd176 && active_x < 10'd496) begin
            speed_lane = active_y < 10'd298 ? 0 :
                         active_y < 10'd362 ? 1 :
                         active_y < 10'd426 ? 2 : 3;
            selected_speedup = speedup_for_lane(speed_lane);
            speed_width = selected_speedup >> 5;
            if (speed_width > 10'd320)
                speed_width = 10'd320;
            if (active_x-10'd176 < speed_width)
                case (speed_lane)
                    0: base_color = COLOR_CYAN;
                    1: base_color = COLOR_PURPLE;
                    2: base_color = COLOR_GREEN;
                    default: base_color = COLOR_AMBER;
                endcase
            else
                base_color = COLOR_BAR_BG;
        end

        if (active_x >= 10'd368 && active_x < 10'd768 &&
            active_y >= 10'd476 && active_y < 10'd480) begin
            progress_segment = (active_x-10'd368) / 20;
            progress_filled = snap_batch_total != 0 &&
                ((progress_segment+1) * snap_batch_total <=
                 snap_batch_completed * 20);
            base_color = progress_filled ? COLOR_CYAN : COLOR_BAR_BG;
        end

        if (text_row == 6 || text_row == 7 || text_row == 9 ||
            text_row == 11 || text_row == 13 || text_row == 14)
            text_color = COLOR_CYAN;
        if (text_row == 2 && snap_clock_profile == 2 && text_col >= 45)
            text_color = COLOR_AMBER;
        if (text_row == 0 && text_col >= 43)
            text_color = 24'hffffff;

        if (snap_service_state == 4 && live_frame[4] &&
            (active_x < 6 || active_x >= 794 ||
             active_y < 6 || active_y >= 474))
            base_color = COLOR_RED;

        if (!pixel_de)
            pixel_rgb = 24'h000000;
        else if (DIAGNOSTIC_MODE != 0)
            pixel_rgb = diagnostic_color(active_x);
        else if (font_pixel)
            pixel_rgb = text_color;
        else
            pixel_rgb = base_color;
    end

    // Register the renderer on the rising edge, then launch that stage on
    // the falling edge.  This gives the character/color path a full pixel
    // period while keeping panel data stable around the sampling edge.
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            pixel_rgb_pipe <= 24'h000000;
            pixel_hs_pipe <= 1'b1;
            pixel_vs_pipe <= 1'b1;
            pixel_de_pipe <= 1'b0;
        end else begin
            pixel_rgb_pipe <= pixel_rgb;
            pixel_hs_pipe <= pixel_hs;
            pixel_vs_pipe <= pixel_vs;
            pixel_de_pipe <= pixel_de;
        end
    end

    always @(negedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            lcd_rgb <= 24'h000000;
            lcd_hs <= 1'b1;
            lcd_vs <= 1'b1;
            lcd_de <= 1'b0;
        end else begin
            lcd_rgb <= pixel_rgb_pipe;
            lcd_hs <= pixel_hs_pipe;
            lcd_vs <= pixel_vs_pipe;
            lcd_de <= pixel_de_pipe;
        end
    end
endmodule
