`timescale 1ns/1ps

// 小型 2x2 FAT32 镜像集成测试。通过参数化引擎验证扫描、仲裁、文件流、
// BMP 三字节拼装和写请求握手；640x480 默认参数仍由独立 parser TB 覆盖。
module sd_card_top (
    input clk, input rst, input sd_recover_req,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done, input sd_sec_read, input [31:0] sd_sec_read_addr,
    output wire [7:0] sd_sec_read_data, output wire sd_sec_read_data_valid,
    output wire sd_sec_read_end, output wire [7:0] sd_sec_read_error,
    output wire sd_sec_read_abort, input sd_sec_write, input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data, output sd_sec_write_data_req, output sd_sec_write_end
);
    reg [7:0] mem [0:32767];
    reg active;
    reg [31:0] base;
    integer index;
    assign SD_nCS=1'b1; assign SD_DCLK=1'b0; assign SD_MOSI=1'b0;
    assign sd_sec_write_data_req=1'b0; assign sd_sec_write_end=1'b0;
    assign sd_sec_read_data = active ? mem[base+index] : 8'd0;
    assign sd_sec_read_data_valid = active;
    assign sd_sec_read_end = active && (index==511);
    assign sd_sec_read_error = 8'd0;
    assign sd_sec_read_abort = 1'b0;
    integer i, f, c;
    task put32(input integer a, input [31:0] v);
        begin mem[a]=v[7:0]; mem[a+1]=v[15:8]; mem[a+2]=v[23:16]; mem[a+3]=v[31:24]; end
    endtask
    task put16(input integer a, input [15:0] v);
        begin mem[a]=v[7:0]; mem[a+1]=v[15:8]; end
    endtask
    task make_bmp(input integer a);
        begin
            mem[a+0]=8'h42; mem[a+1]=8'h4d; put32(a+2,32'd66);
            put32(a+10,32'd54); put32(a+14,32'd40); put32(a+18,32'd2);
            put32(a+22,32'd2); put16(a+26,16'd1); put16(a+28,16'd24);
            put32(a+30,32'd0); put32(a+34,32'd66);
            // BGR: red, green, blue, white (two pixels per row, no padding in test parser)
            mem[a+54]=8'h00; mem[a+55]=8'h00; mem[a+56]=8'hff;
            mem[a+57]=8'h00; mem[a+58]=8'hff; mem[a+59]=8'h00;
            mem[a+60]=8'hff; mem[a+61]=8'h00; mem[a+62]=8'h00;
            mem[a+63]=8'hff; mem[a+64]=8'hff; mem[a+65]=8'hff;
        end
    endtask
    task dir_name(input integer a, input [7:0] n);
        begin
            mem[a+0]="P"; mem[a+1]="I"; mem[a+2]="C"; mem[a+3]=n;
            mem[a+4]=" "; mem[a+5]=" "; mem[a+6]=" "; mem[a+7]=" ";
            mem[a+8]="B"; mem[a+9]="M"; mem[a+10]="P"; mem[a+11]=8'h20;
        end
    endtask
    initial begin
        for (i=0;i<32768;i=i+1) mem[i]=0;
        // Super-floppy BPB at LBA0.
        mem[510]=8'h55; mem[511]=8'haa; put16(11,16'd512); mem[13]=1;
        put16(14,16'd1); mem[16]=1; put32(32,32'd64); put32(36,32'd1); put32(44,32'd2);
        // FAT at LBA1: clusters 2..6 are all single-cluster files/directories.
        put32(512+2*4,32'h0ffffff8); put32(512+3*4,32'h0ffffff8);
        put32(512+4*4,32'h0ffffff8); put32(512+5*4,32'h0ffffff8); put32(512+6*4,32'h0ffffff8);
        // Root directory at LBA2.
        for (f=0; f<4; f=f+1) begin
            dir_name(1024+f*32, 8'h31+f); put32(1024+f*32+28,32'd66);
            put16(1024+f*32+26,16'(3+f));
        end
        mem[1024+128]=0;
        for (c=0;c<4;c=c+1) make_bmp((3+c)*512);
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_init_done<=1'b1; active<=0; base<=0; index<=0;
        end else begin
            if (sd_sec_read && !active) begin
                active<=1; base<=sd_sec_read_addr*512; index<=0;
            end else if (active) begin
                if (index==511) begin active<=0; end
                else index<=index+1;
            end
        end
    end
endmodule

module tb_fat32_bmp_engine;
    reg clk=0, rst=1, scan_start=0, load_start=0;
    reg [31:0] load_sector=0;
    wire ready, sd_init_done, scan_done, scan_found_valid, write_req;
    wire [31:0] scan_found_sector;
    wire [2:0] scan_found_total;
    wire [3:0] state_code;
    wire write_en, load_error, load_success, recover;
    wire [23:0] write_data;
    wire [2:0] bmp_error;
    wire [1:0] write_buf_idx = 0;
    wire ncs, dclk, mosi;
    integer found=0, pixels=0, errors=0;
    reg [23:0] expected [0:3];
    assign expected[0]=24'hff0000; assign expected[1]=24'h00ff00;
    assign expected[2]=24'h0000ff; assign expected[3]=24'hffffff;
    always #1 clk=~clk;
    fat32_bmp_engine #(.SD_TIMEOUT_CYCLES(1000),.EXPECTED_WIDTH(2),.EXPECTED_HEIGHT(2)) dut(
        .clk(clk),.rst(rst),.ready(ready),.scan_start(scan_start),.scan_start_sector(0),
        .scan_max_sector(32'd63),.scan_target_count(3'd4),.scan_done(scan_done),
        .scan_found_valid(scan_found_valid),.scan_found_sector(scan_found_sector),
        .scan_found_total(scan_found_total),.load_start(load_start),.load_sector(load_sector),
        .sd_init_done(sd_init_done),.state_code(state_code),.bmp_width(16'd2),.bmp_height(16'd2),
        .write_req(write_req),.write_req_ack(write_req),.bmp_data_wr_en(write_en),
        .bmp_data(write_data[23:0]),.bmp_error(bmp_error),.load_error(load_error),
        .load_success(load_success),.sd_recover_req(recover),
        .pcm_valid(),.pcm_cluster0(),.pcm_cluster1(),.pcm_cluster2(),.pcm_cluster3(),
        .pcm_size0(),.pcm_size1(),.pcm_size2(),.pcm_size3(),
        .fs_sectors_per_cluster(),.fs_fat_start_lba(),.fs_data_start_lba(),
        .fs_max_cluster(),.fs_root_cluster(),
        .audio_req(1'b0),.audio_lba(32'd0),.audio_busy(),.audio_valid(),.audio_byte(),
        .audio_byte_index(),.audio_done(),.audio_error(),.audio_abort(),
        .SD_nCS(ncs),.SD_DCLK(dclk),
        .SD_MOSI(mosi),.SD_MISO(1'b0)
    );
    always @(posedge clk) begin
        if (scan_found_valid) begin
            found=found+1;
            if (scan_found_sector !== (3+found-1)) errors=errors+1;
        end
        if (write_en) begin
            if (write_data[23:0] !== expected[pixels]) errors=errors+1;
            pixels=pixels+1;
        end
    end
    initial begin
        repeat(4) @(posedge clk); rst=0;
        wait(ready); scan_start=1; repeat(4) @(posedge clk); scan_start=0;
        wait(scan_done); if (found!=4) errors=errors+1;
        load_sector=3; @(posedge clk); load_start=1; @(posedge clk); load_start=0;
        wait(load_success || load_error); if (!load_success || load_error || pixels!=4) errors=errors+1;
        if (errors==0) $display("PASS FAT32 engine: scan/load/pixel path");
        else $display("FAIL FAT32 engine: errors=%0d found=%0d pixels=%0d err=%0d",errors,found,pixels,bmp_error);
        $finish;
    end
    initial begin #200000; $fatal(1,"FAT32 engine timeout"); end
endmodule
