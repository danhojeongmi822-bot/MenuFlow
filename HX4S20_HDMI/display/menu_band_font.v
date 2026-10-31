// 本文件由 tools/menuflow/make_menu_assets.py 生成，请勿手工修改。
// 5x7 ASCII 子集，bit4 为最左像素；仅用于管理模式横幅（EDIT Pn-s / Pn PROMO）。
`timescale 1ns/1ps

module menu_band_font (
    input  wire [6:0] ch,
    input  wire [2:0] row,
    output reg  [4:0] glyph
);

    always @* begin
        case (ch)
            7'h20: case (row) 3'd0: glyph=5'b00000; 3'd1: glyph=5'b00000; 3'd2: glyph=5'b00000; 3'd3: glyph=5'b00000; 3'd4: glyph=5'b00000; 3'd5: glyph=5'b00000; 3'd6: glyph=5'b00000; default: glyph=5'b00000; endcase  // SPACE
            7'h2D: case (row) 3'd0: glyph=5'b00000; 3'd1: glyph=5'b00000; 3'd2: glyph=5'b00000; 3'd3: glyph=5'b11111; 3'd4: glyph=5'b00000; 3'd5: glyph=5'b00000; 3'd6: glyph=5'b00000; default: glyph=5'b00000; endcase  // -
            7'h30: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10011; 3'd3: glyph=5'b10101; 3'd4: glyph=5'b11001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase  // 0
            7'h31: case (row) 3'd0: glyph=5'b00100; 3'd1: glyph=5'b01100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase  // 1
            7'h32: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b00001; 3'd3: glyph=5'b00010; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b01000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase  // 2
            7'h33: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00010; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00010; 3'd4: glyph=5'b00001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase  // 3
            7'h34: case (row) 3'd0: glyph=5'b00010; 3'd1: glyph=5'b00110; 3'd2: glyph=5'b01010; 3'd3: glyph=5'b10010; 3'd4: glyph=5'b11111; 3'd5: glyph=5'b00010; 3'd6: glyph=5'b00010; default: glyph=5'b00000; endcase  // 4
            7'h45: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase  // E
            7'h44: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b11110; default: glyph=5'b00000; endcase  // D
            7'h49: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b00100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase  // I
            7'h54: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b00100; default: glyph=5'b00000; endcase  // T
            7'h50: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b10000; default: glyph=5'b00000; endcase  // P
            7'h52: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10100; 3'd5: glyph=5'b10010; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase  // R
            7'h4F: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase  // O
            7'h4D: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b11011; 3'd2: glyph=5'b10101; 3'd3: glyph=5'b10101; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase  // M
            default: glyph = 5'b00000;
        endcase
    end

endmodule
