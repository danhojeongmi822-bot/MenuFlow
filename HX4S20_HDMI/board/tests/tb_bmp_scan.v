`timescale 1ns/1ps

module tb_bmp_scan;
reg clk = 1'b0;
reg rst = 1'b1;
reg scan_start = 1'b0;
reg sd_valid = 1'b0;
reg sd_end = 1'b0;
reg [7:0] sd_data = 8'd0;
reg serving = 1'b0;
integer i;

wire ready;
wire sd_read;
wire [31:0] sd_addr;
wire scan_done;
wire scan_found_valid;
wire [31:0] scan_found_sector;
wire [2:0] scan_found_total;

always #5 clk = ~clk;

bmp_read #(.SD_TIMEOUT_CYCLES(100000)) dut(
    .clk(clk), .rst(rst), .ready(ready),
    .scan_start(scan_start), .scan_start_sector(32'd0),
    .scan_max_sector(32'd4000), .scan_target_count(3'd2),
    .scan_done(scan_done), .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
    .load_start(1'b0), .load_sector(32'd0), .sd_init_done(1'b1),
    .state_code(), .bmp_width(16'd640), .bmp_height(16'd480),
    .write_req(), .write_req_ack(1'b0), .sd_sec_read(sd_read),
    .sd_sec_read_addr(sd_addr), .sd_sec_read_data(sd_data),
    .sd_sec_read_data_valid(sd_valid), .sd_sec_read_end(sd_end),
    .bmp_data_wr_en(), .bmp_data(), .bmp_error(), .load_error(),
    .load_success(), .sd_recover_req()
);

function [7:0] header_byte;
    input [31:0] sector;
    input integer offset;
    begin
        header_byte = 8'd0;
        if (offset == 0) header_byte = "B";
        else if (offset == 1) header_byte = "M";
        else if (offset == 2) header_byte = 8'h96;
        else if (offset == 3) header_byte = 8'h10;
        else if (offset == 4) header_byte = 8'h0E;
        else if (offset == 5) header_byte = 8'h00;
        else if (offset >= 10 && offset <= 13) header_byte = (offset == 10) ? 8'd54 : 8'd0;
        else if (offset >= 14 && offset <= 17) header_byte = (offset == 14) ? 8'd40 : 8'd0;
        else if (offset >= 18 && offset <= 21) header_byte = (offset == 18) ? 8'h80 : ((offset == 19) ? 8'h02 : 8'd0);
        else if (offset >= 22 && offset <= 25) header_byte = (offset == 22) ? 8'hE0 : ((offset == 23) ? 8'h01 : 8'd0);
        else if (offset == 26) header_byte = 8'd1;
        else if (offset == 28) header_byte = 8'd24;
        else if (offset >= 30 && offset <= 33) header_byte = 8'd0;
    end
endfunction

initial begin
    forever begin
        @(negedge clk);
        if (sd_read && !serving) begin
            serving = 1'b1;
            if (sd_addr !== 32'd0 && sd_addr !== 32'd1801)
                $fatal(1, "unexpected scan address %0d", sd_addr);
            for (i = 0; i < 512; i = i + 1) begin
                sd_data = header_byte(sd_addr, i);
                sd_valid = 1'b1;
                @(negedge clk);
                sd_valid = 1'b0;
            end
            sd_end = 1'b1;
            @(negedge clk);
            sd_end = 1'b0;
            serving = 1'b0;
        end
    end
end

initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    scan_start = 1'b1;
    @(negedge clk);
    scan_start = 1'b0;
    wait(scan_done);
    if (scan_found_total !== 3'd2)
        $fatal(1, "expected two scanned BMPs, got %0d", scan_found_total);
    $display("PASS scan: file-size skip reached sector 1801 and scan_done asserted");
    $finish;
end

initial begin
    #2000000;
    $fatal(1, "scan test timeout");
end
endmodule
