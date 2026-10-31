// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。
// 布局常量由素材生成脚本与 RTL 共用，保证 BMP 商品位置与叠加框/售罄牌坐标一致。
`ifndef MENU_LAYOUT_VH
`define MENU_LAYOUT_VH

localparam integer MF_H_ACTIVE        = 640;
localparam integer MF_V_ACTIVE        = 480;
localparam integer MF_CELL_W          = 320;
localparam integer MF_CELL_H          = 240;

localparam integer MF_CARD_X          = 20;
localparam integer MF_CARD_Y          = 6;
localparam integer MF_CARD_W          = 280;
localparam integer MF_CARD_H          = 196;

localparam integer MF_IMG_X           = 28;
localparam integer MF_IMG_Y           = 14;
localparam integer MF_IMG_W           = 264;
localparam integer MF_IMG_H           = 118;

localparam integer MF_BADGE_X         = 56;
localparam integer MF_BADGE_Y         = 40;
localparam integer MF_BADGE_W         = 208;
localparam integer MF_BADGE_H         = 84;

localparam integer MF_GLYPH_SIZE      = 28;
localparam integer MF_GLYPH_SCALE     = 2;
localparam integer MF_GLYPH_PX        = 56;
localparam integer MF_GLYPH1_X        = 100;
localparam integer MF_GLYPH2_X        = 164;
localparam integer MF_GLYPH_Y         = 54;
localparam integer MF_GLYPH_LAST = 27;

localparam integer MF_BORDER_W        = 4;

localparam integer MF_WAVE_X          = 64;
localparam integer MF_WAVE_Y          = 340;
localparam integer MF_WAVE_W          = 512;
localparam integer MF_WAVE_H          = 92;

localparam integer MF_BAND_Y0         = 206;
localparam integer MF_BAND_Y1         = 242;
localparam integer MF_BAND_TEXT_X     = 176;
localparam integer MF_BAND_TEXT_Y     = 210;
localparam integer MF_BAND_SCALE      = 4;
localparam integer MF_BAND_PITCH      = 32;

localparam [23:0] MF_COLOR_BADGE = 24'hC81E1E;
localparam [23:0] MF_COLOR_BADGE_EDGE = 24'hFFFFFF;
localparam [23:0] MF_COLOR_BORDER = 24'h00FF80;
localparam [23:0] MF_COLOR_BAND_BG = 24'h101820;
localparam [23:0] MF_COLOR_BAND_FG = 24'h00FF80;

`endif
