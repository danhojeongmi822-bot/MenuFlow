`timescale 1ns/1ps
module tb_audio;
reg clk=0,mclk=0,rst=1;
wire bclk,lrck,dout,valid;
wire [23:0] left,right;
integer samples=0,nonzero=0;
always #20 clk=~clk;
always #40.6666667 mclk=~mclk;
hdmi_audio_tone_i2s_64fs tone(mclk,rst,bclk,lrck,dout);
I2S_receiver rx(clk,rst,bclk,lrck,dout,valid,left,right);
always @(posedge clk) begin
 #1;
 if(!rst && valid) begin
  samples=samples+1;
  if(left!==right) $fatal(1,"stereo mismatch left=%h right=%h",left,right);
  if(left!=0) begin
   nonzero=nonzero+1;
   if(left!==24'd2000000 && left!==-24'sd2000000) $fatal(1,"corrupt audio sample %h",left);
  end
 end
end
initial begin
 repeat(10) @(negedge clk);
 if(valid!==0 || left!==0 || right!==0) $fatal(1,"receiver outputs not reset");
 rst=0;
 repeat(22000) @(negedge clk);
 if(samples<35 || nonzero<30) $fatal(1,"insufficient audio samples: %0d/%0d",samples,nonzero);
 rst=1; repeat(5) @(negedge clk);
 if(valid!==0 || left!==0 || right!==0) $fatal(1,"receiver fails warm reset");
 $display("PASS audio: %0d samples, %0d nonzero, reset checked",samples,nonzero); $finish;
end
initial begin #2000000; $fatal(1,"timeout"); end
endmodule
