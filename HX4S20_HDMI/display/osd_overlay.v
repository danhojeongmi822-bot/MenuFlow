`timescale 1ns/1ps

// 视频后级 OSD 叠加层：左上角状态条 + 底部滚动字幕。
// 输入/输出都是已经对齐的像素域信号；输出级统一寄存一拍，
// RGB/DE/HS/VS/坐标保持同拍，不改变下游 AXIS/HDMI 的相对时序。
module osd_overlay #(
    parameter integer H_ACTIVE    = 640,
    parameter integer V_ACTIVE    = 480,
    parameter integer STATUS_X    = 8,
    parameter integer STATUS_Y    = 8,
    parameter integer SUBTITLE_Y  = 448,
    parameter integer SCROLL_STEP = 2,
    parameter integer TEXT_LEN    = 40,
    parameter integer TEXT_WIDTH  = 640,
    parameter integer OSD_ENABLE  = 1
)(
    input  wire        clk,
    input  wire        rst,           // 高有效
    input  wire        hs,
    input  wire        vs,            // 负极性场同步，已与像素对齐
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [1:0]  active_index,  // 已提交显示的 Bank
    input  wire [9:0]  status,        // {display_valid, auto_enable, error_code[7:0]}
    output reg  [23:0] rgb_out,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out,
    output reg         frame_start,
    output reg  [9:0]  pixel_x,
    output reg  [9:0]  pixel_y,
    output reg  [10:0] scroll_offset,
    output reg         osd_active
);

    localparam [23:0] COLOR_STATUS_OK  = 24'hFFFF00;  // 黄色
    localparam [23:0] COLOR_STATUS_ERR = 24'hFF3030;  // 红色
    localparam [23:0] COLOR_SUBTITLE   = 24'h00FFFF;  // 青色

    localparam [10:0] H_ACTIVE_U   = H_ACTIVE;
    localparam [10:0] TEXT_WIDTH_U = TEXT_WIDTH;
    localparam [10:0] SCROLL_LIMIT = TEXT_WIDTH + H_ACTIVE;

    // ---------------- 输入侧坐标重建 ----------------
    reg [9:0] x_cnt;
    reg [9:0] y_cnt;
    reg       vs_d;
    reg       de_d;

    wire vs_fall = vs_d & ~vs;
    wire de_fall = de_d & ~de;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_cnt       <= 10'd0;
            y_cnt       <= 10'd0;
            vs_d        <= 1'b0;
            de_d        <= 1'b0;
            frame_start <= 1'b0;
        end else begin
            vs_d <= vs;
            de_d <= de;

            // 场同步下降沿 = 新一帧的场消隐起点，早于本帧有效行。
            frame_start <= vs_fall;

            if (de)
                x_cnt <= x_cnt + 10'd1;
            else
                x_cnt <= 10'd0;

            if (!vs)
                y_cnt <= 10'd0;
            else if (de_fall)
                y_cnt <= y_cnt + 10'd1;
        end
    end

    // ---------------- 帧边界锁存 ----------------
    reg [1:0]  idx_q;
    reg [9:0]  status_q;

    wire [10:0] scroll_next = (scroll_offset + SCROLL_STEP >= SCROLL_LIMIT)
                              ? 11'd0
                              : scroll_offset + SCROLL_STEP;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            idx_q         <= 2'd0;
            status_q      <= 10'h0E1;   // 未显示 / 手动 / SD 初始化中
            scroll_offset <= 11'd0;
        end else if (frame_start) begin
            idx_q         <= active_index;
            status_q      <= status;
            scroll_offset <= scroll_next;
        end
    end

    // ---------------- 十六进制字符 ----------------
    function [6:0] hex_char;
        input [3:0] v;
        begin
            if (v < 4'd10)
                hex_char = 7'h30 + {3'd0, v};
            else
                hex_char = 7'h41 + {3'd0, v} - 7'd10;
        end
    endfunction

    // ---------------- 状态条：4 个 16x16 单元 ----------------
    wire [9:0] sx   = x_cnt - STATUS_X;
    wire [9:0] sy   = y_cnt - STATUS_Y;
    wire       in_status = (x_cnt >= STATUS_X) && (x_cnt < STATUS_X + 64) &&
                           (y_cnt >= STATUS_Y) && (y_cnt < STATUS_Y + 16);

    wire [1:0] scell = sx[5:4];
    wire [3:0] scol  = sx[3:0];
    wire [3:0] srow  = sy[3:0];
    wire [1:0] s_fx  = scol[3:1];
    wire [2:0] s_fy  = srow[3:1];

    reg [6:0] s_char;
    always @* begin
        case (scell)
            2'd0: s_char = status_q[9] ? (7'h31 + {5'd0, idx_q}) : 7'h2D; // '1'+idx / '-'
            2'd1: s_char = status_q[8] ? 7'h41 : 7'h4D;                   // 'A' / 'M'
            2'd2: s_char = hex_char(status_q[7:4]);
            2'd3: s_char = hex_char(status_q[3:0]);
            default: s_char = 7'h20;
        endcase
    end

    wire [4:0] s_glyph;
    osd_font_rom u_font_status (
        .ch    (s_char),
        .row   (s_fy),
        .glyph (s_glyph)
    );

    wire [2:0] s_bit = 3'd4 - {1'b0, s_fx};
    wire s_hit = OSD_ENABLE && in_status && (scol < 4'd10) && (srow < 4'd14) &&
                 s_glyph[s_bit];

    // ---------------- 滚动字幕：40 字符 x 16 像素 ----------------
    function [6:0] subtitle_char;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  subtitle_char = 7'h48; // H
                6'd1:  subtitle_char = 7'h58; // X
                6'd2:  subtitle_char = 7'h34; // 4
                6'd3:  subtitle_char = 7'h53; // S
                6'd4:  subtitle_char = 7'h32; // 2
                6'd5:  subtitle_char = 7'h30; // 0
                6'd6:  subtitle_char = 7'h20; // space
                6'd7:  subtitle_char = 7'h46; // F
                6'd8:  subtitle_char = 7'h50; // P
                6'd9:  subtitle_char = 7'h47; // G
                6'd10: subtitle_char = 7'h41; // A
                6'd11: subtitle_char = 7'h20; // space
                6'd12: subtitle_char = 7'h48; // H
                6'd13: subtitle_char = 7'h44; // D
                6'd14: subtitle_char = 7'h4D; // M
                6'd15: subtitle_char = 7'h49; // I
                6'd16: subtitle_char = 7'h20; // space
                6'd17: subtitle_char = 7'h50; // P
                6'd18: subtitle_char = 7'h48; // H
                6'd19: subtitle_char = 7'h4F; // O
                6'd20: subtitle_char = 7'h54; // T
                6'd21: subtitle_char = 7'h4F; // O
                6'd22: subtitle_char = 7'h20; // space
                6'd23: subtitle_char = 7'h50; // P
                6'd24: subtitle_char = 7'h4C; // L
                6'd25: subtitle_char = 7'h41; // A
                6'd26: subtitle_char = 7'h59; // Y
                6'd27: subtitle_char = 7'h45; // E
                6'd28: subtitle_char = 7'h52; // R
                6'd29: subtitle_char = 7'h20; // space
                6'd30: subtitle_char = 7'h2D; // -
                6'd31: subtitle_char = 7'h20; // space
                6'd32: subtitle_char = 7'h4F; // O
                6'd33: subtitle_char = 7'h53; // S
                6'd34: subtitle_char = 7'h44; // D
                6'd35: subtitle_char = 7'h20; // space
                6'd36: subtitle_char = 7'h44; // D
                6'd37: subtitle_char = 7'h45; // E
                6'd38: subtitle_char = 7'h4D; // M
                6'd39: subtitle_char = 7'h4F; // O
                default: subtitle_char = 7'h20;
            endcase
        end
    endfunction

    wire [10:0] txsum   = {1'b0, x_cnt} + scroll_offset;
    wire [10:0] tlocal   = txsum - H_ACTIVE_U;
    wire        t_visible = (txsum >= H_ACTIVE_U) && (tlocal < TEXT_WIDTH_U);

    wire [9:0]  sy_sub  = y_cnt - SUBTITLE_Y;
    wire        t_y_ok  = (y_cnt >= SUBTITLE_Y) && (y_cnt < SUBTITLE_Y + 16);
    wire [5:0]  tcell   = tlocal[9:4];
    wire [3:0]  tcol    = tlocal[3:0];
    wire [1:0]  t_fx    = tcol[3:1];
    wire [2:0]  t_fy    = sy_sub[3:1];

    wire [6:0] t_char = subtitle_char(tcell);
    wire [4:0] t_glyph;
    osd_font_rom u_font_subtitle (
        .ch    (t_char),
        .row   (t_fy),
        .glyph (t_glyph)
    );

    wire [2:0] t_bit = 3'd4 - {1'b0, t_fx};
    wire t_hit = OSD_ENABLE && t_visible && t_y_ok && (tcell < TEXT_LEN) &&
                 (tcol < 4'd10) && t_glyph[t_bit];

    // ---------------- 输出选择与寄存 ----------------
    wire        err     = (status_q[7:0] != 8'd0);
    wire [23:0] s_color = err ? COLOR_STATUS_ERR : COLOR_STATUS_OK;
    wire [23:0] osd_rgb = s_hit ? s_color : COLOR_SUBTITLE;
    wire        hit     = (s_hit || t_hit) && de;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rgb_out     <= 24'd0;
            de_out      <= 1'b0;
            hs_out      <= 1'b0;
            vs_out      <= 1'b0;
            pixel_x     <= 10'd0;
            pixel_y     <= 10'd0;
            osd_active  <= 1'b0;
        end else begin
            rgb_out    <= hit ? osd_rgb : rgb_in;
            de_out     <= de;
            hs_out     <= hs;
            vs_out     <= vs;
            pixel_x    <= x_cnt;
            pixel_y    <= y_cnt;
            osd_active <= hit;
        end
    end

endmodule
