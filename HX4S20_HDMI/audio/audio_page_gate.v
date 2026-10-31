`timescale 1ns/1ps

// 促销页音频播放门控（像素域）。
//
// 输入全部来自已提交显示路径（four_bank_frame_commit 的 active_index），
// 不依赖 sd 域的 state_code，避免显示与音频选择不一致。
//
// 行为契约：
//   * page_q 只在 frame_start 跟随 active_index（一帧内不变）。
//   * 页面为促销页（>=2）且 display_valid 时才“应播放”；否则应停止。
//   * 启动只在 !trans_busy 时发生：转场未完成不启动，避免音源提前切换。
//   * 播放中同页不重复启动；切到另一促销页 → 先 stop，等转场结束再 start，
//     并锁存新的 track_sel。
//   * 转场期间若仍在同一促销页，不得产生额外 stop/start（防抖动）。
//   * track_sel 在停止后保持不变（准静态），只在新一次 start 时更新。
module audio_page_gate (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire [1:0]  active_index,     // 已提交显示 Bank（0..3）
    input  wire        display_valid,
    input  wire        trans_busy,

    output reg         start_toggle,
    output reg         stop_toggle,
    output reg  [3:0]  track_sel,        // 1..4 = 页面编号
    output wire        should_play,      // 目标状态（供波形/状态判断）
    output reg  [1:0]  page_q
);
    wire page_is_promo = (page_q >= 2'd2);
    wire want_play     = display_valid && page_is_promo;
    assign should_play = want_play;

    // 当前音频对应的页面编号（1..4）；0 表示未知
    wire [3:0] page_num = {2'b00, page_q} + 4'd1;

    reg playing;
    reg restart_pending;

    // start 请求分两拍提交：先在本拍锁存 track_sel，下一拍才翻转 toggle。
    // 若两者同拍更新，SD 域 2FF 采样 toggle 时可能仍看到旧的 track_sel，
    // 结果播放上一页的文件（PIC4 播 PIC3 的音，甚至因页号不匹配而无声）。
    reg start_arm;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            page_q          <= 2'd0;
            start_toggle    <= 1'b0;
            stop_toggle     <= 1'b0;
            track_sel       <= 4'd1;
            playing         <= 1'b0;
            restart_pending <= 1'b0;
            start_arm       <= 1'b0;
        end else begin
            if (frame_start)
                page_q <= active_index;

            if (playing && want_play && (page_num != track_sel)) begin
                // 切到另一促销页：先平滑停止，等转场结束后再启动新页
                stop_toggle     <= ~stop_toggle;
                playing         <= 1'b0;
                restart_pending <= 1'b1;
            end else if (playing && !want_play) begin
                stop_toggle     <= ~stop_toggle;
                playing         <= 1'b0;
                restart_pending <= 1'b0;
            end else if (!playing && want_play && !trans_busy) begin
                // 第一拍：只锁存目标页号，保持 track_sel 稳定
                track_sel       <= page_num;
                start_arm       <= 1'b1;
                playing         <= 1'b1;
                restart_pending <= 1'b0;
            end else if (start_arm) begin
                // 第二拍：track_sel 已稳定一个周期，此时才翻转 toggle
                start_arm    <= 1'b0;
                start_toggle <= ~start_toggle;
            end
        end
    end

endmodule
