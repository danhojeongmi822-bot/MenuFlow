`timescale 1ns/1ps
// Real frame controllers; FIFO stubs only supply empty occupancy.
// Tests handshake CDC, not SDRAM data or physical FIFO behavior.
module tb_frame_ack;
reg mem_clk=0, write_clk=0, read_clk=0, rst=1;
always #12 mem_clk=~mem_clk;
always #5 write_clk=~write_clk;
always #20 read_clk=~read_clk;
reg wr_req=0, rd_req=0;
wire wr_ack, rd_ack, wr_finish, rd_finish;
integer round;
reg previous_wr_meta=0, previous_rd_meta=0;
frame_read_write #(.BURST_SIZE(16)) dut(
 .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(1'b1),
 .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
 .Sdr_rd_en(1'b0), .Sdr_rd_dout(32'b0),
 .write_clk(write_clk), .write_req(wr_req), .write_req_ack(wr_ack),
 .write_finish(wr_finish), .write_addr_0(21'd0), .write_addr_1(21'd307200),
 .write_addr_2(21'd0), .write_addr_3(21'd0), .write_addr_index(2'd1),
 .write_len(21'd0), .write_en(1'b0), .write_data(32'd0),
 .read_clk(read_clk), .read_req(rd_req), .read_req_ack(rd_ack),
 .read_finish(rd_finish), .read_addr_0(21'd0), .read_addr_1(21'd307200),
 .read_addr_2(21'd0), .read_addr_3(21'd0), .read_addr_index(2'd0),
 .read_len(21'd16), .read_en(1'b0));
always @(posedge write_clk) begin
 previous_wr_meta=dut.write_ack_meta;
 #1;
 if (!rst && wr_ack !== previous_wr_meta) $fatal(1,"write ack bypassed second stage");
end
always @(posedge read_clk) begin
 previous_rd_meta=dut.read_ack_meta;
 #1;
 if (!rst && rd_ack !== previous_rd_meta) $fatal(1,"read ack bypassed second stage");
end
initial begin
 repeat(4) @(negedge mem_clk); rst=0;
 for(round=0;round<3;round=round+1) begin
  fork
   begin
    @(negedge write_clk); wr_req=1;
    wait(wr_ack); repeat(4) @(negedge write_clk);
    if(!wr_ack) $fatal(1,"write ack not held");
    wr_req=0; wait(!wr_ack);
   end
   begin
    @(negedge read_clk); rd_req=1;
    wait(rd_ack); repeat(4) @(negedge read_clk);
    if(!rd_ack) $fatal(1,"read ack not held");
    rd_req=0; wait(!rd_ack);
   end
  join
  // FIFO stubs do not model burst data; reset after each handshake.
  repeat(2) @(negedge mem_clk); rst=1;
  repeat(2) @(negedge mem_clk); rst=0;
 end
 @(negedge write_clk); wr_req=1; wait(wr_ack);
 #2 rst=1; #1;
 if(wr_ack !== 0 || rd_ack !== 0) $fatal(1,"reset did not clear ack");
 $display("PASS frame ack: 3 read/write handshakes, 24/10/40 ns clocks, two stages, hold, rearm, reset");
 $finish;
end
initial begin #200000; $display("round=%0d wrreq=%b wrack=%b rdreq=%b rdack=%b wrstate=%d rdstate=%d",round,wr_req,wr_ack,rd_req,rd_ack,dut.frame_fifo_write_m0.state,dut.frame_fifo_read_m0.state); $fatal(1,"handshake timeout"); end
endmodule
module wfifo_32_32_512(input clkr,clkw,rst,we,re,input [31:0] di,
 output empty_flag,full_flag,output [8:0] wrusedw,rdusedw,output [31:0] dout);
assign empty_flag=1; assign full_flag=0;
assign wrusedw=0; assign rdusedw=0; assign dout=0;
endmodule
module rfifo_32_32_512(input clkr,clkw,rst,we,re,input [31:0] di,
 output empty_flag,full_flag,output [8:0] wrusedw,rdusedw,output [31:0] dout);
assign empty_flag=1; assign full_flag=0;
assign wrusedw=0; assign rdusedw=0; assign dout=0;
endmodule
