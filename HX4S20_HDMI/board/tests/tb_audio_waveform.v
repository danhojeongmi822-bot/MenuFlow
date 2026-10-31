`timescale 1ns/1ps
// 波形采集专项：双缓冲交换、峰值(含 -32768)、静音、停止、抽取计数。
module tb_audio_waveform;

    localparam integer W = 64;
    localparam integer DEC = 12;
    localparam integer PTS = 64;
    localparam integer WAVE_Y  = 340;
    localparam integer WAVE_H  = 92;
    localparam integer CENTER  = WAVE_Y + WAVE_H/2;
    localparam integer HALF_H  = WAVE_H/2 - 2;
    localparam integer PEAK_H_MAX = WAVE_H - 8;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;      // 25 MHz

    reg de = 1'b0, hs = 1'b1, vs = 1'b1;
    reg [23:0] rgb_in = 24'h123456;
    reg [1:0] active_index = 2'd2;
    reg frame_start = 1'b0, display_valid = 1'b1;
    reg pcm_tap_valid = 1'b0;
    reg [23:0] pcm_tap_sample = 24'd0;
    reg pcm_playing = 1'b0;

    wire [23:0] rgb_out;
    wire de_out, hs_out, vs_out;

    integer errors = 0;

    audio_waveform_overlay #(
        .WAVE_X(64), .WAVE_Y(WAVE_Y), .WAVE_W(512), .WAVE_H(WAVE_H),
        .SAMPLE_COUNT(PTS), .DECIMATE(DEC)
    ) dut (
        .clk(clk), .rst(rst),
        .de(de), .hs(hs), .vs(vs), .rgb_in(rgb_in),
        .rgb_out(rgb_out), .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out),
        .active_index(active_index), .frame_start(frame_start), .display_valid(display_valid),
        .pcm_tap_valid(pcm_tap_valid), .pcm_tap_sample(pcm_tap_sample), .pcm_playing(pcm_playing)
    );

    // ------------------------------------------------------------------
    // 采集辅助：喂入 n 个 48 kHz 样本（每个样本前后相隔 DEC 个 valid 脉冲）
    // ------------------------------------------------------------------
    task automatic feed_sample(input [15:0] s16);
        integer k;
        begin
            for (k = 0; k < DEC; k = k + 1) begin
                @(negedge clk);
                pcm_tap_valid  = 1'b1;
                pcm_tap_sample = {s16, 8'b0};
                @(posedge clk);
            end
            @(negedge clk);
            pcm_tap_valid = 1'b0;
        end
    endtask

    task automatic feed_frame_constant(input [15:0] s16);
        integer i;
        begin
            // 采满 PTS 个点（每个点间隔 DEC 个 valid）
            for (i = 0; i < PTS; i = i + 1) feed_sample(s16);
        end
    endtask

    task automatic pulse_frame_start;
        begin
            @(negedge clk);
            frame_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_start = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // 像素遍历：把一帧的有效行扫一遍，收集波形区像素
    // ------------------------------------------------------------------
    integer px, py;
    integer wave_px, axis_px, bg_px, peak_px;
    integer first_wave_y, last_wave_y;
    integer first_peak_y;
    reg     saw_outside_change;
    reg [23:0] exp_wave, exp_bg, exp_axis, exp_peak;

    // 完整一帧：vs 低脉冲 → 480 行 × (640 de 高 + 4 de 低)
    task automatic scan_frame;
        integer lx, d;
        begin
            wave_px = 0; axis_px = 0; bg_px = 0; peak_px = 0;
            first_wave_y = -1; last_wave_y = -1; first_peak_y = -1;
            saw_outside_change = 1'b0;

            // 场同步负脉冲（DUT 用 vs 低电平清零 y）
            @(negedge clk); de = 1'b0; vs = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk); vs = 1'b1;
            repeat (4) @(posedge clk);

            for (py = 0; py < 480; py = py + 1) begin
                for (px = 0; px < 640; px = px + 1) begin
                    // 本模块是组合叠加（0 拍延迟）：x_cnt 在当前周期内就是本像素的
                    // 横坐标，因此在 posedge 之前采样，才对应“本像素”。
                    @(negedge clk);
                    de     = 1'b1;
                    rgb_in = {8'h11, py[7:0], 8'h22};
                    #1;
                    if (rgb_out === 24'h20FF90) begin
                        wave_px = wave_px + 1;
                        if (first_wave_y < 0) first_wave_y = py;
                        last_wave_y = py;
                    end else if (rgb_out === 24'hFFB020) begin
                        peak_px = peak_px + 1;
                        if (first_peak_y < 0) first_peak_y = py;
                    end else if (rgb_out === 24'h081018) begin
                        // 旧版黑底颜色；出现即说明叠加不透明
                        bg_px = bg_px + 1;
                    end else if (rgb_out !== {8'h11, py[7:0], 8'h22}) begin
                        if (!saw_outside_change)
                            $display("  [diag] unexpected rgb at px=%0d py=%0d -> %06h", px, py, rgb_out);
                        saw_outside_change = 1'b1;
                    end
                    @(posedge clk);
                end
                @(negedge clk); de = 1'b0;
                repeat (4) @(posedge clk);
            end
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        // ---- 1) 无数据：波形区不绘制，整帧透传 ----
        pcm_playing = 1'b1;
        pulse_frame_start();
        scan_frame();
        if (wave_px != 0 || peak_px != 0) begin
            $display("FAIL wave: drew without capture (w=%0d p=%0d)", wave_px, peak_px);
            errors = errors + 1;
        end

        // ---- 2) 常值 +100：采集满一帧后交换，波形应在中心上方 ----
        feed_frame_constant(16'sd10000);   // 高 8 位 = 39
        pulse_frame_start();
        scan_frame();
        if (wave_px == 0) begin
            $display("FAIL wave: no waveform after full capture");
            errors = errors + 1;
        end
        // 期望 y = CENTER - 39*44/128 ≈ 386 - 13 = 373
        if (first_wave_y < CENTER - 20 || last_wave_y > CENTER - 5) begin
            $display("FAIL wave: constant +39 drawn at y=%0d..%0d, expect near %0d",
                     first_wave_y, last_wave_y, CENTER - 13);
            errors = errors + 1;
        end
        // 透明叠加：波形区里的非波形像素必须与原图逐位一致（不得出现黑底/边框）
        if (bg_px != 0) begin
            $display("FAIL wave: overlay is not transparent (%0d background pixels painted)", bg_px);
            errors = errors + 1;
        end
        if (saw_outside_change) begin
            $display("FAIL wave: pixels outside the region were modified");
            errors = errors + 1;
        end

        // ---- 3) 常值 -100：波形应在中心下方，且峰值条高度与 +100 相同 ----
        feed_frame_constant(-16'sd10000);  // 高 8 位 = -40 (0xD8)
        pulse_frame_start();
        scan_frame();
        if (first_wave_y < CENTER + 5 || last_wave_y > CENTER + 20) begin
            $display("FAIL wave: constant -40 drawn at y=%0d..%0d, expect near %0d",
                     first_wave_y, last_wave_y, CENTER + 14);
            errors = errors + 1;
        end

        // ---- 4) 满幅 +32767：波形接近区域上界，峰值条顶到最高 ----
        feed_frame_constant(16'sd32767);
        pulse_frame_start();
        scan_frame();
        if (first_wave_y > WAVE_Y + 10) begin
            $display("FAIL wave: full-scale +127 should reach near top (y=%0d)", first_wave_y);
            errors = errors + 1;
        end
        if (first_peak_y > WAVE_Y + 8) begin
            $display("FAIL wave: peak bar not at max height (top y=%0d)", first_peak_y);
            errors = errors + 1;
        end

        // ---- 5) 最小负数 -32768：不得溢出成错误位置或异常峰值 ----
        feed_frame_constant(16'sh8000);
        pulse_frame_start();
        scan_frame();
        if (first_wave_y > CENTER + WAVE_H/2) begin
            $display("FAIL wave: -32768 mapped outside region (y=%0d)", first_wave_y);
            errors = errors + 1;
        end
        if (peak_px == 0) begin
            $display("FAIL wave: -32768 produced no peak bar");
            errors = errors + 1;
        end

        // ---- 6) 静音（0）：波形回到中心轴附近，峰值条为 0 ----
        feed_frame_constant(16'sd0);
        pulse_frame_start();
        scan_frame();
        if (first_wave_y < CENTER - 3 || last_wave_y > CENTER + 3) begin
            $display("FAIL wave: silence not centered (y=%0d..%0d, center=%0d)",
                     first_wave_y, last_wave_y, CENTER);
            errors = errors + 1;
        end
        if (peak_px != 0) begin
            $display("FAIL wave: silence produced %0d peak pixels", peak_px);
            errors = errors + 1;
        end

        // ---- 7) 音频停止：波形必须消失，不保留旧画面 ----
        pcm_playing = 1'b0;
        pulse_frame_start();
        scan_frame();
        if (wave_px != 0 || peak_px != 0) begin
            $display("FAIL wave: kept drawing after stop (w=%0d p=%0d)", wave_px, peak_px);
            errors = errors + 1;
        end

        // ---- 8) 菜单页（page 0/1）：即使有数据也不显示 ----
        pcm_playing = 1'b1;
        active_index = 2'd0;
        feed_frame_constant(16'sd20000);
        pulse_frame_start();
        scan_frame();
        if (wave_px != 0) begin
            $display("FAIL wave: drew on menu page (%0d px)", wave_px);
            errors = errors + 1;
        end
        active_index = 2'd2;

        // ---- 9) 半帧数据不得交换（保持上一帧） ----
        // 先建立一帧完整数据（常数 +50）
        feed_frame_constant(16'sd25000);
        pulse_frame_start();
        scan_frame();
        // 只喂 10 个点，然后帧边界：不应交换，上一帧仍显示
        for (i = 0; i < 10; i = i + 1) feed_sample(16'sd0);
        pulse_frame_start();
        scan_frame();
        if (wave_px == 0) begin
            $display("FAIL wave: partial capture cleared the previous frame");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS audio_waveform: transparent overlay, capture/swap/peak(-32768)/silence/stop/page gate/partial");
        else
            $display("FAIL audio_waveform: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL audio_waveform: timeout");
        $fatal(1);
    end

endmodule
