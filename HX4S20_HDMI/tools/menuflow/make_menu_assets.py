#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MenuFlow V1 素材与字模生成器（单一布局真源）。

生成物（全部可重复生成，属于工程源码的一部分）：
  1. HX4S20_HDMI/include/menu_layout.vh    —— RTL 与 TB 共用的布局常量
  2. HX4S20_HDMI/display/menu_cjk_rom.v    —— "售罄" 32x32 点阵 ROM（LUT 实现）
  3. HX4S20_HDMI/assets/menu/PIC1..4.BMP   —— 640x480/24bit/无压缩/正高度菜单图
  4. HX4S20_HDMI/assets/menu/preview_*.png —— 供人工核对字模与整页排版

字体来源：NotoSansSC-VF.ttf（SIL Open Font License 1.1）。
本仓库只保存由它栅格化得到的少量点阵数据与生成说明，不提交字体文件。

用法（在 HX4S20_HDMI/ 下）：
  python tools/menuflow/make_menu_assets.py            # 生成全部
  python tools/menuflow/make_menu_assets.py --preview  # 只生成预览对比图
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BASE = Path(__file__).resolve().parent.parent.parent  # HX4S20_HDMI/
FONT_PATH = Path(r"C:\Windows\Fonts\NotoSansSC-VF.ttf")
FONT_WEIGHT = 500

# ---------------------------------------------------------------- 布局真源
H_ACTIVE = 640
V_ACTIVE = 480
CELL_W = 320
CELL_H = 240

CARD_X = 20       # 卡片（选中框）在 cell 内的左上角
CARD_Y = 6
CARD_W = 280
CARD_H = 196

IMG_X = 28        # 商品图区
IMG_Y = 14
IMG_W = 264
IMG_H = 118

NAME_Y = 136      # 商品名基线区
PRICE_Y = 164     # 价格区

BADGE_X = 56      # 售罄牌（cell 内坐标）
BADGE_Y = 40
BADGE_W = 208
BADGE_H = 84

GLYPH_SIZE = 28   # 点阵边长（源像素）
GLYPH_SCALE = 2   # 屏幕放大倍数
GLYPH_PX = GLYPH_SIZE * GLYPH_SCALE
GLYPH1_X = 100
GLYPH2_X = 164
GLYPH_Y = 54

BORDER_W = 4      # 选中框线宽

# 波形区（与 display/audio_waveform_overlay.v 默认参数一致）
WAVE_X = 64
WAVE_Y = 340
WAVE_W = 512
WAVE_H = 92

BAND_Y0 = 206     # 管理模式横幅（两行卡片之间的空档）
BAND_Y1 = 242
BAND_TEXT_X = 176
BAND_TEXT_Y = 210
BAND_SCALE = 4
BAND_PITCH = 32   # 5x7 字模 4 倍 = 20 宽 + 12 间距（32 为 2 的幂，RTL 用移位取字符号）

COLOR_BADGE = (0xC8, 0x1E, 0x1E)
COLOR_BADGE_EDGE = (0xFF, 0xFF, 0xFF)
COLOR_BORDER = (0x00, 0xFF, 0x80)
COLOR_BAND_BG = (0x10, 0x18, 0x20)
COLOR_BAND_FG = (0x00, 0xFF, 0x80)

# ---------------------------------------------------------------- 字体与字模

def load_font(px: int, weight: int = FONT_WEIGHT) -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(str(FONT_PATH), px)
    try:
        font.set_variation_by_axes([weight])
    except Exception:
        pass
    return font


