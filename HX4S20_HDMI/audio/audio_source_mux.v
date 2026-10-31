`timescale 1ns/1ps

// 音频源选择 + 固定增益 + 切换淡入淡出。全部工作在像素/音频时钟域（25 MHz）。
//
// 音源优先级（与既有产品行为一致）：
//   1) PCM 流：促销页正在播放卡上的 PCM 文件
//   2) 媒体琶音：既有 media_hdmi_audio_bridge 的媒体音源
//   3) 测试正弦：既有调试音源
//
// 切换策略（避免爆音、避免丢样本）：
//   * 音源与增益只在 I_sample_tick 边界推进。
//   * 目标音源与当前音源不同时，先把增益在 FADE_TICKS 个 tick 内降到 0，
//     再切换音源，再用 FADE_TICKS 个 tick 升回满幅（简单的形淡出-淡入）。
//   * 淡出期间输出的仍是旧音源样本（音量递减），淡入期间是新音源样本，
//     因此不会出现“两个音源拼在一拍”或“切换后重放旧样本”。
//   * 每个 tick 最多产生一个 O_audio_valid，与被选音源的 valid 一一对应。
//
// 增益：固定档（GAIN_LEVEL，默认 255 = 满幅）。PCM 16 位样本在此统一左对齐到
// 24 位（{sample,8'b0}），与 pcm_test_tone/pcm_media_tone 的幅度映射一致。
module audio_source_mux #(
    parameter [7:0]   GAIN_LEVEL = 8'd255,
    parameter integer FADE_TICKS = 16       // 淡出/淡入各 16 个 tick ≈ 0.33 ms
)(
    input  wire        I_clk,
    input  wire        I_rst,

    input  wire        I_sample_tick,

    // 音源 1：PCM 流
    input  wire        I_pcm_valid,
    input  wire [15:0] I_pcm_sample,
    input  wire        I_pcm_playing,

    // 音源 2：媒体琶音（I_media_active 表示媒体链已就绪，I_media_valid 是样本有效）
    input  wire        I_media_active,
    input  wire        I_media_valid,
    input  wire [23:0] I_media_left,
    input  wire [23:0] I_media_right,

    // 音源 3：测试正弦
    input  wire        I_test_valid,
    input  wire [23:0] I_test_left,
    input  wire [23:0] I_test_right,

    output reg         O_audio_valid,
    output reg  [23:0] O_audio_left,
    output reg  [23:0] O_audio_right,
    output wire [1:0]  O_active_source,     // 0=PCM 1=媒体 2=测试
    output wire [7:0]  O_gain,
    // PCM 消费许可：只有当前确实在输出 PCM 时才为 1（淡出旧音源期间为 0），
    // 防止播放器把听不到的样本提前消费掉。
    output wire        O_pcm_consume
);
    localparam [1:0] SRC_PCM   = 2'd0;
    localparam [1:0] SRC_MEDIA = 2'd1;
    localparam [1:0] SRC_TEST  = 2'd2;

    localparam [1:0] F_IDLE = 2'd0;   // 增益已就位
    localparam [1:0] F_OUT  = 2'd1;   // 正在淡出，准备切换
    localparam [1:0] F_IN   = 2'd2;   // 已切换，正在淡入

    // ---------------- 音源 ----------------
    wire [1:0] want_src = I_pcm_playing   ? SRC_PCM :
                          (I_media_active ? SRC_MEDIA : SRC_TEST);

    wire [23:0] pcm24 = {I_pcm_sample, 8'b0};

    reg [1:0] active_src;

    wire        cur_valid = (active_src == SRC_PCM)   ? I_pcm_valid :
                            (active_src == SRC_MEDIA) ? I_media_valid : I_test_valid;
    wire [23:0] cur_left  = (active_src == SRC_PCM)   ? pcm24 :
                            (active_src == SRC_MEDIA) ? I_media_left : I_test_left;
    wire [23:0] cur_right = (active_src == SRC_PCM)   ? pcm24 :
                            (active_src == SRC_MEDIA) ? I_media_right : I_test_right;

    // ---------------- 淡入淡出 ----------------
    reg [1:0]  fade_state;
    reg [7:0]  gain;
    reg [7:0]  gap_cnt;

    // 每 tick 的增益步进（向上取整，保证 FADE_TICKS 内到 0 或到 GAIN_LEVEL）
    localparam [7:0] STEP = (GAIN_LEVEL / FADE_TICKS == 0) ? 8'd1
                             : ((GAIN_LEVEL + FADE_TICKS - 1) / FADE_TICKS);

    // ---------------- 24 位 × 8 位增益（>> 8，四舍五入） ----------------
    function [23:0] apply_gain;
        input [23:0] s;
        input [7:0]  g;
        reg   [24:0] mag;
        reg   [31:0] prod;
        begin
            if (g == 8'd255) begin
                apply_gain = s;                          // 满幅旁路，逐位透传
            end else begin
                mag  = s[23] ? ({1'b0, ~s[23:0]} + 25'd1) : {1'b0, s[23:0]};
                prod = (mag * {24'd0, g} + 32'd128) >> 8;
                apply_gain = s[23] ? (~prod[23:0] + 24'd1) : prod[23:0];
            end
        end
    endfunction

    assign O_active_source = active_src;
    assign O_gain          = gain;
    assign O_pcm_consume   = (active_src == SRC_PCM);

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_audio_valid <= 1'b0;
            O_audio_left  <= 24'd0;
            O_audio_right <= 24'd0;
            active_src    <= SRC_TEST;
            fade_state    <= F_IDLE;
            gain          <= GAIN_LEVEL;
            gap_cnt       <= 8'd0;
            O_audio_left  <= 24'd0;
            O_audio_right <= 24'd0;
        end else begin
            O_audio_valid <= 1'b0;

            if (I_sample_tick) begin
                case (fade_state)
                    F_IDLE: begin
                        gain <= GAIN_LEVEL;
                        if (want_src != active_src) begin
                            fade_state <= F_OUT;
                            gap_cnt    <= 8'd0;
                        end
                    end
                    F_OUT: begin
                        // 用旧音源继续输出，音量降到 0
                        if (gain <= STEP || gain < 8'd8) begin
                            gain       <= 8'd0;
                            active_src <= want_src;      // 在 0 增益处切换
                            fade_state <= F_IN;
                        end else begin
                            gain <= gain - STEP;
                        end
                    end
                    F_IN: begin
                        if (gain >= GAIN_LEVEL - STEP) begin
                            gain       <= GAIN_LEVEL;
                            fade_state <= F_IDLE;
                        end else begin
                            gain <= gain + STEP;
                        end
                    end
                    default: fade_state <= F_IDLE;
                endcase

                // 输出（每 tick 最多一个 valid）
                if (cur_valid) begin
                    O_audio_valid <= 1'b1;
                    O_audio_left  <= apply_gain(cur_left,  gain);
                    O_audio_right <= apply_gain(cur_right, gain);
                end
            end
        end
    end

endmodule
