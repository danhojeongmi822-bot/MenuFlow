`timescale 1ns/1ps

// 顶层连线检查（不验证功能）：
// 本机没有 EG4 原语与加密 HDMI IP，无法直接 elaborate 真实顶层。
// 该 TB 用同端口名的空壳替换 sys_pll / video_pll / HDMI 发射核，
// 目的只是让 top_tf_hdmi_audio 的端口连接、位宽和新增模块实例在仿真器里被检查一遍；
// 真实综合与端口一致性仍以 TD elaborate/综合为准。
//
// 运行（在 HX4S20_HDMI 下）：
//   iverilog -g2012 -I SD -I board/tests/stubs -s tb_top_wiring \
//     board/tests/tb_top_wiring.v top_tf_hdmi_audio.v display/*.v SD/sd_card_bmp.v \
//     SD/fat32_bmp_engine.v SD/fat32_volume_scanner.v SD/fat32_file_streamer.v \
//     SD/sd_sector_adapter.v SD/fat32_bmp_parser.v SD/sdram.v SD/frame_read_write.v \
//     SD/frame_fifo_read.v SD/frame_fifo_write.v SD/seg_decoder.v SD/seg_scan.v \
//     SD/video_timing_data.v SD/video_delay.v SD/color_bar.v SD/four_bank_frame_commit.v \
//     state_code_media_cdc.v pcm_test_tone.v pcm_media_tone.v audio_arc_calculate.v \
//     media_hdmi_audio_bridge.v startup_pulse.v video_rgb_to_axis_640x480.v
module tb_top_wiring;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg key1 = 1'b1;
    reg key2 = 1'b1;
    reg key3 = 1'b1;
    reg sd_miso = 1'b1;

    wire [5:0] seg_sel;
    wire [7:0] seg_data;
    wire HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P;
    wire HDMI_DDC_SCL;
    wire HDMI_DDC_SDA;
    wire sd_ncs, sd_dclk, sd_mosi;

    top u_top (
        .clk(clk), .rst_n(rst_n), .key1(key1), .key2(key2), .key3(key3),
        .seg_sel(seg_sel), .seg_data(seg_data),
        .HDMI_CLK_P(HDMI_CLK_P), .HDMI_D2_P(HDMI_D2_P),
        .HDMI_D1_P(HDMI_D1_P), .HDMI_D0_P(HDMI_D0_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .sd_ncs(sd_ncs), .sd_dclk(sd_dclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    always #10 clk = ~clk;

    initial begin
        #200;
        rst_n = 1'b1;
        #2000;
        // 只检查连线与实例化：转场控制器的关键信号必须存在且已连接
        if (u_top.trans_mode === 2'bx || u_top.trans_alpha === 8'hxx) begin
            $display("FAIL top_wiring: transition outputs undriven");
            $fatal(1);
        end
        if (u_top.trans_mode !== 2'd0 || u_top.trans_alpha !== 8'd255) begin
            $display("FAIL top_wiring: transition not idle after reset (mode=%0d alpha=%0d)",
                     u_top.trans_mode, u_top.trans_alpha);
            $fatal(1);
        end
        if (u_top.u_video_effect.mode !== 2'd0) begin
            $display("FAIL top_wiring: video_effect mode not connected");
            $fatal(1);
        end

        // MenuFlow 音频升级：PCM 播放器与音源选择必须已实例化并接线
        if (u_top.u_pcm_stream_player.O_sector_req === 1'bx) begin
            $display("FAIL top_wiring: pcm_stream_player sector bus undriven");
            $fatal(1);
        end
        if (u_top.u_audio_source_mux.O_audio_left === 24'hxxxxxx) begin
            $display("FAIL top_wiring: audio_source_mux output undriven");
            $fatal(1);
        end
        if (u_top.pcm_playing !== u_top.u_pcm_stream_player.O_pcm_playing) begin
            $display("FAIL top_wiring: pcm_playing not connected to player");
            $fatal(1);
        end
        // 波形层必须位于 video_effect 与 osd_overlay 之间，且 OSD 输入来自波形输出
        if (u_top.u_audio_waveform_overlay.pcm_tap_sample !== u_top.audio_left_data) begin
            $display("FAIL top_wiring: waveform tap not on the HDMI sample path");
            $fatal(1);
        end
        if (u_top.u_osd_overlay.rgb_in !== u_top.wave_rgb) begin
            $display("FAIL top_wiring: OSD input not fed by waveform output");
            $fatal(1);
        end
        if (u_top.u_audio_page_gate.track_sel !== u_top.pcm_track_sel) begin
            $display("FAIL top_wiring: page gate track_sel not connected");
            $fatal(1);
        end
        // MenuFlow：管理控制默认退出、掩码为构建配置值、图层已插入像素链
        if (u_top.menu_active !== 1'b0) begin
            $display("FAIL top_wiring: menu_active not idle after reset");
            $fatal(1);
        end
        if (u_top.soldout_mask !== 8'h00 || u_top.u_menu_control.soldout_mask !== 8'h00) begin
            $display("FAIL top_wiring: reset soldout mask is not all-in-sale (%02x)",
                     u_top.soldout_mask);
            $fatal(1);
        end
        if (u_top.so_rgb !== u_top.vout_data) begin
            $display("FAIL top_wiring: soldout overlay not in the pixel path");
            $fatal(1);
        end

        // 普通模式按键直通；管理模式期间 sd 域按键必须被强制为“松开”
        key1 = 1'b0;
        key2 = 1'b0;
        #200;
        if (u_top.sd_key_next !== 1'b0 || u_top.sd_key_auto !== 1'b0) begin
            $display("FAIL top_wiring: normal-mode keys are blocked");
            $fatal(1);
        end
        force u_top.u_menu_control.state = 1'b1;
        repeat (8) @(posedge clk);
        if (u_top.menu_active !== 1'b1 || u_top.sd_key_next !== 1'b1 || u_top.sd_key_auto !== 1'b1) begin
            $display("FAIL top_wiring: management mode does not block sd keys (menu=%b next=%b auto=%b)",
                     u_top.menu_active, u_top.sd_key_next, u_top.sd_key_auto);
            $fatal(1);
        end
        release u_top.u_menu_control.state;

        $display("PASS top_wiring: top elaborated with stubs; transition/effect/menu wired");
        $finish;
    end

endmodule

// ---------------- 空壳：PLL ----------------
module sys_pll (
    output wire extlock,
    input  wire refclk,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out,
    input  wire reset
);
    assign extlock = 1'b1;
    assign clk0_out = refclk;
    assign clk1_out = refclk;
    assign clk2_out = refclk;
endmodule

module video_pll (
    output wire extlock,
    input  wire refclk,
    output wire clk0_out,
    output wire clk1_out,
    input  wire reset
);
    assign extlock = 1'b1;
    assign clk0_out = refclk;
    assign clk1_out = refclk;
endmodule

// ---------------- 空壳：SDRAM 控制器与 HDMI PHY ----------------
module sdram (
    input  wire        Clk,
    input  wire        Clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    output wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
    assign Sdr_init_done    = 1'b1;
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy         = 1'b0;
    assign Sdr_rd_en        = App_rd_en;
    assign Sdr_rd_dout      = 32'd0;
endmodule

module hdmi_phy_wrapper #(
    parameter DEVICE = "EG"
)(
    input  wire       I_pixel_clk,
    input  wire       I_serial_clk,
    input  wire       I_rst,
    input  wire [9:0] I_tmds_channel_0,
    input  wire [9:0] I_tmds_channel_1,
    input  wire [9:0] I_tmds_channel_2,
    input  wire [9:0] I_tmds_channel_clk,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p
);
    assign O_tmds_ch0_p   = 1'b0;
    assign O_tmds_ch1_p   = 1'b0;
    assign O_tmds_ch2_p   = 1'b0;
    assign O_tmds_clk_p   = 1'b0;
endmodule

// ---------------- 空壳：HDMI 发射核 ----------------
module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE = "EG",
    parameter HTOTAL = 800,
    parameter HSA = 96,
    parameter HFP = 16,
    parameter HBP = 48,
    parameter HACTIVE = 640,
    parameter VTOTAL = 525,
    parameter VSA = 2,
    parameter VFP = 10,
    parameter VBP = 33,
    parameter VACTIVE = 480,
    parameter VIDEO_VIC = 1,
    parameter VIDEO_TPG = "Disable",
    parameter VIDEO_FORMAT = "RGB",
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV = 250
)(
    input  wire        I_pixel_clk,
    input  wire        I_rst,
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,
    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,
    output wire        O_video_locked,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,
    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);
    assign O_edid_read_valid = 1'b0;
    assign O_edid_read_data  = 8'd0;
    assign O_axis_s_ready    = 1'b1;
    assign O_video_locked    = 1'b1;
    assign O_ddc_scl         = 1'b1;
    assign O_ch0_tmds_data   = 10'd0;
    assign O_ch1_tmds_data   = 10'd0;
    assign O_ch2_tmds_data   = 10'd0;
    assign O_clk_tmds_data   = 10'd0;
endmodule
