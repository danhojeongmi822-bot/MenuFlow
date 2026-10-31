`timescale 1ns/1ps

// 图片联动媒体音调：四组六音符琶音，每个音符持续 250 ms。
module pcm_media_tone #(
    parameter integer NOTE_SAMPLES = 12_000,
    parameter signed [15:0] AMP = 16'sd12000
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_sample_valid,
    input  wire        I_media_valid,
    input  wire [1:0]  I_media_id,
    output reg         O_sample_valid,
    output reg [23:0]  O_sample_left,
    output reg [23:0]  O_sample_right,
    output reg [1:0]   O_media_id,
    output reg [2:0]   O_note_index
);

reg [1:0] S_media_id;
reg [2:0] S_note_index;
reg [13:0] S_note_count;
reg [31:0] S_phase_acc;

function [31:0] note_inc_lut;
    input [1:0] media;
    input [2:0] note;
    begin
        case (media)
            2'd0: begin // C5-E5-G5-C6-G5-E5
                case (note)
                    3'd0: note_inc_lut = 32'd46819716;
                    3'd1: note_inc_lut = 32'd58981577;
                    3'd2: note_inc_lut = 32'd70186762;
                    3'd3: note_inc_lut = 32'd93753832;
                    3'd4: note_inc_lut = 32'd70186762;
                    default: note_inc_lut = 32'd58981577;
                endcase
            end
            2'd1: begin // A4-C5-E5-A5-E5-C5
                case (note)
                    3'd0: note_inc_lut = 32'd39370534;
                    3'd1: note_inc_lut = 32'd46819716;
                    3'd2: note_inc_lut = 32'd58981577;
                    3'd3: note_inc_lut = 32'd78741069;
                    3'd4: note_inc_lut = 32'd58981577;
                    default: note_inc_lut = 32'd46819716;
                endcase
            end
            2'd2: begin // 五声音阶：A4-C5-D5-E5-G5-E5
                case (note)
                    3'd0: note_inc_lut = 32'd39370534;
                    3'd1: note_inc_lut = 32'd46819716;
                    3'd2: note_inc_lut = 32'd52553362;
                    3'd3: note_inc_lut = 32'd58981577;
                    3'd4: note_inc_lut = 32'd70186762;
                    default: note_inc_lut = 32'd58981577;
                endcase
            end
            default: begin // 低-高摇摆：C4-C5-C4-C6-C4-C5
                case (note)
                    3'd0: note_inc_lut = 32'd23409862;
                    3'd1: note_inc_lut = 32'd46819716;
                    3'd2: note_inc_lut = 32'd23409862;
                    3'd3: note_inc_lut = 32'd93753832;
                    3'd4: note_inc_lut = 32'd23409862;
                    default: note_inc_lut = 32'd46819716;
                endcase
            end
        endcase
    end
endfunction

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

wire [31:0] W_note_inc = note_inc_lut(S_media_id, S_note_index);
wire signed [15:0] W_sample = sine_lut(S_phase_acc[31:28]);

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_media_id      <= 2'd0;
        S_note_index    <= 3'd0;
        S_note_count    <= 14'd0;
        S_phase_acc     <= 32'd0;
        O_sample_valid  <= 1'b0;
        O_sample_left   <= 24'd0;
        O_sample_right  <= 24'd0;
        O_media_id      <= 2'd0;
        O_note_index    <= 3'd0;
    end else begin
        O_sample_valid <= 1'b0;
        if (I_media_valid && (I_media_id != S_media_id)) begin
            S_media_id   <= I_media_id;
            S_note_index <= 3'd0;
            S_note_count <= 14'd0;
            S_phase_acc  <= 32'd0;
            O_media_id   <= I_media_id;
            O_note_index <= 3'd0;
        end else if (I_sample_valid) begin
            O_sample_valid <= 1'b1;
            O_sample_left  <= {W_sample, 8'b0};
            O_sample_right <= {W_sample, 8'b0};
            O_media_id     <= S_media_id;
            O_note_index   <= S_note_index;
            S_phase_acc    <= S_phase_acc + W_note_inc;
            if (S_note_count == NOTE_SAMPLES - 1) begin
                S_note_count <= 14'd0;
                if (S_note_index == 3'd5)
                    S_note_index <= 3'd0;
                else
                    S_note_index <= S_note_index + 3'd1;
            end else begin
                S_note_count <= S_note_count + 1'b1;
            end
        end
    end
end

endmodule
