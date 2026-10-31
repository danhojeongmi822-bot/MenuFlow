`timescale 1ns/1ps

// 25 MHz 像素时钟域的低资源 PCM 正弦测试音源。
module pcm_test_tone #(
    parameter integer PIXEL_CLK_HZ = 25_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000,
    parameter [31:0] PHASE_INC = 32'd89478485,
    parameter signed [15:0] AMP = 16'sd12000
)(
    input  wire        I_clk,
    input  wire        I_rst,
    output reg         O_sample_valid,
    output reg [23:0]  O_sample_left,
    output reg [23:0]  O_sample_right,
    output reg [3:0]   O_lut_index
);

reg [31:0] S_tick_acc;
reg [31:0] S_phase_acc;
reg signed [15:0] S_sample;

function signed [15:0] sine_lut;
    input [3:0] index;
    begin
        case (index)
            4'd0:  sine_lut = 16'sd0;
            4'd1:  sine_lut = 16'sd4592;
            4'd2:  sine_lut = 16'sd8485;
            4'd3:  sine_lut = 16'sd11087;
            4'd4:  sine_lut = 16'sd12000;
            4'd5:  sine_lut = 16'sd11087;
            4'd6:  sine_lut = 16'sd8485;
            4'd7:  sine_lut = 16'sd4592;
            4'd8:  sine_lut = 16'sd0;
            4'd9:  sine_lut = -16'sd4592;
            4'd10: sine_lut = -16'sd8485;
            4'd11: sine_lut = -16'sd11087;
            4'd12: sine_lut = -16'sd12000;
            4'd13: sine_lut = -16'sd11087;
            4'd14: sine_lut = -16'sd8485;
            default: sine_lut = -16'sd4592;
        endcase
    end
endfunction

wire [3:0] W_lut_index = S_phase_acc[31:28];
wire [31:0] W_tick_sum = S_tick_acc + SAMPLE_RATE_HZ;
wire W_sample_tick = (W_tick_sum >= PIXEL_CLK_HZ);
wire signed [15:0] W_lut_sample = sine_lut(W_lut_index);

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_tick_acc      <= 32'd0;
        S_phase_acc     <= 32'd0;
        S_sample        <= 16'sd0;
        O_sample_valid  <= 1'b0;
        O_sample_left   <= 24'd0;
        O_sample_right  <= 24'd0;
        O_lut_index     <= 4'd0;
    end else begin
        O_sample_valid <= 1'b0;
        if (!W_sample_tick)
            S_tick_acc <= W_tick_sum;
        if (W_sample_tick) begin
            S_tick_acc     <= W_tick_sum - PIXEL_CLK_HZ;
            S_phase_acc    <= S_phase_acc + PHASE_INC;
            S_sample       <= W_lut_sample;
            O_sample_valid <= 1'b1;
            O_sample_left  <= {W_lut_sample, 8'b0};
            O_sample_right <= {W_lut_sample, 8'b0};
            O_lut_index    <= W_lut_index;
        end
    end
end

endmodule
