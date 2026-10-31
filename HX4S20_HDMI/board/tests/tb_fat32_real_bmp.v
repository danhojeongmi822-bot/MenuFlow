`timescale 1ns/1ps

// 640x480 / 24-bit / 921654-byte BMP over a FAT32 chain of 1801 clusters.
// This test exercises the production engine with the same file geometry as
// the board assets, rather than the small 2x2 smoke image.
module sd_card_top (
    input clk, input rst, input sd_recover_req,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done, input sd_sec_read, input [31:0] sd_sec_read_addr,
    output [7:0] sd_sec_read_data, output sd_sec_read_data_valid,
    output sd_sec_read_end, output [7:0] sd_sec_read_error,
    output sd_sec_read_abort, input sd_sec_write, input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data, output sd_sec_write_data_req, output sd_sec_write_end
);
    localparam integer SECTORS = 4096;
    localparam integer BYTES = SECTORS * 512;
    reg [7:0] mem [0:BYTES-1];
    reg active;
    reg [31:0] base;
    reg [8:0] index;
    integer i, p, cluster;
    assign SD_nCS = 1'b1;
    assign SD_DCLK = 1'b0;
    assign SD_MOSI = 1'b0;
    assign sd_sec_write_data_req = 1'b0;
    assign sd_sec_write_end = 1'b0;
    assign sd_sec_read_data = active ? mem[base + index] : 8'd0;
    assign sd_sec_read_data_valid = active;
    assign sd_sec_read_end = active && (index == 9'd511);
    assign sd_sec_read_error = 8'd0;
    assign sd_sec_read_abort = 1'b0;

    task put16(input integer a, input [15:0] v);
        begin mem[a] = v[7:0]; mem[a+1] = v[15:8]; end
    endtask
    task put32(input integer a, input [31:0] v);
        begin mem[a] = v[7:0]; mem[a+1] = v[15:8]; mem[a+2] = v[23:16]; mem[a+3] = v[31:24]; end
    endtask
    task dir_entry(input integer a, input [7:0] n, input [31:0] first, input [31:0] size);
        begin
            mem[a+0] = "P"; mem[a+1] = "I"; mem[a+2] = "C"; mem[a+3] = n;
            mem[a+4] = " "; mem[a+5] = " "; mem[a+6] = " "; mem[a+7] = " ";
            mem[a+8] = "B"; mem[a+9] = "M"; mem[a+10] = "P"; mem[a+11] = 8'h20;
            put16(a+26, first[15:0]); put16(a+20, first[31:16]); put32(a+28, size);
        end
    endtask

    initial begin
        for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'd0;
        // Super-floppy FAT32 layout: FAT=LBA1, root=LBA2, data=LBA3.
        mem[510] = 8'h55; mem[511] = 8'haa;
        put16(11, 16'd512); mem[13] = 8'd1; put16(14, 16'd1); mem[16] = 8'd1;
        put32(32, SECTORS); put32(36, 32'd16); put32(44, 32'd2);
        put32(512 + 2*4, 32'h0fffffff);
        for (cluster = 3; cluster <= 1803; cluster = cluster + 1)
            put32(512 + cluster*4, (cluster == 1803) ? 32'h0fffffff : cluster + 1);
        dir_entry(17*512 + 0*32, "1", 32'd3, 32'd921654);
        dir_entry(17*512 + 1*32, "2", 32'd3, 32'd921654);
        dir_entry(17*512 + 2*32, "3", 32'd3, 32'd921654);
        dir_entry(17*512 + 3*32, "4", 32'd3, 32'd921654);
        // BMP header followed by a solid red BGR payload.
        put16(18*512 + 0, 16'h4d42); put32(18*512 + 2, 32'd921654);
        put32(18*512 + 10, 32'd54); put32(18*512 + 14, 32'd40);
        put32(18*512 + 18, 32'd640); put32(18*512 + 22, 32'd480);
        put16(18*512 + 26, 16'd1); put16(18*512 + 28, 16'd24);
        put32(18*512 + 30, 32'd0); put32(18*512 + 34, 32'd921600);
        for (p = 54; p < 921654; p = p + 3) begin
            mem[18*512 + p] = 8'h00;
            mem[18*512 + p + 1] = 8'h00;
            mem[18*512 + p + 2] = 8'hff;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin sd_init_done <= 1'b1; active <= 1'b0; base <= 0; index <= 0; end
        else if (sd_sec_read && !active) begin active <= 1'b1; base <= sd_sec_read_addr * 512; index <= 0; end
        else if (active && index == 9'd511) active <= 1'b0;
        else if (active) index <= index + 1'b1;
    end
endmodule

module tb_fat32_real_bmp;
    reg clk = 0, rst = 1, scan_start = 0, load_start = 0;
    reg [31:0] load_sector = 0;
    wire ready, sd_init_done, scan_done, scan_found_valid, write_req;
    wire [31:0] scan_found_sector;
    wire [2:0] scan_found_total;
    wire [3:0] state_code;
    wire write_en, load_error, load_success, recover;
    wire [23:0] write_data;
    wire [2:0] bmp_error;
    wire ncs, dclk, mosi;
    integer found = 0, pixels = 0, errors = 0;
    always #1 clk = ~clk;

    fat32_bmp_engine #(.SD_TIMEOUT_CYCLES(2000000)) dut (
        .clk(clk), .rst(rst), .ready(ready), .scan_start(scan_start),
        .scan_start_sector(32'd0), .scan_max_sector(32'd4095), .scan_target_count(3'd4),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
        .load_start(load_start), .load_sector(load_sector), .sd_init_done(sd_init_done),
        .state_code(state_code), .bmp_width(16'd640), .bmp_height(16'd480),
        .write_req(write_req), .write_req_ack(write_req), .bmp_data_wr_en(write_en),
        .bmp_data(write_data), .bmp_error(bmp_error), .load_error(load_error),
        .load_success(load_success), .sd_recover_req(recover), .SD_nCS(ncs),
        .SD_DCLK(dclk), .SD_MOSI(mosi), .SD_MISO(1'b0)
    );
    always @(posedge clk) begin
        if (scan_found_valid) begin
            found = found + 1;
            if (scan_found_sector !== 32'd3) errors = errors + 1;
        end
        if (write_en) begin
            if (write_data !== 24'hff0000) errors = errors + 1;
            pixels = pixels + 1;
        end
    end
    initial begin
        repeat (4) @(posedge clk); rst = 0; wait (ready);
        scan_start = 1; repeat (2) @(posedge clk); scan_start = 0;
        wait (scan_done); if (found != 4) errors = errors + 1;
        load_sector = 3; @(posedge clk); load_start = 1; @(posedge clk); load_start = 0;
        wait (load_success || load_error);
        if (!load_success || load_error || pixels != 307200) errors = errors + 1;
        if (errors == 0) $display("PASS FAT32 real BMP: pixels=%0d", pixels);
        else $display("FAIL FAT32 real BMP: errors=%0d found=%0d pixels=%0d err=%0d", errors, found, pixels, bmp_error);
        $finish;
    end
    initial begin #10000000; $fatal(1, "real FAT32 BMP timeout"); end
endmodule
