
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 板上 KEY2：手动下一张
    input                       key2,           // 板上 KEY3：自动播放 开/关 / 长按上一张
    input                       key3,           // 板上 KEY4：进入/退出商品管理模式

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
// MenuFlow：H2 验收位流曾置 8'h01（第 1 页第 1 件上电即售罄，便于观察中文字模）；
// H3 起恢复 8'h00，上电全部在售。这是构建配置，不是运行期状态。
parameter [7:0] MENU_DEMO_SOLDOUT = 8'h00;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 307200;   // 640*480
parameter [ADDR_BITS-1:0] BUF0_ADDR = 0;        //帧缓存0起始地址
parameter [ADDR_BITS-1:0] BUF1_ADDR = FRAME_PIXELS;//帧缓存1起始地址
parameter [ADDR_BITS-1:0] BUF2_ADDR = FRAME_PIXELS * 2;
parameter [ADDR_BITS-1:0] BUF3_ADDR = FRAME_PIXELS * 3;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [3:0]  bank_valid;
wire        frame_commit_toggle;
wire        sd_commit_is_auto;
wire        sd_auto_play_en;
wire [7:0]  sd_osd_error_code;
wire [9:0]  osd_status_sd;
wire [9:0]  osd_status_video;
wire [23:0] osd_rgb;
wire        osd_de;
wire        osd_hs;
wire        osd_vs;
wire        osd_frame_start;
wire [1:0]  active_buf_idx_video;
wire        frame_start_video;
reg         vs_0_d;
wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// ===================== MenuFlow：商品管理与动态售罄 =====================
// 状态与按键事件都在像素域（25 MHz）处理；只有两个单比特电平跨到 sd 域：
//   keys_blocked -> 管理模式/退出守卫期间把 KEY2/KEY3 强制释放，禁止翻页与轮播开关
//   menu_active  -> 管理模式期间暂停自动轮播
// 售罄掩码/选中号/页号都不跨时钟域，由 soldout_overlay 在帧边界锁存。
wire        menu_active;
wire        keys_blocked;
wire [1:0]  sel_idx;
wire [1:0]  menu_page_q;
wire [7:0]  soldout_mask;
wire        sd_key_next;
wire        sd_key_auto;
wire        menu_active_sd;
wire        menu_block_sd;
wire [23:0] so_rgb;
wire        so_de;
wire        so_hs;
wire        so_vs;

// 转场控制与像素效果
wire        trans_commit_toggle;
wire [1:0]  trans_commit_index;
wire [3:0]  trans_commit_valid;
wire [1:0]  trans_mode;
wire [7:0]  trans_alpha;
wire [10:0] trans_cover;
wire        trans_reveal;
wire        trans_busy;
wire        trans_dropped;
wire        trans_aborted;
wire        trans_invalid;
wire [7:0]  trans_completed;
wire [23:0] eff_rgb;
wire        eff_de;
wire        eff_hs;
wire        eff_vs;

// HDMI 1.4b 音频发射相关
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;

// ===== MenuFlow 音频升级：TF 卡 PCM 流式播放 + 音源选择 =====
wire [3:0]  pcm_valid_sd;
wire [31:0] pcm_cluster0_sd, pcm_cluster1_sd, pcm_cluster2_sd, pcm_cluster3_sd;
wire [31:0] pcm_size0_sd, pcm_size1_sd, pcm_size2_sd, pcm_size3_sd;
wire [7:0]  fs_sectors_per_cluster_sd;
wire [31:0] fs_fat_start_lba_sd, fs_data_start_lba_sd, fs_max_cluster_sd;
wire        sd_init_done_raw;

wire        audio_sector_req;
wire [31:0] audio_sector_lba;
wire        audio_sector_busy, audio_sector_valid;
wire [7:0]  audio_sector_byte;
wire [8:0]  audio_sector_index;
wire        audio_sector_done;
wire [7:0]  audio_sector_error;
wire        audio_sector_abort;

