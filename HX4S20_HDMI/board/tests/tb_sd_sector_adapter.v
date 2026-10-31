`timescale 1ns/1ps
module tb_sd_sector_adapter;
  reg clk=0; always #5 clk=~clk; reg rst_n=0; reg sreq=0,treq=0; reg [31:0] slba=12,tlba=20; wire sbusy,tbusy,svalid,tvalid,sdone,tdone,sabort,tabort; wire [7:0] sdata,tdata,serr,terr; wire [8:0] sidx,tidx; reg [7:0] d=0,e=0; reg dv=0,de=0,da=0; wire rd; wire [31:0] addr;
  reg areq=0; reg [31:0] alba=30; wire abusy,avalid,adone,aabort; wire [7:0] adata,aerr; wire [8:0] aidx;
  sd_sector_adapter #(.TIMEOUT_CYCLES(20)) dut(.clk(clk),.rst_n(rst_n),.scanner_req(sreq),.scanner_lba(slba),.scanner_busy(sbusy),.scanner_valid(svalid),.scanner_byte(sdata),.scanner_byte_index(sidx),.scanner_done(sdone),.scanner_error(serr),.scanner_abort(sabort),.streamer_req(treq),.streamer_lba(tlba),.streamer_busy(tbusy),.streamer_valid(tvalid),.streamer_byte(tdata),.streamer_byte_index(tidx),.streamer_done(tdone),.streamer_error(terr),.streamer_abort(tabort),.audio_req(areq),.audio_lba(alba),.audio_busy(abusy),.audio_valid(avalid),.audio_byte(adata),.audio_byte_index(aidx),.audio_done(adone),.audio_error(aerr),.audio_abort(aabort),.sd_sec_read(rd),.sd_sec_read_addr(addr),.sd_sec_read_data(d),.sd_sec_read_data_valid(dv),.sd_sec_read_end(de),.sd_sec_read_error(e),.sd_sec_read_abort(da));
  reg timeout_seen; reg error_seen; reg late_done_seen; reg owner_seen; integer j;
  initial begin timeout_seen=0; error_seen=0; late_done_seen=0; owner_seen=0; repeat(3) @(posedge clk); rst_n<=1; @(posedge clk); sreq<=1; @(posedge clk); sreq<=0; wait(rd); repeat(3) begin @(posedge clk); d<=8'h5a; dv<=1; end @(posedge clk); dv<=0; de<=1; @(posedge clk); de<=0; wait(sdone); @(posedge clk); #1;
    if(sbusy || serr!=0) begin $display("ADAPTER_FAIL"); $fatal; end
    // Streamer owns the next transaction and receives its data exclusively.
    @(posedge clk); treq<=1; @(posedge clk); treq<=0; wait(rd); repeat(2) begin @(posedge clk); d<=8'ha6; dv<=1; #1 if (tvalid && !svalid && tidx < 2) owner_seen=1; end @(posedge clk); dv<=0; de<=1; @(posedge clk); de<=0; wait(tdone); #1;
    if(!owner_seen || sbusy || serr!=0) begin $display("ADAPTER_OWNER_FAIL owner_seen=%b",owner_seen); $fatal; end
    // A lower-layer read error is routed only to the owning scanner.
    @(posedge clk); sreq<=1; @(posedge clk); sreq<=0; wait(rd); @(posedge clk); e<=8'h21; @(posedge clk); e<=0; #1; if (serr==8'h21) error_seen=1; @(posedge clk); de<=1; @(posedge clk); de<=0; @(posedge clk); #1; if(sdone) late_done_seen=1;
    if(!error_seen || late_done_seen) begin $display("ADAPTER_ERROR_ROUTE_FAIL serr=%h late_done=%b",serr,late_done_seen); $fatal; end
    @(posedge clk); treq<=1; @(posedge clk); treq<=0; wait(tbusy); for(j=0;j<30;j=j+1) begin @(posedge clk); if(terr==8'h08 || tabort) timeout_seen=1; end
    if(!timeout_seen) begin $display("ADAPTER_TIMEOUT_FAIL terr=%h abort=%b",terr,tabort); $fatal; end
    $display("ADAPTER_PASS"); $finish; end
endmodule
