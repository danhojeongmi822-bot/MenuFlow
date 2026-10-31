`timescale 1ns/1ps

// 将 sd_card_clk 域的图片编号安全地交付到 video_clk 域。
module state_code_media_cdc (
    input  wire       I_src_clk,
    input  wire       I_src_rst,
    input  wire [3:0] I_state_code,
    input  wire       I_dst_clk,
    input  wire       I_dst_rst,
    output reg [1:0]  O_media_id,
    output reg        O_media_valid,
    output reg        O_update_pulse
);

reg [3:0] S_shadow;
reg       S_toggle;
reg       D_toggle_1;
reg       D_toggle_2;
reg       D_toggle_seen;
reg [3:0] D_bus_1;
reg [3:0] D_bus_2;
reg [3:0] D_candidate;
reg [1:0] D_stable_count;

always @(posedge I_src_clk or posedge I_src_rst) begin
    if (I_src_rst) begin
        S_shadow <= 4'd1;
        S_toggle <= 1'b0;
    end else if (I_state_code != S_shadow) begin
        S_shadow <= I_state_code;
        S_toggle <= ~S_toggle;
    end
end

always @(posedge I_dst_clk or posedge I_dst_rst) begin
    if (I_dst_rst) begin
        D_toggle_1   <= 1'b0;
        D_toggle_2   <= 1'b0;
        D_toggle_seen<= 1'b0;
        D_bus_1      <= 4'd1;
        D_bus_2      <= 4'd1;
        D_candidate  <= 4'd1;
        D_stable_count <= 2'd0;
        O_media_id   <= 2'd0;
        O_media_valid<= 1'b0;
        O_update_pulse <= 1'b0;
    end else begin
        D_toggle_1 <= S_toggle;
        D_toggle_2 <= D_toggle_1;
        D_bus_1    <= S_shadow;
        D_bus_2    <= D_bus_1;
        O_update_pulse <= 1'b0;

        if (D_toggle_2 != D_toggle_seen) begin
            D_toggle_seen <= D_toggle_2;
            D_candidate   <= D_bus_2;
            D_stable_count<= 2'd0;
        end else if (D_bus_2 == D_candidate) begin
            if (D_stable_count != 2'd3)
                D_stable_count <= D_stable_count + 1'b1;
            if ((D_stable_count == 2'd2) &&
                (D_candidate >= 4'd1) && (D_candidate <= 4'd4)) begin
                O_media_id      <= D_candidate - 4'd1;
                O_media_valid   <= 1'b1;
                O_update_pulse  <= 1'b1;
            end
        end else begin
            D_stable_count <= 2'd0;
        end
    end
end

endmodule
