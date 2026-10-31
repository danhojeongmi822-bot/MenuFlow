`timescale 1ns/1ps
module tb_fat32_volume_scanner;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, scan_start=0, link_ready=1;
  wire busy,done,ready,req; wire [31:0] lba; wire [7:0] err;
  wire valid; wire [7:0] data; wire [8:0] idx; reg sec_busy=0; wire sec_done; wire [7:0] sec_byte; wire sec_valid; reg [7:0] sec_err=0;
  wire [3:0] resources; wire [31:0] c0,c1,c2,c3,s0,s1,s2,s3;
  wire [3:0] pcmv; wire [31:0] pc0,pc1,pc2,pc3,ps0,ps1,ps2,ps3;
  reg [7:0] mem [0:53247]; reg serving=0; integer pos=0; integer base;
  assign idx = pos[8:0]; assign sec_valid=serving; assign sec_byte=serving ? mem[base+pos] : 0; assign sec_done=serving && (pos==511);
  fat32_volume_scanner dut(.clk(clk),.rst_n(rst_n),.scan_start(scan_start),.sector_link_ready(link_ready),.scan_busy(busy),.scan_done(done),.fs_ready(ready),.fs_error(err),.partition_lba(),.root_cluster(),.sectors_per_cluster(),.fat_start_lba(),.data_start_lba(),.max_cluster(),.resource_valid(resources),.resource_cluster0(c0),.resource_cluster1(c1),.resource_cluster2(c2),.resource_cluster3(c3),.resource_size0(s0),.resource_size1(s1),.resource_size2(s2),.resource_size3(s3),
   .pcm_valid(pcmv),.pcm_cluster0(pc0),.pcm_cluster1(pc1),.pcm_cluster2(pc2),.pcm_cluster3(pc3),
   .pcm_size0(ps0),.pcm_size1(ps1),.pcm_size2(ps2),.pcm_size3(ps3),.sector_req(req),.sector_lba(lba),.sector_busy(sec_busy),.sector_valid(sec_valid),.sector_byte(sec_byte),.sector_byte_index(idx),.sector_done(sec_done),.sector_error(sec_err),.sector_abort(1'b0));
  always @(posedge clk) begin
    if(req && !serving) begin serving<=1; pos<=0; base<=lba*512; sec_busy<=1; end
    else if(serving) begin
      if(pos==511) begin serving<=0; sec_busy<=0; end else pos<=pos+1;
    end
  end
  initial begin
    $readmemh("HX4S20_HDMI/board/fat32/fat32_contiguous.hex",mem);
    if ($test$plusargs("BAD_ATTR")) mem[41*512+11] = 8'h10;
    repeat(4) @(posedge clk); rst_n<=1; @(posedge clk); scan_start<=1; @(posedge clk); scan_start<=0;
    wait(done); #1;
    if ($test$plusargs("BAD_ATTR")) begin
      if (ready || resources[0] || err==0) begin
        $display("SCANNER_ATTR_FAIL ready=%b err=%h resources=%b",ready,err,resources); $fatal;
      end
      $display("SCANNER_ATTR_PASS"); $finish;
    end
    if(!ready || err!=0 || resources!==4'b1111 || c0!=3 || c1!=5 || c2!=6 || c3!=8) begin
      $display("SCANNER_FAIL ready=%b err=%h resources=%b c=%0d,%0d,%0d,%0d",ready,err,resources,c0,c1,c2,c3); $fatal;
    end
    $display("SCANNER_PASS root resources=%b",resources); $finish;
  end
endmodule
