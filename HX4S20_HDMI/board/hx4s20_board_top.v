// HX4S20 HDL2410 board adapter; application top stays unchanged.
module hx4s20_board_top(
 input clk, input rst_n, input key1, input key2, input key3,
 output [7:0] seg_sel, output [7:0] seg_data,
 output HDMI_CLK_P, output HDMI_D2_P, output HDMI_D1_P, output HDMI_D0_P,
 output HDMI_DDC_SCL, inout HDMI_DDC_SDA,
 output sd_ncs, output sd_dclk, output sd_mosi, input sd_miso
);
 wire [5:0] app_seg_sel_n;
 // Board digit selects are active high. Use the rightmost six digits.
 // Explicitly disable unused leftmost digits SEL0 and SEL1.
 assign seg_sel = {~app_seg_sel_n, 2'b00};
 top u_app(
  .clk(clk), .rst_n(rst_n), .key1(key1), .key2(key2), .key3(key3),
  .seg_sel(app_seg_sel_n), .seg_data(seg_data),
  .HDMI_CLK_P(HDMI_CLK_P), .HDMI_D2_P(HDMI_D2_P),
  .HDMI_D1_P(HDMI_D1_P), .HDMI_D0_P(HDMI_D0_P),
  .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
  .sd_ncs(sd_ncs), .sd_dclk(sd_dclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
 );
endmodule

// Assert asynchronously; release after 16 stable destination clock edges.
module reset_release(input clk, input arst, output rst);
 (* ASYNC_REG = "TRUE" *) reg [15:0] pipe;
 always @(posedge clk or posedge arst) begin
  if (arst) pipe <= 16'hffff;
  else pipe <= {pipe[14:0],1'b0};
 end
 assign rst = pipe[15];
endmodule
