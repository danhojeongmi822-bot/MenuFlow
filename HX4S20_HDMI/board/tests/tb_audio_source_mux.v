`timescale 1ns/1ps

// audio_source_mux 自检 TB：切换不丢样本、不重复、不混源；增益逐样本精确。
module tb_audio_source_mux;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;      // 25 MHz

    reg sample_tick = 1'b0;

    reg        pcm_valid = 1'b0;
    reg [15:0] pcm_sample = 16'd0;
    reg        pcm_playing = 1'b0;

    reg        media_valid = 1'b0;
    reg [23:0] media_left = 24'd0, media_right = 24'd0;

    reg        test_valid = 1'b0;
    reg [23:0] test_left = 24'd0, test_right = 24'd0;

    wire        audio_valid;
    wire [23:0] audio_left, audio_right;
    wire [1:0]  active_source;
    wire [7:0]  gain;

    integer errors = 0;

    audio_source_mux #(.GAIN_LEVEL(8'd255), .FADE_TICKS(8)) dut (
        .I_clk(clk), .I_rst(rst), .I_sample_tick(sample_tick),
        .I_pcm_valid(pcm_valid), .I_pcm_sample(pcm_sample), .I_pcm_playing(pcm_playing),
        .I_media_active(media_valid), .I_media_valid(media_valid),
        .I_media_left(media_left), .I_media_right(media_right),
        .I_test_valid(test_valid), .I_test_left(test_left), .I_test_right(test_right),
        .O_audio_valid(audio_valid), .O_audio_left(audio_left), .O_audio_right(audio_right),
        .O_active_source(active_source), .O_gain(gain)
    );

    // 产生一个 sample_tick（单拍）。输出与 gain 在同一拍更新，因此比较时
    // 必须使用 tick 之前锁存的 gain（输出用的是旧 gain）。
    reg [7:0] gain_at_tick;
    task automatic tick;
        begin
            @(negedge clk);
            gain_at_tick = gain;
            sample_tick  = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            sample_tick = 1'b0;
        end
    endtask

    // 参考模型：24 位有符号增益
    function [23:0] ref_gain;
        input [23:0] s;
        input [7:0]  g;
        reg   [24:0] mag;
        reg   [31:0] prod;
        begin
            if (g == 8'd255)
                ref_gain = s;
            else begin
                mag  = s[23] ? ({1'b0, ~s[23:0]} + 25'd1) : {1'b0, s[23:0]};
                prod = (mag * {24'd0, g} + 32'd128) >> 8;
                ref_gain = s[23] ? (~prod[23:0] + 24'd1) : prod[23:0];
            end
        end
    endfunction

    integer i;
    reg [7:0] expect_gain;

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---- 1) 满幅、无切换：24 位样本必须逐位透传 ----
        test_valid = 1'b1; test_left = 24'sd1234567; test_right = -24'sd1234567;
        repeat (3) tick();
        if (gain_at_tick !== 8'd255) begin
            $display("FAIL mux: gain not 255 in steady state (%0d)", gain);
            errors = errors + 1;
        end
        if (!audio_valid || audio_left !== 24'sd1234567 || audio_right !== -24'sd1234567) begin
            $display("FAIL mux: pass-through wrong (valid=%b L=%0d R=%0d)",
                     audio_valid, $signed(audio_left), $signed(audio_right));
            errors = errors + 1;
        end
        test_valid = 1'b0;

        // ---- 2) 切到 PCM：必须经过淡出-切换-淡入，不得同拍混源 ----
        media_valid = 1'b1; media_left = 24'sd1000000; media_right = 24'sd1000000;
        pcm_playing = 1'b1; pcm_valid = 1'b1; pcm_sample = 16'sd20000;
        // FADE_TICKS=8，步进 ceil(255/8)=32，需要 8 个 tick 淡出到 0 后再切换
        for (i = 0; i < 16; i = i + 1) begin
            tick();
            if ((active_source === 2'd2) && audio_valid && (gain_at_tick < 8'd255) &&
                (audio_left !== 24'sd1000000)) begin
                $display("FAIL mux: old source sample not used during fade-out");
                errors = errors + 1;
            end
        end
        if (active_source !== 2'd0) begin
            $display("FAIL mux: did not switch to PCM after fade (src=%0d gain=%0d)",
                     active_source, gain);
            errors = errors + 1;
        end
        // 淡入完成后再检查样本值：16 位左对齐
        for (i = 0; i < 20; i = i + 1) tick();
        if (gain !== 8'd255) begin
            $display("FAIL mux: gain did not return to 255 (%0d)", gain);
            errors = errors + 1;
        end
        if (audio_left !== {16'sd20000, 8'b0}) begin
            $display("FAIL mux: PCM not left aligned (got %0d exp %0d)",
                     $signed(audio_left), $signed({16'sd20000, 8'b0}));
            errors = errors + 1;
        end

        // ---- 3) 每个 tick 最多一个 valid；不 tick 时不得输出 ----
        pcm_valid = 1'b0;
        repeat (4) @(posedge clk);
        if (audio_valid) begin
            $display("FAIL mux: valid asserted without tick");
            errors = errors + 1;
        end
        pcm_valid = 1'b1;
        @(negedge clk);
        #1;
        // 没有 tick：不应产生 valid
        repeat (3) @(posedge clk);
        if (audio_valid) begin
            $display("FAIL mux: valid asserted without sample_tick");
            errors = errors + 1;
        end

        // ---- 4) PCM 停止：必须淡回媒体音，且不残留 PCM 样本 ----
        pcm_playing = 1'b0;
        pcm_valid   = 1'b0;
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        for (i = 0; i < 1; i = i + 1) tick();
        if (active_source !== 2'd1) begin
            $display("FAIL mux: did not return to media (src=%0d)", active_source);
            errors = errors + 1;
        end
        for (i = 0; i < 12; i = i + 1) tick();
        if (audio_valid && (audio_left !== 24'sd1000000)) begin
            $display("FAIL mux: media sample wrong after return (%0d)", $signed(audio_left));
            errors = errors + 1;
        end

        // ---- 5) 增益精度：在淡入过程中逐 tick 与参考模型比对 ----
        // 触发一次切换，遍历淡入阶段的每个 tick
        test_valid = 1'b1; test_left = 24'sd1000000; test_right = -24'sd1000000;
        media_valid = 1'b0;
        pcm_playing = 1'b1; pcm_valid = 1'b1; pcm_sample = 16'sd1000;
        for (i = 0; i < 40; i = i + 1) begin
            tick();
            if (audio_valid) begin
                // 输出用的增益是 tick 当拍生效的 gain（DUT 在同一拍寄存输出与 gain）
                if (active_source === 2'd0) begin
                    if (audio_left !== ref_gain({16'sd1000, 8'b0}, gain_at_tick)) begin
                        $display("FAIL mux: gain model mismatch g=%0d got %0d exp %0d",
                                 gain_at_tick, $signed(audio_left),
                                 $signed(ref_gain({16'sd1000, 8'b0}, gain_at_tick)));
                        errors = errors + 1;
                    end
                end else begin
                    if (audio_left !== ref_gain(24'sd1000000, gain_at_tick)) begin
                        $display("FAIL mux: gain model mismatch (test src) g=%0d got %0d exp %0d",
                                 gain_at_tick, $signed(audio_left),
                                 $signed(ref_gain(24'sd1000000, gain_at_tick)));
                        errors = errors + 1;
                    end
                end
            end
        end

        // ---- 6) 静音/复位：复位后增益回到满幅、valid 关闭 ----
        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        if (gain !== 8'd255) begin
            $display("FAIL mux: gain not restored after reset (%0d)", gain);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS audio_source_mux: switch fade, alignment, gain model");
        else
            $display("FAIL audio_source_mux: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL audio_source_mux: timeout");
        $fatal(1);
    end

endmodule
