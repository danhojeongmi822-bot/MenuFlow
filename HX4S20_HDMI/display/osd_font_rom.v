`timescale 1ns/1ps

// 5x7 ASCII 点阵字库（仅大写字母、数字和少量标点）。
// 每个字符 7 行，每行 5 位；bit4 为最左像素，bit0 为最右像素。
// 输出的是“字符行”，2 倍缩放、字符间距和坐标都由调用方处理。
module osd_font_rom (
    input  wire [6:0] ch,      // ASCII
    input  wire [2:0] row,     // 0..6；其它行返回空白
    output reg  [4:0] glyph
);

    always @* begin
        case (ch)
            // 数字 0-9
            7'h30: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10011; 3'd3: glyph=5'b10101; 3'd4: glyph=5'b11001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h31: case (row) 3'd0: glyph=5'b00100; 3'd1: glyph=5'b01100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h32: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b00001; 3'd3: glyph=5'b00010; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b01000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase
            7'h33: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00010; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00010; 3'd4: glyph=5'b00001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h34: case (row) 3'd0: glyph=5'b00010; 3'd1: glyph=5'b00110; 3'd2: glyph=5'b01010; 3'd3: glyph=5'b10010; 3'd4: glyph=5'b11111; 3'd5: glyph=5'b00010; 3'd6: glyph=5'b00010; default: glyph=5'b00000; endcase
            7'h35: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b11110; 3'd3: glyph=5'b00001; 3'd4: glyph=5'b00001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h36: case (row) 3'd0: glyph=5'b00110; 3'd1: glyph=5'b01000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h37: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00001; 3'd2: glyph=5'b00010; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b01000; 3'd5: glyph=5'b01000; 3'd6: glyph=5'b01000; default: glyph=5'b00000; endcase
            7'h38: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b01110; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h39: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b01111; 3'd4: glyph=5'b00001; 3'd5: glyph=5'b00010; 3'd6: glyph=5'b01100; default: glyph=5'b00000; endcase
            // 大写字母 A-Z
            7'h41: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11111; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h42: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b11110; default: glyph=5'b00000; endcase
            7'h43: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b10000; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h44: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b11110; default: glyph=5'b00000; endcase
            7'h45: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase
            7'h46: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b10000; default: glyph=5'b00000; endcase
            7'h47: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b10111; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h48: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11111; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h49: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b00100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h4a: case (row) 3'd0: glyph=5'b00111; 3'd1: glyph=5'b00010; 3'd2: glyph=5'b00010; 3'd3: glyph=5'b00010; 3'd4: glyph=5'b00010; 3'd5: glyph=5'b10010; 3'd6: glyph=5'b01100; default: glyph=5'b00000; endcase
            7'h4b: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10010; 3'd2: glyph=5'b10100; 3'd3: glyph=5'b11000; 3'd4: glyph=5'b10100; 3'd5: glyph=5'b10010; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h4c: case (row) 3'd0: glyph=5'b10000; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b10000; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase
            7'h4d: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b11011; 3'd2: glyph=5'b10101; 3'd3: glyph=5'b10101; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h4e: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b11001; 3'd2: glyph=5'b10101; 3'd3: glyph=5'b10011; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h4f: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h50: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b10000; default: glyph=5'b00000; endcase
            7'h51: case (row) 3'd0: glyph=5'b01110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10101; 3'd5: glyph=5'b10010; 3'd6: glyph=5'b01101; default: glyph=5'b00000; endcase
            7'h52: case (row) 3'd0: glyph=5'b11110; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b11110; 3'd4: glyph=5'b10100; 3'd5: glyph=5'b10010; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h53: case (row) 3'd0: glyph=5'b01111; 3'd1: glyph=5'b10000; 3'd2: glyph=5'b10000; 3'd3: glyph=5'b01110; 3'd4: glyph=5'b00001; 3'd5: glyph=5'b00001; 3'd6: glyph=5'b11110; default: glyph=5'b00000; endcase
            7'h54: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00100; 3'd2: glyph=5'b00100; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b00100; default: glyph=5'b00000; endcase
            7'h55: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b01110; default: glyph=5'b00000; endcase
            7'h56: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10001; 3'd4: glyph=5'b10001; 3'd5: glyph=5'b01010; 3'd6: glyph=5'b00100; default: glyph=5'b00000; endcase
            7'h57: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b10001; 3'd3: glyph=5'b10101; 3'd4: glyph=5'b10101; 3'd5: glyph=5'b11011; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h58: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b01010; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b01010; 3'd5: glyph=5'b10001; 3'd6: glyph=5'b10001; default: glyph=5'b00000; endcase
            7'h59: case (row) 3'd0: glyph=5'b10001; 3'd1: glyph=5'b10001; 3'd2: glyph=5'b01010; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b00100; 3'd5: glyph=5'b00100; 3'd6: glyph=5'b00100; default: glyph=5'b00000; endcase
            7'h5a: case (row) 3'd0: glyph=5'b11111; 3'd1: glyph=5'b00001; 3'd2: glyph=5'b00010; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b01000; 3'd5: glyph=5'b10000; 3'd6: glyph=5'b11111; default: glyph=5'b00000; endcase
            // 标点
            7'h2d: case (row) 3'd0: glyph=5'b00000; 3'd1: glyph=5'b00000; 3'd2: glyph=5'b00000; 3'd3: glyph=5'b01110; 3'd4: glyph=5'b00000; 3'd5: glyph=5'b00000; 3'd6: glyph=5'b00000; default: glyph=5'b00000; endcase
            7'h2e: case (row) 3'd0: glyph=5'b00000; 3'd1: glyph=5'b00000; 3'd2: glyph=5'b00000; 3'd3: glyph=5'b00000; 3'd4: glyph=5'b00000; 3'd5: glyph=5'b01100; 3'd6: glyph=5'b01100; default: glyph=5'b00000; endcase
            7'h3a: case (row) 3'd0: glyph=5'b00000; 3'd1: glyph=5'b01100; 3'd2: glyph=5'b01100; 3'd3: glyph=5'b00000; 3'd4: glyph=5'b01100; 3'd5: glyph=5'b01100; 3'd6: glyph=5'b00000; default: glyph=5'b00000; endcase
            7'h2f: case (row) 3'd0: glyph=5'b00001; 3'd1: glyph=5'b00010; 3'd2: glyph=5'b00010; 3'd3: glyph=5'b00100; 3'd4: glyph=5'b01000; 3'd5: glyph=5'b01000; 3'd6: glyph=5'b10000; default: glyph=5'b00000; endcase
            // 空格及其它字符
            default: glyph = 5'b00000;
        endcase
    end

endmodule
