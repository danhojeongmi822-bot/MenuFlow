`timescale 1ns/1ps

// video_transition 单元验证（加速帧边界，双时钟域）：
//  - 手动请求：IDLE -> ARM -> OUT(alpha 255->0) -> COMMIT(全黑时提交) -> READY
//    -> IN(0->255) -> IDLE；
//  - 自动请求：幕布 cover_x 0->640 -> 提交 -> READY -> 揭示 0->640 -> IDLE；
//  - 提交只在完全遮蔽后发生，且每次请求只提交一次；
//  - 忙时缓存 1 个请求、第三个请求丢弃；
//  - 无有效画面时直接提交不做效果；目标等于当前 Bank 时静默消费；
//  - 提交确认超时 -> abort 并恢复显示，不永久全黑；
//  - 转场中复位 -> 回到 IDLE/alpha=255 且不产生幻影请求；
//  - 旁路参数（FADE_FRAMES=0）与基线硬切等价。
module tb_video_transition;

    localparam integer FRAME_PERIOD = 200;   // 加速帧周期（像素时钟）

    reg         pix_clk;
    reg         pix_rst;
    reg         sd_clk;
    reg         frame_start;

    reg         sd_toggle;
    reg  [1:0]  sd_index;
    reg  [3:0]  sd_valid;
    reg         sd_auto;
    reg         sd_player;

    wire        commit_toggle;
    wire [1:0]  commit_index;
    wire [3:0]  commit_valid;
    wire [1:0]  mode_o;
    wire [7:0]  alpha_o;
    wire [10:0] cover_o;
    wire        reveal_o;
    wire        busy;
    wire        dropped;
    wire        aborted;
    wire        invalid;
    wire [7:0]  completed;
    wire [1:0]  active_index;

    // 旁路实例（独立信号）
    reg         bp_frame_start;
    reg         bp_toggle;
    reg  [1:0]  bp_index;
    wire        bp_commit_toggle;
    wire [1:0]  bp_commit_index;
    wire [3:0]  bp_commit_valid;
    wire [1:0]  bp_mode;
    wire [7:0]  bp_alpha;
    wire [10:0] bp_cover;
    wire        bp_reveal;
    wire        bp_busy;
    wire        bp_dropped;
    wire        bp_aborted;
    wire        bp_invalid;
    wire [7:0]  bp_completed;

    integer fails;
    integer checks;
    integer frame_no;
    integer fcnt;
    reg     fs_d;

    // 记录器
    reg [7:0]  alpha_rec;
    reg [10:0] cover_rec;
    reg [1:0]  mode_rec;
    integer    n_alpha;
    integer    n_cover;
    integer    n_mode;
    reg [7:0]  alpha_hist [0:127];
    reg [10:0] cover_hist [0:127];
    reg [1:0]  mode_hist  [0:63];
    integer    commit_edges;
    integer    active_changes;
    reg        commit_prev;
    reg [1:0]  active_prev;
    integer    commit_bad;
    integer    midframe_bad;
    reg [3:0]  req_mask;
    reg        aborted_d;
    reg        drop_seen;

    video_transition #(
        .FADE_FRAMES(16), .WIPE_FRAMES(16), .H_ACTIVE(640),
        .READY_FRAMES(2), .COMMIT_TIMEOUT_FRAMES(8), .SETTLE_CYCLES(4)
    ) dut (
        .sd_commit_toggle(sd_toggle), .sd_pending_index(sd_index),
        .sd_bank_valid(sd_valid), .sd_commit_is_auto(sd_auto),
        .sd_player_active(sd_player),
        .pix_clk(pix_clk), .pix_rst(pix_rst),
        .frame_start(frame_start), .active_index(active_index),
        .commit_toggle(commit_toggle), .commit_index(commit_index),
        .commit_valid(commit_valid),
        .mode(mode_o), .alpha(alpha_o), .cover_x(cover_o), .wipe_reveal(reveal_o),
        .busy(busy), .req_dropped(dropped), .stat_aborted(aborted),
        .stat_invalid(invalid), .stat_completed(completed)
    );

    four_bank_frame_commit u_commit (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .frame_start(frame_start),
        .commit_toggle_mem(commit_toggle), .pending_index_mem(commit_index),
        .bank_valid_mem(commit_valid), .active_index(active_index)
    );

    // 旁路实例：FADE_FRAMES=0
    video_transition #(
        .FADE_FRAMES(0), .WIPE_FRAMES(16), .H_ACTIVE(640),
        .READY_FRAMES(2), .COMMIT_TIMEOUT_FRAMES(8), .SETTLE_CYCLES(4)
    ) dut_bp (
        .sd_commit_toggle(bp_toggle), .sd_pending_index(bp_index),
        .sd_bank_valid(4'b1111), .sd_commit_is_auto(1'b0),
        .sd_player_active(1'b1),
        .pix_clk(pix_clk), .pix_rst(pix_rst),
        .frame_start(bp_frame_start), .active_index(2'd0),
        .commit_toggle(bp_commit_toggle), .commit_index(bp_commit_index),
        .commit_valid(bp_commit_valid),
        .mode(bp_mode), .alpha(bp_alpha), .cover_x(bp_cover), .wipe_reveal(bp_reveal),
        .busy(bp_busy), .req_dropped(bp_dropped), .stat_aborted(bp_aborted),
        .stat_invalid(bp_invalid), .stat_completed(bp_completed)
    );

    always #20 pix_clk = ~pix_clk;   // 25 MHz
    always #5  sd_clk  = ~sd_clk;    // 100 MHz

    // 帧边界：每 FRAME_PERIOD 个像素时钟一个单拍脉冲
    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            fcnt           <= 0;
            frame_start    <= 1'b0;
            bp_frame_start <= 1'b0;
        end else begin
            if (fcnt == FRAME_PERIOD - 1) begin
                fcnt           <= 0;
                frame_start    <= 1'b1;
                bp_frame_start <= 1'b1;
            end else begin
                fcnt           <= fcnt + 1;
                frame_start    <= 1'b0;
                bp_frame_start <= 1'b0;
            end
        end
    end

    always @(posedge pix_clk) begin
        fs_d <= frame_start;
        aborted_d <= aborted;
        if (dropped)
            drop_seen <= 1'b1;
        if (!pix_rst && frame_start)
            frame_no = frame_no + 1;
    end

    // ---- 记录与不变量检查（negedge 采样，避开 NBA 竞争） ----
    always @(negedge pix_clk) begin
        if (pix_rst) begin
            // 复位期间让记录跟随输出，避免复位释放瞬间误报“帧中途改变”
            alpha_rec = alpha_o;
            cover_rec = cover_o;
            mode_rec  = mode_o;
            commit_prev = commit_toggle;
            active_prev = active_index;
        end else begin
            checks = checks + 1;

            if (alpha_o !== alpha_rec) begin
                if (!fs_d) begin
                    midframe_bad = midframe_bad + 1;
                    if (midframe_bad <= 5)
                        $display("FAIL transition: alpha changed mid-frame (%0d -> %0d)",
                                 alpha_rec, alpha_o);
                end
                alpha_rec = alpha_o;
                if (n_alpha < 128) alpha_hist[n_alpha] = alpha_o;
                n_alpha = n_alpha + 1;
            end

            if (cover_o !== cover_rec) begin
                if (!fs_d) begin
                    midframe_bad = midframe_bad + 1;
                    if (midframe_bad <= 5)
                        $display("FAIL transition: cover_x changed mid-frame (%0d -> %0d)",
                                 cover_rec, cover_o);
                end
                cover_rec = cover_o;
                if (n_cover < 128) cover_hist[n_cover] = cover_o;
                n_cover = n_cover + 1;
            end

            if (mode_o !== mode_rec) begin
                if (!fs_d) begin
                    midframe_bad = midframe_bad + 1;
                    if (midframe_bad <= 5)
                        $display("FAIL transition: mode changed mid-frame (%0d -> %0d)",
                                 mode_rec, mode_o);
                end
                mode_rec = mode_o;
                if (n_mode < 64) mode_hist[n_mode] = mode_o;
                n_mode = n_mode + 1;
            end

            if (active_index !== active_prev) begin
                active_prev = active_index;
                active_changes = active_changes + 1;
            end

            if (commit_toggle !== commit_prev) begin
                commit_prev = commit_toggle;
                commit_edges = commit_edges + 1;
                $display("INFO commit edge @%0t idx=%0d mode=%0d alpha=%0d cover=%0d mask=%b aborted=%b bus=%b st=%0d pl=%b sdidx=%0d",
                         $time, commit_index, mode_o, alpha_o, cover_o, req_mask, aborted, busy,
                         dut.state, sd_player, sd_index);
                // abort 取消边不是提交：它与 stat_aborted 上升沿同拍
                if (!(aborted === 1'b1 && aborted_d === 1'b0)) begin
                    // 提交必须在完全遮蔽后：淡出 alpha=0，幕布 cover=640；
                    // 例外是“无有效画面”时直接提交（此时画面本就是黑的）。
                    if (mode_o == 2'd1 && alpha_o !== 8'd0) begin
                        commit_bad = commit_bad + 1;
                        $display("FAIL transition: commit while alpha=%0d (not black)", alpha_o);
                    end
                    if (mode_o == 2'd2 && cover_o !== 11'd640) begin
                        commit_bad = commit_bad + 1;
                        $display("FAIL transition: commit while cover_x=%0d (not covered)", cover_o);
                    end
                    if (mode_o == 2'd0 && sd_player === 1'b1) begin
                        commit_bad = commit_bad + 1;
                        $display("FAIL transition: commit in pass-through mode while picture active");
                    end
                    if (!req_mask[commit_index]) begin
                        commit_bad = commit_bad + 1;
                        $display("FAIL transition: commit_index=%0d was never requested (mask=%b)",
                                 commit_index, req_mask);
                    end
                    req_mask[commit_index] = 1'b0;
                end
            end
        end
    end

    task clear_rec;
        begin
            // 用当前值作为序列首项，便于比较“第一个变化”
            alpha_rec = alpha_o; cover_rec = cover_o; mode_rec = mode_o;
            alpha_hist[0] = alpha_o;
            cover_hist[0] = cover_o;
            mode_hist[0]  = mode_o;
            n_alpha = 1; n_cover = 1; n_mode = 1;
        end
    endtask

    task sd_req;
        input [1:0] idx;
        input       is_auto;
        begin
            @(negedge sd_clk);
            sd_index  = idx;
            sd_auto   = is_auto;
            sd_toggle = ~sd_toggle;
            req_mask[idx] = 1'b1;
            $display("INFO sd_req @%0t idx=%0d auto=%b busy=%b st=%0d pl=%b valid=%b",
                     $time, idx, is_auto, busy, dut.state, sd_player, sd_valid);
            @(negedge sd_clk);
        end
    endtask

    task wait_idle;
        integer n;
        begin
            n = 0;
            // 上限按帧计：一次手动转场约 37 帧，给 300 帧余量
            while (busy && n < 300 * FRAME_PERIOD) begin
                @(posedge pix_clk);
                n = n + 1;
            end
            if (n >= 300 * FRAME_PERIOD) begin
                fails = fails + 1;
                $display("FAIL transition: busy did not clear (deadlock)");
            end
        end
    endtask

    task check_fade16;
        input integer first;
        integer i;
        integer steps;
        reg [7:0] exp_val;
        begin
            if (alpha_hist[first] !== 8'd255) begin
                fails = fails + 1;
                $display("FAIL fade: first alpha %0d != 255", alpha_hist[first]);
            end
            i = first + 1;
            steps = 0;
            while (i < n_alpha && alpha_hist[i] > 8'd0) begin
                exp_val = alpha_hist[i-1] - 8'd16;
                if (exp_val > alpha_hist[i-1]) exp_val = 8'd0;
                if (alpha_hist[i] !== exp_val) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL fade: expected %0d got %0d at step %0d",
                                 exp_val, alpha_hist[i], steps);
                end
                steps = steps + 1;
                i = i + 1;
            end
            if (steps != 15) begin
                fails = fails + 1;
                $display("FAIL fade: 255->0 took %0d steps (expected 15)", steps);
            end
            if (i >= n_alpha || alpha_hist[i] !== 8'd0) begin
                fails = fails + 1;
                $display("FAIL fade: never reached alpha=0");
            end
            while (i < n_alpha && alpha_hist[i] == 8'd0) i = i + 1;
            steps = 0;
            while (i < n_alpha) begin
                exp_val = (9'd0 + {1'b0, alpha_hist[i-1]} + 9'd16 > 9'd240)
                          ? 8'd255 : (alpha_hist[i-1] + 8'd16);
                if (alpha_hist[i] !== exp_val) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL fade-in: expected %0d got %0d at step %0d",
                                 exp_val, alpha_hist[i], steps);
                end
                steps = steps + 1;
                i = i + 1;
            end
            if (alpha_hist[n_alpha-1] !== 8'd255) begin
                fails = fails + 1;
                $display("FAIL fade-in: final alpha %0d != 255", alpha_hist[n_alpha-1]);
            end
        end
    endtask

    task check_cover_profile;
        input integer first;
        integer i;
        integer steps;
        reg [10:0] exp_val;
        begin
            if (cover_hist[first] !== 11'd0) begin
                fails = fails + 1;
                $display("FAIL wipe: first cover %0d != 0", cover_hist[first]);
            end
            i = first + 1;
            steps = 0;
            while (i < n_cover && cover_hist[i] != 11'd0) begin
                exp_val = cover_hist[i-1] + 11'd40;
                if (exp_val > 11'd640) exp_val = 11'd640;
                if (cover_hist[i] !== exp_val) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL wipe: expected %0d got %0d at step %0d",
                                 exp_val, cover_hist[i], steps);
                end
                steps = steps + 1;
                i = i + 1;
            end
            if (cover_hist[i-1] !== 11'd640) begin
                fails = fails + 1;
                $display("FAIL wipe: cover did not reach 640 (got %0d)", cover_hist[i-1]);
            end
            if (i >= n_cover || cover_hist[i] !== 11'd0) begin
                fails = fails + 1;
                $display("FAIL wipe: reveal did not restart from 0");
            end
            i = i + 1;
            steps = 0;
            while (i < n_cover && cover_hist[i] != 11'd0) begin
                exp_val = (cover_hist[i-1] + 11'd40 > 11'd640) ? 11'd640
                                                               : (cover_hist[i-1] + 11'd40);
                if (cover_hist[i] !== exp_val) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL reveal: expected %0d got %0d at step %0d",
                                 exp_val, cover_hist[i], steps);
                end
                steps = steps + 1;
                i = i + 1;
            end
            if (cover_hist[i-1] !== 11'd640) begin
                fails = fails + 1;
                $display("FAIL reveal: final cover %0d != 640", cover_hist[i-1]);
            end
        end
    endtask

    integer t0;
    integer e0;
    integer a0;

    initial begin
        #20_000_000;
        $display("FAIL video_transition: watchdog timeout at %0t", $time);
        $fatal(1);
    end
    initial begin
        $display("INFO: tb_video_transition start");
        pix_clk     = 1'b0;
        pix_rst     = 1'b1;
        sd_clk      = 1'b0;
        frame_start = 1'b0;
        sd_toggle   = 1'b0;
        sd_index    = 2'd0;
        sd_valid    = 4'b1111;
        sd_auto     = 1'b0;
        sd_player   = 1'b1;
        bp_toggle   = 1'b0;
        bp_index    = 2'd0;
        fails       = 0;
        checks      = 0;
        frame_no    = 0;
        fcnt        = 0;
        fs_d        = 1'b0;
        alpha_rec   = 8'd255;
        cover_rec   = 11'd0;
        mode_rec    = 2'd0;
        n_alpha     = 1;
        n_cover     = 1;
        n_mode      = 1;
        commit_edges   = 0;
        active_changes = 0;
        commit_prev    = 1'b0;
        active_prev    = 2'd0;
        commit_bad     = 0;
        midframe_bad   = 0;
        req_mask       = 4'b0000;
        aborted_d      = 1'b0;
        drop_seen      = 1'b0;

        repeat (5) @(negedge pix_clk);
        pix_rst = 1'b0;
        // 复位后 12 个像素时钟内只跟踪源 toggle（防幻影请求），
        // 测试必须等这段窗口结束再发请求。
        repeat (20) @(negedge pix_clk);

        // ================= 1) 手动淡出淡入 =================
        $display("INFO: test1 manual fade start");
        sd_valid  = 4'b1111;
        sd_player = 1'b1;
        clear_rec;
        t0 = frame_no;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd1, 1'b0);
        wait (busy);
        wait_idle();
        if (commit_edges - e0 != 1) begin
            fails = fails + 1;
            $display("FAIL manual: %0d commit edges (expected 1)", commit_edges - e0);
        end
        if (active_changes - a0 != 1 || active_index !== 2'd1) begin
            fails = fails + 1;
            $display("FAIL manual: active_index=%0d changes=%0d (expected 1 to 1)",
                     active_index, active_changes - a0);
        end
        if (mode_o !== 2'd0 || alpha_o !== 8'd255 || cover_o !== 11'd0 || reveal_o !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL manual: not back to pass-through after transition");
        end
        check_fade16(0);
        $display("INFO manual: %0d frames, alpha steps %0d, mode steps %0d",
                 frame_no - t0, n_alpha, n_mode);
        if (frame_no - t0 < 30 || frame_no - t0 > 46) begin
            fails = fails + 1;
            $display("FAIL manual: total %0d frames outside expected window", frame_no - t0);
        end

        // ================= 2) 自动幕布 Wipe =================
        clear_rec;
        t0 = frame_no;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd2, 1'b1);
        wait (busy);
        wait_idle();
        if (commit_edges - e0 != 1) begin
            fails = fails + 1;
            $display("FAIL wipe: %0d commit edges (expected 1)", commit_edges - e0);
        end
        if (active_changes - a0 != 1 || active_index !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL wipe: active_index=%0d changes=%0d (expected 1 to 2)",
                     active_index, active_changes - a0);
        end
        check_cover_profile(0);
        $display("INFO wipe: %0d frames, cover steps %0d, mode steps %0d",
                 frame_no - t0, n_cover, n_mode);
        if (frame_no - t0 < 30 || frame_no - t0 > 46) begin
            fails = fails + 1;
            $display("FAIL wipe: total %0d frames outside expected window", frame_no - t0);
        end

        // ================= 3) 相同目标：静默消费 =================
        e0 = commit_edges;
        a0 = active_changes;
        clear_rec;
        sd_req(2'd2, 1'b0);
        repeat (FRAME_PERIOD * 3) @(posedge pix_clk);
        if (busy || commit_edges != e0 || active_changes != a0) begin
            fails = fails + 1;
            $display("FAIL same-target: unexpected transition/commit");
        end
        if (completed !== 8'd2) begin
            fails = fails + 1;
            $display("FAIL same-target: stat_completed=%0d (expected 2)", completed);
        end

        // ================= 4) 无效目标：不切换 =================
        sd_valid = 4'b1101;   // bank1 无效（bit1=0）
        clear_rec;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd1, 1'b0);
        repeat (FRAME_PERIOD * 4) @(posedge pix_clk);
        if (busy || commit_edges != e0 || active_changes != a0 || active_index !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL invalid-target: transition happened for invalid bank");
        end
        if (!invalid) begin
            fails = fails + 1;
            $display("FAIL invalid-target: stat_invalid not set");
        end
        sd_valid = 4'b1111;

        // ================= 5) 忙时排队 + 丢弃 =================
        clear_rec;
        drop_seen = 1'b0;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd0, 1'b0);
        wait (busy);
        repeat (FRAME_PERIOD / 2) @(posedge pix_clk);
        sd_req(2'd3, 1'b0);              // 缓存
        repeat (FRAME_PERIOD / 2) @(posedge pix_clk);
        sd_req(2'd1, 1'b0);              // 丢弃
        repeat (20) @(posedge pix_clk);
        if (!drop_seen) begin
            fails = fails + 1;
            $display("FAIL queue: third request was not dropped @%0t", $time);
        end
        wait_idle();
        wait (busy);
        wait_idle();
        if (commit_edges - e0 != 2) begin
            fails = fails + 1;
            $display("FAIL queue: %0d commits (expected 2)", commit_edges - e0);
        end
        if (active_changes - a0 != 2 || active_index !== 2'd3) begin
            fails = fails + 1;
            $display("FAIL queue: active_index=%0d changes=%0d (expected 2 to 3)",
                     active_index, active_changes - a0);
        end

        // ================= 6) 提交确认超时 -> abort =================
        clear_rec;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd0, 1'b0);
        wait (busy);
        repeat (FRAME_PERIOD * 3) @(posedge pix_clk);
        sd_valid = 4'b0000;   // 模拟重新扫描清空有效标记，four_bank 拒绝提交
        wait_idle();
        if (!aborted) begin
            fails = fails + 1;
            $display("FAIL timeout: stat_aborted not set");
        end
        if (active_index !== 2'd3 || active_changes != a0) begin
            fails = fails + 1;
            $display("FAIL timeout: active_index changed to %0d on aborted commit", active_index);
        end
        if (alpha_o !== 8'd255 || mode_o !== 2'd0) begin
            fails = fails + 1;
            $display("FAIL timeout: did not recover to normal display (alpha=%0d mode=%0d)",
                     alpha_o, mode_o);
        end
        if (commit_edges - e0 != 2) begin
            fails = fails + 1;
            $display("FAIL timeout: commit edge count %0d (expected issue+cancel = 2)",
                     commit_edges - e0);
        end
        sd_valid = 4'b1111;

        // ================= 7) 无有效画面：立即提交 =================
        sd_player = 1'b0;
        clear_rec;
        e0 = commit_edges;
        sd_req(2'd2, 1'b0);
        repeat (FRAME_PERIOD * 2) @(posedge pix_clk);
        if (commit_edges - e0 != 1) begin
            fails = fails + 1;
            $display("FAIL no-player: no immediate commit");
        end
        if (busy || n_alpha != 1) begin
            fails = fails + 1;
            $display("FAIL no-player: unexpected fade effect");
        end
        if (active_index !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL no-player: active_index=%0d (expected 2)", active_index);
        end
        sd_player = 1'b1;
        sd_valid  = 4'b1111;

        // ================= 8) 转场中复位 =================
        clear_rec;
        sd_req(2'd1, 1'b0);
        wait (busy);
        repeat (FRAME_PERIOD * 4) @(posedge pix_clk);
        if (alpha_o == 8'd255) begin
            fails = fails + 1;
            $display("FAIL reset: transition did not start before reset");
        end
        pix_rst = 1'b1;
        repeat (3) @(posedge pix_clk);
        pix_rst = 1'b0;
        repeat (FRAME_PERIOD * 3) @(posedge pix_clk);
        if (busy || alpha_o !== 8'd255 || mode_o !== 2'd0) begin
            fails = fails + 1;
            $display("FAIL reset: state not idle after reset (busy=%b alpha=%0d mode=%0d)",
                     busy, alpha_o, mode_o);
        end

        // 复位后正常切一次，确认状态机仍可用
        clear_rec;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd3, 1'b0);
        wait (busy);
        wait_idle();
        if (commit_edges - e0 != 1 || active_index !== 2'd3 || alpha_o !== 8'd255) begin
            fails = fails + 1;
            $display("FAIL reset: transition after reset broken");
        end

        // ================= 9) 旁路参数 =================
        bp_index = 2'd2;
        @(negedge sd_clk);
        bp_toggle = 1'b1;
        repeat (FRAME_PERIOD * 2) @(posedge pix_clk);
        if (bp_commit_toggle !== 1'b1 || bp_commit_index !== 2'd2) begin
            fails = fails + 1;
            $display("FAIL bypass: request not forwarded immediately");
        end
        if (bp_mode !== 2'd0 || bp_alpha !== 8'd255 || bp_busy) begin
            fails = fails + 1;
            $display("FAIL bypass: effect active in bypass mode");
        end

        // ================= 10) 首图：目标等于当前 Bank 且无有效画面 =================
        // 上电首图提交时 display_valid=0、目标 Bank 已经是当前 Bank，
        // 必须静默消费：不提交、不做效果，display_valid 拉高后直接显示该 Bank。
        sd_player = 1'b0;
        clear_rec;
        e0 = commit_edges;
        a0 = active_changes;
        sd_req(2'd3, 1'b0);
        repeat (FRAME_PERIOD * 2) @(posedge pix_clk);
        if (busy || commit_edges != e0 || active_changes != a0 || n_alpha != 1) begin
            fails = fails + 1;
            $display("FAIL first-image: target==active must be consumed silently");
        end
        sd_player = 1'b1;

        if (midframe_bad != 0) begin
            fails = fails + midframe_bad;
            $display("FAIL transition: %0d mid-frame value change(s)", midframe_bad);
        end
        if (commit_bad != 0) begin
            fails = fails + commit_bad;
            $display("FAIL transition: %0d bad commit(s)", commit_bad);
        end

        if (fails == 0) begin
            $display("PASS video_transition: %0d checks, %0d frames simulated", checks, frame_no);
            $finish;
        end else begin
            $display("FAIL video_transition: %0d failure(s) over %0d checks", fails, checks);
            $fatal(1);
        end
    end

endmodule
