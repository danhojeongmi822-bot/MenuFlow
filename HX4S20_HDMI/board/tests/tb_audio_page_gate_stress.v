`timescale 1ns/1ps

// audio_page_gate 快速翻页压力测试：模拟用户连续快按 KEY，切页间隔很短。
//
// 关注缺陷：start_arm 置位后，若下一拍 want_play 或 trans_busy 变化，
// 优先级链可能走进其他分支，导致 start_arm 残留 / start_toggle 丢失，
// 表现为“翻几次之后音频再也不响”。
module tb_audio_page_gate_stress;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;

    reg       frame_start = 1'b0;
    reg [1:0] active_index = 2'd0;
    reg       display_valid = 1'b1;
    reg       trans_busy = 1'b0;

    wire       start_toggle, stop_toggle;
    wire [3:0] track_sel;
    wire       should_play;
    wire [1:0] page_q;

    integer errors = 0;
    integer starts = 0, stops = 0;
    reg     start_d = 1'b0, stop_d = 1'b0;

    audio_page_gate dut (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .active_index(active_index), .display_valid(display_valid), .trans_busy(trans_busy),
        .start_toggle(start_toggle), .stop_toggle(stop_toggle),
        .track_sel(track_sel), .should_play(should_play), .page_q(page_q)
    );

    always @(posedge clk) begin
        start_d <= start_toggle;
        stop_d  <= stop_toggle;
        if (start_toggle != start_d) starts = starts + 1;
        if (stop_toggle  != stop_d)  stops  = stops + 1;
    end

    // 快速翻页：每页停留 n 拍（远小于一帧），模拟连续点击
    task automatic burst_pages(input integer dwell, input integer rounds);
        integer r;
        begin
            for (r = 0; r < rounds; r = r + 1) begin
                // 0 -> 2 -> 3 -> 0 -> 2 ... 交替进出促销页
                @(negedge clk); active_index = 2'd2; frame_start = 1'b1;
                @(posedge clk);
                @(negedge clk); frame_start = 1'b0;
                repeat (dwell) @(posedge clk);

                @(negedge clk); active_index = 2'd3; frame_start = 1'b1;
                @(posedge clk);
                @(negedge clk); frame_start = 1'b0;
                repeat (dwell) @(posedge clk);

                @(negedge clk); active_index = 2'd0; frame_start = 1'b1;
                @(posedge clk);
                @(negedge clk); frame_start = 1'b0;
                repeat (dwell) @(posedge clk);
            end
        end
    endtask

    integer s0, t0v;

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- 1) 极短停留（3 拍）：连续 8 轮进出促销页 ----
        s0 = starts; t0v = stops;
        burst_pages(3, 8);
        // 每轮应产生 start（进入促销）与 stop（离开），不能丢
        if ((starts - s0) < 8) begin
            $display("FAIL stress: short dwell lost starts (%0d in 8 rounds)", starts - s0);
            errors = errors + 1;
        end

        // ---- 2) 停留刚好跨过 start_arm 那一拍（2 拍）----
        s0 = starts; t0v = stops;
        burst_pages(2, 8);
        if ((starts - s0) < 8) begin
            $display("FAIL stress: 2-cycle dwell lost starts (%0d in 8 rounds)", starts - s0);
            errors = errors + 1;
        end

        // ---- 3) 转场与切页交错：trans_busy 与 active_index 随机变化 ----
        s0 = starts;
        begin : chaos
            integer k;
            for (k = 0; k < 400; k = k + 1) begin
                @(negedge clk);
                case (k % 5)
                    0: begin active_index = 2'd2; frame_start = 1'b1; end
                    1: begin trans_busy = ~trans_busy; end
                    2: begin active_index = 2'd3; frame_start = 1'b1; end
                    3: begin display_valid = ~display_valid; end
                    default: begin active_index = 2'd0; frame_start = 1'b1; end
                endcase
                @(posedge clk);
                @(negedge clk);
                frame_start = 1'b0;
            end
        end

        // ---- 4) 稳定进入 PIC3 后必须能起来 ----
        @(negedge clk);
        trans_busy = 1'b0; display_valid = 1'b1;
        active_index = 2'd2; frame_start = 1'b1;
        @(posedge clk);
        @(negedge clk); frame_start = 1'b0;
        repeat (10) @(posedge clk);
        if (!should_play) begin
            $display("FAIL stress: did not recover to should_play after settling");
            errors = errors + 1;
        end
        if (dut.playing !== 1'b1) begin
            $display("FAIL stress: gate not playing after settling (playing=%b arm=%b)",
                     dut.playing, dut.start_arm);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS audio_page_gate_stress: %0d starts / %0d stops, no lost transitions", starts, stops);
        else
            $display("FAIL audio_page_gate_stress: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL audio_page_gate_stress: timeout");
        $fatal(1);
    end

endmodule
