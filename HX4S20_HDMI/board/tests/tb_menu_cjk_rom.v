`timescale 1ns/1ps

// 「售罄」点阵 ROM 的回归检查（黄金向量）。
//
// 目的：锁定行数、行序、位序与墨量，防止重新生成字模时出现镜像、上下翻转、
// 位序反转或整行丢失。黄金值由 tools/menuflow/make_menu_assets.py 的 28x28
// 输出统计得到，人工核对过 preview_glyph_sizes.png；字形本身是否美观由 H2 实板确认。
module tb_menu_cjk_rom;

    reg clk = 1'b0;
    reg [4:0] row = 5'd31;   // 初始为越界值，保证第一次写入 0 也是变化事件
    wire [27:0] shou, qing;

    integer errors = 0;
    integer ink_s = 0, ink_q = 0;
    reg [27:0] sum_s = 0, sum_q = 0;
    reg [27:0] xor_s = 0, xor_q = 0;
    integer first_s = 99, last_s = -1, first_q = 99, last_q = -1;
    integer cmin_s = 99, cmax_s = -1, cmin_q = 99, cmax_q = -1;
    integer i, c;

    menu_cjk_rom dut (
        .clk (clk), .row (row),
        .glyph_shou (shou), .glyph_qing (qing)
    );

    always #20 clk = ~clk;

    initial begin
        // 逐行读取并统计
        for (i = 0; i < 28; i = i + 1) begin
            @(negedge clk); row = i[4:0];
            @(posedge clk); #1;
            ink_s = ink_s + popcount(shou);
            ink_q = ink_q + popcount(qing);
            sum_s = sum_s + shou;
            sum_q = sum_q + qing;
            xor_s = xor_s ^ shou;
            xor_q = xor_q ^ qing;
            if (shou != 0) begin
                if (i < first_s) first_s = i;
                if (i > last_s)  last_s = i;
            end
            if (qing != 0) begin
                if (i < first_q) first_q = i;
                if (i > last_q)  last_q = i;
            end
            for (c = 0; c < 28; c = c + 1) begin
                if (shou[27 - c]) begin
                    if (c < cmin_s) cmin_s = c;
                    if (c > cmax_s) cmax_s = c;
                end
                if (qing[27 - c]) begin
                    if (c < cmin_q) cmin_q = c;
                    if (c > cmax_q) cmax_q = c;
                end
            end
        end

        if (ink_s !== 312) begin
            $display("FAIL cjk_rom: 售 ink %0d expected 312", ink_s); errors = errors + 1;
        end
        if (ink_q !== 358) begin
            $display("FAIL cjk_rom: 罄 ink %0d expected 358", ink_q); errors = errors + 1;
        end
        if (sum_s !== 28'h15cf878 || xor_s !== 28'h14c2008) begin
            $display("FAIL cjk_rom: 售 checksum sum=%07x xor=%07x expected 15cf878/14c2008",
                     sum_s, xor_s); errors = errors + 1;
        end
        if (sum_q !== 28'h14a9a3c || xor_q !== 28'h6f82420) begin
            $display("FAIL cjk_rom: 罄 checksum sum=%07x xor=%07x expected 14a9a3c/6f82420",
                     sum_q, xor_q); errors = errors + 1;
        end
        if (first_s !== 1 || last_s !== 26 || first_q !== 1 || last_q !== 26) begin
            $display("FAIL cjk_rom: 行范围 s=%0d..%0d q=%0d..%0d expected 1..26",
                     first_s, last_s, first_q, last_q); errors = errors + 1;
        end
        if (cmin_s !== 2 || cmax_s !== 25 || cmin_q !== 1 || cmax_q !== 26) begin
            $display("FAIL cjk_rom: 列范围 s=%0d..%0d q=%0d..%0d expected 2..25/1..26",
                     cmin_s, cmax_s, cmin_q, cmax_q); errors = errors + 1;
        end
        if (ink_s === ink_q) begin
            $display("FAIL cjk_rom: two glyphs have identical ink count"); errors = errors + 1;
        end

        // 行地址越界必须输出空白（生成代码的 default 分支）
        @(negedge clk); row = 5'd31;
        @(posedge clk); #1;
        if (shou !== 28'd0 || qing !== 28'd0) begin
            $display("FAIL cjk_rom: out-of-range row not blank"); errors = errors + 1;
        end

        // 首尾行留白（字形不贴边，2 倍放大后不会溢出牌面）
        @(negedge clk); row = 5'd0;
        @(posedge clk); #1;
        if (shou !== 0 || qing !== 0) begin
            $display("FAIL cjk_rom: row 0 not blank"); errors = errors + 1;
        end
        @(negedge clk); row = 5'd27;
        @(posedge clk); #1;
        if (shou !== 0 || qing !== 0) begin
            $display("FAIL cjk_rom: last row not blank"); errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS menu_cjk_rom: 28 rows, bit order, ink 312/358, blank borders");
        else
            $display("FAIL menu_cjk_rom: %0d assertion(s)", errors);
        $finish;
    end

    function integer popcount(input [27:0] v);
        integer k, n;
        begin
            n = 0;
            for (k = 0; k < 28; k = k + 1) n = n + v[k];
            popcount = n;
        end
    endfunction

    initial begin
        #1000000;
        $fatal(1, "cjk_rom timeout");
    end

endmodule
