`timescale 1ns/1ps

// 转场控制器：把 sd_card_clk 域的“图片提交请求”改造成
// “先遮住画面 → 安全期提交 Bank → 确认真实切换 → 再揭示”的帧级状态机。
//
// 设计要点（详见任务 design.md）：
//  1. sd_card_bmp 保持原有提交契约：frame_commit_toggle 翻转的同时更新
//     disp_buf_idx / commit_is_auto，并在下一次提交前保持不变。
//  2. 本模块用 2FF + 稳定窗口采样 toggle 与多位目标编号，窗口结束后才采样，
//     避免“同步 toggle 却读正在变化的数据”。
//  3. 对外输出自己的 commit_toggle/commit_index，只有画面完全遮蔽后才翻转
//     一次；确认条件是 four_bank_frame_commit 真正更新 active_index。
//  4. alpha/cover_x/mode 只在 frame_start 变化，一帧内恒定。
//  5. 转场忙时最多缓存 1 个请求，其余丢弃并给出 req_dropped 脉冲。
//  6. 提交确认超时 → abort，从当前已提交 Bank 淡入/揭示，绝不永久全黑。
//
// FADE_FRAMES/WIPE_FRAMES 为 0 时是回退旁路：请求立即转发提交，不做效果。
module video_transition #(
    parameter integer FADE_FRAMES = 16,      // 合法 0..255，0=旁路
    parameter integer WIPE_FRAMES = 16,      // 合法 0..H_ACTIVE，0=旁路
    parameter integer H_ACTIVE    = 640,
    parameter integer READY_FRAMES = 2,      // 确认后再等待的帧数
    parameter integer COMMIT_TIMEOUT_FRAMES = 8,
    parameter integer SETTLE_CYCLES = 4      // 多位数据采样前的稳定窗口（像素时钟）
)(
    // ---- sd_card_clk 域（异步） ----
    input  wire       sd_commit_toggle,
    input  wire [1:0] sd_pending_index,
    input  wire [3:0] sd_bank_valid,
    input  wire       sd_commit_is_auto,
    input  wire       sd_player_active,
    // ---- 像素域 ----
    input  wire       pix_clk,
    input  wire       pix_rst,          // 高有效
    input  wire       frame_start,      // vs 下降沿单拍（场消隐内）
    input  wire [1:0] active_index,     // 已提交显示 Bank（同域）
    // ---- 提交给 four_bank_frame_commit ----
    output wire       commit_toggle,
    output wire [1:0] commit_index,
    output wire [3:0] commit_valid,
    // ---- 像素效果 ----
    output wire [1:0] mode,             // 0=旁路 1=整帧Alpha 2=幕布
    output wire [7:0] alpha,
    output wire [10:0] cover_x,
    output wire       wipe_reveal,
    // ---- 观测/统计 ----
    output wire       busy,
    output reg        req_dropped,
    output reg        stat_aborted,
    output reg        stat_invalid,
    output reg  [7:0] stat_completed
);

    localparam [8:0]  FADE_STEP = (FADE_FRAMES <= 0) ? 9'd1 : ((255 + FADE_FRAMES - 1) / FADE_FRAMES);
    localparam [10:0] WIPE_STEP = (WIPE_FRAMES <= 0) ? 11'd1 : ((H_ACTIVE + WIPE_FRAMES - 1) / WIPE_FRAMES);

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_ARM    = 3'd7;
    localparam [2:0] S_OUT    = 3'd1;
    localparam [2:0] S_COVER  = 3'd2;
    localparam [2:0] S_COMMIT = 3'd3;
    localparam [2:0] S_READY  = 3'd4;
    localparam [2:0] S_IN     = 3'd5;
    localparam [2:0] S_REVEAL = 3'd6;

    localparam [1:0] M_PASS = 2'd0;
    localparam [1:0] M_FADE = 2'd1;
    localparam [1:0] M_WIPE = 2'd2;

    // 参数合法性：非法组合在 elaboration 阶段以未定义模块报错。
    generate
        if (FADE_FRAMES < 0 || FADE_FRAMES > 255 ||
            WIPE_FRAMES < 0 || WIPE_FRAMES > H_ACTIVE ||
            H_ACTIVE <= 0 || READY_FRAMES < 0 || COMMIT_TIMEOUT_FRAMES < 1) begin : g_param_error
            invalid_video_transition_parameter u_invalid_parameter();
        end
    endgenerate

    localparam BYPASS = (FADE_FRAMES == 0) || (WIPE_FRAMES == 0);

    // ---------------- 跨时钟域采样 ----------------
    (* ASYNC_REG = "TRUE" *) reg        tgl_meta, tgl_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0]  idx_meta, idx_sync;
    (* ASYNC_REG = "TRUE" *) reg [3:0]  vld_meta, vld_sync;
    (* ASYNC_REG = "TRUE" *) reg        auto_meta, auto_sync;
    (* ASYNC_REG = "TRUE" *) reg        act_meta, act_sync;

    // ---------------- 状态寄存器 ----------------
    reg [2:0]  state;
    reg [1:0]  mode_q;
    reg [7:0]  alpha_q;
    reg [10:0] cover_q;
    reg [1:0]  tgt_idx;
    reg        tgt_auto;
    reg        commit_toggle_q;
    reg [1:0]  commit_index_q;
    reg [3:0]  commit_wait_cnt;
    reg [3:0]  ready_cnt;
    reg [3:0]  init_cnt;

    // ---------------- 请求采样 ----------------
    reg        req_seen;
    reg [3:0]  settle_cnt;
    reg        req_fire;
    reg        req_valid;
    reg [1:0]  cand_idx;
    reg        cand_auto;

    // ---------------- 排队 ----------------
    reg        q_valid;
    reg [1:0]  q_idx;
    reg        q_auto;

    assign commit_toggle = commit_toggle_q;
    assign commit_index  = commit_index_q;
    assign commit_valid  = vld_sync;
    assign mode          = mode_q;
    assign alpha         = alpha_q;
    assign cover_x       = cover_q;
    assign wipe_reveal   = (state == S_REVEAL);
    assign busy          = (state != S_IDLE);

    // 请求动作：0=忙（交排队），1=静默消费，2=立即提交（无有效画面/旁路），3=启动转场
    function [1:0] request_action;
        input [2:0] cur_state;
        input [1:0] cur_active;
        input [3:0] valid_mask;
        input       player_on;
        input [1:0] cand;
        begin
            if (cur_state != S_IDLE)
                request_action = 2'd0;
            else if (cand == cur_active)
                request_action = 2'd1;      // 目标已是当前 Bank（含首图 index0）
            else if (!valid_mask[cand])
                request_action = 2'd1;      // 无效目标：不提交
            else if (!player_on)
                request_action = 2'd2;      // 无有效画面：直接提交，不做效果
            else
                request_action = 2'd3;      // 正常转场
        end
    endfunction

    wire [1:0] act_now = request_action(state, active_index, vld_sync, act_sync, cand_idx);
    wire [1:0] act_q   = request_action(state, active_index, vld_sync, act_sync, q_idx);

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            tgl_meta   <= 1'b0;
            tgl_sync   <= 1'b0;
            idx_meta   <= 2'd0;
            idx_sync   <= 2'd0;
            vld_meta   <= 4'd0;
            vld_sync   <= 4'd0;
            auto_meta  <= 1'b0;
            auto_sync  <= 1'b0;
            act_meta   <= 1'b0;
            act_sync   <= 1'b0;

            state            <= S_IDLE;
            mode_q           <= M_PASS;
            alpha_q          <= 8'd255;
            cover_q          <= 11'd0;
            tgt_idx          <= 2'd0;
            tgt_auto         <= 1'b0;
            commit_toggle_q  <= 1'b0;
            commit_index_q   <= 2'd0;
            commit_wait_cnt  <= 4'd0;
            ready_cnt        <= 4'd0;
            init_cnt         <= 4'd0;

            req_seen    <= 1'b0;
            settle_cnt  <= 4'd0;
            req_fire    <= 1'b0;
            req_valid   <= 1'b0;
            cand_idx    <= 2'd0;
            cand_auto   <= 1'b0;

            q_valid     <= 1'b0;
            q_idx       <= 2'd0;
            q_auto      <= 1'b0;

            req_dropped    <= 1'b0;
            stat_aborted   <= 1'b0;
            stat_invalid   <= 1'b0;
            stat_completed <= 8'd0;
        end else begin
            // ---- 1) 2FF 采样（源域数据与 toggle 同拍更新） ----
            tgl_meta  <= sd_commit_toggle;
            tgl_sync  <= tgl_meta;
            idx_meta  <= sd_pending_index;
            idx_sync  <= idx_meta;
            vld_meta  <= sd_bank_valid;
            vld_sync  <= vld_meta;
            auto_meta <= sd_commit_is_auto;
            auto_sync <= auto_meta;
            act_meta  <= sd_player_active;
            act_sync  <= act_meta;

            req_dropped <= 1'b0;
            req_fire    <= 1'b0;
            req_valid   <= req_fire;

            // ---- 2) 复位后先跟踪源 toggle，避免幻影请求 ----
            if (init_cnt != 4'd12) begin
                init_cnt   <= init_cnt + 4'd1;
                req_seen   <= tgl_sync;
                settle_cnt <= 4'd0;
            end else begin
                // ---- 3) toggle 变化后等待 SETTLE_CYCLES 再采样多位数据 ----
                if (tgl_sync != req_seen) begin
                    if (settle_cnt < SETTLE_CYCLES[3:0]) begin
                        settle_cnt <= settle_cnt + 4'd1;
                    end else begin
                        cand_idx   <= idx_sync;
                        cand_auto  <= auto_sync;
                        req_fire   <= 1'b1;
                        req_seen   <= tgl_sync;
                        settle_cnt <= 4'd0;
                    end
                end else begin
                    settle_cnt <= 4'd0;
                end
            end

            // ---- 4) 请求分派（优先于帧步进，保证同一拍不丢请求） ----
            if (req_valid) begin
                if (BYPASS) begin
                    commit_index_q  <= cand_idx;
                    commit_toggle_q <= ~commit_toggle_q;
                    stat_completed  <= stat_completed + 8'd1;
                end else if (state != S_IDLE) begin
                    if (!q_valid) begin
                        q_valid <= 1'b1;
                        q_idx   <= cand_idx;
                        q_auto  <= cand_auto;
                    end else begin
                        req_dropped <= 1'b1;
                    end
                end else begin
                    case (act_now)
                        2'd1: begin
                            if (!vld_sync[cand_idx])
                                stat_invalid <= 1'b1;
                        end
                        2'd2: begin
                            commit_index_q  <= cand_idx;
                            commit_toggle_q <= ~commit_toggle_q;
                            stat_completed  <= stat_completed + 8'd1;
                        end
                        2'd3: begin
                            tgt_idx         <= cand_idx;
                            tgt_auto        <= cand_auto;
                            commit_wait_cnt <= 4'd0;
                            ready_cnt       <= 4'd0;
                            // 只锁存目标；mode/alpha/cover 留到下一个帧边界再改，
                            // 保证一帧内效果参数完全不变。
                            state           <= S_ARM;
                        end
                        default: ;
                    endcase
                end
            end else if (state == S_IDLE && q_valid) begin
                case (act_q)
                    2'd1: begin
                        q_valid <= 1'b0;
                        if (!vld_sync[q_idx])
                            stat_invalid <= 1'b1;
                    end
                    2'd2: begin
                        q_valid         <= 1'b0;
                        commit_index_q  <= q_idx;
                        commit_toggle_q <= ~commit_toggle_q;
                        stat_completed  <= stat_completed + 8'd1;
                    end
                    2'd3: begin
                        q_valid         <= 1'b0;
                        tgt_idx         <= q_idx;
                        tgt_auto        <= q_auto;
                        commit_wait_cnt <= 4'd0;
                        ready_cnt       <= 4'd0;
                        state           <= S_ARM;
                    end
                    default: ;
                endcase
            end

            // ---- 5) 帧边界步进（只推进非空闲状态；旁路时不启动） ----
            if (frame_start && !BYPASS && state != S_IDLE) begin
                case (state)
                    S_ARM: begin
                        // 帧边界才切换效果模式：本帧之前画面完全不受影响
                        mode_q  <= tgt_auto ? M_WIPE : M_FADE;
                        alpha_q <= 8'd255;
                        cover_q <= 11'd0;
                        state   <= tgt_auto ? S_COVER : S_OUT;
                    end

                    S_OUT: begin
                        if (alpha_q <= FADE_STEP[7:0]) begin
                            // 本帧恰好全黑：同一拍提交 Bank，保证提交发生在完全遮蔽后
                            alpha_q         <= 8'd0;
                            state           <= S_COMMIT;
                            commit_index_q  <= tgt_idx;
                            commit_toggle_q <= ~commit_toggle_q;
                            commit_wait_cnt <= 4'd0;
                        end else begin
                            alpha_q <= alpha_q - FADE_STEP[7:0];
                        end
                    end

                    S_COVER: begin
                        if (cover_q + WIPE_STEP >= H_ACTIVE[10:0]) begin
                            cover_q         <= H_ACTIVE[10:0];
                            state           <= S_COMMIT;
                            commit_index_q  <= tgt_idx;
                            commit_toggle_q <= ~commit_toggle_q;
                            commit_wait_cnt <= 4'd0;
                        end else begin
                            cover_q <= cover_q + WIPE_STEP;
                        end
                    end

                    S_COMMIT: begin
                        if (active_index == tgt_idx) begin
                            state     <= S_READY;
                            ready_cnt <= 4'd0;
                        end else if (commit_wait_cnt >= COMMIT_TIMEOUT_FRAMES[3:0]) begin
                            // 提交未确认：撤销待提交请求（再翻一次 toggle 使奇偶回到
                            // four_bank 已见值），从当前已提交 Bank 恢复显示，绝不永久全黑
                            stat_aborted    <= 1'b1;
                            commit_toggle_q <= ~commit_toggle_q;
                            alpha_q         <= 8'd0;
                            cover_q         <= 11'd0;
                            state           <= tgt_auto ? S_REVEAL : S_IN;
                        end else begin
                            commit_wait_cnt <= commit_wait_cnt + 4'd1;
                        end
                    end

                    S_READY: begin
                        if (ready_cnt + 4'd1 >= READY_FRAMES[3:0]) begin
                            state   <= tgt_auto ? S_REVEAL : S_IN;
                            alpha_q <= 8'd0;
                            cover_q <= 11'd0;
                        end else begin
                            ready_cnt <= ready_cnt + 4'd1;
                        end
                    end

                    S_IN: begin
                        if ({1'b0, alpha_q} + FADE_STEP >= 9'd255) begin
                            alpha_q <= 8'd255;
                            cover_q <= 11'd0;
                            state   <= S_IDLE;
                            mode_q  <= M_PASS;
                            stat_completed <= stat_completed + 8'd1;
                        end else begin
                            alpha_q <= alpha_q + FADE_STEP[7:0];
                        end
                    end

                    S_REVEAL: begin
                        if (cover_q + WIPE_STEP >= H_ACTIVE[10:0]) begin
                            cover_q <= H_ACTIVE[10:0];
                            alpha_q <= 8'd255;
                            state   <= S_IDLE;
                            mode_q  <= M_PASS;
                            stat_completed <= stat_completed + 8'd1;
                        end else begin
                            cover_q <= cover_q + WIPE_STEP;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
