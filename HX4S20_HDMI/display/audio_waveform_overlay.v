`timescale 1ns/1ps

// 实时音频波形 + 峰值条叠加（时域，不是 FFT 频谱）。
//
// 数据来源：I_pcm_valid / I_pcm_sample 来自 audio_source_mux 的**选择与增益之后**的
// 样本（即实际送往 HDMI 音频接口的同一条数据流）。本模块不含任何独立动画。
//
// 采集参数（按本工程实际帧率推导，见 design.md §0）：
//   帧率 59.52 Hz（800×525 @25 MHz），每帧 806.4 个 48 kHz 样本。
//   SAMPLE_COUNT=64、DECIMATE=12 → 窗口 768 样本 = 16.0 ms ≈ 一帧。
//
// 双缓冲：写侧采集到 write_bank，帧边界且**采满**时才交换；显示侧只读 display_bank。
// 无新数据（离开促销页/音频停止）时 display_valid 拉低，波形区不绘制，也不保留旧画面。
//
// 绘制（纯组合，0 拍延迟，插在 video_effect 之后、osd_overlay 之前，
// 因此 OSD 天然优先，既有 23 拍链路不变）：
//   区域  x∈[WAVE_X, WAVE_X+WAVE_W)、y∈[WAVE_Y, WAVE_Y+WAVE_H)
//   背景/边框/中心轴/折线（相邻样本线性插值，±1 像素粗）/右侧峰值条
module audio_waveform_overlay #(
    parameter integer H_ACTIVE     = 640,
    parameter integer V_ACTIVE     = 480,
    // 波形区布局由 tools/menuflow/make_menu_assets.py 生成到 include/menu_layout.vh
    // （MF_WAVE_*），促销页素材与 RTL 共用同一真源；此处默认值仅作兜底。
    parameter integer WAVE_X       = 64,
    parameter integer WAVE_Y       = 340,
    parameter integer WAVE_W       = 512,
    parameter integer WAVE_H       = 92,
    // 64 点 × 8 px 间距 = 512 px，正好铺满波形区，无左右留白。
    // 注意：H2 改版曾把默认值降为 48 点（384 px 居中）以省寄存器，
    // 但顶层实例始终覆盖为 64 点，最终位流与实板验收用的都是 64 点。
    // 默认值必须与顶层一致，否则单独例化本模块会得到与整机不同的波形区。
    parameter integer SAMPLE_COUNT = 64,
    parameter integer DECIMATE     = 12,
    parameter integer PEAK_W       = 16,
    // 只画“波形折线 + 峰值条”，不画背景块/边框/轴线：
    // 促销图本身是画面主体，黑色方框会把图挡住。
    parameter [23:0]  C_WAVE      = 24'h20FF90,
    parameter [23:0]  C_PEAK      = 24'hFFB020
)(
    input  wire        clk,
    input  wire        rst,

    // 视频
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,

    // 页面门控：只在促销页（2/3）显示
    input  wire [1:0]  active_index,
    input  wire        frame_start,
    input  wire        display_valid,

    // 音频抽头（选择 + 增益之后）
    input  wire        pcm_tap_valid,
    input  wire [23:0] pcm_tap_sample,
    input  wire        pcm_playing
);
    localparam integer PTS        = SAMPLE_COUNT;
    localparam integer SPACING    = (WAVE_W / PTS);                 // 8
    localparam integer CENTER_Y   = WAVE_Y + (WAVE_H / 2);          // 386
    localparam integer HALF_H     = (WAVE_H / 2) - 2;               // 44
    localparam integer PEAK_X     = WAVE_X + WAVE_W + 8;
    localparam integer PEAK_H_MAX = WAVE_H - 8;                     // 84

    // ---------------- 坐标重建（与 soldout_overlay 同规则） ----------------
    reg [9:0] x_cnt, y_cnt;
    reg       vs_d, de_d;
    wire      de_fall = de_d & ~de;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_cnt <= 10'd0;
            y_cnt <= 10'd0;
            vs_d  <= 1'b0;
            de_d  <= 1'b0;
        end else begin
            vs_d <= vs;
            de_d <= de;
            if (de) x_cnt <= x_cnt + 10'd1; else x_cnt <= 10'd0;
            if (!vs) y_cnt <= 10'd0;
            else if (de_fall) y_cnt <= y_cnt + 10'd1;
        end
    end

    // ---------------- 采集侧 ----------------
    // 8 位有符号样本（取 16 位高 8 位），双 bank
    reg signed [7:0] bank_a [0:PTS-1];
    reg signed [7:0] bank_b [0:PTS-1];
    reg [7:0] peak_a, peak_b;

    reg        write_bank;         // 0=a 1=b
    reg        display_bank;
    reg        disp_valid;
    reg [7:0]  disp_peak;
    reg [6:0]  capture_count;
    reg [7:0]  decim_cnt;
    reg        got_data;

    // 有符号绝对值的 8 位版本：-32768 → 128 → 饱和到 127
    wire signed [15:0] tap16 = pcm_tap_sample[23:8];
    wire [16:0] mag17 = tap16[15] ? (17'd0 - {1'b0, tap16}) : {1'b0, tap16};
    wire [7:0]  mag8  = (mag17[16:8] >= 9'h080) ? 8'h7F : mag17[15:8];

    reg  [1:0] page_lat;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_bank   <= 1'b0;
            display_bank <= 1'b1;
            disp_valid   <= 1'b0;
            disp_peak    <= 8'd0;
            capture_count<= 7'd0;
            decim_cnt    <= 8'd0;
            got_data     <= 1'b0;
            page_lat     <= 2'd0;
            peak_a       <= 8'd0;
            peak_b       <= 8'd0;
        end else begin
            if (frame_start) begin
                page_lat <= active_index;

                // 只在“本帧采满且确实有音频”时交换；否则保持上一帧（不显示半帧）
                if ((capture_count >= PTS) && got_data && pcm_playing) begin
                    display_bank <= write_bank;
                    disp_valid   <= 1'b1;
                    disp_peak    <= write_bank ? peak_b : peak_a;
                    write_bank   <= ~write_bank;
                end else if (!pcm_playing) begin
                    // 音频停止：停止显示旧波形
                    disp_valid <= 1'b0;
                    disp_peak  <= 8'd0;
                end

                capture_count <= 7'd0;
                decim_cnt     <= 8'd0;
                got_data      <= 1'b0;
                // 清下一个要写的 bank 的峰值
                if (write_bank) peak_a <= 8'd0;
                else            peak_b <= 8'd0;
            end else if (pcm_tap_valid && (capture_count < PTS)) begin
                got_data <= 1'b1;
                if (decim_cnt == 8'd0) begin
                    decim_cnt <= DECIMATE - 1;
                    if (write_bank) begin
                        bank_b[capture_count[5:0]] <= tap16[15:8];
                        if (mag8 > peak_b) peak_b <= mag8;
                    end else begin
                        bank_a[capture_count[5:0]] <= tap16[15:8];
                        if (mag8 > peak_a) peak_a <= mag8;
                    end
                    capture_count <= capture_count + 7'd1;
                end else begin
                    decim_cnt <= decim_cnt - 8'd1;
                end
            end
        end
    end

    // ---------------- 显示侧（组合） ----------------
    wire in_area = (x_cnt >= WAVE_X) && (x_cnt < WAVE_X + WAVE_W) &&
                   (y_cnt >= WAVE_Y) && (y_cnt < WAVE_Y + WAVE_H);
    wire in_peak = (x_cnt >= PEAK_X) && (x_cnt < PEAK_X + PEAK_W) &&
                   (y_cnt >= WAVE_Y) && (y_cnt < WAVE_Y + WAVE_H);

    // 64 点 × 8 px = 512 px，正好等于 WAVE_W，左右留白为 0。
    // 下面的居中计算保留通用形式：若把 SAMPLE_COUNT 调小，波形会自动居中。
    localparam integer WAVE_SPAN = PTS * SPACING;              // 512
    localparam integer WAVE_PAD  = (WAVE_W - WAVE_SPAN) / 2;   // 0

    wire [8:0] pad_x = x_cnt - WAVE_X;
    wire       in_wave_x = in_area && (pad_x >= WAVE_PAD) &&
                           (pad_x < WAVE_PAD + WAVE_SPAN);
    wire [8:0] off_x = pad_x - WAVE_PAD;
    wire [5:0] idx   = off_x[8:3];                 // 每点 8 px
    wire [2:0] frac  = off_x[2:0];
    wire [5:0] idx_n = (idx >= PTS - 1) ? PTS - 1 : (idx + 6'd1);

    wire signed [7:0] s0 = display_bank ? bank_b[idx]   : bank_a[idx];
    wire signed [7:0] s1 = display_bank ? bank_b[idx_n] : bank_a[idx_n];

    // 幅度映射用纯 LUT（8 位有符号 → 相对中心的像素偏移量）。
    // 避免 8x6 乘法器与除法进入像素组合路径（TD 在布线阶段因资源/拥塞崩溃）。
    // 映射规则与原公式一致：offset = (s * HALF_H) / 128，四舍五入。
    function automatic signed [6:0] sample_off;
        input signed [7:0] s;
        integer v;
        begin
            v = (s * HALF_H + (s >= 0 ? 64 : -64)) / 128;
            sample_off = v[6:0];
        end
    endfunction

    wire signed [6:0] off0 = sample_off(s0);
    wire signed [6:0] off1 = sample_off(s1);
    // 相邻样本之间按 3 位小数做线性插值：off = off0 + (off1-off0)*frac/8
    // 只做“移位 + 加法”，不引入乘法器。
    wire signed [10:0] d_off = {{4{off1[6]}}, off1} - {{4{off0[6]}}, off0};
    wire signed [10:0] d_scaled = (d_off * $signed({8'd0, frac})) >>> 3;
    wire signed [10:0] off_sum = {{4{off0[6]}}, off0} + d_scaled;

    wire signed [10:0] y_interp = $signed({4'b0, CENTER_Y[9:0]}) - off_sum;

    wire signed [10:0] py = $signed({4'b0, y_cnt});
    wire wave_hit = in_wave_x && disp_valid &&
                    (py >= y_interp - 11'sd1) && (py <= y_interp + 11'sd1);

    // 峰值高度同样用 LUT（0..127 → 0..PEAK_H_MAX）
    function [6:0] peak_off;
        input [7:0] pk;
        integer v;
        begin
            v = (pk * PEAK_H_MAX + 64) / 128;
            peak_off = v[6:0];
        end
    endfunction

    wire [7:0]  peak_used = (disp_peak > 8'd127) ? 8'd127 : disp_peak;
    wire [6:0]  peak_h7   = peak_off(peak_used);
    wire [9:0]  peak_top  = WAVE_Y + WAVE_H - 1 - peak_h7;
    wire peak_hit = in_peak && disp_valid && (peak_used != 8'd0) && ({1'b0,y_cnt} >= {1'b0,peak_top});

    // ---------------- 颜色（透明叠加） ----------------
    // 只有折线/峰值条像素被改写，其余像素（含整个波形区背景）逐位透传原图。
    wire show = disp_valid && (page_lat >= 2'd2) && display_valid;
    wire [23:0] area_rgb = wave_hit ? C_WAVE : C_PEAK;
    wire in_region = wave_hit || peak_hit;

    assign rgb_out = (de && show && in_region) ? area_rgb : rgb_in;
    assign de_out  = de;
    assign hs_out  = hs;
    assign vs_out  = vs;

endmodule