wire        pcm_start_toggle, pcm_stop_toggle;
wire [3:0]  pcm_track_sel;
wire        pcm_stream_playing, pcm_stream_eof, pcm_stream_err;
wire        pcm_should_play;
wire [10:0] pcm_stream_level;
wire [15:0] pcm_sample;
wire        pcm_sample_valid, pcm_sample_underrun, pcm_playing;
wire [1:0]  audio_src_sel;
wire [7:0]  audio_gain_now;
wire        pcm_consume_en;
wire [23:0] wave_rgb;
wire        wave_de, wave_hs, wave_vs;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire sys_pll_lock, video_pll_lock;
wire rst_all = ~rst_n | ~sys_pll_lock | ~video_pll_lock;
wire rst_sd, rst_mem, rst_video, rst_serial;
(* ASYNC_REG = "TRUE" *) reg [1:0] sdr_done_sd_sync;
wire sdr_init_done_sd = sdr_done_sd_sync[1];
reset_release reset_sd(sd_card_clk, rst_all, rst_sd);
reset_release reset_mem(ext_mem_clk, rst_all, rst_mem);
reset_release reset_video(video_clk, rst_all, rst_video);
reset_release reset_serial(hdmi_5x_clk, rst_all, rst_serial);

// Sdr_init_done 在 SDRAM 时钟域产生，跨到 SD 时钟域后才允许扫描/加载。
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        sdr_done_sd_sync <= 2'b00;
    else
        sdr_done_sd_sync <= {sdr_done_sd_sync[0], Sdr_init_done};
end

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .extlock    (sys_pll_lock),
    .refclk     (clk),
    .clk0_out   (sd_card_clk),//100MHZ TF 卡输入时钟
    .clk1_out   (ext_mem_clk),// 41.667 MHz SDRAM controller, 0 degrees
    .clk2_out   (ext_mem_clk_sft),
    .reset      (~rst_n)
);

