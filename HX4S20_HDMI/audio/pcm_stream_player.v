`timescale 1ns/1ps

// TF 卡 PCM 流式播放器（裸 16 bit signed 小端、单声道、48 kHz）。
//
// 两个时钟域：
//   写侧 I_sd_clk  (100 MHz)：驱动 FAT32 文件流、收字节拼样本、写环形缓冲。
//   读侧 I_aud_clk (25 MHz) ：按 I_sample_tick 消费样本，送 HDMI 音频链。
//
// 流量控制（关键设计）：
//   fat32_file_streamer 没有暂停端口，且每个扇区只发**一拍** sector_req 后进入
//   S_DATA_WAIT 等待 sector_done。因此不能直接丢弃请求（会死锁），必须
//   **锁存请求**，等环形缓冲能完整容纳一个扇区（256 样本）时再交给仲裁器：
//     grant = (level <= DEPTH - 256)
//   文件流会自然停在扇区边界，水位永不超过容量，也不会丢样本。
//
// 启动/停止跨域：
//   I_track_sel（页面编号，准静态）由视频侧保持 ≥ 4 个 SD 周期后翻转 toggle；
//   写侧 2FF 同步 toggle，看到翻转时锁存 track_sel，避免多位裸采样。
//
// 停止（重要）：
//   fat32_file_streamer 没有中止端口，且它在每个扇区只发一拍 sector_req 后
//   就进入 S_DATA_WAIT 等 sector_done。若 stop 时直接撤回请求，streamer 会永久
//   卡在 S_DATA_WAIT、file_busy 恒为 1，之后所有 file_start 都不再生效
//   （实板现象：连续切页几次后音频永久失效）。
//   因此 stop 后进入 W_ABORT 状态：继续把在途扇区读完并**丢弃数据**，
//   等 streamer 自然回到 IDLE（file_busy=0）后才真正回到 W_IDLE。
//
// 读侧契约：
//   I_sample_tick 当拍向环形缓冲发起读请求，样本在下一拍返回；本模块把返回的
//   样本**保持到下一个 tick**，使 O_sample_valid/O_sample_data 在 tick 边沿稳定。
//   这样音源选择器在 tick 上采样时不会漏掉只持续一拍的 valid。
//   下溢时返回静音，valid 仍保持，下游 HDMI 音频链永不停顿。
module pcm_stream_player #(
    parameter integer AW           = 10,
    parameter integer MAX_VISITED  = 4096,
    parameter integer FLUSH_HOLD   = 6'd32     // flush 保持的 SD 周期数（覆盖 25 MHz 读侧）
)(
    // ---------------- 写侧（SD 域） ----------------
    input  wire        I_sd_clk,
    input  wire        I_sd_rst,

    input  wire        I_start_toggle,
    input  wire        I_stop_toggle,
    input  wire [3:0]  I_track_sel,

    // 四个 PCM 资源描述（扫描完成后稳定在 SD 域）。播放时按 track_lat 选一路，
    // 选择在 SD 域完成，避免把文件描述跨域搬运。
    input  wire [3:0]  I_pcm_valid,
    input  wire [31:0] I_pcm_cluster0, I_pcm_cluster1, I_pcm_cluster2, I_pcm_cluster3,
    input  wire [31:0] I_pcm_size0, I_pcm_size1, I_pcm_size2, I_pcm_size3,
    input  wire [7:0]  I_sectors_per_cluster,
    input  wire [31:0] I_fat_start_lba,
    input  wire [31:0] I_data_start_lba,
    input  wire [31:0] I_max_cluster,
    input  wire        I_sd_link_ready,

    // 到 SD 仲裁器的扇区接口（音频 owner）
    output wire        O_sector_req,
    output wire [31:0] O_sector_lba,
    input  wire        I_sector_busy,
    input  wire        I_sector_valid,
    input  wire [7:0]  I_sector_byte,
    input  wire [8:0]  I_sector_index,
    input  wire        I_sector_done,
    input  wire [7:0]  I_sector_error,
    input  wire        I_sector_abort,

    // 状态（写域）
    output wire        O_playing,
    output wire        O_eof,
    output wire        O_err,
    output wire [10:0] O_level,

    // ---------------- 读侧（音频域） ----------------
    input  wire        I_aud_clk,
    input  wire        I_aud_rst,
    input  wire        I_sample_tick,
    input  wire        I_sample_ready,
    // 1 = 当前音源确实是 PCM：只有此时才消费环形缓冲。
    // 音频源选择在切到 PCM 前要先淡出旧源（约 16 个 tick），若期间仍消费，
    // 这部分 PCM 数据会被丢掉且听不到，因此必须由选择器给出消费许可。
    input  wire        I_pcm_consume,
    output wire [15:0] O_sample_data,
    output wire        O_sample_valid,
    output wire        O_underrun,
    output wire        O_pcm_playing
);
    // 一个扇区 = 512 B = 256 样本。授予请求时必须保证整扇区能放下，
    // 因此水位上限留出 32 样本余量（同步延迟导致的估算误差）。
    localparam integer SEC_SAMPLES = 256;
    localparam [10:0]  GRANT_LIMIT = (1 << AW) - SEC_SAMPLES - 32;  // 默认 736

    // =======================================================================
    // FAT32 文件流
    // =======================================================================
    reg         file_start_pulse;
    wire        streamer_busy, streamer_done, streamer_valid;
    wire [7:0]  streamer_byte;
    wire [31:0] streamer_offset;
    wire [7:0]  streamer_error;
    wire        str_sector_req;
    wire [31:0] str_sector_lba;
    wire        str_sector_busy, str_sector_valid;
    wire [7:0]  str_sector_byte;
    wire [8:0]  str_sector_index;
    wire        str_sector_done;
    wire [7:0]  str_sector_error;
    wire        str_sector_abort;

    reg  [31:0] file_cluster_lat;
    reg  [31:0] file_size_lat;

    // 停止时给文件流一个单拍中止，让它从 S_DATA_WAIT / S_FAT_WAIT 中退出。
    // 若不给，streamer 会一直等 sector_done，file_busy 永久为 1，
    // 之后所有 file_start 都失效（实板：连续切页 3~4 次后音频永久静音）。
    reg  streamer_abort;
    reg  abort_pending;

    // 按已锁存的页面编号（1..4）选资源；越界返回 0（上层判为无效文件）
    function [31:0] pcm_cluster_lut;
        input [3:0] sel;
        begin
            case (sel)
                4'd1: pcm_cluster_lut = I_pcm_cluster0;
                4'd2: pcm_cluster_lut = I_pcm_cluster1;
                4'd3: pcm_cluster_lut = I_pcm_cluster2;
                4'd4: pcm_cluster_lut = I_pcm_cluster3;
                default: pcm_cluster_lut = 32'd0;
            endcase
        end
    endfunction

    function [31:0] pcm_size_lut;
        input [3:0] sel;
        begin
            case (sel)
                4'd1: pcm_size_lut = I_pcm_size0;
                4'd2: pcm_size_lut = I_pcm_size1;
                4'd3: pcm_size_lut = I_pcm_size2;
                4'd4: pcm_size_lut = I_pcm_size3;
                default: pcm_size_lut = 32'd0;
            endcase
        end
    endfunction

    function pcm_entry_valid;
        input [3:0] sel;
        begin
            pcm_entry_valid = (sel >= 4'd1) && (sel <= 4'd4) && I_pcm_valid[sel - 4'd1];
        end
    endfunction

    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(MAX_VISITED)) u_file_streamer (
        .clk                 (I_sd_clk),
        .rst_n               (~I_sd_rst),
        .file_start          (file_start_pulse),
        .first_cluster       (file_cluster_lat),
        .file_size           (file_size_lat),
        .sectors_per_cluster (I_sectors_per_cluster),
        .fat_start_lba       (I_fat_start_lba),
        .data_start_lba      (I_data_start_lba),
        .max_cluster         (I_max_cluster),
        .file_busy           (streamer_busy),
        .file_done           (streamer_done),
        .file_valid          (streamer_valid),
        .file_byte           (streamer_byte),
        .file_byte_offset    (streamer_offset),
        .fs_error            (streamer_error),
        .sector_req          (str_sector_req),
        .sector_lba          (str_sector_lba),
        .sector_busy         (str_sector_busy),
        .sector_valid        (str_sector_valid),
        .sector_byte         (str_sector_byte),
        .sector_byte_index   (str_sector_index),
        .sector_done         (str_sector_done),
        .sector_error        (str_sector_error),
        .sector_abort        (str_sector_abort),
        .stream_abort        (streamer_abort)
    );

    wire [10:0] level_w;

    // 授予判断寄存一拍：level_w 来自跨域同步 + gray2bin，直接与比较器组合会
    // 形成 ring → player → adapter 的长路径（实测 SWNS -1.08 ns）。
    reg         grant_ok_q;
    always @(posedge I_sd_clk or posedge I_sd_rst) begin
        if (I_sd_rst) grant_ok_q <= 1'b0;
        else          grant_ok_q <= (level_w <= GRANT_LIMIT);
    end
    wire grant_ok = grant_ok_q;

    // 锁存文件流的单拍请求：水位不足时保持，等有空间再交给仲裁器。
    reg        req_hold;
    reg [31:0] req_lba_hold;
    // 启动请求挂起：fat32_file_streamer 只在 S_IDLE 接受 file_start 单拍，
    // 若上一笔事务未结束，脉冲会被静默吞掉，因此这里保持到它空闲。
    reg        start_pending;
    wire       req_accept = O_sector_req && I_sector_busy;   // 仲裁器已接管

    assign O_sector_req = req_hold && grant_ok && I_sd_link_ready;
    assign O_sector_lba = req_lba_hold;
    assign str_sector_busy  = I_sector_busy;
    assign str_sector_valid = I_sector_valid;
    assign str_sector_byte  = I_sector_byte;
    assign str_sector_index = I_sector_index;
    assign str_sector_done  = I_sector_done;
    assign str_sector_error = I_sector_error;
    assign str_sector_abort = I_sector_abort;

    // =======================================================================
    // 环形缓冲
    // =======================================================================
    reg         ring_wr_en;
    reg  [15:0] ring_wr_data;
    reg  [3:0]  flush_hold;
    wire        flush_rd;

    wire [15:0] ring_rd_data;
    wire        ring_rd_valid, ring_rd_underrun, ring_rd_empty;
    wire [10:0] ring_rd_level;
    wire        ring_wr_full;

    pcm_ring_buffer #(.AW(AW)) u_ring (
        .I_wr_clk     (I_sd_clk),
        .I_wr_rst     (I_sd_rst),
        .I_wr_en      (ring_wr_en),
        .I_wr_data    (ring_wr_data),
        .O_wr_full    (ring_wr_full),
        .O_wr_level   (level_w),
        .I_rd_clk     (I_aud_clk),
        .I_rd_rst     (I_aud_rst),
        .I_rd_req     (I_sample_tick && I_sample_ready && I_pcm_consume),
        .I_rd_flush   (flush_rd),
        .O_rd_data    (ring_rd_data),
        .O_rd_valid   (ring_rd_valid),
        .O_rd_underrun(ring_rd_underrun),
        .O_rd_level   (ring_rd_level),
        .O_rd_empty   (ring_rd_empty)
    );

    // flush 跨越到读域：保持足够长的 SD 周期，确保 25 MHz 侧至少采到一次。
    assign flush_rd = (flush_hold != 4'd0);

    // =======================================================================
    // 写侧状态机
    // =======================================================================
    localparam W_IDLE  = 3'd0;
    localparam W_STREAM= 3'd1;
    localparam W_DRAIN = 3'd2;
    localparam W_ERR   = 3'd3;
    localparam W_HOLD  = 3'd4;   // 文件播完：保持 PCM 被选中并输出静音，直到停止
    localparam W_ABORT = 3'd5;   // 停止中：排空在途扇区（丢弃数据）后回 IDLE

    reg [2:0]  wstate;
    reg [1:0]  start_sync, stop_sync;
    reg        start_seen, stop_seen;
    reg        lo_pending;
    reg  [7:0] lo_byte;
    // 字节暂存：环形缓冲短暂满时不得丢字节（丢一个字节会永久错位）
    reg        byte_pending;
    reg  [7:0] byte_hold;
    reg        eof_q, err_q;

    wire start_pulse = start_sync[1] ^ start_seen;
    wire stop_pulse  = stop_sync[1]  ^ stop_seen;

    assign O_playing = (wstate == W_STREAM) || (wstate == W_DRAIN) || (wstate == W_HOLD);
    assign O_eof     = eof_q;
    assign O_err     = err_q;
    assign O_level   = level_w;

    always @(posedge I_sd_clk or posedge I_sd_rst) begin
        if (I_sd_rst) begin
            wstate           <= W_IDLE;
            start_sync       <= 2'b00;
            stop_sync        <= 2'b00;
            start_seen       <= 1'b0;
            stop_seen        <= 1'b0;
            lo_pending       <= 1'b0;
            lo_byte          <= 8'd0;
            byte_pending     <= 1'b0;
            byte_hold        <= 8'd0;
            ring_wr_en       <= 1'b0;
            ring_wr_data     <= 16'd0;
            flush_hold       <= 4'd0;
            file_start_pulse <= 1'b0;
            file_cluster_lat <= 32'd0;
            file_size_lat    <= 32'd0;
            eof_q            <= 1'b0;
            err_q            <= 1'b0;
            req_hold         <= 1'b0;
            req_lba_hold     <= 32'd0;
            start_pending    <= 1'b0;
            streamer_abort   <= 1'b0;
            abort_pending    <= 1'b0;
        end else begin
            start_sync <= {start_sync[0], I_start_toggle};
            stop_sync  <= {stop_sync[0],  I_stop_toggle};
            ring_wr_en       <= 1'b0;
            file_start_pulse <= 1'b0;
            if (flush_hold != 4'd0)
                flush_hold <= flush_hold - 4'd1;

            // 请求锁存/释放：接受后立即清，其他时间保持
            if (req_accept)
                req_hold <= 1'b0;
            else if (str_sector_req && !req_hold && (wstate == W_STREAM)) begin
                req_hold     <= 1'b1;
                req_lba_hold <= str_sector_lba;
            end

            if (start_pulse) begin
                start_seen       <= start_sync[1];
                wstate           <= W_STREAM;
                lo_pending       <= 1'b0;
                byte_pending     <= 1'b0;
                req_hold         <= 1'b0;
                eof_q            <= 1'b0;
                err_q            <= 1'b0;
                flush_hold       <= FLUSH_HOLD[3:0];
                start_pending    <= 1'b0;
                streamer_abort   <= 1'b0;
                abort_pending    <= 1'b0;
                // 锁存文件描述，之后即使扫描表更新也不影响本次播放
                file_cluster_lat <= pcm_cluster_lut(I_track_sel);
                file_size_lat    <= pcm_size_lut(I_track_sel);
                // 缺失 / 空文件 / 无效簇：直接判失败，由上层回落琶音
                if (!pcm_entry_valid(I_track_sel) ||
                    (pcm_size_lut(I_track_sel) == 32'd0) ||
                    (pcm_cluster_lut(I_track_sel) < 32'd2)) begin
                    err_q  <= 1'b1;
                    wstate <= W_ERR;
                end else begin
                    start_pending <= 1'b1;
                end
            end else if (stop_pulse) begin
                stop_seen    <= stop_sync[1];
                lo_pending   <= 1'b0;
                byte_pending <= 1'b0;
                // 给 streamer 一个中止脉冲，让它从等待状态退出；同时撤回请求。
                // 这两件事必须一起做：只撤请求会让 streamer 永久等 sector_done。
                req_hold      <= 1'b0;
                abort_pending <= 1'b1;
                flush_hold    <= FLUSH_HOLD[3:0];
                eof_q        <= 1'b0;
                start_pending<= 1'b0;      // 丢弃尚未发出的启动脉冲
                // 不能直接回 IDLE：若 streamer 正在等 sector_done，
                // 撤回请求会让它永久卡死。进入 W_ABORT 排空在途事务。
                if (streamer_busy)
                    wstate <= W_ABORT;
                else
                    wstate <= W_IDLE;
            end else begin
                // 空闲后补发启动脉冲（只发一拍）
                if (start_pending && !streamer_busy && (wstate == W_STREAM)) begin
                    start_pending    <= 1'b0;
                    file_start_pulse <= 1'b1;
                end
                case (wstate)
                    W_IDLE: begin
                        lo_pending <= 1'b0;
                    end
                    W_STREAM: begin
                        // 先处理暂存字节（上一拍因满而未写入的）
                        if (byte_pending) begin
                            if (!ring_wr_full) begin
                                ring_wr_en   <= 1'b1;
                                ring_wr_data <= {byte_hold, lo_byte};
                                byte_pending <= 1'b0;
                                lo_pending   <= 1'b0;
                            end
                        end else if (streamer_valid) begin
                            if (!lo_pending) begin
                                lo_byte    <= streamer_byte;
                                lo_pending <= 1'b1;
                            end else if (!ring_wr_full) begin
                                lo_pending   <= 1'b0;
                                ring_wr_en   <= 1'b1;
                                ring_wr_data <= {streamer_byte, lo_byte};
                            end else begin
                                // 满：把高字节暂存，等下一拍有空间再写（不丢数据）
                                byte_hold    <= streamer_byte;
                                byte_pending <= 1'b1;
                            end
                        end

                        if (streamer_error != 8'd0) begin
                            err_q  <= 1'b1;
                            wstate <= W_ERR;
                        end else if (streamer_done) begin
                            eof_q  <= 1'b1;
                            wstate <= W_DRAIN;
                        end
                    end
                    W_DRAIN: begin
                        // 等待残余样本排空（读侧水位由读域指针反馈）
                        if (level_w == 11'd0)
                            wstate <= W_HOLD;
                    end
                    W_HOLD: begin
                        // 播完后保持“正在播放 PCM”，让音源选择继续输出静音，
                        // 不要跳回琶音造成音源抖动；页面切换时由 stop 退出。
                    end
                    W_ABORT: begin
                        lo_pending   <= 1'b0;
                        byte_pending <= 1'b0;
                        if (abort_pending) begin
                            streamer_abort <= 1'b1;   // 单拍中止脉冲
                            abort_pending  <= 1'b0;
                        end else begin
                            streamer_abort <= 1'b0;
                        end
                        if (!streamer_busy && !str_sector_req && !req_hold)
                            wstate <= W_IDLE;
                    end
                    W_ERR: begin
                        // 停在此状态，直到下一次启动或停止
                        if (level_w == 11'd0 && !streamer_busy)
                            wstate <= W_ERR;
                    end
                    default: wstate <= W_IDLE;
                endcase
            end
        end
    end

    // 环形缓冲在请求当拍即返回样本，直接透出（与音源选择的 tick 语义一致）。
    assign O_sample_data  = ring_rd_data;
    assign O_sample_valid = ring_rd_valid;
    assign O_underrun     = ring_rd_underrun;
    assign O_pcm_playing  = O_playing && !err_q;

    // 供顶层检查读域是否真的在消费（未使用于控制逻辑）
    wire unused_rd_empty = ring_rd_empty;
    wire [10:0] unused_rd_level = ring_rd_level;

endmodule
