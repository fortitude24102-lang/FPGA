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
    reg [2:0] current_task = 3'd7;
    reg activity_toggle = 1'b0;
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
    wire default_lcd_rst, default_lcd_bl;
    reg [23:0] expected_rgb_pipe;
    reg expected_hs_pipe;
    reg expected_vs_pipe;
    reg expected_de_pipe;

    lcd_status_display #(.POWER_UP_CYCLES(6)) dut (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .clock_locked(clock_locked), .service_state(service_state),
        .clock_profile(clock_profile), .current_task(current_task),
        .activity_toggle(activity_toggle),
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

    lcd_status_display default_delay_dut (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .clock_locked(clock_locked), .service_state(service_state),
        .clock_profile(clock_profile), .current_task(current_task),
        .activity_toggle(activity_toggle),
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
        .lcd_rst(default_lcd_rst), .lcd_bl(default_lcd_bl)
    );

    always #5 pixel_clk = ~pixel_clk;

    // The panel-facing signals must come from a full-cycle render pipeline,
    // not directly from the half-cycle combinational renderer.
    always @(posedge pixel_clk) begin
        expected_rgb_pipe <= dut.pixel_rgb;
        expected_hs_pipe <= dut.pixel_hs;
        expected_vs_pipe <= dut.pixel_vs;
        expected_de_pipe <= dut.pixel_de;
    end

    integer cycles;
    integer hs_low;
    integer vs_low;
    integer active_pixels;
    integer font_top_pixels;
    integer live_x_first;
    integer live_x_second;
    integer idle_activity_pixels;

    task fail(input [8*96-1:0] message);
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        repeat (3) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b1)
            fail("diagnostic backlight is not forced on during reset");
        reset_n = 1'b1;
        repeat (3) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b1)
            fail("diagnostic backlight changed before clock lock");

        clock_locked = 1'b1;
        repeat (5) @(posedge pixel_clk);
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b1)
            fail("diagnostic backlight changed during power-up delay");
        @(posedge pixel_clk); #1;
        if (lcd_rst !== 1'b1 || lcd_bl !== 1'b1)
            fail("panel reset did not release after power-up delay");
        repeat (659993) @(posedge pixel_clk);
        if (default_lcd_rst !== 1'b0 || default_lcd_bl !== 1'b1)
            fail("default diagnostic backlight is not forced on");
        @(posedge pixel_clk); #1;
        if (default_lcd_rst !== 1'b1 || default_lcd_bl !== 1'b1)
            fail("default panel did not enable after 660000 cycles");
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
            @(negedge pixel_clk); #1;
            if (lcd_rgb !== expected_rgb_pipe ||
                lcd_hs !== expected_hs_pipe ||
                lcd_vs !== expected_vs_pipe ||
                lcd_de !== expected_de_pipe)
                fail("panel output did not use the full-cycle render pipeline");
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

        while (!(dut.v_count == 35 && dut.h_count == 136)) begin
            @(posedge pixel_clk); #1;
        end
        @(posedge pixel_clk); #1;
        @(negedge pixel_clk); #1;
        if (lcd_rgb !== 24'h0a2b4c)
            fail("dashboard header background was not restored");
        repeat (500) @(posedge pixel_clk);
        @(negedge pixel_clk); #1;
        if (lcd_rgb !== 24'h0a2b4c)
            fail("dashboard output fell back to diagnostic color bars");
        if (dut.bcd_completed != 40'h0000001234 ||
            dut.bcd_temperature != 40'h0000000045 ||
            dut.bcd_latency1 != 40'h0000005890 ||
            dut.bcd_batch_completed != 40'h0000025000 ||
            dut.bcd_batch_total != 40'h0000100000)
            fail("shared binary-to-decimal renderer produced wrong digits");

        // A frame-start snapshot must be converted in that same frame.  The
        // converter must not start on the stale pre-snapshot register values.
        completed_count = 32'd4321;
        temperature_q8_8 = 16'h3280;
        while (!(dut.h_count == H_TOTAL-1 && dut.v_count == V_TOTAL-1)) begin
            @(posedge pixel_clk); #1;
        end
        @(posedge pixel_clk); #1;
        repeat (520) @(posedge pixel_clk);
        #1;
        if (dut.snap_completed_count != 32'd4321 ||
            dut.bcd_completed != 40'h0000004321 ||
            dut.bcd_temperature != 40'h0000000050)
            fail("new frame values were not converted without a stale-frame delay");

        // The 16x32 dashboard keeps only demo-critical information and
        // leaves the middle of each speedup row for a shorter bar.
        if (dut.screen_char(5'd0, 7'd2) != "M" ||
            dut.screen_char(5'd2, 7'd2) != "T" ||
            dut.screen_char(5'd4, 7'd2) != "D" ||
            dut.screen_char(5'd6, 7'd2) != "F" ||
            dut.screen_char(5'd7, 7'd2) != "T" ||
            dut.screen_char(5'd14, 7'd2) != "B")
            fail("compact dashboard omitted a required summary");
        if (dut.screen_char(5'd1, 7'd2) != 8'h20 ||
            dut.screen_char(5'd3, 7'd2) != 8'h20 ||
            dut.screen_char(5'd5, 7'd2) != 8'h20)
            fail("compact dashboard retained crowded legacy rows");

        // The 5x7 source glyph must be expanded to 15x28 inside a 16x32 cell.
        // This is large enough to read at demo distance while retaining a
        // one-pixel horizontal and four-pixel vertical gap.
        while (!(dut.active_y == 9'd64 && dut.active_x == 10'd32)) begin
            @(posedge pixel_clk); #1;
        end
        font_top_pixels = 0;
        repeat (16) begin
            if (dut.font_pixel)
                font_top_pixels = font_top_pixels + 1;
            @(posedge pixel_clk); #1;
        end
        if (font_top_pixels != 15)
            fail("font glyph was not enlarged to a 16x32 display cell");

        // With no submitted batch or completed task, zeros must not look
        // like a failed benchmark.  The dashboard says IDLE and -- instead.
        completed_count = 0;
        avg_latency_us = 0;
        batch_completed = 0;
        batch_total = 0;
        while (!(dut.h_count == H_TOTAL-1 && dut.v_count == V_TOTAL-1)) begin
            @(posedge pixel_clk); #1;
        end
        @(posedge pixel_clk); #1;
        repeat (520) @(posedge pixel_clk);
        #1;
        if (dut.screen_char(5'd4, 7'd38) != "-" ||
            dut.screen_char(5'd14, 7'd8) != "I")
            fail("idle latency or batch status was displayed as a real zero");

        // Network animation is quiet while idle; the heartbeat remains the
        // always-on proof of life.  Toggling the request event starts a cyan
        // marker that moves for several frames.
        idle_activity_pixels = 0;
        while (!(dut.v_count == 35+24 && dut.h_count == 136+520)) begin
            @(posedge pixel_clk); #1;
        end
        repeat (120) begin
            if (dut.pixel_rgb == 24'h25c7e8)
                idle_activity_pixels = idle_activity_pixels + 1;
            @(posedge pixel_clk); #1;
        end
        if (idle_activity_pixels != 0)
            fail("network activity marker moved while the service was idle");

        activity_toggle = ~activity_toggle;
        while (!(dut.h_count == H_TOTAL-1 && dut.v_count == V_TOTAL-1)) begin
            @(posedge pixel_clk); #1;
        end
        @(posedge pixel_clk); #1;
        live_x_first = -1;
        while (!(dut.v_count == 35+24 && dut.h_count == 136+520)) begin
            @(posedge pixel_clk); #1;
        end
        repeat (120) begin
            if (dut.pixel_rgb == 24'h25c7e8 && live_x_first < 0)
                live_x_first = dut.active_x;
            @(posedge pixel_clk); #1;
        end
        live_x_second = -1;
        while (!(dut.v_count == 35+24 && dut.h_count == 136+520)) begin
            @(posedge pixel_clk); #1;
        end
        repeat (120) begin
            if (dut.pixel_rgb == 24'h25c7e8 && live_x_second < 0)
                live_x_second = dut.active_x;
            @(posedge pixel_clk); #1;
        end
        if (live_x_first < 0 || live_x_second < 0 ||
            live_x_first == live_x_second)
            fail("LIVE marker was missing or did not move between frames");

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
        if (lcd_rst !== 1'b0 || lcd_bl !== 1'b1)
            fail("reset/backlight diagnostic state is wrong after lock loss");

        $display("PASS: LCD 800x480 timing, startup and snapshots");
        $finish;
    end
endmodule
