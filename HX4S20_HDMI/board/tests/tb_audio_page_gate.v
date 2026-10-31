`timescale 1ns/1ps

// audio_page_gate 专项：页面切换、转场抑制、重复触发、复位、track_sel 稳定性。
module tb_audio_page_gate;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;

    reg       frame_start = 1'b0;
    reg [1:0] active_index = 2'd0;
    reg       display_valid = 1'b0;
    reg       trans_busy = 1'b0;

    wire       start_toggle, stop_toggle;
    wire [3:0] track_sel;
    wire       should_play;
    wire [1:0] page_q;

    integer errors = 0;
    integer starts = 0, stops = 0;
    reg     start_d, stop_d;

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

    task automatic do_frame(input [1:0] idx);
        begin
            @(negedge clk);
            active_index = idx;
            frame_start  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_start = 1'b0;
            // start 分两拍提交（先锁存 track_sel，再翻 toggle），多等几拍
            repeat (6) @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        display_valid = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1) 菜单页（0/1）：不启动 ----
        do_frame(2'd0);
        do_frame(2'd1);
        if (starts != 0) begin
            $display("FAIL gate: started on menu page (%0d)", starts);
            errors = errors + 1;
        end
        if (should_play) begin
            $display("FAIL gate: should_play on menu page");
            errors = errors + 1;
        end

        // ---- 2) 进入 PIC3：恰好一次 start，track_sel=3 ----
        do_frame(2'd2);
        if (starts != 1) begin
            $display("FAIL gate: PIC3 start count %0d", starts);
            errors = errors + 1;
        end
        if (track_sel !== 4'd3) begin
            $display("FAIL gate: PIC3 track_sel=%0d", track_sel);
            errors = errors + 1;
        end
        if (!should_play) begin
            $display("FAIL gate: should_play=0 on PIC3");
            errors = errors + 1;
        end

        // ---- 3) 停留在同一页：不得重复 start ----
        repeat (10) do_frame(2'd2);
        if (starts != 1) begin
            $display("FAIL gate: repeated start on same page (%0d)", starts);
            errors = errors + 1;
        end

        // ---- 4) 转场期间不抖动：trans_busy 拉高再拉低，不应产生 stop/start ----
        trans_busy = 1'b1;
        repeat (4) @(posedge clk);
        if (stops != 0) begin
            $display("FAIL gate: stop during transition");
            errors = errors + 1;
        end
        if (starts != 1) begin
            $display("FAIL gate: start flutter during transition");
            errors = errors + 1;
        end
        trans_busy = 1'b0;
        repeat (4) @(posedge clk);
        if (stops != 0 || starts != 1) begin
            $display("FAIL gate: restart after transition (s=%0d t=%0d)", starts, stops);
            errors = errors + 1;
        end

        // ---- 5) 切到 PIC4：先 stop 再 start，track_sel=4 ----
        do_frame(2'd3);
        do_frame(2'd3);
        if (stops != 1) begin
            $display("FAIL gate: PIC3->PIC4 stop count %0d", stops);
            errors = errors + 1;
        end
        if (starts != 2) begin
            $display("FAIL gate: PIC3->PIC4 start count %0d", starts);
            errors = errors + 1;
        end
        if (track_sel !== 4'd4) begin
            $display("FAIL gate: PIC4 track_sel=%0d", track_sel);
            errors = errors + 1;
        end

        // ---- 6) 回到 PIC1：停止；track_sel 保持上一次值（准静态） ----
        do_frame(2'd0);
        do_frame(2'd0);
        if (stops != 2) begin
            $display("FAIL gate: stop on return to menu (%0d)", stops);
            errors = errors + 1;
        end
        if (track_sel !== 4'd4) begin
            $display("FAIL gate: track_sel changed while stopped (%0d)", track_sel);
            errors = errors + 1;
        end

        // ---- 7) display_valid=0：不得启动 ----
        display_valid = 1'b0;
        do_frame(2'd2);
        do_frame(2'd2);
        if (starts != 2) begin
            $display("FAIL gate: started without display_valid (%0d)", starts);
            errors = errors + 1;
        end
        display_valid = 1'b1;

        // ---- 8) 复位：toggle 清零、playing 清除 ----
        @(negedge clk); rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        repeat (2) @(posedge clk);
        if (start_toggle !== 1'b0 || stop_toggle !== 1'b0 || should_play !== 1'b0) begin
            $display("FAIL gate: reset state s=%b t=%b play=%b",
                     start_toggle, stop_toggle, should_play);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS audio_page_gate: enters/exits promo, no flutter, track_sel stable");
        else
            $display("FAIL audio_page_gate: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL audio_page_gate: timeout");
        $fatal(1);
    end

endmodule
