`timescale 1ns/1ps

module tb_bmp_stability;
reg clk = 1'b0;
reg rst = 1'b1;
reg load_start = 1'b0;
reg valid_byte = 1'b0;
reg end_sector = 1'b0;
reg [7:0] byte_data = 8'd0;
reg [7:0] sector_mem [0:511];
integer i;

wire ready;
wire sd_read;
wire [31:0] sd_addr;
wire write_req;
wire pixel_wr;
wire [23:0] pixel;
wire [2:0] bmp_error;
wire load_error;
wire load_success;
wire sd_recover_req;

always #5 clk = ~clk;

bmp_read #(.SD_TIMEOUT_CYCLES(8)) dut(
    .clk(clk), .rst(rst), .ready(ready),
    .scan_start(1'b0), .scan_start_sector(32'd0), .scan_max_sector(32'd0),
    .scan_target_count(3'd1), .scan_done(), .scan_found_valid(),
    .scan_found_sector(), .scan_found_total(),
    .load_start(load_start), .load_sector(32'd0), .sd_init_done(1'b1),
    .state_code(), .bmp_width(16'd640), .bmp_height(16'd480),
    .write_req(write_req), .write_req_ack(write_req),
    .sd_sec_read(sd_read), .sd_sec_read_addr(sd_addr),
    .sd_sec_read_data(byte_data), .sd_sec_read_data_valid(valid_byte),
    .sd_sec_read_end(end_sector), .bmp_data_wr_en(pixel_wr),
    .bmp_data(pixel), .bmp_error(bmp_error), .load_error(load_error),
    .load_success(load_success), .sd_recover_req(sd_recover_req)
);

task clear_sector;
    begin
        for (i = 0; i < 512; i = i + 1)
            sector_mem[i] = 8'd0;
    end
endtask

task put32;
    input integer off;
    input [31:0] value;
    begin
        sector_mem[off] = value[7:0];
        sector_mem[off+1] = value[15:8];
        sector_mem[off+2] = value[23:16];
        sector_mem[off+3] = value[31:24];
    end
endtask

task send_sector;
    begin
        wait(sd_read);
        for (i = 0; i < 512; i = i + 1) begin
            @(negedge clk);
            byte_data = sector_mem[i];
            valid_byte = 1'b1;
            @(negedge clk);
            valid_byte = 1'b0;
        end
        @(negedge clk);
        end_sector = 1'b1;
        @(negedge clk);
        end_sector = 1'b0;
    end
endtask

initial begin
    clear_sector();
    // 先验证 SD 完全无响应：必须在有界周期内上报超时并拉起局部恢复请求。
    repeat (2) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    load_start = 1'b1;
    @(negedge clk);
    load_start = 1'b0;
    wait(load_error);
    if (bmp_error !== 3'd4 || !sd_recover_req)
        $fatal(1, "timeout error/recovery pulse mismatch");
    @(posedge clk);
    #1;
    if (sd_recover_req)
        $fatal(1, "recovery request did not return to idle");

    // 再验证像素区长度不可信的 BMP 头被拒绝，不产生写请求。
    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    clear_sector();
    sector_mem[0] = "B";
    sector_mem[1] = "M";
    put32(2, 32'd1000);
    put32(10, 32'd54);
    put32(14, 32'd40);
    put32(18, 32'd640);
    put32(22, 32'd480);
    sector_mem[26] = 8'd1;
    sector_mem[28] = 8'd24;
    put32(30, 32'd0);
    @(negedge clk);
    load_start = 1'b1;
    @(negedge clk);
    load_start = 1'b0;
    send_sector();
    wait(load_error);
    if (bmp_error !== 3'd2 || write_req)
        $fatal(1, "invalid length header was not rejected");

    // 宽度高 16 位非零，即使低 16 位仍为 640，也必须拒绝。
    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    clear_sector();
    sector_mem[0] = "B";
    sector_mem[1] = "M";
    put32(2, 32'd921654);
    put32(10, 32'd54);
    put32(14, 32'd40);
    put32(18, 32'h00010280);
    put32(22, 32'd480);
    sector_mem[26] = 8'd1;
    sector_mem[28] = 8'd24;
    put32(30, 32'd0);
    @(negedge clk);
    load_start = 1'b1;
    @(negedge clk);
    load_start = 1'b0;
    send_sector();
    wait(load_error);
    if (bmp_error !== 3'd1 || write_req)
        $fatal(1, "upper width bits were not rejected");

    // 合法头但像素区只返回一个扇区，后续扇区无进度时必须有界超时且不成功。
    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    clear_sector();
    sector_mem[0] = "B";
    sector_mem[1] = "M";
    put32(2, 32'd921654);
    put32(10, 32'd54);
    put32(14, 32'd40);
    put32(18, 32'd640);
    put32(22, 32'd480);
    sector_mem[26] = 8'd1;
    sector_mem[28] = 8'd24;
    put32(30, 32'd0);
    @(negedge clk);
    load_start = 1'b1;
    @(negedge clk);
    load_start = 1'b0;
    send_sector();
    send_sector();
    wait(load_error);
    if (bmp_error !== 3'd4 || load_success || write_req)
        $fatal(1, "truncated pixel data was not bounded by timeout");

    $display("PASS stability: timeout, strict header checks, and truncated-pixel rejection");
    $finish;
end

initial begin
    #200000;
    $fatal(1, "stability test timeout");
end
endmodule
