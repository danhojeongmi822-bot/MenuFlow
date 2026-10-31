`timescale 1ns/1ps

// 将像素域 PCM 音源接到现有 HDMI 发射器的 PCM/ACR 接口。
module media_hdmi_audio_bridge (
    input  wire        I_rst,
    input  wire        I_sample_valid,
    input  wire [23:0] I_test_left,
    input  wire [23:0] I_test_right,
    input  wire        I_media_valid,
    input  wire        I_media_sample_valid,
    input  wire [23:0] I_media_left,
    input  wire [23:0] I_media_right,
    output reg         O_audio_valid,
    output reg [23:0]  O_audio_left,
    output reg [23:0]  O_audio_right
);

always @* begin
    O_audio_valid = 1'b0;
    O_audio_left  = 24'd0;
    O_audio_right = 24'd0;
    if (I_media_valid) begin
        O_audio_valid = I_media_sample_valid;
        O_audio_left  = I_media_left;
        O_audio_right = I_media_right;
    end else begin
        O_audio_valid = I_sample_valid;
        O_audio_left  = I_test_left;
        O_audio_right = I_test_right;
    end
end

endmodule
