`timescale 1ns/1ps

// 音频媒体编号联动验证：
// 顶层现在把 state_code_media_cdc 的源改成“已提交显示 Bank 编号”，
// 因此 SD 域发起切图请求时媒体编号不得提前变化，只有 Bank 真正提交后
// 才更新，且更新后 O_media_valid 置位。
//
// 本 TB 复现顶层接法（src_clk = dst_clk = video_clk），验证：
//  - 请求阶段（sd_img_idx 改变、committed_code 未变）媒体编号保持不变；
//  - 提交阶段（committed_code 改变）媒体编号在若干拍后更新为 code-1；
//  - 复位后 media_valid 清零、media_id 归零；
//  - 编号在 1..4 范围内才被接受。
module tb_media_follow_bank;

    reg        clk;
    reg        rst;
    reg [3:0]  committed_code;   // 已提交显示 Bank 的 1~4 编号
    reg [3:0]  sd_img_idx_code;  // sd 域请求的编号（只用于模拟“请求先发生”）
    wire [1:0] media_id;
    wire       media_valid;
    wire       update_pulse;

    integer fails;
    integer checks;

    state_code_media_cdc dut (
        .I_src_clk      (clk),
        .I_src_rst      (rst),
        .I_state_code   (committed_code),
        .I_dst_clk      (clk),
        .I_dst_rst      (rst),
        .O_media_id     (media_id),
        .O_media_valid  (media_valid),
        .O_update_pulse (update_pulse)
    );

    always #20 clk = ~clk;   // 25 MHz

    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        clk            = 1'b0;
        rst            = 1'b1;
        committed_code = 4'd1;
        sd_img_idx_code= 4'd1;
        fails          = 0;
        checks         = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        wait_cycles(10);

        // 1) 复位后：模块按“已提交编号 1”重新建立基线，媒体有效且为 Bank0
        checks = checks + 1;
        if (media_valid !== 1'b1 || media_id !== 2'd0) begin
            fails = fails + 1;
            $display("FAIL media: baseline after reset wrong (valid=%b id=%0d)",
                     media_valid, media_id);
        end

        // 2) SD 域已经请求下一张（编号 2），但 Bank 尚未提交：
        //    已提交编号仍是 1，媒体编号必须不动。
        sd_img_idx_code = 4'd2;
        wait_cycles(20);
        checks = checks + 1;
        if (media_id !== 2'd0) begin
            fails = fails + 1;
            $display("FAIL media: media id changed before Bank commit (valid=%b id=%0d)",
                     media_valid, media_id);
        end

        // 3) Bank 真正提交（已提交编号 1 -> 2）：媒体编号变为 1
        committed_code = 4'd2;
        wait_cycles(12);
        checks = checks + 1;
        if (media_valid !== 1'b1 || media_id !== 2'd1) begin
            fails = fails + 1;
            $display("FAIL media: media id did not follow commit (valid=%b id=%0d)",
                     media_valid, media_id);
        end

        // 4) 编号 2 -> 3
        committed_code = 4'd3;
        wait_cycles(12);
        checks = checks + 1;
        if (media_id !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL media: media id %0d != 2 after commit 3", media_id);
        end

        // 5) 编号跳到 4
        committed_code = 4'd4;
        wait_cycles(12);
        checks = checks + 1;
        if (media_id !== 2'd3) begin
            fails = fails + 1;
            $display("FAIL media: media id %0d != 3 after commit 4", media_id);
        end

        // 6) 非法编号（0/5..）不得改变媒体编号
        committed_code = 4'd0;
        wait_cycles(12);
        checks = checks + 1;
        if (media_id !== 2'd3) begin
            fails = fails + 1;
            $display("FAIL media: illegal code 0 changed media id to %0d", media_id);
        end
        committed_code = 4'd3;
        wait_cycles(12);
        checks = checks + 1;
        if (media_id !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL media: media id %0d != 2 after returning to 3", media_id);
        end

        // 7) 运行中复位：媒体状态清零，随后按“当前已提交 Bank”重新建立
        //    （此时 committed_code=3，对应 media_id=2）
        rst = 1'b1;
        repeat (2) @(posedge clk);
        if (media_valid !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL media: reset did not clear media_valid");
        end
        rst = 1'b0;
        wait_cycles(10);
        checks = checks + 1;
        if (media_valid !== 1'b1 || media_id !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL media: reset did not re-arm to current Bank (valid=%b id=%0d)",
                     media_valid, media_id);
        end

        if (fails == 0) begin
            $display("PASS media_follow_bank: %0d checks, media follows committed Bank only", checks);
            $finish;
        end else begin
            $display("FAIL media_follow_bank: %0d failure(s) over %0d checks", fails, checks);
            $fatal(1);
        end
    end

endmodule
