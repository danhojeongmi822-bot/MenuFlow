`timescale 1ns/1ps

// 动态售罄图层像素级 Scoreboard。
//
// 参考模型在 TB 内独立实现（坐标、矩形、颜色、横幅 5x7 字模），不复用 RTL 表达式。
// 对每个有效像素比较 rgb_out：
//   * 售罄牌/选中框/横幅之外：必须与 rgb_in 逐位相同（透传）
//   * 售罄牌边框/牌面：精确颜色
//   * 售罄牌字形区：只允许红/白，并统计白色像素总数 = 点阵墨量 x 4（2 倍放大）
//   * 横幅：按 5x7 字模逐位比较
// 另验证：帧内改配置不生效、display_valid=0 立即透传、DE/HS/VS 同拍。
module tb_soldout_overlay;

    // ---- 布局常量（与 include/menu_layout.vh 独立维护，改动必须同步） ----
    localparam integer CELL_W = 320, CELL_H = 240;
    localparam integer CARD_X = 20, CARD_Y = 6, CARD_W = 280, CARD_H = 196;
    localparam integer BADGE_X = 56, BADGE_Y = 40, BADGE_W = 208, BADGE_H = 84;
    localparam integer G1X = 100, G2X = 164, GY = 54, GPX = 56, GSZ = 28;
    localparam integer BORDER_W = 4;
    localparam integer BAND_Y0 = 206, BAND_Y1 = 242;
    localparam integer TEXT_X = 176, TEXT_Y = 210, PITCH = 32;
    localparam integer INK_SHOU = 312, INK_QING = 358;   // 生成脚本实测墨量

    localparam [23:0] C_BADGE = 24'hC81E1E;
    localparam [23:0] C_EDGE  = 24'hFFFFFF;
    localparam [23:0] C_BORD  = 24'h00FF80;
    localparam [23:0] C_BAND  = 24'h101820;
    localparam [23:0] C_FG    = 24'h00FF80;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg de = 1'b0, hs = 1'b0, vs = 1'b1, frame_start = 1'b0, display_valid = 1'b1;
    reg [23:0] rgb_in = 24'd0;

    reg [1:0] active_index = 2'd0;
    reg       menu_active = 1'b0;
    reg [1:0] sel_idx = 2'd0;
    reg [7:0] soldout_mask = 8'd0;

    wire [23:0] rgb_out;
    wire de_out, hs_out, vs_out;

    // TB 侧的帧边界锁存副本
    reg [1:0] page_lat = 2'd0, sel_lat = 2'd0;
    reg [7:0] mask_lat = 8'd0;
    reg       menu_lat = 1'b0;

    integer errors = 0;
    integer checked = 0;
    integer glyph_white = 0;
    integer glyph_px = 0;
    integer badges = 0;

    soldout_overlay dut (
        .clk (clk), .rst (rst), .de (de), .hs (hs), .vs (vs),
        .frame_start (frame_start), .display_valid (display_valid),
        .rgb_in (rgb_in), .active_index (active_index),
        .menu_active (menu_active), .sel_idx (sel_idx), .soldout_mask (soldout_mask),
        .rgb_out (rgb_out), .de_out (de_out), .hs_out (hs_out), .vs_out (vs_out)
    );

    always #20 clk = ~clk;

    // ---------------- 5x7 字模（TB 独立副本） ----------------
    function [4:0] font5x7(input [6:0] ch, input integer row);
        begin
            case (ch)
                7'h20: font5x7 = 5'b00000;
                7'h2D: font5x7 = (row == 3) ? 5'b11111 : 5'b00000;
                7'h30: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10011; 3: font5x7=5'b10101; 4: font5x7=5'b11001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=0; endcase
                7'h31: case (row) 0: font5x7=5'b00100; 1: font5x7=5'b01100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b01110; default: font5x7=0; endcase
                7'h32: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b00001; 3: font5x7=5'b00010; 4: font5x7=5'b00100; 5: font5x7=5'b01000; 6: font5x7=5'b11111; default: font5x7=0; endcase
                7'h33: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b00010; 2: font5x7=5'b00100; 3: font5x7=5'b00010; 4: font5x7=5'b00001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=0; endcase
                7'h34: case (row) 0: font5x7=5'b00010; 1: font5x7=5'b00110; 2: font5x7=5'b01010; 3: font5x7=5'b10010; 4: font5x7=5'b11111; 5: font5x7=5'b00010; 6: font5x7=5'b00010; default: font5x7=0; endcase
                7'h45: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b10000; 2: font5x7=5'b10000; 3: font5x7=5'b11110; 4: font5x7=5'b10000; 5: font5x7=5'b10000; 6: font5x7=5'b11111; default: font5x7=0; endcase
                7'h44: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b11110; default: font5x7=0; endcase
                7'h49: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b00100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b01110; default: font5x7=0; endcase
                7'h54: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b00100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b00100; default: font5x7=0; endcase
                7'h50: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11110; 4: font5x7=5'b10000; 5: font5x7=5'b10000; 6: font5x7=5'b10000; default: font5x7=0; endcase
                7'h52: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11110; 4: font5x7=5'b10100; 5: font5x7=5'b10010; 6: font5x7=5'b10001; default: font5x7=0; endcase
                7'h4F: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=0; endcase
                7'h4D: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b11011; 2: font5x7=5'b10101; 3: font5x7=5'b10101; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b10001; default: font5x7=0; endcase
                default: font5x7 = 5'b00000;
            endcase
        end
    endfunction

    function [6:0] band_char(input integer idx);
        begin
            if (page_lat < 2) begin
                case (idx)
                    0: band_char = 7'h45;               // E
                    1: band_char = 7'h44;               // D
                    2: band_char = 7'h49;               // I
                    3: band_char = 7'h54;               // T
                    4: band_char = 7'h20;
                    5: band_char = 7'h50;               // P
                    6: band_char = 7'h31 + {5'd0, page_lat};
                    7: band_char = 7'h2D;               // -
                    8: band_char = 7'h31 + {5'd0, sel_lat};
                    default: band_char = 7'h20;
                endcase
            end else begin
                case (idx)
                    0: band_char = 7'h50;
                    1: band_char = 7'h31 + {5'd0, page_lat};
                    2: band_char = 7'h20;
                    3: band_char = 7'h50;
                    4: band_char = 7'h52;
                    5: band_char = 7'h4F;
                    6: band_char = 7'h4D;
                    7: band_char = 7'h4F;
                    8: band_char = 7'h20;
                    default: band_char = 7'h20;
                endcase
            end
        end
    endfunction

    task fail(input [511:0] msg);
        begin
            if (errors < 20)
                $display("FAIL %0s", msg);
            errors = errors + 1;
        end
    endtask

    task latch_cfg;
        integer k;
        begin
            page_lat = active_index;
            sel_lat  = sel_idx;
            mask_lat = soldout_mask;
            menu_lat = menu_active;
            badges = 0;
            if (page_lat < 2)
                for (k = 0; k < 4; k = k + 1)
                    if (mask_lat[(page_lat*4)+k]) badges = badges + 1;
            glyph_white = 0;
            glyph_px = 0;
        end
    endtask

    // 每个有效像素：驱动 -> 断言 -> 采样
    task pixel(input integer x, input integer y);
        integer lx, ly, unit, pidx;
        reg rowbit, colbit, page_menu, sold, in_badge, is_edge, in_g1, in_g2;
        reg in_card, in_ring, border_hit, in_band, expect_any;
        reg [23:0] exp;
        reg [23:0] driven;
        begin
            driven = {x[7:0], y[7:0], 8'hA5};

            @(negedge clk);
            de = 1'b1;
            hs = ~(x < 40);
            rgb_in = driven;
            #1;

            if (hs_out !== hs || vs_out !== vs || de_out !== de)
                fail("DE/HS/VS not aligned with pixel");

            rowbit = (y >= CELL_H);
            colbit = (x >= CELL_W);
            unit = (rowbit ? 2 : 0) + (colbit ? 1 : 0);
            lx = x - (colbit ? CELL_W : 0);
            ly = y - (rowbit ? CELL_H : 0);

            page_menu = (page_lat < 2);
            sold = page_menu && mask_lat[(page_lat[0]*4) + unit];
            in_badge = (lx >= BADGE_X) && (lx < BADGE_X + BADGE_W) &&
                       (ly >= BADGE_Y) && (ly < BADGE_Y + BADGE_H);
            is_edge = (lx < BADGE_X + 3) || (lx >= BADGE_X + BADGE_W - 3) ||
                   (ly < BADGE_Y + 3) || (ly >= BADGE_Y + BADGE_H - 3);
            in_g1 = (lx >= G1X) && (lx < G1X + GPX) && (ly >= GY) && (ly < GY + GPX);
            in_g2 = (lx >= G2X) && (lx < G2X + GPX) && (ly >= GY) && (ly < GY + GPX);

            in_card = (lx >= CARD_X) && (lx < CARD_X + CARD_W) &&
                      (ly >= CARD_Y) && (ly < CARD_Y + CARD_H);
            in_ring = (lx < CARD_X + BORDER_W) ||
                      (lx >= CARD_X + CARD_W - BORDER_W) ||
                      (ly < CARD_Y + BORDER_W) ||
                      (ly >= CARD_Y + CARD_H - BORDER_W);
            border_hit = menu_lat && page_menu && (sel_lat == unit) && in_card && in_ring;

            in_band = (y >= BAND_Y0) && (y < BAND_Y1);
            expect_any = 1'b0;
            exp = driven;
            pidx = 0;

            if (!display_valid) begin
                exp = driven;
            end else if (sold && in_badge) begin
                if (is_edge) begin
                    exp = C_EDGE;
                end else if (in_g1 || in_g2) begin
                    expect_any = 1'b1;
                    glyph_px = glyph_px + 1;
                    if (rgb_out === C_EDGE) glyph_white = glyph_white + 1;
                    if (!(rgb_out === C_EDGE || rgb_out === C_BADGE))
                        fail("glyph pixel is neither red nor white");
                end else begin
                    exp = C_BADGE;
                end
            end else if (border_hit) begin
                exp = C_BORD;
            end else if (menu_lat && in_band) begin
                if (y == BAND_Y0 || y == BAND_Y1 - 1) begin
                    exp = C_FG;
                end else if ((x >= TEXT_X) && (x < TEXT_X + 9 * PITCH) &&
                             (y >= TEXT_Y) && (y < TEXT_Y + 7 * 4)) begin
                    pidx = (x - TEXT_X) / PITCH;
                    if ((pidx < 9) && (((x - TEXT_X) % PITCH) < 20)) begin
                        if ((font5x7(band_char(pidx), (y - TEXT_Y) / 4) >> (4 - (((x - TEXT_X) % PITCH) / 4))) & 1)
                            exp = C_FG;
                        else
                            exp = C_BAND;
                    end else begin
                        exp = C_BAND;
                    end
                end else begin
                    exp = C_BAND;
                end
            end

            if (!expect_any && (rgb_out !== exp)) begin
                if (errors < 20)
                    $display("FAIL pixel (%0d,%0d): got %06x expected %06x (page=%0d mask=%02x menu=%b sel=%0d valid=%b)",
                             x, y, rgb_out, exp, page_lat, mask_lat, menu_lat, sel_lat, display_valid);
                errors = errors + 1;
            end
            checked = checked + 1;
        end
    endtask

    task run_frame;
        integer y, x;
        begin
            @(negedge clk); vs = 1'b0; de = 1'b0; hs = 1'b0; rgb_in = 24'd0;
            repeat (3 * 64) @(posedge clk);         // 垂直同步期（vs 低）
            @(negedge clk); vs = 1'b1; frame_start = 1'b1;
            latch_cfg;
            @(negedge clk); frame_start = 1'b0;
            for (y = 0; y < 480; y = y + 1) begin
                for (x = 0; x < 640; x = x + 1)
                    pixel(x, y);
                @(negedge clk); de = 1'b0; hs = 1'b0; rgb_in = 24'd0;
                repeat (2) @(posedge clk);
            end
            // 消隐像素必须逐位透传
            for (x = 0; x < 8; x = x + 1) begin
                @(negedge clk); de = 1'b0; rgb_in = {8'h11, 8'h22, x[7:0]};
                #1;
                if (rgb_out !== rgb_in) fail("blanking pixel not passed through");
            end
            repeat (16) @(posedge clk);
        end
    endtask

    task expect_glyph_ink(input [255:0] tag);
        integer want;
        begin
            want = badges * (INK_SHOU + INK_QING) * 4;
            if (glyph_white !== want || glyph_px !== badges * 2 * GPX * GPX) begin
                $display("FAIL %0s: glyph white=%0d px=%0d, expected white=%0d px=%0d (badges=%0d)",
                         tag, glyph_white, glyph_px, want, badges * 2 * GPX * GPX, badges);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // 复位
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // A. 无有效画面 + 无状态：全透传
        display_valid = 1'b0; menu_active = 1'b0; soldout_mask = 8'h00; sel_idx = 2'd0;
        run_frame();
        expect_glyph_ink("frame A");

        // B. 有画面但无状态：仍全透传（含管理横幅关闭）
        display_valid = 1'b1; active_index = 2'd0;
        run_frame();
        expect_glyph_ink("frame B");

        // C. 单商品售罄（页 1 商品 0）
        soldout_mask = 8'h01;
        run_frame();
        if (badges !== 1) fail("C: badge count");
        expect_glyph_ink("frame C");

        // D. 四商品售罄 + 管理模式（选中商品 3）+ 横幅 EDIT P1-3
        soldout_mask = 8'h0F; menu_active = 1'b1; sel_idx = 2'd2;
        run_frame();
        if (badges !== 4) fail("D: badge count");
        expect_glyph_ink("frame D");

        // E. 帧内改配置：本帧必须保持 D 的配置（TB 参考也在帧边界才更新）
        soldout_mask = 8'h00;
        sel_idx = 2'd0;
        menu_active = 1'b0;
        // 只跑一半帧再恢复，检查未提前生效 —— 用 run_frame 时参考模型会在帧首锁存新值，
        // 因此这里先手动跑一段。
        begin : mid_frame
            integer y, x;
            @(negedge clk); vs = 1'b0; de = 1'b0; rgb_in = 0;
            repeat (3 * 64) @(posedge clk);
            @(negedge clk); vs = 1'b1; frame_start = 1'b1;
            // 恢复帧首配置（D）
            soldout_mask = 8'h0F; menu_active = 1'b1; sel_idx = 2'd2;
            latch_cfg;
            @(negedge clk); frame_start = 1'b0;
            for (y = 0; y < 480; y = y + 1) begin
                for (x = 0; x < 640; x = x + 1) begin
                    if (x == 100 && y == 300) begin
                        // 帧中途改配置：TB 不更新参考，DUT 只能在下一帧生效
                        soldout_mask = 8'h00; menu_active = 1'b0; sel_idx = 2'd0;
                        display_valid = 1'b0;
                    end
                    if (x == 200 && y == 300)
                        display_valid = 1'b1;
                    pixel(x, y);
                end
                @(negedge clk); de = 1'b0; hs = 1'b0;
                repeat (2) @(posedge clk);
            end
        end
        // 帧 F：新配置（无状态、有画面）在下一帧生效
        run_frame();
        display_valid = 1'b1;
        expect_glyph_ink("frame F");

        // G. 促销页：无牌无框，只有横幅 "P3 PROMO "
        active_index = 2'd2; soldout_mask = 8'hFF; menu_active = 1'b1; sel_idx = 2'd0;
        run_frame();
        if (badges !== 0) fail("G: promo page must not show badges");
        expect_glyph_ink("frame G");

        // H. 页 2（菜单第二页）与页 1 独立
        active_index = 2'd1; soldout_mask = 8'h40; menu_active = 1'b1; sel_idx = 2'd2;
        run_frame();
        if (badges !== 1) fail("H: page2 badge count");
        expect_glyph_ink("frame H");

        if (errors == 0)
            $display("PASS soldout_overlay: %0d pixel checks, passthrough/badge/border/band/promo/frame-latch",
                     checked);
        else
            $display("FAIL soldout_overlay: %0d error(s) over %0d pixel checks", errors, checked);
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "soldout_overlay timeout");
    end

endmodule
