`timescale 1ns/1ps

module tb_lcd_status_display;
    localparam integer H_TOTAL = 976;
    localparam integer V_TOTAL = 528;
    localparam integer FRAME_CYCLES = H_TOTAL * V_TOTAL;

    reg pixel_clk = 1'b0;
    reg reset_n = 1'b0;
    reg clock_locked = 1'b0;
    reg [2:0] service_state = 3'd1;
    reg [1:0] clock_profile = 2'd1;
    reg [2:0] current_task = 3'd1;
    reg [15:0] temperature_q8_8 = 16'h2d80;
    reg [15:0] vccint_mv = 16'd1000;
    reg [15:0] vccaux_mv = 16'd1800;
    reg [2:0] engine_busy = 3'b010;
    reg [31:0] completed_count = 32'd1234;
    reg [31:0] failed_count = 32'd2;
    reg [31:0] avg_latency_us = 32'd5891;
    reg [31:0] latest_latency0_us = 32'd14;
    reg [31:0] latest_latency1_us = 32'd5890;
    reg [31:0] latest_latency2_us = 32'd3;
    reg [31:0] latest_latency3_us = 32'd5892;
    reg [15:0] speedup0_q8_8 = 16'h145f;
    reg [15:0] speedup1_q8_8 = 16'h024a;
    reg [15:0] speedup2_q8_8 = 16'h28e6;
    reg [15:0] speedup3_q8_8 = 16'h024a;
    reg [31:0] batch_completed = 32'd25000;
    reg [31:0] batch_total = 32'd100000;

    wire [23:0] lcd_rgb;
    wire lcd_hs, lcd_vs, lcd_de, lcd_clk, lcd_rst, lcd_bl;

    lcd_status_display #(.POWER_UP_CYCLES(6)) dut (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .clock_locked(clock_locked), .service_state(service_state),
        .clock_profile(clock_profile), .current_task(current_task),
        .temperature_q8_8(temperature_q8_8), .vccint_mv(vccint_mv),
        .vccaux_mv(vccaux_mv), .engine_busy(engine_busy),
        .completed_count(completed_count), .failed_count(failed_count),
        .avg_latency_us(avg_latency_us),
        .latest_latency0_us(latest_latency0_us),
        .latest_latency1_us(latest_latency1_us),
        .latest_latency2_us(latest_latency2_us),
        .latest_latency3_us(latest_latency3_us),
        .speedup0_q8_8(speedup0_q8_8), .speedup1_q8_8(speedup1_q8_8),
        .speedup2_q8_8(speedup2_q8_8), .speedup3_q8_8(speedup3_q8_8),
        .batch_completed(batch_completed), .batch_total(batch_total),
        .lcd_rgb(lcd_rgb), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_de(lcd_de), .lcd_clk(lcd_clk), .lcd_rst(lcd_rst),
        .lcd_bl(lcd_bl)
    );

    always #5 pixel_clk = ~pixel_clk;

    integer cycles;
    integer hs_low;
    integer vs_low;
    integer active_pixels;

    task fail(input [8*96-1:0] message);
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        repeat (3) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b0)
            fail("panel enabled during reset");
        reset_n = 1'b1;
        repeat (3) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b0)
            fail("panel enabled before clock lock");

        clock_locked = 1'b1;
        repeat (5) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b0)
            fail("panel enabled before power-up delay");
        @(posedge pixel_clk); #1;
        if (lcd_rst !== 1'b1 || lcd_bl !== 1'b1)
            fail("panel did not enable after power-up delay");
        if (lcd_clk !== pixel_clk)
            fail("pixel clock is not forwarded");

        @(posedge pixel_clk); #1;
        while (!(dut.h_count == 0 && dut.v_count == 0)) begin
            @(posedge pixel_clk); #1;
        end
        cycles = 0;
        hs_low = 0;
        vs_low = 0;
        active_pixels = 0;
        repeat (FRAME_CYCLES) begin
            if (!lcd_hs) hs_low = hs_low + 1;
            if (!lcd_vs) vs_low = vs_low + 1;
            if (lcd_de) active_pixels = active_pixels + 1;
            cycles = cycles + 1;
            @(posedge pixel_clk); #1;
        end
        if (dut.h_count != 0 || dut.v_count != 0)
            fail("frame length is not 976x528");
        if (hs_low != 48 * V_TOTAL)
            fail("HSYNC width is not 48 clocks per line");
        if (vs_low != 3 * H_TOTAL)
            fail("VSYNC width is not 3 lines");
        if (active_pixels != 800 * 480)
            fail("active area is not 800x480");
        if (dut.bcd_completed != 40'h0000001234 ||
            dut.bcd_temperature != 40'h0000000045 ||
            dut.bcd_latency1 != 40'h0000005890 ||
            dut.bcd_batch_completed != 40'h0000025000 ||
            dut.bcd_batch_total != 40'h0000100000)
            fail("shared binary-to-decimal renderer produced wrong digits");

        service_state = 3'd1;
        @(posedge pixel_clk); #1;
        if (dut.snap_service_state != 3'd1)
            fail("frame-start snapshot did not capture READY");
        repeat (1000) @(posedge pixel_clk);
        service_state = 3'd4;
        repeat (1000) @(posedge pixel_clk);
        if (dut.snap_service_state != 3'd1)
            fail("status changed inside a frame");
        @(posedge pixel_clk); #1;
        while (!(dut.h_count == 0 && dut.v_count == 0)) begin
            @(posedge pixel_clk); #1;
        end
        @(posedge pixel_clk); #1;
        if (dut.snap_service_state != 3'd4)
            fail("next frame did not capture FAULT");

        clock_locked = 1'b0;
        @(posedge pixel_clk); #1;
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b0)
            fail("panel stayed enabled after lock loss");

        $display("PASS: LCD 800x480 timing, startup and snapshots");
        $finish;
    end
endmodule
