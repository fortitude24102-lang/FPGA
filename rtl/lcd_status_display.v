`timescale 1ns/1ps

// Framebuffer-free 800x480 status dashboard for the ATK-MD0430R RGB panel.
// Multi-bit service values are sampled only at frame start so a displayed
// frame remains coherent while software updates the AXI-visible registers.
module lcd_status_display #(
    parameter integer POWER_UP_CYCLES = 660000
)(
    input  wire        pixel_clk,
    input  wire        reset_n,
    input  wire        clock_locked,
    input  wire [2:0]  service_state,
    input  wire [1:0]  clock_profile,
    input  wire [2:0]  current_task,
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
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_de,
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

    assign lcd_clk = pixel_clk;
    assign lcd_rst = panel_ready;
    assign lcd_bl  = panel_ready;
    assign lcd_hs  = panel_ready ? (h_count >= H_SYNC) : 1'b1;
    assign lcd_vs  = panel_ready ? (v_count >= V_SYNC) : 1'b1;
    assign lcd_de  = panel_ready &&
                     h_count >= H_SYNC + H_BACK &&
                     h_count <  H_SYNC + H_BACK + H_ACTIVE &&
                     v_count >= V_SYNC + V_BACK &&
                     v_count <  V_SYNC + V_BACK + V_ACTIVE;

    wire [9:0] active_x = h_count - (H_SYNC + H_BACK);
    wire [8:0] active_y = v_count - (V_SYNC + V_BACK);
    wire [6:0] text_col = active_x[9:3];
    wire [4:0] text_row = active_y[8:4];
    wire [2:0] glyph_x = active_x[2:0];
    wire [2:0] glyph_y = active_y[3:1];

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
        end else if (!clock_locked || !panel_ready) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
        end else if (h_count == H_TOTAL-1) begin
            h_count <= 10'd0;
            if (v_count == V_TOTAL-1)
                v_count <= 10'd0;
            else
                v_count <= v_count + 10'd1;
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
            bcd_batch_total <= 40'h0000100000;
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
            snap_batch_total <= 32'd100000;
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
        reg [6:0] rel;
        reg [1:0] lane;
        begin
            screen_char = 8'h20;
            case (row)
                5'd1: begin
                    if (col >= 3 && col < 27)
                        screen_char = pick_char("MOLRECOMMENDER / Z15 FPGA", 24, col-3);
                    else if (col >= 84 && col < 90)
                        screen_char = state_char(snap_service_state, col-84);
                end
                5'd4: begin
                    if (col >= 4 && col < 16)
                        screen_char = pick_char("BOARD HEALTH", 12, col-4);
                    else if (col >= 29 && col < 41)
                        screen_char = pick_char("CURRENT TASK", 12, col-29);
                    else if (col >= 58 && col < 71)
                        screen_char = pick_char("CLOCK PROFILE", 13, col-58);
                end
                5'd5: begin
                    if (col >= 4 && col < 10)
                        screen_char = state_char(snap_service_state, col-4);
                    else if (col >= 29 && col < 38)
                        screen_char = task_char(snap_current_task, col-29);
                    else if (col >= 58 && col < 61)
                        screen_char = decimal_char(
                            snap_clock_profile == 0 ? 40'h0000000050 :
                            snap_clock_profile == 1 ? 40'h0000000100 :
                                                       40'h0000000150,
                                                   3, col-58);
                    else if (col >= 62 && col < 65)
                        screen_char = pick_char("MHZ", 3, col-62);
                    else if (snap_clock_profile == 2 && col >= 67 && col < 79)
                        screen_char = pick_char("OC EXPERIMENT", 12, col-67);
                end
                5'd7: begin
                    if (col >= 4 && col < 8)
                        screen_char = pick_char("TEMP", 4, col-4);
                    else if (col >= 9 && col < 14)
                        screen_char = fixed1_char(bcd_temperature,
                                                  snap_temperature_q8_8,
                                                  col-9);
                    else if (col == 15)
                        screen_char = "C";
                    else if (col >= 29 && col < 35)
                        screen_char = pick_char("VCCINT", 6, col-29);
                    else if (col >= 36 && col < 40)
                        screen_char = decimal_char(bcd_vccint, 4, col-36);
                    else if (col >= 41 && col < 43)
                        screen_char = pick_char("MV", 2, col-41);
                    else if (col >= 58 && col < 64)
                        screen_char = pick_char("VCCAUX", 6, col-58);
                    else if (col >= 65 && col < 69)
                        screen_char = decimal_char(bcd_vccaux, 4, col-65);
                    else if (col >= 70 && col < 72)
                        screen_char = pick_char("MV", 2, col-70);
                end
                5'd10: begin
                    if (col >= 4 && col < 12)
                        screen_char = pick_char("TANIMOTO", 8, col-4);
                    else if (col >= 28 && col < 31)
                        screen_char = pick_char("GNN", 3, col-28);
                    else if (col >= 52 && col < 57)
                        screen_char = pick_char("ADMET", 5, col-52);
                    else if (col >= 76 && col < 84)
                        screen_char = pick_char("PIPELINE", 8, col-76);
                end
                5'd11: begin
                    lane = col >= 76 ? 3 : col >= 52 ? 2 : col >= 28 ? 1 : 0;
                    rel = col - (lane == 0 ? 4 : lane == 1 ? 28 : lane == 2 ? 52 : 76);
                    if (rel < 7) begin
                        if (lane < 3 && snap_engine_busy[lane])
                            screen_char = pick_char("RUNNING", 7, rel);
                        else
                            screen_char = pick_char("READY", 5, rel);
                    end
                end
                5'd12: begin
                    lane = col >= 76 ? 3 : col >= 52 ? 2 : col >= 28 ? 1 : 0;
                    rel = col - (lane == 0 ? 4 : lane == 1 ? 28 : lane == 2 ? 52 : 76);
                    if (rel < 4)
                        screen_char = pick_char("LAT ", 4, rel);
                    else if (rel < 10)
                        screen_char = decimal_char(bcd_latency_for_lane(lane),
                                                   6, rel-4);
                    else if (rel < 12)
                        screen_char = pick_char("US", 2, rel-10);
                end
                5'd15: begin
                    if (col >= 4 && col < 8)
                        screen_char = pick_char("DONE", 4, col-4);
                    else if (col >= 9 && col < 19)
                        screen_char = decimal_char(bcd_completed, 10, col-9);
                    else if (col >= 29 && col < 33)
                        screen_char = pick_char("FAIL", 4, col-29);
                    else if (col >= 34 && col < 44)
                        screen_char = decimal_char(bcd_failed, 10, col-34);
                    else if (col >= 58 && col < 65)
                        screen_char = pick_char("AVG LAT", 7, col-58);
                    else if (col >= 66 && col < 76)
                        screen_char = decimal_char(bcd_avg_latency, 10, col-66);
                    else if (col >= 77 && col < 79)
                        screen_char = pick_char("US", 2, col-77);
                end
                5'd18: begin
                    if (col >= 4 && col < 23)
                        screen_char = pick_char("CPU VS FPGA SPEEDUP", 19, col-4);
                end
                5'd20, 5'd21, 5'd22, 5'd23: begin
                    lane = row - 20;
                    if (col >= 4 && col < 12)
                        case (lane)
                            0: screen_char = pick_char("TANIMOTO", 8, col-4);
                            1: screen_char = pick_char("GNN", 3, col-4);
                            2: screen_char = pick_char("ADMET", 5, col-4);
                            default: screen_char = pick_char("PIPELINE", 8, col-4);
                        endcase
                    else if (col >= 78 && col < 83)
                        screen_char = fixed1_char(bcd_speedup_for_lane(lane),
                                                  speedup_for_lane(lane),
                                                  col-78);
                    else if (col == 83)
                        screen_char = "X";
                end
                5'd26: begin
                    if (col >= 4 && col < 18)
                        screen_char = pick_char("BATCH PROGRESS", 14, col-4);
                    else if (col >= 57 && col < 67)
                        screen_char = decimal_char(bcd_batch_completed, 10,
                                                   col-57);
                    else if (col == 68)
                        screen_char = "/";
                    else if (col >= 70 && col < 80)
                        screen_char = decimal_char(bcd_batch_total, 10, col-70);
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
    wire font_pixel = glyph_x < 5 && selected_row[4-glyph_x];

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

        if (active_y < 10'd56)
            base_color = COLOR_HEADER;
        else if ((active_y >= 10'd64 && active_y < 10'd144) ||
                 (active_y >= 10'd152 && active_y < 10'd224) ||
                 (active_y >= 10'd232 && active_y < 10'd272) ||
                 (active_y >= 10'd288 && active_y < 10'd400) ||
                 (active_y >= 10'd408 && active_y < 10'd472))
            base_color = COLOR_PANEL;

        if (active_x >= 10'd664 && active_x < 10'd784 &&
            active_y >= 10'd12 && active_y < 10'd44)
            case (snap_service_state)
                3'd1: base_color = COLOR_GREEN;
                3'd2, 3'd3: base_color = COLOR_AMBER;
                3'd4: base_color = COLOR_RED;
                default: base_color = COLOR_MUTED;
            endcase

        if (active_y >= 10'd320 && active_y < 10'd384 &&
            active_x >= 10'd112 && active_x < 10'd512) begin
            speed_lane = (active_y-10'd320) >> 4;
            selected_speedup = speedup_for_lane(speed_lane);
            speed_width = selected_speedup >> 5;
            if (speed_width > 10'd400)
                speed_width = 10'd400;
            if (active_x-10'd112 < speed_width)
                case (speed_lane)
                    0: base_color = COLOR_CYAN;
                    1: base_color = COLOR_PURPLE;
                    2: base_color = COLOR_GREEN;
                    default: base_color = COLOR_AMBER;
                endcase
            else
                base_color = COLOR_BAR_BG;
        end

        if (active_x >= 10'd32 && active_x < 10'd768 &&
            active_y >= 10'd448 && active_y < 10'd468) begin
            progress_segment = (active_x-10'd32) / 37;
            progress_filled = snap_batch_total != 0 &&
                ((progress_segment+1) * snap_batch_total <=
                 snap_batch_completed * 20);
            base_color = progress_filled ? COLOR_CYAN : COLOR_BAR_BG;
        end

        if (text_row == 18 || (text_row >= 20 && text_row <= 23) ||
            text_row == 26)
            text_color = COLOR_CYAN;
        if (text_row == 5 && snap_clock_profile == 2 && text_col >= 67)
            text_color = COLOR_AMBER;
        if (text_row == 1 && text_col >= 84)
            text_color = 24'hffffff;

        if (!lcd_de)
            lcd_rgb = 24'h000000;
        else if (font_pixel)
            lcd_rgb = text_color;
        else
            lcd_rgb = base_color;
    end
endmodule