video_pll video_pll_m0(
    .extlock    (video_pll_lock),
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (~rst_n)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    // 促销页要看完 8 秒音频与整段波形，轮播间隔从默认 3 s 放宽到 12 s。
    // 菜单页仍可在 12 s 内浏览，避免来回切换过于频繁。
    .AUTO_PLAY_MS      (12000),
    .USE_FAT32         (1'b1)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .sdram_init_done   (sdr_init_done_sd),
    .key_next          (sd_key_next),
    .key_auto          (sd_key_auto),
    .auto_hold         (menu_active_sd),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .bank_valid        (bank_valid),
    .frame_commit_toggle(frame_commit_toggle),
    .commit_is_auto     (sd_commit_is_auto),
    .auto_play_en      (sd_auto_play_en),
    .osd_error_code    (sd_osd_error_code),
    .pcm_valid         (pcm_valid_sd),
    .pcm_cluster0      (pcm_cluster0_sd), .pcm_cluster1 (pcm_cluster1_sd),
    .pcm_cluster2      (pcm_cluster2_sd), .pcm_cluster3 (pcm_cluster3_sd),
    .pcm_size0         (pcm_size0_sd),    .pcm_size1    (pcm_size1_sd),
    .pcm_size2         (pcm_size2_sd),    .pcm_size3    (pcm_size3_sd),
    .fs_sectors_per_cluster (fs_sectors_per_cluster_sd),
    .fs_fat_start_lba  (fs_fat_start_lba_sd),
    .fs_data_start_lba (fs_data_start_lba_sd),
    .fs_max_cluster    (fs_max_cluster_sd),
    .sd_init_done_out  (sd_init_done_raw),
    .audio_req         (audio_sector_req),
    .audio_lba         (audio_sector_lba),
    .audio_busy        (audio_sector_busy),
    .audio_valid       (audio_sector_valid),
    .audio_byte        (audio_sector_byte),
    .audio_byte_index  (audio_sector_index),
    .audio_done        (audio_sector_done),
    .audio_error      (audio_sector_error),
    .audio_abort      (audio_sector_abort),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        vs_0_d <= 1'b0;
    else
        vs_0_d <= vs_0;
end
assign frame_start_video = vs_0_d & ~vs_0;

// 转场控制器：所有显示 Bank 提交都经过这里。
// sd 域提交 toggle/目标编号在这里被采样、锁定，只有画面完全遮蔽后才向
// four_bank_frame_commit 发出一次提交，并等待 active_index 真实更新。
video_transition #(
    .FADE_FRAMES            (16),
    .WIPE_FRAMES            (16),
    .H_ACTIVE               (640),
    .READY_FRAMES           (2),
    .COMMIT_TIMEOUT_FRAMES  (8),
    .SETTLE_CYCLES          (4)
) u_video_transition (
    .sd_commit_toggle   (frame_commit_toggle),
    .sd_pending_index   (disp_buf_idx),
    .sd_bank_valid      (bank_valid),
    .sd_commit_is_auto  (sd_commit_is_auto),
    .sd_player_active   (display_valid),
    .pix_clk            (video_clk),
    .pix_rst            (rst_video),
    .frame_start        (frame_start_video),
    .active_index       (active_buf_idx_video),
    .commit_toggle      (trans_commit_toggle),
    .commit_index       (trans_commit_index),
    .commit_valid      (trans_commit_valid),
    .mode               (trans_mode),
    .alpha              (trans_alpha),
    .cover_x            (trans_cover),
    .wipe_reveal        (trans_reveal),
    .busy               (trans_busy),
    .req_dropped        (trans_dropped),
    .stat_aborted       (trans_aborted),
    .stat_invalid       (trans_invalid),
    .stat_completed     (trans_completed)
);

four_bank_frame_commit u_four_bank_frame_commit(
    .pix_clk             (video_clk),
    .pix_rst             (rst_video),
    .frame_start         (frame_start_video),
    .commit_toggle_mem   (trans_commit_toggle),
    .pending_index_mem   (trans_commit_index),
    .bank_valid_mem      (trans_commit_valid),
    .active_index        (active_buf_idx_video)
);

// 已提交显示 Bank 的 1~4 编号：音频联动与数码管都以它为准
wire [3:0] display_code_video = {2'b0, active_buf_idx_video} + 4'd1;

wire [1:0] media_id;
wire       media_id_valid;

state_code_media_cdc u_state_code_media_cdc(
    .I_src_clk      (video_clk),
    .I_src_rst      (rst_video),
    .I_state_code   (display_code_video),
    .I_dst_clk      (video_clk),
    .I_dst_rst      (rst_video),
    .O_media_id     (media_id),
    .O_media_valid  (media_id_valid),
    .O_update_pulse ()
);

// 数码管显示“已提交显示 Bank”编号，经两级同步到板载 50 MHz 时钟域。
// 该值每次转场至多变化一次，变化间隔远大于目标时钟周期。
// 板载 clk 域用高有效复位（与工程其它模块一致），避免“异步复位/异步置位”混用告警。
wire rst_50m = ~rst_n;
(* ASYNC_REG = "TRUE" *) reg [3:0] seg_code_meta, seg_code_sync;
always @(posedge clk or posedge rst_50m) begin
    if (rst_50m) begin
        seg_code_meta <= 4'd1;
        seg_code_sync <= 4'd1;
    end else begin
        seg_code_meta <= display_code_video;
        seg_code_sync <= seg_code_meta;
    end
end

seg_decoder seg_decoder_m0(
    .bin_data          (seg_code_sync),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容。
// display_valid 来自 sd_card_clk 域，先用两级同步落到像素域再参与组合门控，
// 避免 100 MHz 触发器直接驱动 25 MHz 域的乘法/加法链（会造成跨域时序违例）。
(* ASYNC_REG = "TRUE" *) reg [1:0] display_valid_v_sync;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        display_valid_v_sync <= 2'b00;
    else
        display_valid_v_sync <= {display_valid_v_sync[0], display_valid};
end
wire display_valid_v = display_valid_v_sync[1];
assign vout_data = display_valid_v ? vout_data_raw : 24'd0;

// ---------------- 商品管理模式（像素域） ----------------
menu_control #(
    .CLK_HZ       (25_000_000),
    .DEBOUNCE_MS  (20),
    .LONG_MS      (800),
    .SHORT_MAX_MS (600),
    .GUARD_MS     (200),
    .DEMO_SOLDOUT (MENU_DEMO_SOLDOUT)
) u_menu_control (
    .clk           (video_clk),
    .rst           (rst_video),
    .key_next      (key1),
    .key_prev      (key2),
    .key_menu      (key3),
    .active_index  (active_buf_idx_video),
    .frame_start   (frame_start_video),
    .trans_busy    (trans_busy),
    .display_valid (display_valid_v),
    .menu_active   (menu_active),
    .sel_idx       (sel_idx),
    .soldout_mask  (soldout_mask),
    .page_q        (menu_page_q),
    .keys_blocked  (keys_blocked)
);

// 单比特电平跨到 sd_card_clk 域（2FF，ASYNC_REG）。
(* ASYNC_REG = "TRUE" *) reg [1:0] menu_active_sd_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] menu_block_sd_sync;
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        menu_active_sd_sync <= 2'b00;
        menu_block_sd_sync  <= 2'b00;
    end else begin
        menu_active_sd_sync <= {menu_active_sd_sync[0], menu_active};
        menu_block_sd_sync  <= {menu_block_sd_sync[0],  keys_blocked};
    end
end
assign menu_active_sd = menu_active_sd_sync[1];
assign menu_block_sd  = menu_block_sd_sync[1];

// 管理模式/退出守卫期间把按键强制为“松开”，原有翻页与轮播开关被抑制。
assign sd_key_next = key1 | menu_block_sd;
assign sd_key_auto = key2 | menu_block_sd;

// ---------------- 动态售罄图层（组合叠加，0 拍延迟） ----------------
soldout_overlay u_soldout_overlay (
    .clk           (video_clk),
    .rst           (rst_video),
    .de            (de),
    .hs            (hs),
    .vs            (vs),
    .frame_start   (frame_start_video),
    .display_valid (display_valid_v),
    .rgb_in        (vout_data),
    .active_index  (active_buf_idx_video),
    .menu_active   (menu_active),
    .sel_idx       (sel_idx),
    .soldout_mask  (soldout_mask),
    .rgb_out       (so_rgb),
    .de_out        (so_de),
    .hs_out        (so_hs),
    .vs_out        (so_vs)
);

// 转场像素处理：只作用于背景图片，位于 OSD 之前。
// 输出与输入同拍对齐并统一延迟 1 级（RGB/DE/HS/VS 一起寄存）。
video_effect #(
    .H_ACTIVE    (640),
    .COVER_COLOR (24'h000000)
) u_video_effect (
    .clk         (video_clk),
    .rst         (rst_video),
    .de          (so_de),
    .hs          (so_hs),
    .vs          (so_vs),
    .rgb_in      (so_rgb),
    .mode        (trans_mode),
    .alpha       (trans_alpha),
    .cover_x     (trans_cover),
    .wipe_reveal (trans_reveal),
    .rgb_out     (eff_rgb),
    .de_out      (eff_de),
    .hs_out      (eff_hs),
    .vs_out      (eff_vs)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (active_buf_idx_video),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== PCM 播放页面门控（像素域） =====================
// 促销页判定沿用既有不变量：图片 n 固定写入 bank n-1，active_buf_idx>=2 即 PIC3/PIC4。
// start/stop 为单比特 toggle，track_sel 为启动时锁存的页面编号（准静态跨域）。
audio_page_gate u_audio_page_gate (
    .clk           (video_clk),
    .rst           (rst_video),
    .frame_start   (frame_start_video),
    .active_index  (active_buf_idx_video),
    .display_valid (display_valid_v),
    .trans_busy    (trans_busy),
    .start_toggle  (pcm_start_toggle),
    .stop_toggle   (pcm_stop_toggle),
    .track_sel     (pcm_track_sel),
    .should_play   (pcm_should_play),
    .page_q        ()
);

// ===================== 音频：像素时钟 PCM + 媒体联动 =====================
wire        test_sample_valid;
wire [23:0] test_left_data;
wire [23:0] test_right_data;
wire [3:0]  test_lut_index;
wire        media_sample_valid;
wire [23:0] media_left_data;
wire [23:0] media_right_data;
wire [1:0]  media_tone_id;
wire [2:0]  media_note_index;

pcm_test_tone u_pcm_test_tone(
    .I_clk          (video_clk),
    .I_rst          (rst_video),
    .O_sample_valid (test_sample_valid),
    .O_sample_left  (test_left_data),
    .O_sample_right (test_right_data),
    .O_lut_index    (test_lut_index)
);

pcm_media_tone u_pcm_media_tone(
    .I_clk          (video_clk),
    .I_rst          (rst_video),
    .I_sample_valid (test_sample_valid),
    .I_media_valid  (media_id_valid),
    .I_media_id     (media_id),
    .O_sample_valid (media_sample_valid),
    .O_sample_left  (media_left_data),
    .O_sample_right (media_right_data),
    .O_media_id     (media_tone_id),
    .O_note_index   (media_note_index)
);

// ---- PCM 流式播放器（写侧 SD 域 / 读侧像素域） ----
pcm_stream_player #(
    .AW          (10),
    .MAX_VISITED (4096)
) u_pcm_stream_player (
    .I_sd_clk                (sd_card_clk),
    .I_sd_rst                (rst_sd),
    .I_start_toggle          (pcm_start_toggle),
    .I_stop_toggle           (pcm_stop_toggle),
    .I_track_sel             (pcm_track_sel),
    .I_pcm_valid             (pcm_valid_sd),
    .I_pcm_cluster0          (pcm_cluster0_sd), .I_pcm_cluster1 (pcm_cluster1_sd),
    .I_pcm_cluster2          (pcm_cluster2_sd), .I_pcm_cluster3 (pcm_cluster3_sd),
    .I_pcm_size0             (pcm_size0_sd),    .I_pcm_size1    (pcm_size1_sd),
    .I_pcm_size2             (pcm_size2_sd),    .I_pcm_size3    (pcm_size3_sd),
    .I_sectors_per_cluster   (fs_sectors_per_cluster_sd),
    .I_fat_start_lba         (fs_fat_start_lba_sd),
    .I_data_start_lba        (fs_data_start_lba_sd),
    .I_max_cluster           (fs_max_cluster_sd),
    .I_sd_link_ready         (sd_init_done_raw),
    .O_sector_req            (audio_sector_req),
    .O_sector_lba            (audio_sector_lba),
    .I_sector_busy           (audio_sector_busy),
    .I_sector_valid          (audio_sector_valid),
    .I_sector_byte           (audio_sector_byte),
    .I_sector_index          (audio_sector_index),
    .I_sector_done           (audio_sector_done),
    .I_sector_error          (audio_sector_error),
    .I_sector_abort          (audio_sector_abort),
    .O_playing               (pcm_stream_playing),
    .O_eof                   (pcm_stream_eof),
    .O_err                   (pcm_stream_err),
    .O_level                 (pcm_stream_level),
    .I_aud_clk               (video_clk),
    .I_aud_rst               (rst_video),
    .I_sample_tick           (test_sample_valid),
    .I_sample_ready          (1'b1),
    .I_pcm_consume           (pcm_consume_en),
    .O_sample_data           (pcm_sample),
    .O_sample_valid          (pcm_sample_valid),
    .O_underrun              (pcm_sample_underrun),
    .O_pcm_playing           (pcm_playing)
);

// 音源选择 + 固定增益 + 切换淡入淡出。
// 波形抽头与 HDMI 输出使用同一份选择/增益后样本（见 audio_waveform_overlay）。
audio_source_mux #(
    .GAIN_LEVEL (8'd255),
    .FADE_TICKS (16)
) u_audio_source_mux (
    .I_clk            (video_clk),
    .I_rst            (rst_video),
    .I_sample_tick    (test_sample_valid),
    .I_pcm_valid      (pcm_sample_valid),
    .I_pcm_sample     (pcm_sample),
    .I_pcm_playing    (pcm_playing),
    .I_media_active   (media_id_valid),
    .I_media_valid    (media_sample_valid),
    .I_media_left     (media_left_data),
    .I_media_right    (media_right_data),
    .I_test_valid     (test_sample_valid),
    .I_test_left      (test_left_data),
    .I_test_right     (test_right_data),
    .O_audio_valid    (audio_valid),
    .O_audio_left     (audio_left_data),
    .O_audio_right    (audio_right_data),
    .O_active_source  (audio_src_sel),
    .O_gain           (audio_gain_now),
    .O_pcm_consume    (pcm_consume_en)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== OSD 状态叠加与滚动字幕 =====================
// 状态快照在 sd_card_clk 域产生，经四相握手跨到视频域，并在帧边界提交。
assign osd_status_sd = {display_valid, sd_auto_play_en, sd_osd_error_code};

osd_status_cdc u_osd_status_cdc(
    .src_clk          (sd_card_clk),
    .src_rst          (rst_sd),
    .src_status       (osd_status_sd),
    .dst_clk          (video_clk),
    .dst_rst          (rst_video),
    .dst_frame_start  (osd_frame_start),
    .dst_status       (osd_status_video)
);

// 实时音频波形（时域包络 + 峰值条）：插入在转场之后、OSD 之前。
// 纯组合叠加，0 拍延迟，既有 23 拍链路与 OSD 帧边界语义不变；OSD 优先于波形。
audio_waveform_overlay #(
    .H_ACTIVE     (640),
    .V_ACTIVE     (480),
    // 与 include/menu_layout.vh 的 MF_WAVE_* 一致；由 make_menu_assets.py 校验
    .WAVE_X       (64),
    .WAVE_Y       (340),
    .WAVE_W       (512),
    .WAVE_H       (92),
    .SAMPLE_COUNT (64),
    .DECIMATE     (12)
) u_audio_waveform_overlay (
    .clk            (video_clk),
    .rst            (rst_video),
    .de             (eff_de),
    .hs             (eff_hs),
    .vs             (eff_vs),
    .rgb_in         (eff_rgb),
    .rgb_out        (wave_rgb),
    .de_out         (wave_de),
    .hs_out         (wave_hs),
    .vs_out         (wave_vs),
    .active_index   (active_buf_idx_video),
    .frame_start    (frame_start_video),
    .display_valid  (display_valid_v),
    .pcm_tap_valid  (audio_valid),
    .pcm_tap_sample (audio_left_data),
    .pcm_playing    (pcm_playing)
);

osd_overlay #(
    .H_ACTIVE    (640),
    .V_ACTIVE    (480),
    .STATUS_X    (8),
    .STATUS_Y    (8),
    .SUBTITLE_Y  (448),
    .SCROLL_STEP (2),
    .TEXT_LEN    (40),
    .TEXT_WIDTH  (640),
    .OSD_ENABLE  (1)
) u_osd_overlay (
    .clk           (video_clk),
    .rst           (rst_video),
    .hs            (wave_hs),
    .vs            (wave_vs),
    .de            (wave_de),
    .rgb_in        (wave_rgb),
    .active_index  (active_buf_idx_video),
    .status        (osd_status_video),
    .rgb_out       (osd_rgb),
    .de_out        (osd_de),
    .hs_out        (osd_hs),
    .vs_out        (osd_vs),
    .frame_start   (osd_frame_start),
    .pixel_x       (),
    .pixel_y       (),
    .scroll_offset (),
    .osd_active    ()
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (osd_vs),
    .I_de          (osd_de),
    .I_rgb         (osd_rgb),
    .I_ready       (axis_s_ready),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data),
    .O_overflow    ()
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_serial),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
