`timescale 1ns/1ps

// 转场像素处理：整帧 Alpha 缩放 + 单路幕布式（遮挡/揭示）。
//
// 插入点：video_delay.vout_data 经 display_valid 门控之后、osd_overlay 之前。
// 因此 OSD 状态条与滚动字幕不受 alpha/遮挡影响。
//
// 延迟契约：输出级统一寄存 1 拍，RGB/DE/HS/VS 与像素横坐标同拍寄存，
// 后续 osd_overlay 按 de 自行重建坐标，不会产生左右错位。
//
// Alpha 精度：
//   out = (alpha == 255) ? in : floor(in * alpha / 255)
//   floor(t/255) = (t + (t>>8) + 1) >> 8  （t = in*alpha <= 65025，见设计文档证明）
//   alpha=0 时结果精确为 0；alpha=255 时走显式旁路，逐位透传。
//
// Wipe：mode==M_WIPE 时按 cover_x 做水平边界比较。
//   wipe_reveal=0（遮挡）：x < cover_x 输出遮挡色，右侧继续输出旧图。
//   wipe_reveal=1（揭示）：x < cover_x 输出新图（此时 Bank 已切换），右侧保持遮挡色。
//   边界只在帧边界变化，一帧内恒定。
module video_effect #(
    parameter integer H_ACTIVE   = 640,
    parameter [23:0]  COVER_COLOR = 24'h000000
)(
    input  wire        clk,
    input  wire        rst,          // 高有效
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [23:0] rgb_in,
    input  wire [1:0]  mode,         // 0=旁路 1=整帧Alpha 2=幕布
    input  wire [7:0]  alpha,
    input  wire [10:0] cover_x,
    input  wire        wipe_reveal,
    output reg  [23:0] rgb_out,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out
);

    localparam [1:0] M_PASS = 2'd0;
    localparam [1:0] M_FADE = 2'd1;
    localparam [1:0] M_WIPE = 2'd2;

    // 当前像素横坐标：de 无效时清零，de 有效时每拍 +1；首像素为 0。
    reg [10:0] x_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst)
            x_cnt <= 11'd0;
        else if (de)
            x_cnt <= x_cnt + 11'd1;
        else
            x_cnt <= 11'd0;
    end

    // ---------------- 精确 /255 缩放 ----------------
    wire [15:0] t_r = rgb_in[23:16] * alpha;
    wire [15:0] t_g = rgb_in[15:8]  * alpha;
    wire [15:0] t_b = rgb_in[7:0]   * alpha;

    wire [16:0] u_r = {1'b0, t_r} + 17'd1;
    wire [16:0] u_g = {1'b0, t_g} + 17'd1;
    wire [16:0] u_b = {1'b0, t_b} + 17'd1;

    wire [16:0] w_r = u_r + {8'd0, u_r[16:8]};
    wire [16:0] w_g = u_g + {8'd0, u_g[16:8]};
    wire [16:0] w_b = u_b + {8'd0, u_b[16:8]};

    wire [23:0] faded_rgb = {w_r[15:8], w_g[15:8], w_b[15:8]};

    // ---------------- 幕布边界 ----------------
    wire        cover_hit = (x_cnt < cover_x);
    wire [23:0] wipe_rgb  = wipe_reveal
                            ? (cover_hit ? rgb_in : COVER_COLOR)
                            : (cover_hit ? COVER_COLOR : rgb_in);

    // ---------------- 模式选择 ----------------
    // de 无效的消隐像素保持逐位透传，确保“空白期不改写 RGB”的既有契约。
    wire [23:0] active_rgb = (mode == M_FADE)
                             ? ((alpha == 8'd255) ? rgb_in : faded_rgb)
                             : ((mode == M_WIPE) ? wipe_rgb : rgb_in);
    wire [23:0] mixed_rgb  = de ? active_rgb : rgb_in;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rgb_out <= 24'd0;
            de_out  <= 1'b0;
            hs_out  <= 1'b0;
            vs_out  <= 1'b0;
        end else begin
            rgb_out <= mixed_rgb;
            de_out  <= de;
            hs_out  <= hs;
            vs_out  <= vs;
        end
    end

endmodule