def rasterize(ch: str, size: int, weight: int = FONT_WEIGHT, threshold: int = 128) -> list[int]:
    """把单字栅格化成 size 行 × size 列的 0/1 点阵，返回每行整数（bit size-1 为最左）。

    先在大画布上渲染，按真实墨迹包围盒居中，避免 CJK 字体 getbbox 与实际墨迹不一致
    导致的裁边、下移和孤立残点。
    """
    font = load_font(size, weight)
    pad = size
    big = size * 3
    canvas = Image.new("L", (big, big), 0)
    ImageDraw.Draw(canvas).text((pad, pad), ch, fill=255, font=font)
    px = canvas.load()
    ink = [(x, y) for y in range(big) for x in range(big) if px[x, y] >= threshold]
    if not ink:
        return [0] * size
    x0 = min(p[0] for p in ink)
    x1 = max(p[0] for p in ink)
    y0 = min(p[1] for p in ink)
    y1 = max(p[1] for p in ink)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    if w > size or h > size:
        raise ValueError(f"字形 {ch} 在 {size}px 下墨迹 {w}x{h} 超出画框")
    small = Image.new("L", (size, size), 0)
    small.paste(canvas.crop((x0, y0, x1 + 1, y1 + 1)), ((size - w) // 2, (size - h) // 2))
    spx = small.load()
    rows = []
    for r in range(size):
        bits = 0
        for c in range(size):
            if spx[c, r] >= threshold:
                bits |= 1 << (size - 1 - c)
        rows.append(bits)
    return rows


def glyph_png(rows: list[int], size: int, scale: int, fg=(255, 255, 255), bg=(0, 0, 0)) -> Image.Image:
    img = Image.new("RGB", (size * scale, size * scale), bg)
    px = img.load()
    for r in range(size):
        for c in range(size):
            if rows[r] >> (size - 1 - c) & 1:
                for dy in range(scale):
                    for dx in range(scale):
                        px[c * scale + dx, r * scale + dy] = fg
    return img


def contact_sheet() -> Image.Image:
    """24/28/32 三种尺寸、两种阈值的对比图，供人工判断笔画完整性。"""
    tiles = []
    for size in (24, 28, 32):
        for th in (90, 130):
            a = rasterize("售", size, threshold=th)
            b = rasterize("罄", size, threshold=th)
            pair = Image.new("RGB", (size * 2 * 4 + 12, size * 4), (24, 30, 38))
            pair.paste(glyph_png(a, size, 4), (0, 0))
            pair.paste(glyph_png(b, size, 4), (size * 4 + 4, 0))
            tiles.append((f"{size}px th{th}", pair))
    pad = 14
    label_h = 18
    w = max(t[1].width for t in tiles) + pad * 2
    h = sum(t[1].height + label_h + pad for t in tiles) + pad
    sheet = Image.new("RGB", (w, h), (8, 10, 14))
    d = ImageDraw.Draw(sheet)
    y = pad
    for label, img in tiles:
        d.text((pad, y), label, fill=(200, 220, 240))
        y += label_h
        sheet.paste(img, (pad, y))
        y += img.height + pad
    return sheet


# ---------------------------------------------------------------- 布局头文件

def layout_header() -> str:
    return f"""// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。
// 布局常量由素材生成脚本与 RTL 共用，保证 BMP 商品位置与叠加框/售罄牌坐标一致。
`ifndef MENU_LAYOUT_VH
`define MENU_LAYOUT_VH

localparam integer MF_H_ACTIVE        = {H_ACTIVE};
localparam integer MF_V_ACTIVE        = {V_ACTIVE};
localparam integer MF_CELL_W          = {CELL_W};
localparam integer MF_CELL_H          = {CELL_H};

localparam integer MF_CARD_X          = {CARD_X};
localparam integer MF_CARD_Y          = {CARD_Y};
localparam integer MF_CARD_W          = {CARD_W};
localparam integer MF_CARD_H          = {CARD_H};

localparam integer MF_IMG_X           = {IMG_X};
localparam integer MF_IMG_Y           = {IMG_Y};
localparam integer MF_IMG_W           = {IMG_W};
localparam integer MF_IMG_H           = {IMG_H};

localparam integer MF_BADGE_X         = {BADGE_X};
localparam integer MF_BADGE_Y         = {BADGE_Y};
localparam integer MF_BADGE_W         = {BADGE_W};
localparam integer MF_BADGE_H         = {BADGE_H};

localparam integer MF_GLYPH_SIZE      = {GLYPH_SIZE};
localparam integer MF_GLYPH_SCALE     = {GLYPH_SCALE};
localparam integer MF_GLYPH_PX        = {GLYPH_PX};
localparam integer MF_GLYPH1_X        = {GLYPH1_X};
localparam integer MF_GLYPH2_X        = {GLYPH2_X};
localparam integer MF_GLYPH_Y         = {GLYPH_Y};
localparam integer MF_GLYPH_LAST = {GLYPH_SIZE - 1};

localparam integer MF_BORDER_W        = {BORDER_W};

localparam integer MF_WAVE_X          = {WAVE_X};
localparam integer MF_WAVE_Y          = {WAVE_Y};
localparam integer MF_WAVE_W          = {WAVE_W};
localparam integer MF_WAVE_H          = {WAVE_H};

localparam integer MF_BAND_Y0         = {BAND_Y0};
localparam integer MF_BAND_Y1         = {BAND_Y1};
localparam integer MF_BAND_TEXT_X     = {BAND_TEXT_X};
localparam integer MF_BAND_TEXT_Y     = {BAND_TEXT_Y};
localparam integer MF_BAND_SCALE      = {BAND_SCALE};
localparam integer MF_BAND_PITCH      = {BAND_PITCH};

localparam [23:0] MF_COLOR_BADGE = 24'h{COLOR_BADGE[0]:02X}{COLOR_BADGE[1]:02X}{COLOR_BADGE[2]:02X};
localparam [23:0] MF_COLOR_BADGE_EDGE = 24'h{COLOR_BADGE_EDGE[0]:02X}{COLOR_BADGE_EDGE[1]:02X}{COLOR_BADGE_EDGE[2]:02X};
localparam [23:0] MF_COLOR_BORDER = 24'h{COLOR_BORDER[0]:02X}{COLOR_BORDER[1]:02X}{COLOR_BORDER[2]:02X};
localparam [23:0] MF_COLOR_BAND_BG = 24'h{COLOR_BAND_BG[0]:02X}{COLOR_BAND_BG[1]:02X}{COLOR_BAND_BG[2]:02X};
localparam [23:0] MF_COLOR_BAND_FG = 24'h{COLOR_BAND_FG[0]:02X}{COLOR_BAND_FG[1]:02X}{COLOR_BAND_FG[2]:02X};

`endif
"""


# ---------------------------------------------------------------- 字模 ROM

def cjk_rom(rows_s: list[int], rows_q: list[int]) -> str:
    n = GLYPH_SIZE
    assert len(rows_s) == n and len(rows_q) == n
    digits = (n + 3) // 4
    lines = []
    lines.append("// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。")
    lines.append("// 字模来源：Noto Sans SC（SIL Open Font License 1.1），只保存 %dx%d 点阵数据。" % (n, n))
    lines.append("// 位序：每行最高位 = 最左像素；char0='售'，char1='罄'。")
    lines.append("// 实现：纯 LUT 常量 ROM（不推断 BRAM，不依赖存储器初值），输出寄存 1 拍。")
    lines.append("`timescale 1ns/1ps")
    lines.append("")
    lines.append("module menu_cjk_rom (")
    lines.append("    input  wire        clk,")
    lines.append("    input  wire [4:0]  row,       // 源点阵行 0..%d" % (n - 1))
    lines.append("    output reg  [%d:0] glyph_shou," % (n - 1))
    lines.append("    output reg  [%d:0] glyph_qing" % (n - 1))
    lines.append(");")
    lines.append("")
    lines.append("    reg [%d:0] shou_comb;" % (n - 1))
    lines.append("    reg [%d:0] qing_comb;" % (n - 1))
    lines.append("")
    lines.append("    always @* begin")
    lines.append("        case (row)")
    for i in range(n):
        lines.append("            5'd%2d: begin shou_comb = %d'h%0*X; qing_comb = %d'h%0*X; end"
                     % (i, n, digits, rows_s[i], n, digits, rows_q[i]))
    lines.append("            default: begin shou_comb = {%d{1'b0}}; qing_comb = {%d{1'b0}}; end" % (n, n))
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("    always @(posedge clk) begin")
    lines.append("        glyph_shou <= shou_comb;")
    lines.append("        glyph_qing <= qing_comb;")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    return "\n".join(lines)


def band_font_rom() -> str:
    """管理模式横幅用的 5x7 ASCII 子集字模，与预览图共用同一张表。"""
    lines = []
    lines.append("// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。")
    lines.append("// 5x7 ASCII 子集，bit4 为最左像素；仅用于管理模式横幅（EDIT Pn-s / Pn PROMO）。")
    lines.append("`timescale 1ns/1ps")
    lines.append("")
    lines.append("module menu_band_font (")
    lines.append("    input  wire [6:0] ch,")
    lines.append("    input  wire [2:0] row,")
    lines.append("    output reg  [4:0] glyph")
    lines.append(");")
    lines.append("")
    lines.append("    always @* begin")
    lines.append("        case (ch)")
    for ch, rows in ASCII_5x7.items():
        code = ord(ch)
        vals = " ".join("3'd%d: glyph=5'b%s;" % (i, format(v, "05b")) for i, v in enumerate(rows))
        lines.append("            7'h%02X: case (row) %s default: glyph=5'b00000; endcase  // %s"
                     % (code, vals, "SPACE" if ch == " " else ch))
    lines.append("            default: glyph = 5'b00000;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------- 菜单 BMP

PALETTES = [
    ((0x3A, 0x2A, 0x1E), (0xD9, 0xA0, 0x5B), (0xF2, 0xE3, 0xC9)),
    ((0x2A, 0x1E, 0x3A), (0x9B, 0x6B, 0xD9), (0xEC, 0xE0, 0xF7)),
    ((0x1E, 0x30, 0x2A), (0x4F, 0xB0, 0x86), (0xE0, 0xF5, 0xEC)),
    ((0x2E, 0x24, 0x18), (0xD4, 0x7A, 0x3A), (0xFA, 0xEC, 0xDC)),
]

MENU_PAGES = [
    [
        ("珍珠奶茶", "¥12", PALETTES[0]),
        ("芝士葡萄", "¥18", PALETTES[1]),
        ("杨枝甘露", "¥16", PALETTES[2]),
        ("生椰拿铁", "¥15", PALETTES[3]),
    ],
    [
        ("抹茶拿铁", "¥17", PALETTES[2]),
        ("黑糖波波", "¥14", PALETTES[0]),
        ("芒果冰沙", "¥18", PALETTES[3]),
        ("桂花乌龙", "¥13", PALETTES[1]),
    ],
]

PROMOS = [
    ("第二杯半价", "每日 14:00 - 17:00", "同款饮品第二杯半价，限堂食", (0x4A, 0x10, 0x18), (0xFF, 0xC1, 0x07)),
    ("新店开业", "全场 8 折", "开业首周，所有饮品八折优惠", (0x0E, 0x2A, 0x3A), (0x4F, 0xD1, 0xC5)),
]


def rounded(draw: ImageDraw.ImageDraw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def draw_cup(draw: ImageDraw.ImageDraw, box, body, light):
    """简单杯型插图：杯体 + 杯盖 + 吸管。"""
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    lid_h = max(6, h // 8)
    cup_top = y0 + lid_h + 4
    # 杯体（上宽下窄）
    inset = w // 10
    draw.polygon(
        [(x0 + inset, cup_top), (x1 - inset, cup_top), (x1 - inset * 2, y1 - 4), (x0 + inset * 2, y1 - 4)],
        fill=body,
    )
    # 杯盖
    rounded(draw, (x0 + inset // 2, y0 + 2, x1 - inset // 2, y0 + lid_h + 2), 4, fill=light)
    # 吸管
    draw.line([(x0 + w // 2 + w // 8, y0 + 2), (x0 + w // 2 + w // 4, cup_top + h // 5)], fill=light, width=max(3, w // 24))
    # 液面高光
    rounded(draw, (x0 + inset * 2 + 6, cup_top + 10, x1 - inset * 3 - 6, cup_top + 20), 5, fill=light)


def make_bmp(page_no: int) -> Image.Image:
    img = Image.new("RGB", (H_ACTIVE, V_ACTIVE), (0x12, 0x18, 0x1F))
    d = ImageDraw.Draw(img)

    # 顶部标题条（左侧 x<96 留给 OSD 状态条）
    d.rectangle((0, 0, H_ACTIVE, 32), fill=(0x0B, 0x10, 0x16))
    d.rectangle((0, 32, H_ACTIVE, 34), fill=(0x2A, 0x3B, 0x4A))
    d.text((120, 15), "MenuFlow 茶饮菜单", font=load_font(22), fill=(0xEC, 0xF3, 0xFA), anchor="lm")
    d.text((H_ACTIVE - 16, 15), f"PAGE {page_no}", font=load_font(20), fill=(0x8F, 0xA8, 0xBF), anchor="rm")

    for cell in range(4):
        cx = (cell % 2) * CELL_W
        cy = (cell // 2) * CELL_H
        # 卡片底
        rounded(d, (cx + CARD_X, cy + CARD_Y, cx + CARD_X + CARD_W - 1, cy + CARD_Y + CARD_H - 1),
                12, fill=(0x1C, 0x24, 0x2E), outline=(0x2E, 0x3B, 0x4A), width=2)
        name, price, pal = MENU_PAGES[page_no - 1][cell]
        base, body, light = pal
        # 商品图区
        rounded(d, (cx + IMG_X, cy + IMG_Y, cx + IMG_X + IMG_W - 1, cy + IMG_Y + IMG_H - 1), 10, fill=base)
        draw_cup(d, (cx + IMG_X + IMG_W // 2 - 42, cy + IMG_Y + 12, cx + IMG_X + IMG_W // 2 + 42, cy + IMG_Y + IMG_H - 8), body, light)
        d.text((cx + IMG_X + 10, cy + IMG_Y + 8), f"{cell + 1:02d}", font=load_font(16), fill=light)
        # 商品名与价格（售罄牌不遮挡这两行：牌底 y = cy+40+84 = cy+124 < cy+136）
        d.text((cx + IMG_X, cy + NAME_Y), name, font=load_font(26), fill=(0xF2, 0xF6, 0xFA))
        d.text((cx + IMG_X, cy + PRICE_Y), price, font=load_font(26), fill=(0xFF, 0xB3, 0x00))
    return img


def make_promo(page_no: int) -> Image.Image:
    title, sub, note, bg, accent = PROMOS[page_no - 3]
    img = Image.new("RGB", (H_ACTIVE, V_ACTIVE), bg)
    d = ImageDraw.Draw(img)
    for y in range(V_ACTIVE):
        k = 1.0 - (y / V_ACTIVE) * 0.45
        d.line((0, y, H_ACTIVE, y), fill=tuple(int(c * k) for c in bg))
    d.rectangle((0, 0, H_ACTIVE, 32), fill=(0x0B, 0x10, 0x16))
    d.rectangle((0, 32, H_ACTIVE, 34), fill=accent)
    d.text((120, 15), "MenuFlow 茶饮菜单", font=load_font(22), fill=(0xEC, 0xF3, 0xFA), anchor="lm")
    d.text((H_ACTIVE - 16, 15), f"PAGE {page_no}", font=load_font(20), fill=(0x8F, 0xA8, 0xBF), anchor="rm")
    # 波形区占据 y=340..432（见 audio_waveform_overlay），所以促销文字整体上移，
    # 底部 footer 取消，避免与波形/OSD 字幕（y=448）重叠。
    d.text((H_ACTIVE // 2, 120), title, font=load_font(64), fill=accent, anchor="mm")
    d.text((H_ACTIVE // 2, 196), sub, font=load_font(40), fill=(0xFF, 0xFF, 0xFF), anchor="mm")
    d.text((H_ACTIVE // 2, 252), note, font=load_font(24), fill=(0xD8, 0xE4, 0xEE), anchor="mm")
    d.line((160, 286, H_ACTIVE - 160, 286), fill=accent, width=3)
    return img


def save_bmp(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, format="BMP")
    data = path.read_bytes()
    assert data[:2] == b"BM", "BMP 魔数错误"
    off = int.from_bytes(data[10:14], "little")
    size = int.from_bytes(data[2:6], "little")
    width = int.from_bytes(data[18:22], "little", signed=True)
    height = int.from_bytes(data[22:26], "little", signed=True)
    bpp = int.from_bytes(data[28:30], "little")
    comp = int.from_bytes(data[30:34], "little")
    assert (off, size, width, height, bpp, comp) == (54, 640 * 480 * 3 + 54, 640, 480, 24, 0), (
        off, size, width, height, bpp, comp)


def overlay_preview(page_img: Image.Image, page_no: int, mask: int, menu: bool, sel: int) -> Image.Image:
    """按 RTL 规则画出叠加层，用于人工核对坐标（不是仿真证据）。"""
    img = page_img.copy()
    d = ImageDraw.Draw(img)
    if menu:
        d.rectangle((0, BAND_Y0, H_ACTIVE - 1, BAND_Y1 - 1), fill=COLOR_BAND_BG)
        d.line((0, BAND_Y0, H_ACTIVE - 1, BAND_Y0), fill=COLOR_BAND_FG)
        d.line((0, BAND_Y1 - 1, H_ACTIVE - 1, BAND_Y1 - 1), fill=COLOR_BAND_FG)
        text = f"EDIT P{page_no}-{sel + 1}"
        for i, ch in enumerate(text):
            draw_ascii(d, ch, BAND_TEXT_X + i * BAND_PITCH, BAND_TEXT_Y, BAND_SCALE, COLOR_BAND_FG)
    if page_no <= 2:
        for cell in range(4):
            cx = (cell % 2) * CELL_W
            cy = (cell // 2) * CELL_H
            if menu and cell == sel:
                bx0, by0 = cx + CARD_X, cy + CARD_Y
                bx1, by1 = bx0 + CARD_W - 1, by0 + CARD_H - 1
                d.rectangle((bx0, by0, bx1, by1), outline=COLOR_BORDER, width=BORDER_W)
            if (mask >> ((page_no - 1) * 4 + cell)) & 1:
                x0, y0 = cx + BADGE_X, cy + BADGE_Y
                x1, y1 = x0 + BADGE_W - 1, y0 + BADGE_H - 1
                d.rectangle((x0, y0, x1, y1), fill=COLOR_BADGE, outline=COLOR_BADGE_EDGE, width=3)
                a = glyph_png(rasterize("售", GLYPH_SIZE), GLYPH_SIZE, GLYPH_SCALE)
                b = glyph_png(rasterize("罄", GLYPH_SIZE), GLYPH_SIZE, GLYPH_SCALE)
                img.paste(a, (cx + GLYPH1_X, cy + GLYPH_Y))
                img.paste(b, (cx + GLYPH2_X, cy + GLYPH_Y))
    return img


ASCII_5x7 = {
    " ": [0, 0, 0, 0, 0, 0, 0],
    "-": [0, 0, 0, 0x1F, 0, 0, 0],
    "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "2": [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
    "3": [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
    "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "M": [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
}


def draw_ascii(d: ImageDraw.ImageDraw, ch: str, x: int, y: int, scale: int, color) -> None:
    rows = ASCII_5x7.get(ch, ASCII_5x7[" "])
    for r, bits in enumerate(rows):
        for c in range(5):
            if bits >> (4 - c) & 1:
                d.rectangle((x + c * scale, y + r * scale, x + c * scale + scale - 1, y + r * scale + scale - 1),
                            fill=color)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true", help="只生成字模尺寸对比图")
    args = ap.parse_args()

    assets = BASE / "assets" / "menu"
    assets.mkdir(parents=True, exist_ok=True)

    if args.preview:
        sheet = contact_sheet()
        sheet.save(assets / "preview_glyph_sizes.png")
        print(f"glyph size sheet -> {assets / 'preview_glyph_sizes.png'}")
        return 0

    # 1) 字模 ROM + 布局头
    rows_s = rasterize("售", GLYPH_SIZE)
    rows_q = rasterize("罄", GLYPH_SIZE)
    (BASE / "display" / "menu_cjk_rom.v").write_text(cjk_rom(rows_s, rows_q), encoding="utf-8")
    (BASE / "display" / "menu_band_font.v").write_text(band_font_rom(), encoding="utf-8")
    (BASE / "include" / "menu_layout.vh").write_text(layout_header(), encoding="utf-8")
    print("generated display/menu_cjk_rom.v, display/menu_band_font.v, include/menu_layout.vh")

    # 2) 页面 BMP
    for page in range(1, 5):
        img = make_bmp(page) if page <= 2 else make_promo(page)
        save_bmp(img, assets / f"PIC{page}.BMP")
        print(f"PIC{page}.BMP {640}x{480} 24bpp")

    # 3) 预览：整页 + 叠加层（P1 商品 1 售罄 + 管理模式选中商品 2）
    p1 = make_bmp(1)
    p1.save(assets / "preview_page1.png")
    overlay_preview(p1, 1, 0b0001, True, 1).save(assets / "preview_page1_soldout_edit.png")
    make_bmp(2).save(assets / "preview_page2.png")
    make_promo(3).save(assets / "preview_page3.png")
    make_promo(4).save(assets / "preview_page4.png")
    sheet = contact_sheet()
    sheet.save(assets / "preview_glyph_sizes.png")

    # 3b) 波形区布局与 RTL 默认参数一致性校验（menu_layout.vh 有 include 保护，
    #     多个模块不能重复引入 localparam，因此 RTL 用字面量并在生成时校验）
    rtl = (BASE / "top_tf_hdmi_audio.v").read_text(encoding="utf-8")
    for name, val in (("WAVE_X", WAVE_X), ("WAVE_Y", WAVE_Y),
                      ("WAVE_W", WAVE_W), ("WAVE_H", WAVE_H)):
        expect = f".{name}".ljust(14) + f"({val}),"
        if expect not in rtl:
            raise SystemExit(f"RTL 波形参数与布局真源不一致：期望 {expect}")
    print("waveform layout matches RTL defaults")

    # 4) 点阵自检：非空、包围盒不触边、两字不同
    for name, rows in (("售", rows_s), ("罄", rows_q)):
        ink = sum(bin(r).count("1") for r in rows)
        assert ink > 40, f"{name} 点阵墨量过低: {ink}"
        assert rows[0] == 0 and rows[-1] == 0, f"{name} 首末行应留白"
        assert all((r & ((1 << GLYPH_SIZE) - 1)) == r for r in rows)
        print(f"glyph {name}: {ink} px")
    assert rows_s != rows_q
    return 0


if __name__ == "__main__":
    sys.exit(main())
