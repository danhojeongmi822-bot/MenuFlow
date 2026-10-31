`timescale 1ns/1ps

// 转场 + 视频链路集成验证（真实 640x480 时序）：
//   video_timing_data -> video_delay -> [display_valid 门控] -> video_effect
//     -> osd_overlay -> （本 TB 的检查器）
//   同时用真实 four_bank_frame_commit + video_transition 完成 Bank 提交。
//
// 覆盖：
//  - 每帧 307200 个有效像素，DE/HS/VS 经过效果与 OSD 后仍严格对齐；
//  - 旁路/淡出/幕布三种模式下逐像素比对模型（含 x=0 与 x=639）；
//  - 转场期间 OSD 状态条与滚动字幕像素不被变暗、不被遮挡（与参考 OSD 比对）；
//  - 字幕每帧继续移动；
//  - active_index 只允许在“画面完全遮蔽”时变化；
//  - 手动与自动两条转场各跑一轮，转场结束后画面来自新 Bank。
//
// 说明：这是真实视频时序下的集成验证；状态机的帧级细节（16 帧步长、
// 超时、排队、复位）由 tb_video_transition 以加速帧覆盖。
module tb_transition_pipeline;

    localparam integer H_ACTIVE = 640;
    localparam integer V_ACTIVE = 480;
    localparam [23:0]  SENTINEL = 24'hDEAD01;

    reg         clk;
    reg         rst;

    // ---------------- 真实视频时序链 ----------------
    wire        rd_req;
    wire        hs0, vs0, de0;
    reg  [23:0] rd_data;
    wire        hs, vs, de;
    wire [23:0] vout;

    video_timing_data u_timing (
        .video_clk    (clk),
        .rst          (rst),
        .read_req     (rd_req),
        .read_req_ack (1'b0),
        .hs           (hs0),
        .vs           (vs0),
        .de           (de0)
    );

    video_delay u_delay (
        .video_clk (clk),
        .rst       (rst),
        .read_en   (),
        .read_data (rd_data),
        .hs        (hs0),
        .vs        (vs0),
        .de        (de0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout)
    );

    reg display_valid;
    wire [23:0] vout_gated = display_valid ? vout : 24'd0;

    // ---------------- 转场控制 + Bank 提交 ----------------
    reg         vs_0_d;
    wire        frame_start_video;
    always @(posedge clk or posedge rst) begin
        if (rst) vs_0_d <= 1'b0;
        else     vs_0_d <= vs0;
    end
    assign frame_start_video = vs_0_d & ~vs0;

    reg         sd_toggle;
    reg  [1:0]  sd_index;
    reg  [3:0]  sd_valid;
    reg         sd_auto;
    reg         sd_player;

    wire        commit_toggle;
    wire [1:0]  commit_index;
    wire [3:0]  commit_valid;
    wire [1:0]  trans_mode;
    wire [7:0]  trans_alpha;
    wire [10:0] trans_cover;
    wire        trans_reveal;
    wire        trans_busy;
    wire        trans_dropped;
    wire        trans_aborted;
    wire        trans_invalid;
    wire [7:0]  trans_completed;
    wire [1:0]  active_index;

    video_transition #(
        .FADE_FRAMES(4), .WIPE_FRAMES(4), .H_ACTIVE(H_ACTIVE),
        .READY_FRAMES(2), .COMMIT_TIMEOUT_FRAMES(8), .SETTLE_CYCLES(4)
    ) u_transition (
        .sd_commit_toggle (sd_toggle),
        .sd_pending_index (sd_index),
        .sd_bank_valid    (sd_valid),
        .sd_commit_is_auto(sd_auto),
        .sd_player_active (sd_player),
        .pix_clk          (clk),
        .pix_rst          (rst),
        .frame_start      (frame_start_video),
        .active_index     (active_index),
        .commit_toggle    (commit_toggle),
        .commit_index     (commit_index),
        .commit_valid     (commit_valid),
        .mode             (trans_mode),
        .alpha            (trans_alpha),
        .cover_x          (trans_cover),
        .wipe_reveal      (trans_reveal),
        .busy             (trans_busy),
        .req_dropped      (trans_dropped),
        .stat_aborted     (trans_aborted),
        .stat_invalid     (trans_invalid),
        .stat_completed   (trans_completed)
    );

    four_bank_frame_commit u_commit (
        .pix_clk(clk), .pix_rst(rst), .frame_start(frame_start_video),
        .commit_toggle_mem(commit_toggle),
        .pending_index_mem(commit_index),
        .bank_valid_mem(commit_valid),
        .active_index(active_index)
    );

    // 每个 Bank 一个可识别的固定颜色（与 OSD 颜色、黑色都不同）
    reg [23:0] bank_color;
    always @* begin
        case (active_index)
            2'd0:    bank_color = 24'h204060;
            2'd1:    bank_color = 24'h60A0C0;
            2'd2:    bank_color = 24'hC06020;
            default: bank_color = 24'h804020;
        endcase
    end
    always @* rd_data = bank_color;

    // ---------------- 转场像素效果 ----------------
    wire [23:0] eff_rgb;
    wire        eff_de, eff_hs, eff_vs;

    video_effect #(.H_ACTIVE(H_ACTIVE), .COVER_COLOR(24'h000000)) u_effect (
        .clk(clk), .rst(rst),
        .de(de), .hs(hs), .vs(vs), .rgb_in(vout_gated),
        .mode(trans_mode), .alpha(trans_alpha), .cover_x(trans_cover),
        .wipe_reveal(trans_reveal),
        .rgb_out(eff_rgb), .de_out(eff_de), .hs_out(eff_hs), .vs_out(eff_vs)
    );

    // ---------------- 真实 OSD + 参考 OSD ----------------
    wire [23:0] osd_rgb;
    wire        osd_de, osd_hs, osd_vs, osd_fs;
    wire [9:0]  osd_x;
    wire [10:0] osd_scroll;

    osd_overlay #(
        .H_ACTIVE(640), .V_ACTIVE(480),
        .STATUS_X(8), .STATUS_Y(8), .SUBTITLE_Y(448),
        .SCROLL_STEP(2), .TEXT_LEN(40), .TEXT_WIDTH(640),
        .OSD_ENABLE(1)
    ) u_osd_real (
        .clk(clk), .rst(rst), .hs(eff_hs), .vs(eff_vs), .de(eff_de),
        .rgb_in(eff_rgb), .active_index(active_index),
        .status({1'b1, 1'b0, 8'h00}),
        .rgb_out(osd_rgb), .de_out(osd_de), .hs_out(osd_hs), .vs_out(osd_vs),
        .frame_start(osd_fs), .pixel_x(osd_x), .pixel_y(),
        .scroll_offset(osd_scroll), .osd_active()
    );

    // 参考 OSD：输入换成哨兵色。输出 != 哨兵 即该像素被 OSD 命中，
    // 输出值就是 OSD 颜色；命中与否则与真实 OSD 完全一致（同一 de/rgb 时序）。
    wire [23:0] ref_rgb;
    wire        ref_de, ref_fs;

    osd_overlay #(
        .H_ACTIVE(640), .V_ACTIVE(480),
        .STATUS_X(8), .STATUS_Y(8), .SUBTITLE_Y(448),
        .SCROLL_STEP(2), .TEXT_LEN(40), .TEXT_WIDTH(640),
        .OSD_ENABLE(1)
    ) u_osd_ref (
        .clk(clk), .rst(rst), .hs(eff_hs), .vs(eff_vs), .de(eff_de),
        .rgb_in(SENTINEL), .active_index(active_index),
        .status({1'b1, 1'b0, 8'h00}),
        .rgb_out(ref_rgb), .de_out(ref_de), .hs_out(), .vs_out(),
        .frame_start(ref_fs), .pixel_x(), .pixel_y(),
        .scroll_offset(), .osd_active()
    );

    // ---------------- 独立模型 ----------------
    reg [10:0] m_x;
    always @(posedge clk or posedge rst) begin
        if (rst) m_x <= 11'd0;
        else if (de) m_x <= m_x + 11'd1;
        else m_x <= 11'd0;
    end

    function [7:0] scale_model;
        input [7:0] v;
        input [7:0] a;
        begin
            scale_model = (v * a) / 255;
        end
    endfunction

    function [23:0] effect_model;
        input [23:0] rgb;
        input [10:0] px;
        input [1:0]  md;
        input [7:0]  al;
        input [10:0] cv;
        input        rev;
        begin
            if (md == 2'd0)
                effect_model = rgb;
            else if (md == 2'd1)
                effect_model = (al == 8'd255) ? rgb :
                               {scale_model(rgb[23:16], al),
                                scale_model(rgb[15:8],  al),
                                scale_model(rgb[7:0],   al)};
            else if (rev)
                effect_model = (px < cv) ? rgb : 24'h000000;
            else
                effect_model = (px < cv) ? 24'h000000 : rgb;
        end
    endfunction

    reg [23:0] exp_eff;
    reg [23:0] exp_eff_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            exp_eff   <= 24'd0;
            exp_eff_d <= 24'd0;
        end else begin
            exp_eff   <= effect_model(vout_gated, m_x, trans_mode, trans_alpha,
                                      trans_cover, trans_reveal);
            exp_eff_d <= exp_eff;
        end
    end

    // 参考 OSD 命中时使用 OSD 颜色，否则使用效果模型值。
    // OSD 输出相对效果输入晚 2 拍，故模型值也要再对齐 1 拍。
    wire [23:0] expected_final = (ref_rgb !== SENTINEL) ? ref_rgb : exp_eff_d;

    // 延迟模型：de 经效果 1 拍 + OSD 1 拍 = 2 拍
    reg de_d1, de_d2, hs_d1, hs_d2, vs_d1, vs_d2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            de_d1 <= 1'b0; de_d2 <= 1'b0;
            hs_d1 <= 1'b0; hs_d2 <= 1'b0;
            vs_d1 <= 1'b0; vs_d2 <= 1'b0;
        end else begin
            de_d1 <= de;    de_d2 <= de_d1;
            hs_d1 <= hs;    hs_d2 <= hs_d1;
            vs_d1 <= vs;    vs_d2 <= vs_d1;
        end
    end

    // ---------------- 检查器 ----------------
    integer fails;
    integer checks;
    integer frames;
    integer pix_cnt;
    integer pix_frames;
    integer osd_pix;
    integer osd_checked;
    reg     de_prev;
    reg     vs_prev;
    reg     frame_seen;
    reg [1:0] active_prev;
    integer cover_changes;
    integer last_cover;
    integer scroll_prev;
    integer scroll_hold;

    always #20 clk = ~clk;   // 25 MHz

    initial begin
        clk           = 1'b0;
        rst           = 1'b1;
        display_valid = 1'b0;
        sd_toggle     = 1'b0;
        sd_index      = 2'd0;
        sd_valid      = 4'b1111;
        sd_auto       = 1'b0;
        sd_player     = 1'b0;
        fails         = 0;
        checks        = 0;
        frames        = 0;
        pix_cnt       = 0;
        pix_frames    = 0;
        osd_pix       = 0;
        osd_checked   = 0;
        de_prev       = 1'b0;
        vs_prev       = 1'b0;
        frame_seen    = 1'b0;
        active_prev   = 2'd0;
        cover_changes = 0;
        last_cover    = 0;
        scroll_prev   = 0;
        scroll_hold   = 0;
    end

    // 逐像素检查（negedge 采样，输出已稳定）
    always @(negedge clk) begin
        if (!rst) begin
            checks = checks + 1;

            // DE/HS/VS 延迟必须是 2 拍
            if (osd_de !== de_d2 || osd_hs !== hs_d2 || osd_vs !== vs_d2) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("FAIL pipe: sync delayed wrong (de=%b/%b hs=%b/%b vs=%b/%b)",
                             osd_de, de_d2, osd_hs, hs_d2, osd_vs, vs_d2);
            end

            if (osd_de) begin
                checks = checks + 1;
                if (osd_rgb !== expected_final) begin
                    fails = fails + 1;
                    if (fails <= 12)
                        $display("FAIL pipe: rgb %06h != expected %06h at x=%0d (mode=%0d a=%0d cov=%0d rev=%b bank=%0d osd=%b)",
                                 osd_rgb, expected_final, osd_x, trans_mode, trans_alpha,
                                 trans_cover, trans_reveal, active_index,
                                 (ref_rgb !== SENTINEL));
                end
                if (ref_rgb !== SENTINEL) osd_pix = osd_pix + 1;
                pix_cnt = pix_cnt + 1;

                // 关键不变量：完全遮蔽时背景必须为黑
                if ((trans_mode == 2'd1 && trans_alpha == 8'd0) ||
                    (trans_mode == 2'd2 && trans_cover == 11'd640 && !trans_reveal)) begin
                    if (ref_rgb === SENTINEL && osd_rgb !== 24'h000000) begin
                        fails = fails + 1;
                        if (fails <= 12)
                            $display("FAIL pipe: background not black while fully covered (rgb=%06h)",
                                     osd_rgb);
                    end
                end
                // 旁路/满亮时背景必须精确等于 Bank 颜色
                if ((trans_mode == 2'd0) ||
                    (trans_mode == 2'd1 && trans_alpha == 8'd255)) begin
                    if (ref_rgb === SENTINEL && osd_rgb !== bank_color) begin
                        fails = fails + 1;
                        if (fails <= 12)
                            $display("FAIL pipe: background %06h != bank color %06h",
                                     osd_rgb, bank_color);
                    end
                end
            end

            // Bank 只允许在完全遮蔽时变化
            if (active_index !== active_prev) begin
                active_prev = active_index;
                if (!((trans_mode == 2'd1 && trans_alpha == 8'd0) ||
                      (trans_mode == 2'd2 && trans_cover == 11'd640 && !trans_reveal) ||
                      (trans_mode == 2'd0 && !trans_busy))) begin
                    fails = fails + 1;
                    $display("FAIL pipe: Bank changed without full cover (mode=%0d a=%0d cov=%0d)",
                             trans_mode, trans_alpha, trans_cover);
                end
            end

            // 帧统计
            if (vs_prev && !osd_vs) begin
                frames = frames + 1;
                if (frame_seen) begin
                    if (pix_cnt != 307200) begin
                        fails = fails + 1;
                        $display("FAIL pipe: frame %0d has %0d pixels", frames, pix_cnt);
                    end else begin
                        pix_frames = pix_frames + 1;
                    end
                end
                frame_seen = 1'b1;
                pix_cnt = 0;
                // 字幕每帧必须前进（复位后跳过 3 帧，等滚动寄存器重新起算）
                if (scroll_hold > 0) begin
                    scroll_hold = scroll_hold - 1;
                    scroll_prev = osd_scroll;
                end else if (frames > 2) begin
                    if (osd_scroll !== ((scroll_prev + 2 >= 1280) ? 0 : scroll_prev + 2)) begin
                        fails = fails + 1;
                        $display("FAIL pipe: subtitle did not advance (scroll %0d -> %0d)",
                                 scroll_prev, osd_scroll);
                    end
                    scroll_prev = osd_scroll;
                end else begin
                    scroll_prev = osd_scroll;
                end
            end

            de_prev = osd_de;
            vs_prev = osd_vs;
        end else begin
            de_prev = 1'b0;
            vs_prev = 1'b0;
            pix_cnt = 0;
            frame_seen = 1'b0;
            scroll_prev = 0;
            scroll_hold = 3;
        end
    end

    task wait_frames;
        input integer n;
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(posedge clk);
                if (frame_start_video) k = k + 1;
            end
        end
    endtask

    task sd_request;
        input [1:0] idx;
        input       is_auto;
        begin
            @(negedge clk);
            sd_index  = idx;
            sd_auto   = is_auto;
            sd_toggle = ~sd_toggle;
        end
    endtask

    integer f0;
    integer t_limit;

    initial begin
        #400;
        rst = 1'b0;
        display_valid = 1'b1;
        sd_player     = 1'b1;     // 已有有效画面
        wait_frames(3);

        if (trans_mode !== 2'd0 || active_index !== 2'd0) begin
            fails = fails + 1;
            $display("FAIL pipe: initial state wrong (mode=%0d bank=%0d)", trans_mode, active_index);
        end

        // ---------------- 1) 手动淡出淡入 ----------------
        f0 = frames;
        sd_request(2'd1, 1'b0);
        t_limit = 0;
        while (active_index !== 2'd1 && t_limit < 30) begin
            @(posedge clk);
            if (frame_start_video) t_limit = t_limit + 1;
        end
        if (active_index !== 2'd1) begin
            fails = fails + 1;
            $display("FAIL pipe: manual transition did not commit bank 1");
        end
        t_limit = 0;
        while (trans_busy && t_limit < 30) begin
            @(posedge clk);
            if (frame_start_video) t_limit = t_limit + 1;
        end
        $display("INFO pipe: manual transition %0d frames", frames - f0);
        if (frames - f0 < 6 || frames - f0 > 20) begin
            fails = fails + 1;
            $display("FAIL pipe: manual transition frame count %0d unexpected", frames - f0);
        end
        if (trans_mode !== 2'd0 || trans_alpha !== 8'd255) begin
            fails = fails + 1;
            $display("FAIL pipe: not back to pass-through after manual transition");
        end
        wait_frames(2);

        // ---------------- 2) 自动幕布 Wipe ----------------
        f0 = frames;
        osd_checked = osd_pix;
        sd_request(2'd2, 1'b1);
        t_limit = 0;
        while (active_index !== 2'd2 && t_limit < 30) begin
            @(posedge clk);
            if (frame_start_video) t_limit = t_limit + 1;
        end
        if (active_index !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL pipe: wipe transition did not commit bank 2");
        end
        t_limit = 0;
        while (trans_busy && t_limit < 30) begin
            @(posedge clk);
            if (frame_start_video) t_limit = t_limit + 1;
        end
        $display("INFO pipe: wipe transition %0d frames", frames - f0);
        if (frames - f0 < 6 || frames - f0 > 20) begin
            fails = fails + 1;
            $display("FAIL pipe: wipe transition frame count %0d unexpected", frames - f0);
        end
        // IDLE 下 cover_x 保留 640（mode=PASS 时被忽略），alpha 必须回到 255
        if (trans_mode !== 2'd0 || trans_alpha !== 8'd255) begin
            fails = fails + 1;
            $display("FAIL pipe: not back to pass-through after wipe (mode=%0d alpha=%0d cover=%0d)",
                     trans_mode, trans_alpha, trans_cover);
        end
        wait_frames(2);

        // ---------------- 3) 复位后恢复 ----------------
        rst = 1'b1;
        #400;
        rst = 1'b0;
        sd_player = 1'b1;
        wait_frames(3);
        if (trans_mode !== 2'd0 || trans_alpha !== 8'd255) begin
            fails = fails + 1;
            $display("FAIL pipe: not idle after reset");
        end

        if (osd_pix == 0) begin
            fails = fails + 1;
            $display("FAIL pipe: OSD never produced any pixel (reference broken)");
        end

        if (fails == 0) begin
            $display("PASS transition_pipeline: %0d checks, %0d frames (%0d full 307200-pixel frames), %0d OSD pixels",
                     checks, frames, pix_frames, osd_pix);
            $finish;
        end else begin
            $display("FAIL transition_pipeline: %0d failure(s) over %0d checks", fails, checks);
            $fatal(1);
        end
    end

endmodule
