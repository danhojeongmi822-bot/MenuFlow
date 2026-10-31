// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。
// 字模来源：Noto Sans SC（SIL Open Font License 1.1），只保存 28x28 点阵数据。
// 位序：每行最高位 = 最左像素；char0='售'，char1='罄'。
// 实现：纯 LUT 常量 ROM（不推断 BRAM，不依赖存储器初值），输出寄存 1 拍。
`timescale 1ns/1ps

module menu_cjk_rom (
    input  wire        clk,
    input  wire [4:0]  row,       // 源点阵行 0..27
    output reg  [27:0] glyph_shou,
    output reg  [27:0] glyph_qing
);

    reg [27:0] shou_comb;
    reg [27:0] qing_comb;

    always @* begin
        case (row)
            5'd 0: begin shou_comb = 28'h0000000; qing_comb = 28'h0000000; end
            5'd 1: begin shou_comb = 28'h0081800; qing_comb = 28'h0180000; end
            5'd 2: begin shou_comb = 28'h01C3800; qing_comb = 28'h0180FF0; end
            5'd 3: begin shou_comb = 28'h0181C00; qing_comb = 28'h3FFCFF0; end
            5'd 4: begin shou_comb = 28'h03FFFFC; qing_comb = 28'h3FFCC70; end
            5'd 5: begin shou_comb = 28'h07FFFFC; qing_comb = 28'h0180C30; end
            5'd 6: begin shou_comb = 28'h0F01C00; qing_comb = 28'h1FF983C; end
            5'd 7: begin shou_comb = 28'h0F01C00; qing_comb = 28'h1FFB03C; end
            5'd 8: begin shou_comb = 28'h1FFFFF0; qing_comb = 28'h1FFBFF8; end
            5'd 9: begin shou_comb = 28'h3FFFFF0; qing_comb = 28'h1FFBFF8; end
            5'd10: begin shou_comb = 28'h3301C00; qing_comb = 28'h1998C30; end
            5'd11: begin shou_comb = 28'h03FFFF0; qing_comb = 28'h1998E60; end
            5'd12: begin shou_comb = 28'h03FFFF8; qing_comb = 28'h1FF87C0; end
            5'd13: begin shou_comb = 28'h0301C00; qing_comb = 28'h1FF87E0; end
            5'd14: begin shou_comb = 28'h0301C00; qing_comb = 28'h3183E7C; end
            5'd15: begin shou_comb = 28'h03FFFFC; qing_comb = 28'h718301C; end
            5'd16: begin shou_comb = 28'h03FFFFC; qing_comb = 28'h23FFFF0; end
            5'd17: begin shou_comb = 28'h0300000; qing_comb = 28'h07FFFF0; end
            5'd18: begin shou_comb = 28'h0000000; qing_comb = 28'h0E06000; end
            5'd19: begin shou_comb = 28'h07FFFF8; qing_comb = 28'h0406000; end
            5'd20: begin shou_comb = 28'h07FFFF8; qing_comb = 28'h3FFFFFE; end
            5'd21: begin shou_comb = 28'h0700038; qing_comb = 28'h3FFFFFE; end
            5'd22: begin shou_comb = 28'h0700038; qing_comb = 28'h0E06030; end
            5'd23: begin shou_comb = 28'h0700038; qing_comb = 28'h0E06030; end
            5'd24: begin shou_comb = 28'h07FFFF8; qing_comb = 28'h0FFFFF0; end
            5'd25: begin shou_comb = 28'h07FFFF8; qing_comb = 28'h0FFFFF0; end
            5'd26: begin shou_comb = 28'h0700038; qing_comb = 28'h0000070; end
            5'd27: begin shou_comb = 28'h0000000; qing_comb = 28'h0000000; end
            default: begin shou_comb = {28{1'b0}}; qing_comb = {28{1'b0}}; end
        endcase
    end

    always @(posedge clk) begin
        glyph_shou <= shou_comb;
        glyph_qing <= qing_comb;
    end

endmodule
