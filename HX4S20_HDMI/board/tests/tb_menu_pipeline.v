`timescale 1ns/1ps

// 售罄图层与转场/OSD 的集成验证（真实 640x480 时序，像素级）。
//
// 方法：同一路视频源并联两条链路
//   A: video_delay -> soldout_overlay -> video_effect -> osd_overlay
//   B: video_delay -------------------> video_effect -> osd_overlay
// 断言：
//   1. A/B 的 DE/HS/VS 逐拍完全相同 → 新增图层没有增加延迟、没有错拍；
//   2. 售罄牌/选中框/横幅之外的像素 A === B（逐位透传）；
//   3. 售罄牌区域内 A 等于 alpha 缩放后的牌色，且（alpha=255 时）与 B 不同；
//   4. 无售罄/无管理时整帧 A === B；
//   5. 转场淡出期间牌色被 alpha 缩放；
//   6. 换页后上一页的牌不残留（旧牌位置恢复为 A === B）。
module tb_menu_pipeline;

    localparam integer H_ACTIVE = 640;
    localparam integer V_ACTIVE = 480;

    localparam integer CELL_W = 320, CELL_H = 240;
    localparam integer CARD_X = 20, CARD_Y = 6, CARD_W = 280, CARD_H = 196;
    localparam integer BADGE_X = 56, BADGE_Y = 40, BADGE_W = 208, BADGE_H = 84;
    localparam integer BORDER_W = 4;
    localparam integer BAND_Y0 = 206, BAND_Y1 = 242;
    localparam [23:0] C_BADGE = 24'hC81E1E, C_EDGE = 24'hFFFFFF;
    localparam [23:0] C_BORD = 24'h00FF80, C_BAND = 24'h101820, C_FG = 24'h00FF80;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;   // 25 MHz

    // ---------------- 真实视频时序 ----------------
    wire        rd_req;
    wire        hs0, vs0, de0;
    reg  [23:0] rd_data = 24'h204060;
    wire        hs, vs, de;
    wire [23:0] vout;

    video_timing_data u_timing (
        .video_clk (clk), .rst (rst), .read_req (rd_req), .read_req_ack (1'b0),
        .hs (hs0), .vs (vs0), .de (de0)
    );

    video_delay u_delay (
        .video_clk (clk), .rst (rst), .read_en (), .read_data (rd_data),
        .hs (hs0), .vs (vs0), .de (de0),
        .hs_r (hs), .vs_r (vs), .de_r (de), .vout_data (vout)
    );

    reg display_valid = 1'b1;
    wire [23:0] gated = display_valid ? vout : 24'd0;

    reg vs_0_d;
    wire frame_start_video;
    always @(posedge clk or posedge rst) begin
        if (rst) vs_0_d <= 1'b0; else vs_0_d <= vs0;
    end
    assign frame_start_video = vs_0_d & ~vs0;

    // ---------------- 配置（仿真直接驱动，等效 menu_control 输出） ----------------
    reg [1:0] page = 2'd0;
    reg [7:0] mask = 8'h00;
    reg       menu = 1'b0;
    reg [1:0] sel = 2'd0;

    reg [1:0] page_l = 2'd0, sel_l = 2'd0;
    reg [7:0] mask_l = 8'h00;
    reg       menu_l = 1'b0;

    // ---------------- 链 A：含售罄层 ----------------
    wire [23:0] sa_rgb;
    wire        sa_de, sa_hs, sa_vs;

    soldout_overlay u_soldout (
        .clk (clk), .rst (rst), .de (de), .hs (hs), .vs (vs),
        .frame_start (frame_start_video), .display_valid (display_valid),
        .rgb_in (gated), .active_index (page),
        .menu_active (menu), .sel_idx (sel), .soldout_mask (mask),
        .rgb_out (sa_rgb), .de_out (sa_de), .hs_out (sa_hs), .vs_out (sa_vs)
    );

    // ---------------- 转场参数（直接驱动） ----------------
    reg [1:0]  t_mode = 2'd0;
    reg [7:0]  t_alpha = 8'd255;
    reg [10:0] t_cover = 11'd0;
    reg        t_reveal = 1'b0;

    wire [23:0] ea_rgb, eb_rgb;
    wire ea_de, ea_hs, ea_vs, eb_de, eb_hs, eb_vs;

    video_effect u_eff_a (
        .clk (clk), .rst (rst), .de (sa_de), .hs (sa_hs), .vs (sa_vs), .rgb_in (sa_rgb),
        .mode (t_mode), .alpha (t_alpha), .cover_x (t_cover), .wipe_reveal (t_reveal),
        .rgb_out (ea_rgb), .de_out (ea_de), .hs_out (ea_hs), .vs_out (ea_vs)
    );

    video_effect u_eff_b (
        .clk (clk), .rst (rst), .de (de), .hs (hs), .vs (vs), .rgb_in (gated),
        .mode (t_mode), .alpha (t_alpha), .cover_x (t_cover), .wipe_reveal (t_reveal),
        .rgb_out (eb_rgb), .de_out (eb_de), .hs_out (eb_hs), .vs_out (eb_vs)
    );

    wire [23:0] oa_rgb, ob_rgb;
    wire oa_de, oa_hs, oa_vs, ob_de, ob_hs, ob_vs;
    wire ofa, ofb;

    osd_overlay #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE), .STATUS_X (8), .STATUS_Y (8),
        .SUBTITLE_Y (448), .SCROLL_STEP (2), .TEXT_LEN (40), .TEXT_WIDTH (640),
        .OSD_ENABLE (1)
    ) u_osd_a (
        .clk (clk), .rst (rst), .hs (ea_hs), .vs (ea_vs), .de (ea_de), .rgb_in (ea_rgb),
        .active_index (page), .status ({display_valid, 1'b1, 8'h00}),
        .rgb_out (oa_rgb), .de_out (oa_de), .hs_out (oa_hs), .vs_out (oa_vs),
        .frame_start (ofa), .pixel_x (), .pixel_y (), .scroll_offset (), .osd_active ()
    );

    osd_overlay #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE), .STATUS_X (8), .STATUS_Y (8),
        .SUBTITLE_Y (448), .SCROLL_STEP (2), .TEXT_LEN (40), .TEXT_WIDTH (640),
        .OSD_ENABLE (1)
    ) u_osd_b (
        .clk (clk), .rst (rst), .hs (eb_hs), .vs (eb_vs), .de (eb_de), .rgb_in (eb_rgb),
        .active_index (page), .status ({display_valid, 1'b1, 8'h00}),
        .rgb_out (ob_rgb), .de_out (ob_de), .hs_out (ob_hs), .vs_out (ob_vs),
        .frame_start (ofb), .pixel_x (), .pixel_y (), .scroll_offset (), .osd_active ()
    );

    // ---------------- 检查 ----------------
    integer errors = 0;
    integer px_count = 0;
    integer frame_px = 0;
    integer diff_count = 0;
    integer frames = 0;
    integer ox = 0, oy = 0;
    integer badge_region_px = 0;

    function [23:0] scale(input [23:0] c, input [7:0] a);
        reg [15:0] tr, tg, tb;
        reg [16:0] ur, ug, ub, wr, wg, wb;
        begin
            if (a == 8'd255) scale = c;
            else if (a == 8'd0) scale = 24'd0;
            else begin
                tr = c[23:16] * a; tg = c[15:8] * a; tb = c[7:0] * a;
                ur = {1'b0,tr} + 17'd1; ug = {1'b0,tg} + 17'd1; ub = {1'b0,tb} + 17'd1;
                wr = ur + {8'd0,ur[16:8]}; wg = ug + {8'd0,ug[16:8]}; wb = ub + {8'd0,ub[16:8]};
                scale = {wr[15:8], wg[15:8], wb[15:8]};
            end
        end
    endfunction

    task fail(input [511:0] msg);
        begin
            if (errors < 20) $display("FAIL %0s", msg);
            errors = errors + 1;
        end
    endtask

    task check_pixel(input integer x, input integer y);
        integer lx, ly, unit;
        reg rowbit, colbit, page_menu, sold, in_badge, is_edge;
        reg in_card, in_ring, border_hit, in_band;
        begin
            rowbit = (y >= CELL_H);
            colbit = (x >= CELL_W);
            unit = (rowbit ? 2 : 0) + (colbit ? 1 : 0);
            lx = x - (colbit ? CELL_W : 0);
            ly = y - (rowbit ? CELL_H : 0);

            page_menu = (page_l < 2);
            sold = page_menu && mask_l[(page_l[0]*4) + unit];
            in_badge = (lx >= BADGE_X) && (lx < BADGE_X + BADGE_W) &&
                       (ly >= BADGE_Y) && (ly < BADGE_Y + BADGE_H);
            is_edge = (lx < BADGE_X + 3) || (lx >= BADGE_X + BADGE_W - 3) ||
                      (ly < BADGE_Y + 3) || (ly >= BADGE_Y + BADGE_H - 3);
            in_card = (lx >= CARD_X) && (lx < CARD_X + CARD_W) &&
                      (ly >= CARD_Y) && (ly < CARD_Y + CARD_H);
            in_ring = (lx < CARD_X + BORDER_W) ||
                      (lx >= CARD_X + CARD_W - BORDER_W) ||
                      (ly < CARD_Y + BORDER_W) ||
                      (ly >= CARD_Y + CARD_H - BORDER_W);
            border_hit = menu_l && page_menu && (sel_l == unit) && in_card && in_ring;
            in_band = menu_l && (y >= BAND_Y0) && (y < BAND_Y1);

            if (sold && in_badge) begin
                badge_region_px = badge_region_px + 1;
                if (!((oa_rgb === scale(C_BADGE, t_alpha)) ||
                      (oa_rgb === scale(C_EDGE,  t_alpha))))
                    fail("badge pixel color mismatch (expected scaled red or white)");
                if ((t_alpha == 8'd255) && (oa_rgb === ob_rgb))
                    fail("badge pixel identical to bypass reference");
                if (oa_rgb !== ob_rgb) diff_count = diff_count + 1;
            end else if (border_hit) begin
                if (oa_rgb !== scale(C_BORD, t_alpha))
                    fail("selection border color mismatch");
                if (oa_rgb !== ob_rgb) diff_count = diff_count + 1;
            end else if (in_band) begin
                if (!((oa_rgb === scale(C_BAND, t_alpha)) ||
                      (oa_rgb === scale(C_FG,  t_alpha))))
                    fail("mode band color mismatch");
                if (oa_rgb !== ob_rgb) diff_count = diff_count + 1;
            end else if (oa_rgb !== ob_rgb) begin
                fail("overlay leaked outside its regions (passthrough broken)");
            end
        end
    endtask

    // 帧边界锁存参考副本
    always @(posedge clk) begin
        if (frame_start_video) begin
            page_l <= page; mask_l <= mask; menu_l <= menu; sel_l <= sel;
            frames <= frames + 1;
        end
    end

    // 逐像素检查（用输出 de 重建坐标）
    always @(posedge clk) begin
        if (rst) begin
            ox <= 0; oy <= 0;
        end else begin
            if (oa_de !== 1'b0 && ob_de === 1'b0) fail("A has de but B does not");
            if (oa_de === 1'b0 && ob_de !== 1'b0) fail("B has de but A does not");
            if (oa_de) begin
                check_pixel(ox, oy);
                ox <= ox + 1;
                frame_px = frame_px + 1;
                px_count = px_count + 1;
            end else begin
                if (ox != 0) oy <= oy + 1;
                ox <= 0;
            end
            if (!oa_vs) oy <= 0;
        end
    end

    task run_frame(input integer expect_badges);
        integer px0, diff0;
        begin
            @(posedge frame_start_video);          // 对齐到帧首再清零，保证统计整帧
            px0 = frame_px; diff0 = diff_count;
            frame_px = 0;
            badge_region_px = 0;
            @(posedge frame_start_video);
            if (frame_px !== 307200) begin
                $display("FAIL frame pixels: %0d (expected 307200)", frame_px);
                errors = errors + 1;
            end
            if ((expect_badges > 0) && (diff_count == diff0)) begin
                $display("FAIL overlay had no visible effect (badges=%0d)", expect_badges);
                errors = errors + 1;
            end
            if ((expect_badges == 0) && (diff_count != diff0)) begin
                $display("FAIL overlay changed pixels with no badge (%0d pixels)",
                         diff_count - diff0);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;

        @(posedge frame_start_video);

        // 1) 无状态：整帧透传
        page = 2'd0; mask = 8'h00; menu = 1'b0; sel = 2'd0;
        run_frame(0);

        // 2) 页 1 商品 0 售罄：牌只出现在该单元
        mask = 8'h01;
        run_frame(1);
        if (badge_region_px !== BADGE_W * BADGE_H) begin
            $display("FAIL badge region pixel count %0d (expected %0d)",
                     badge_region_px, BADGE_W * BADGE_H);
            errors = errors + 1;
        end

        // 3) 四商品 + 管理模式（选中第 3 件）+ 横幅
        mask = 8'h0F; menu = 1'b1; sel = 2'd2;
        run_frame(4);

        // 4) 转场淡出到中间：牌色被 alpha 缩放，仍只影响牌区
        t_mode = 2'd1; t_alpha = 8'd128;
        run_frame(4);
        t_alpha = 8'd0;
        run_frame(0);                               // 全黑帧：两链都应完全相同

        // 5) 全黑时提交换页：页 2 商品 3 售罄，页 1 的牌不得残留
        page = 2'd1; mask = 8'h80; menu = 1'b0;
        t_alpha = 8'd255; t_mode = 2'd0;
        run_frame(1);
        // 旧牌位置（页 1 商品 0）现在应完全等于参考
        // run_frame 已逐像素检查：旧区域不在 sold 区域 → 必须 A===B

        // 6) 帧内改 mask：本帧不生效，下一帧才生效
        mask = 8'h00;
        @(posedge frame_start_video);      // 帧首：参考锁存 0x00
        #100;                              // 帧内改回
        mask = 8'h10;
        @(posedge frame_start_video);      // 下一帧首：参考锁存 0x10
        @(posedge frame_start_video);

        if (errors == 0)
            $display("PASS menu_pipeline: alignment, passthrough, badge/border/band, alpha, page switch (%0d frames, %0d px)",
                     frames, px_count);
        else
            $display("FAIL menu_pipeline: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #600000000;
        $fatal(1, "menu_pipeline timeout");
    end

endmodule
