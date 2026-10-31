`timescale 1ns/1ps
module tb_bmp;
reg clk=0, rst=1, load=0;
reg valid_byte=0, end_sector=0;
reg [7:0] byte_data=0;
wire ready,req,write_req,pixel_valid;
wire [31:0] sector;
wire [23:0] pixel;
wire [3:0] state_code;
wire [2:0] bmp_error;
wire load_error, load_success, sd_recover_req;
reg [7:0] image[0:921653];
reg [2047:0] path;
integer f,n,i,offset,received=0;
always #5 clk=~clk;
bmp_read dut(.clk(clk),.rst(rst),.ready(ready),
 .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd0),.scan_target_count(3'd4),
 .scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
 .load_start(load),.load_sector(32'd0),.sd_init_done(1'b1),.state_code(state_code),
 .bmp_width(16'd640),.bmp_height(16'd480),.write_req(write_req),.write_req_ack(write_req),
 .sd_sec_read(req),.sd_sec_read_addr(sector),.sd_sec_read_data(byte_data),
 .sd_sec_read_data_valid(valid_byte),.sd_sec_read_end(end_sector),.bmp_data_wr_en(pixel_valid),.bmp_data(pixel),
 .bmp_error(bmp_error),.load_error(load_error),.load_success(load_success),.sd_recover_req(sd_recover_req));
always @(posedge clk) begin
 #1;
 if(!rst && pixel_valid) begin
  if(received>=307200) $fatal(1,"extra pixel");
  offset=54+received*3;
  if(pixel !== {image[offset+2],image[offset+1],image[offset]}) $fatal(1,"RGB mismatch at pixel %0d",received);
  received=received+1;
 end
end
initial begin
 if(!$value$plusargs("BMP=%s",path)) $fatal(1,"missing BMP path");
 f=$fopen(path,"rb"); if(!f) $fatal(1,"open failed");
 n=$fread(image,f); $fclose(f);
 if(n!=921654) $fatal(1,"unexpected file length");
 repeat(3) @(negedge clk); rst=0; load=1;
 @(negedge clk); load=0;
 wait(!ready); wait(ready);
 if(received!=307200) $fatal(1,"pixel count %0d",received);
 if(load_error || !load_success) $fatal(1,"normal BMP did not report success: error=%b code=%0d",load_error,bmp_error);
 $display("PASS BMP: 307200 pixels, every RGB value matches actual file"); $finish;
end
initial begin
 forever begin
  @(negedge clk);
  if(req) begin
   n=sector*512;
   repeat(3) @(negedge clk);
   for(i=0;i<512;i=i+1) begin
    valid_byte=1; byte_data=(n+i<921654)?image[n+i]:0;
    @(negedge clk); valid_byte=0; @(negedge clk);
   end
   end_sector=1; @(negedge clk); end_sector=0;
   wait(!req); repeat(3) @(negedge clk);
  end
 end
end
initial begin #50000000; $fatal(1,"timeout"); end
endmodule
