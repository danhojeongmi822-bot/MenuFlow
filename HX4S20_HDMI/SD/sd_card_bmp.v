
`timescale 1ns/1ps

//**核心控制**：BMP扫描、图片加载、按键消抖、自动轮播、四Bank缓存切换

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer LONG_PRESS_MS     = 1000,
    parameter integer AUTO_PLAY_MS      = 3000,
    parameter integer SD_TIMEOUT_CYCLES = 50_000_000,
    parameter integer USE_FAT32         = 1'b0
)(
    input                       clk,
    input                       rst,
    input                       sdram_init_done,
    input                       key_next,
    input                       key_auto,
    input                       auto_hold,      // 1=暂停自动轮播（管理模式）；不改变 auto_play_en 记忆
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output reg [3:0]            bank_valid,
    output reg                  frame_commit_toggle,
    output reg                  commit_is_auto,   // 本次提交是否由自动轮播触发
    output reg                  auto_play_en,
    output reg [7:0]            osd_error_code,

    // ---- PCM 音频可选资源（PIC1..4.PCM）与音频 owner 扇区总线 ----
    output wire [3:0]           pcm_valid,
    output wire [31:0]          pcm_cluster0, pcm_cluster1, pcm_cluster2, pcm_cluster3,
    output wire [31:0]          pcm_size0, pcm_size1, pcm_size2, pcm_size3,
    output wire [7:0]           fs_sectors_per_cluster,
    output wire [31:0]          fs_fat_start_lba,
    output wire [31:0]          fs_data_start_lba,
    output wire [31:0]          fs_max_cluster,
    output wire                 sd_init_done_out,
    input                       audio_req,
    input  [31:0]               audio_lba,
    output wire                 audio_busy,
    output wire                 audio_valid,
    output wire [7:0]           audio_byte,
    output wire [8:0]           audio_byte_index,
    output wire                 audio_done,
    output wire [7:0]           audio_error,
    output wire                 audio_abort,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_stable;
reg  key_auto_stable_d;
wire key_auto_release;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;
wire [2:0]       bmp_error;
wire             bmp_load_error;
wire             bmp_load_success;
wire             sd_recover_req;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              scan_complete;
reg              first_image_committed;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg              load_is_preload;     // 后台预加载完成后只置 valid，不提交显示
reg              load_is_auto;        // 当前加载任务是否由自动轮播发起
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              prev_req_pending;
reg              load_busy;
reg [31:0]       long_press_cnt;
reg              long_press_marked;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              source_done_toggle;
reg              initial_load_exhausted;
reg [3:0]        bank_blocked;
reg              scan_recovery_exhausted;
reg              recovery_pending;
reg              recovery_auto_context;
reg [1:0]        recovery_retry_count;
reg [2:0]        recovery_candidates_tried;
reg [1:0]        recovery_start_idx;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;
wire [1:0] prev_from_current;
wire [31:0] auto_play_cycles;
wire [31:0] long_press_cycles;
wire [3:0] bmp_state_code;
wire long_press_reached;
wire next_issue_fire;
wire scan_available;
wire [1:0] preload_idx;
wire preload_pending;

assign sd_init_done_out = sd_init_done;
assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_play_cycles = (CLK_FREQ_HZ / 1000) * AUTO_PLAY_MS;
assign long_press_cycles = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
assign auto_tick  = (auto_play_cycles <= 32'd1) || (auto_cnt >= (auto_play_cycles - 32'd1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign prev_from_current = prev_index_limited(img_idx, img_found_count);
assign scan_available = scan_done || scan_complete;
assign next_issue_fire = scan_available && sdram_init_done && bmp_ready && display_valid &&
                         !load_busy && next_req_pending && (img_found_count > 3'd1);
assign preload_idx = first_invalid_bank(bank_valid, bank_blocked, img_found_count);
assign preload_pending = scan_available && first_image_committed && display_valid &&
                         bank_valid[img_idx] && !load_busy &&
                         (img_found_count == 3'd4) &&
                         ((bank_valid | bank_blocked) != ((4'd1 << img_found_count) - 1'b1));
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

// OSD 错误码：SD 未就绪优先显示 E1；错误事件锁存为 01..04；
// 扫描完成且无可用图片显示 E0；成功事件或初始化恢复后清零。
// 该状态只用于显示，不参与原有的提交/恢复门控。
always @(posedge clk or posedge rst) begin
    if (rst)
        osd_error_code <= 8'hE1;
    else if (!sd_init_done)
        osd_error_code <= 8'hE1;
    else if (bmp_error != 3'd0)
        osd_error_code <= {5'd0, bmp_error};
    else if (scan_done && (img_found_count == 3'd0))
        osd_error_code <= 8'hE0;
    else if (bmp_load_success || scan_done)
        osd_error_code <= 8'h00;
    else if (osd_error_code == 8'hE1)
        osd_error_code <= 8'h00;
end
assign key_auto_release = !key_auto_stable_d && key_auto_stable;
assign long_press_reached = !key_auto_stable && !long_press_marked &&
                            ((long_press_cycles <= 32'd1) ||
                             (long_press_cnt >= (long_press_cycles - 32'd1)));

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(),
    .button_stable_out(key_auto_stable)
);

// 将下一张按键请求从加载状态机中隔离，避免按键脉冲直接进入长优先级链。
// 请求在扫描/当前写图期间保持，真正发起下一张加载时清除。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_req_pending <= 1'b0;
    end else if (!sdram_init_done || !sd_init_done || scan_start_pulse) begin
        next_req_pending <= 1'b0;
    end else if (next_issue_fire) begin
        next_req_pending <= 1'b0;
    end else if (key_next_press && (img_found_count > 3'd1)) begin
        next_req_pending <= 1'b1;
    end
end

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: prev_index_limited = 2'd0;
            3'd1: prev_index_limited = 2'd0;
            3'd2: prev_index_limited = (cur == 2'd0) ? 2'd1 : (cur - 2'd1);
            3'd3: prev_index_limited = (cur == 2'd0) ? 2'd2 : (cur - 2'd1);
            default: prev_index_limited = (cur == 2'd0) ? 2'd3 : (cur - 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] first_invalid_bank;
    input [3:0] valid_mask;
    input [3:0] blocked_mask;
    input [2:0] count;
    begin
        first_invalid_bank = 2'd0;
        if (count > 3'd0 && !valid_mask[0] && !blocked_mask[0])
            first_invalid_bank = 2'd0;
        else if (count > 3'd1 && !valid_mask[1] && !blocked_mask[1])
            first_invalid_bank = 2'd1;
        else if (count > 3'd2 && !valid_mask[2] && !blocked_mask[2])
            first_invalid_bank = 2'd2;
        else if (count > 3'd3 && !valid_mask[3] && !blocked_mask[3])
            first_invalid_bank = 2'd3;
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        scan_complete         <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        load_is_preload       <= 1'b0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        prev_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        long_press_cnt        <= 32'd0;
        long_press_marked     <= 1'b0;
        key_auto_stable_d     <= 1'b1;
        source_done_seen      <= 1'b0;
        source_done_toggle    <= 1'b0;
        initial_load_exhausted <= 1'b0;
        bank_valid            <= 4'b0000;
        bank_blocked          <= 4'b0000;
        frame_commit_toggle   <= 1'b0;
        commit_is_auto        <= 1'b0;
        load_is_auto          <= 1'b0;
        scan_recovery_exhausted <= 1'b0;
        recovery_pending      <= 1'b0;
        recovery_auto_context <= 1'b0;
        recovery_retry_count  <= 2'd0;
        recovery_candidates_tried <= 3'd0;
        recovery_start_idx    <= 2'd0;
        display_valid         <= 1'b0;
        state_code            <= 4'd1;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        // 写请求发出时锁存完成 toggle 基线。SDRAM 可能先于 BMP 末扇区
        // 报告完成，也可能稍后完成；基线不能在 bmp_load_success 时才采样。
        if (load_start_pulse)
            source_done_toggle <= wrfin_tgl_sync[2];

        if (!sd_init_done && !recovery_pending && !bmp_load_error) begin
            scan_kicked           <= 1'b0;
            scan_complete         <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            load_is_preload       <= 1'b0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            prev_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            long_press_cnt        <= 32'd0;
            long_press_marked     <= 1'b0;
            key_auto_stable_d     <= 1'b1;
            source_done_seen      <= 1'b0;
            bank_valid            <= 4'b0000;
            bank_blocked          <= 4'b0000;
            frame_commit_toggle   <= 1'b0;
        commit_is_auto        <= 1'b0;
        load_is_auto          <= 1'b0;
            initial_load_exhausted <= 1'b0;
            display_valid         <= 1'b0;
            state_code            <= 4'd1;
        end else if (!sdram_init_done) begin
            // SDRAM 尚未完成初始化时，保持 SD 可用但禁止扫描、加载和提交。
            // 该许可撤销也覆盖运行中重新启动的场景。
            scan_kicked           <= 1'b0;
            scan_complete         <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            load_is_preload       <= 1'b0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            prev_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            long_press_cnt        <= 32'd0;
            long_press_marked     <= 1'b0;
            source_done_seen      <= 1'b0;
            source_done_toggle    <= wrfin_tgl_sync[2];
            bank_valid            <= 4'b0000;
            bank_blocked          <= 4'b0000;
            frame_commit_toggle   <= 1'b0;
        commit_is_auto        <= 1'b0;
        load_is_auto          <= 1'b0;
            initial_load_exhausted <= 1'b0;
            scan_recovery_exhausted <= 1'b0;
            recovery_pending      <= 1'b0;
            recovery_auto_context <= 1'b0;
            recovery_retry_count  <= 2'd0;
            recovery_candidates_tried <= 3'd0;
            recovery_start_idx    <= 2'd0;
            display_valid         <= 1'b0;
            scan_start_pulse      <= 1'b0;
            load_start_pulse      <= 1'b0;
            state_code            <= 4'd1;
        end else if (!sd_init_done) begin
            // SD 子系统局部恢复期间保留候选表、已显示帧和图片编号，
            // 等初始化完成后由 recovery_pending 重新发起当前事务。
            if (bmp_load_error) begin
                recovery_pending          <= 1'b1;
                recovery_auto_context     <= (!display_valid) || auto_play_en;
                if (!recovery_pending) begin
                    recovery_retry_count      <= 2'd0;
                    recovery_candidates_tried <= 3'd1;
                    recovery_start_idx        <= load_idx;
                end
            end
            load_busy        <= 1'b0;
            source_done_seen  <= 1'b0;
            source_done_toggle <= wrfin_tgl_sync[2];
            scan_start_pulse  <= 1'b0;
            load_start_pulse  <= 1'b0;
        end else begin
            key_auto_stable_d <= key_auto_stable;
            // state_code 对外显示当前图片编号（1~4），不再透传 bmp_read 的内部状态码
            state_code <= {2'b0, img_idx} + 4'd1;

            if (bmp_load_error) begin
                recovery_pending          <= 1'b1;
                recovery_auto_context     <= (!display_valid) || auto_play_en;
                if (!recovery_pending) begin
                    recovery_retry_count      <= 2'd0;
                    recovery_candidates_tried <= 3'd1;
                    recovery_start_idx        <= load_idx;
                end
                load_busy                 <= 1'b0;
                source_done_seen          <= 1'b0;
            end

            // 扫描超时也必须有界：局部 SD 恢复完成后不再无条件重启扫描。
            if (sd_recover_req && !load_busy && !bmp_load_error)
                scan_recovery_exhausted <= 1'b1;

            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_done)
                scan_complete <= 1'b1;

            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_load_success) begin
                source_done_seen <= 1'b1;
            end

            // 只有真正收到 write_finish_toggle 脉冲，才确认写入完成；后台预加载只置 valid，不能切换显示。
            if (load_busy && source_done_seen &&
                (wrfin_tgl_sync[2] != source_done_toggle)) begin
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                bank_valid[load_idx]  <= 1'b1;
                bank_blocked[load_idx] <= 1'b0;
                if (!load_is_preload) begin
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    frame_commit_toggle   <= ~frame_commit_toggle;
                    commit_is_auto        <= load_is_auto;
                    state_code            <= {2'b0, load_idx} + 4'd1;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                end
                recovery_pending      <= 1'b0;
                recovery_retry_count  <= 2'd0;
                recovery_candidates_tried <= 3'd0;
                initial_load_exhausted <= 1'b0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && !scan_recovery_exhausted && !sd_recover_req &&
                sdram_init_done && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                prev_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                scan_complete         <= 1'b0;
                bank_valid            <= 4'b0000;
                bank_blocked          <= 4'b0000;
                frame_commit_toggle   <= 1'b0;
        commit_is_auto        <= 1'b0;
        load_is_auto          <= 1'b0;
            end else begin
                // 自动播放计时：只有当前没有写图任务时才计时
                if (scan_available && auto_play_en && key_auto_stable && !key_next_press && !long_press_reached && !key_auto_release && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1) && !auto_hold) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // KEY2 长按约 LONG_PRESS_MS 后只产生一次上一张请求；松开后
                // 若从未达到长按阈值，才把这次操作作为短按切换自动轮播。
                if (!key_auto_stable) begin
                    if (long_press_reached) begin
                        long_press_marked <= 1'b1;
                        if (img_found_count > 3'd1)
                            prev_req_pending <= 1'b1;
                        auto_cnt          <= 32'd0;
                    end else if (long_press_cnt < long_press_cycles) begin
                        long_press_cnt <= long_press_cnt + 32'd1;
                    end
                end else begin
                    long_press_cnt <= 32'd0;
                    if (key_auto_release) begin
                        if (!long_press_marked && scan_available && (img_found_count > 3'd1))
                            auto_play_en <= ~auto_play_en;
                        auto_cnt          <= 32'd0;
                        long_press_marked <= 1'b0;
                    end
                end

                // 首图自动加载到 buffer0
                if (recovery_pending && sdram_init_done && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    if (recovery_retry_count == 2'd0) begin
                        // 第一次失败只重试原候选一次。
                        load_idx         <= recovery_start_idx;
                        load_sector      <= sector_lut(recovery_start_idx);
                        pending_buf_idx  <= recovery_start_idx;
                        write_buf_idx     <= recovery_start_idx;
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        recovery_retry_count <= 2'd1;
                        load_is_auto     <= recovery_auto_context;
                    end else if (recovery_auto_context &&
                                 (recovery_candidates_tried < img_found_count)) begin
                        // 自动/首图恢复最多遍历登记候选一轮。
                        load_idx         <= next_index_limited(recovery_start_idx, img_found_count);
                        load_sector      <= sector_lut(next_index_limited(recovery_start_idx, img_found_count));
                        pending_buf_idx  <= next_index_limited(recovery_start_idx, img_found_count);
                        write_buf_idx     <= next_index_limited(recovery_start_idx, img_found_count);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        recovery_start_idx <= next_index_limited(recovery_start_idx, img_found_count);
                        recovery_candidates_tried <= recovery_candidates_tried + 3'd1;
                        load_is_auto     <= recovery_auto_context;
                    end else begin
                        // 手动失败保持当前帧；首图全部失败则保持空白待机。
                        recovery_pending <= 1'b0;
                        recovery_retry_count <= 2'd0;
                        load_busy <= 1'b0;
                        bank_blocked[load_idx] <= 1'b1;
                        if (!first_image_committed)
                            initial_load_exhausted <= 1'b1;
                    end
                end else if (scan_available && !first_image_committed && !initial_load_exhausted &&
                             sdram_init_done && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_is_preload  <= 1'b0;
                    load_is_auto     <= 1'b0;   // 首图不是轮播
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 首图提交后，把其余已扫描图片预加载到各自固定 Bank。
                // 这条路径优先于按键和自动轮播，避免首次切图再次访问 TF。
                else if (preload_pending && sdram_init_done && bmp_ready) begin
                    load_idx         <= preload_idx;
                    load_sector      <= sector_lut(preload_idx);
                    pending_buf_idx  <= preload_idx;
                    write_buf_idx    <= preload_idx;
                    load_is_preload  <= 1'b1;
                    load_is_auto     <= 1'b0;
                    bank_blocked[preload_idx] <= 1'b0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 已完成的图片只提交 Bank 索引，不重新读取 TF。
                else if (next_issue_fire && bank_valid[next_from_current]) begin
                    disp_buf_idx      <= next_from_current;
                    img_idx           <= next_from_current;
                    state_code        <= {2'b0, next_from_current} + 4'd1;
                    frame_commit_toggle <= ~frame_commit_toggle;
                    commit_is_auto    <= 1'b0;   // 手动下一张（命中缓存）
                    auto_cnt           <= 32'd0;
                end
                // 手动下一张：无效 Bank 才重新加载，目标固定为图片编号对应 Bank。
                else if (next_issue_fire) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_from_current;
                    write_buf_idx     <= next_from_current;
                    load_is_preload  <= 1'b0;
                    load_is_auto     <= 1'b0;   // 手动下一张
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 上一张命中缓存时同样只提交索引。
                else if (scan_available && sdram_init_done && display_valid && !load_busy &&
                         prev_req_pending && (img_found_count > 3'd1) &&
                         bank_valid[prev_from_current]) begin
                    prev_req_pending <= 1'b0;
                    disp_buf_idx      <= prev_from_current;
                    img_idx           <= prev_from_current;
                    state_code        <= {2'b0, prev_from_current} + 4'd1;
                    frame_commit_toggle <= ~frame_commit_toggle;
                    commit_is_auto    <= 1'b0;   // 手动上一张（命中缓存）
                    auto_cnt           <= 32'd0;
                end
                // 上一张请求排在下一张之后，确保下一张优先
                else if (scan_available && sdram_init_done && bmp_ready && display_valid && !load_busy && prev_req_pending && (img_found_count > 3'd1)) begin
                    load_idx         <= prev_from_current;
                    load_sector      <= sector_lut(prev_from_current);
                    pending_buf_idx  <= prev_from_current;
                    write_buf_idx     <= prev_from_current;
                    load_is_preload  <= 1'b0;
                    load_is_auto     <= 1'b0;   // 手动上一张
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放命中缓存时不发起文件加载。
                else if (scan_available && sdram_init_done && display_valid && !load_busy &&
                         auto_play_en && key_auto_stable && !key_next_press &&
                         !key_auto_release && !long_press_reached && auto_tick &&
                         (img_found_count > 3'd1) && !auto_hold &&
                         bank_valid[next_from_current]) begin
                    disp_buf_idx        <= next_from_current;
                    img_idx             <= next_from_current;
                    state_code          <= {2'b0, next_from_current} + 4'd1;
                    frame_commit_toggle <= ~frame_commit_toggle;
                    commit_is_auto      <= 1'b1;   // 自动轮播（命中缓存）
                    auto_cnt            <= 32'd0;
                end
                // 自动播放下一张：无效 Bank 才访问 TF。
                else if (scan_available && sdram_init_done && bmp_ready && display_valid && !load_busy && auto_play_en && key_auto_stable && !key_next_press && !key_auto_release && !long_press_reached && auto_tick && (img_found_count > 3'd1) && !auto_hold) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_from_current;
                    write_buf_idx     <= next_from_current;
                    load_is_preload  <= 1'b0;
                    load_is_auto     <= 1'b1;   // 自动轮播下一张
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

generate
if (USE_FAT32) begin : g_fat32_path
fat32_bmp_engine #(
    .SD_TIMEOUT_CYCLES     (SD_TIMEOUT_CYCLES)
) fat32_bmp_engine_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),
    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),
    .load_start             (load_start_pulse),
    .load_sector            (load_sector),
    .sd_init_done           (sd_init_done),
    .state_code             (bmp_state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .bmp_error              (bmp_error),
    .load_error             (bmp_load_error),
    .load_success            (bmp_load_success),
    .sd_recover_req         (sd_recover_req),
    .pcm_valid              (pcm_valid),
    .pcm_cluster0           (pcm_cluster0), .pcm_cluster1 (pcm_cluster1),
    .pcm_cluster2           (pcm_cluster2), .pcm_cluster3 (pcm_cluster3),
    .pcm_size0              (pcm_size0),    .pcm_size1    (pcm_size1),
    .pcm_size2              (pcm_size2),    .pcm_size3    (pcm_size3),
    .fs_sectors_per_cluster (fs_sectors_per_cluster),
    .fs_fat_start_lba       (fs_fat_start_lba),
    .fs_data_start_lba      (fs_data_start_lba),
    .fs_max_cluster         (fs_max_cluster),
    .fs_root_cluster        (),
    .audio_req              (audio_req),
    .audio_lba              (audio_lba),
    .audio_busy             (audio_busy),
    .audio_valid            (audio_valid),
    .audio_byte             (audio_byte),
    .audio_byte_index       (audio_byte_index),
    .audio_done             (audio_done),
    .audio_error            (audio_error),
    .audio_abort            (audio_abort),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO)
);
end else begin : g_legacy_path
// 旧路径不提供 PCM 资源：把新增输出接到常量，避免悬空。
assign pcm_valid = 4'b0000;
assign pcm_cluster0 = 32'd0; assign pcm_cluster1 = 32'd0;
assign pcm_cluster2 = 32'd0; assign pcm_cluster3 = 32'd0;
assign pcm_size0 = 32'd0; assign pcm_size1 = 32'd0;
assign pcm_size2 = 32'd0; assign pcm_size3 = 32'd0;
assign fs_sectors_per_cluster = 8'd1;
assign fs_fat_start_lba = 32'd0;
assign fs_data_start_lba = 32'd0;
assign fs_max_cluster = 32'd0;
assign audio_busy = 1'b0;
assign audio_valid = 1'b0;
assign audio_byte = 8'd0;
assign audio_byte_index = 9'd0;
assign audio_done = 1'b0;
assign audio_error = 8'd0;
assign audio_abort = 1'b0;

bmp_read #(
    .SD_TIMEOUT_CYCLES     (SD_TIMEOUT_CYCLES)
) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (bmp_state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .bmp_error              (bmp_error),
    .load_error             (bmp_load_error),
    .load_success           (bmp_load_success),
    .sd_recover_req         (sd_recover_req)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .sd_recover_req         (sd_recover_req),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);
end
endgenerate

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output reg  button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
        button_stable_out <= 1'b1;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                button_stable_out <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
