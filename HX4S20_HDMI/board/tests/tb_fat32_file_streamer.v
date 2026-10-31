`timescale 1ns/1ps
module tb_fat32_file_streamer;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,start=0; reg [31:0] first=3,size=600; reg [7:0] spc=1; reg [31:0] fat=40,data_lba=41,maxc=100;
  wire busy,done,valid,req; wire [7:0] out_byte,err; wire [31:0] off,lba; wire [8:0] idx; reg serving=0; integer pos=0,base; reg [7:0] mem[0:65535];
  wire sec_done=serving && pos==511; wire sec_valid=serving; wire [7:0] sec_byte=serving ? mem[base+pos] : 0; wire [8:0] sec_idx=pos;
  fat32_file_streamer dut(.clk(clk),.rst_n(rst_n),.file_start(start),.first_cluster(first),.file_size(size),.sectors_per_cluster(spc),.fat_start_lba(fat),.data_start_lba(data_lba),.max_cluster(maxc),.file_busy(busy),.file_done(done),.file_valid(valid),.file_byte(out_byte),.file_byte_offset(off),.fs_error(err),.sector_req(req),.sector_lba(lba),.sector_busy(1'b0),.sector_valid(sec_valid),.sector_byte(sec_byte),.sector_byte_index(sec_idx),.sector_done(sec_done),.sector_error(8'd0),.sector_abort(1'b0));
  always @(posedge clk) begin
    if(req && !serving) begin serving<=1; pos<=0; base<=lba*512; end else if(serving) begin if(pos==511) serving<=0; else pos<=pos+1; end
  end
  integer i,count;
  initial begin
    for(i=0;i<65536;i=i+1) mem[i]=0;
    // FAT[3] = 4, FAT[4] = EOF.
    mem[40*512+12]=8'h04; mem[40*512+16]=8'hff; mem[40*512+17]=8'hff; mem[40*512+18]=8'hff; mem[40*512+19]=8'h0f;
    for(i=0;i<512;i=i+1) begin mem[42*512+i]=i[7:0]; mem[43*512+i]=(i+8'd1); end
    count=0; repeat(4) @(posedge clk); rst_n<=1; @(posedge clk); start<=1; @(posedge clk); start<=0;
    forever begin @(posedge clk); if(valid) count=count+1; if(done) begin #1; if(count!=600 || err!=0) begin $display("STREAM_FAIL count=%0d err=%h",count,err); $fatal; end $display("STREAM_PASS bytes=%0d",count); $finish; end end
  end
endmodule
