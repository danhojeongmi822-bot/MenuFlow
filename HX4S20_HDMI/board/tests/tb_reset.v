`timescale 1ns/1ps
module tb_reset;
reg clk=0, arst=0;
wire rst;
integer n;
always #5 clk=~clk;
reset_release dut(clk,arst,rst);
initial begin
 #1; arst=1;
 #2; if(rst!==1) $fatal(1,"async assert failed");
 @(negedge clk); arst=0;
 for(n=1;n<=16;n=n+1) begin
  @(posedge clk); #1;
  if(rst !== (n<16)) $fatal(1,"release mismatch at cycle %0d",n);
 end
 #2; arst=1; #1;
 if(rst!==1) $fatal(1,"loss of lock did not assert reset");
 $display("PASS reset: async assertion, 16-edge release, lock loss"); $finish;
end
endmodule
