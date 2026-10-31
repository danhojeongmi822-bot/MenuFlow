`timescale 1ns/1ps

// 动态售罄图层（组合叠加，0 拍延迟）。
//
// 插入点：video_delay 输出经 display_valid 门控之后、video_effect 之前。
// 由于本模块只做组合选择，`video_effect`/`osd_overlay` 的寄存契约不变，
// 整条像素链路仍为 23 拍，RGB/DE/HS/VS 同拍。
//
// 绘制优先级：售罄牌 > 选中框 > 管理模式横幅 > 原像素。
// 所有影响画面的配置（页号/选中号/掩码/模式/有效）只在 frame_start 锁存，
// 因此一帧内不会出现新旧状态混合。转场在下一级 video_effect 完成，
// 售罄牌随图一起淡出/被遮挡，不会残留在新页上。

module soldout_overlay (
    input  wire        clk,
    input  wire        rst,            // 高有效
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire        frame_start,
    input  wire        display_valid,
    input  wire [23:0] rgb_in,
    input  wire [1:0]  active_index,
    input  wire        menu_active,
    input  wire [1:0]  sel_idx,
    input  wire [7:0]  soldout_mask,
    output wire [23:0] rgb_out,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out
);

    // 布局常量（由 tools/menuflow/make_menu_assets.py 生成）。
    // 放在模块作用域内，避免文件级 localparam 在 Verilog-2001 模式下的根作用域告警。
`include "menu_layout.vh"

    // ---------------- 坐标重建（与 osd_overlay 同规则） ----------------
    reg [9:0] x_cnt;
    reg [9:0] y_cnt;
    reg       vs_d;
    reg       de_d;

    wire de_fall = de_d & ~de;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_cnt <= 10'd0;
            y_cnt <= 10'd0;
            vs_d  <= 1'b0;
            de_d  <= 1'b0;
        end else begin
            vs_d <= vs;
            de_d <= de;
            if (de) x_cnt <= x_cnt + 10'd1; else x_cnt <= 10'd0;
            if (!vs) y_cnt <= 10'd0;
            else if (de_fall) y_cnt <= y_cnt + 10'd1;
        end
    end

    // ---------------- 帧边界锁存配置 ----------------
    reg [1:0] page_q;
    reg [1:0] sel_q;
    reg [7:0] mask_q;
    reg       menu_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            page_q  <= 2'd0;
            sel_q   <= 2'd0;
            mask_q  <= 8'd0;
            menu_q  <= 1'b0;
        end else if (frame_start) begin
            page_q  <= active_index;
            sel_q   <= sel_idx;
            mask_q  <= soldout_mask;
            menu_q  <= menu_active;
        end
    end

    // ---------------- 单元与局部坐标 ----------------
    wire       row_bit = (y_cnt >= MF_CELL_H);
    wire       col_bit = (x_cnt >= MF_CELL_W);
    wire [1:0] unit_idx = {row_bit, col_bit};   // 0=左上 1=右上 2=左下 3=右下
    wire [9:0] lx      = x_cnt - (col_bit ? MF_CELL_W : 0);
    wire [9:0] ly      = y_cnt - (row_bit ? MF_CELL_H : 0);

    wire page_is_menu = (page_q < 2'd2);
    // {page_q[0], unit_idx} = 8 位掩码索引 0..7（促销页由 page_is_menu 屏蔽）
    wire sold = page_is_menu && mask_q[{page_q[0], unit_idx}];

    // ---------------- 售罄牌 ----------------
    wire in_badge = (lx >= MF_BADGE_X) && (lx < MF_BADGE_X + MF_BADGE_W) &&
                    (ly >= MF_BADGE_Y) && (ly < MF_BADGE_Y + MF_BADGE_H);

    wire badge_edge = (lx < MF_BADGE_X + 3) || (lx >= MF_BADGE_X + MF_BADGE_W - 3) ||
                      (ly < MF_BADGE_Y + 3) || (ly >= MF_BADGE_Y + MF_BADGE_H - 3);

    // 字模行：只在牌内按行节奏更新，像素级只做位选择
    wire [9:0]  gy      = ly - MF_GLYPH_Y;
    wire        in_gy   = (ly >= MF_GLYPH_Y) && (ly < MF_GLYPH_Y + MF_GLYPH_PX);
    wire [4:0]  src_row = in_gy ? gy[5:1] : 5'd0;

    wire [27:0] shou_row;
    wire [27:0] qing_row;

    menu_cjk_rom u_menu_cjk_rom (
        .clk        (clk),
        .row        (src_row),
        .glyph_shou (shou_row),
        .glyph_qing (qing_row)
    );

    wire [9:0] g1x   = lx - MF_GLYPH1_X;
    wire [9:0] g2x   = lx - MF_GLYPH2_X;
    wire       in_g1 = (lx >= MF_GLYPH1_X) && (lx < MF_GLYPH1_X + MF_GLYPH_PX) && in_gy;
    wire       in_g2 = (lx >= MF_GLYPH2_X) && (lx < MF_GLYPH2_X + MF_GLYPH_PX) && in_gy;
    wire [4:0] s1    = in_g1 ? (MF_GLYPH_LAST - g1x[5:1]) : 5'd0;
    wire [4:0] s2    = in_g2 ? (MF_GLYPH_LAST - g2x[5:1]) : 5'd0;

    wire glyph_bit = (in_g1 && shou_row[s1]) || (in_g2 && qing_row[s2]);
    wire badge_hit = sold && in_badge;

    // ---------------- 选中框 ----------------
    wire in_card = (lx >= MF_CARD_X) && (lx < MF_CARD_X + MF_CARD_W) &&
                   (ly >= MF_CARD_Y) && (ly < MF_CARD_Y + MF_CARD_H);
    wire in_ring = (lx < MF_CARD_X + MF_BORDER_W) ||
                   (lx >= MF_CARD_X + MF_CARD_W - MF_BORDER_W) ||
                   (ly < MF_CARD_Y + MF_BORDER_W) ||
                   (ly >= MF_CARD_Y + MF_CARD_H - MF_BORDER_W);
    wire sel_here  = menu_q && page_is_menu && (sel_q == unit_idx);
    wire border_hit = sel_here && in_card && in_ring;

    // ---------------- 管理模式横幅 ----------------
    wire in_band   = (y_cnt >= MF_BAND_Y0) && (y_cnt < MF_BAND_Y1);
    wire band_line = (y_cnt == MF_BAND_Y0) || (y_cnt == MF_BAND_Y1 - 1);

    wire [9:0] tx        = x_cnt - MF_BAND_TEXT_X;
    wire       in_text_x = (x_cnt >= MF_BAND_TEXT_X) && (tx < 9 * MF_BAND_PITCH);
    wire [3:0] band_idx  = tx[8:5];          // 0..8
    wire [4:0] band_col  = tx[4:0];          // 0..31
    wire       in_text_y = (y_cnt >= MF_BAND_TEXT_Y) &&
                           (y_cnt < MF_BAND_TEXT_Y + 7 * MF_BAND_SCALE);
    wire [4:0] band_dy   = y_cnt - MF_BAND_TEXT_Y;
    wire [2:0] band_row  = band_dy[4:2];     // 0..6

    reg [6:0] band_char;
    always @* begin
        if (page_is_menu) begin
            case (band_idx)
                4'd0: band_char = 7'h45;                            // E
                4'd1: band_char = 7'h44;                            // D
                4'd2: band_char = 7'h49;                            // I
                4'd3: band_char = 7'h54;                            // T
                4'd4: band_char = 7'h20;                            // space
                4'd5: band_char = 7'h50;                            // P
                4'd6: band_char = 7'h31 + {5'd0, page_q};           // 1/2
                4'd7: band_char = 7'h2D;                            // -
                4'd8: band_char = 7'h31 + {5'd0, sel_q};            // 1..4
                default: band_char = 7'h20;
            endcase
        end else begin
            case (band_idx)
                4'd0: band_char = 7'h50;                            // P
                4'd1: band_char = 7'h31 + {5'd0, page_q};           // 3/4
                4'd2: band_char = 7'h20;
                4'd3: band_char = 7'h50;                            // P
                4'd4: band_char = 7'h52;                            // R
                4'd5: band_char = 7'h4F;                            // O
                4'd6: band_char = 7'h4D;                            // M
                4'd7: band_char = 7'h4F;                            // O
                4'd8: band_char = 7'h20;
                default: band_char = 7'h20;
            endcase
        end
    end

    wire [4:0] band_glyph;
    menu_band_font u_menu_band_font (
        .ch    (band_char),
        .row   (band_row),
        .glyph (band_glyph)
    );

    wire [2:0] band_gcol = band_col[4:2];               // 0..7，前 5 列为字形
    wire [2:0] band_gbit = (band_gcol < 3'd5) ? (3'd4 - band_gcol) : 3'd0;
    wire band_char_bit = (band_gcol < 3'd5) && band_glyph[band_gbit];
    wire band_hit      = menu_q && in_band && in_text_x && in_text_y && band_char_bit;

    // ---------------- 最终像素选择 ----------------
    wire [23:0] badge_rgb = (badge_edge || glyph_bit) ? MF_COLOR_BADGE_EDGE
                                                      : MF_COLOR_BADGE;
    wire [23:0] band_rgb  = (band_line || band_hit) ? MF_COLOR_BAND_FG
                                                    : MF_COLOR_BAND_BG;

    wire [23:0] layer_rgb = badge_hit  ? badge_rgb :
                            border_hit ? MF_COLOR_BORDER :
                            (menu_q && in_band) ? band_rgb : rgb_in;

    assign rgb_out = (de && display_valid) ? layer_rgb : rgb_in;
    assign de_out  = de;
    assign hs_out  = hs;
    assign vs_out  = vs;

endmodule
