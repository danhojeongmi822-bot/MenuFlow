`timescale 1ns/1ps

// 控制层行为测试使用桩模块隔离 SD/SPI 和 BMP 数据通道。
module bmp_read #(
    parameter integer SD_TIMEOUT_CYCLES = 50_000_000
)(
    input clk, input rst, output ready,
    input scan_start, input [31:0] scan_start_sector, input [31:0] scan_max_sector,
    input [2:0] scan_target_count, output scan_done, output scan_found_valid,
    output [31:0] scan_found_sector, output [2:0] scan_found_total,
    input load_start, input [31:0] load_sector, input sd_init_done,
    output [3:0] state_code, input [15:0] bmp_width, input [15:0] bmp_height,
    output write_req, input write_req_ack, output sd_sec_read,
    output [31:0] sd_sec_read_addr, input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, input sd_sec_read_end,
    output bmp_data_wr_en, output [23:0] bmp_data,
    output [2:0] bmp_error, output load_error, output reg load_success,
    output sd_recover_req
);
assign ready = 1'b1;
assign scan_done = 1'b1;
assign scan_found_valid = 1'b0;
assign scan_found_sector = 32'd0;
assign scan_found_total = 3'd0;
assign state_code = 4'd0;
assign write_req = 1'b0;
assign sd_sec_read = 1'b0;
assign sd_sec_read_addr = 32'd0;
assign bmp_data_wr_en = 1'b0;
assign bmp_data = 24'd0;
assign bmp_error = 3'd0;
assign load_error = 1'b0;
assign sd_recover_req = 1'b0;
always @(posedge clk or posedge rst) begin
    if (rst)
        load_success <= 1'b0;
    else
        load_success <= load_start;
end
endmodule

module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV = 248,
    parameter SPI_HIGH_SPEED_DIV = 0
)(
    input clk, input rst, input sd_recover_req, output SD_nCS, output SD_DCLK, output SD_MOSI,
    input SD_MISO, output sd_init_done, input sd_sec_read,
    input [31:0] sd_sec_read_addr, output [7:0] sd_sec_read_data,
    output sd_sec_read_data_valid, output sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data, output sd_sec_write_data_req,
    output sd_sec_write_end
);
assign SD_nCS = 1'b1;
assign SD_DCLK = 1'b0;
assign SD_MOSI = 1'b0;
assign sd_init_done = 1'b1;
assign sd_sec_read_data = 8'd0;
assign sd_sec_read_data_valid = 1'b0;
assign sd_sec_read_end = 1'b0;
assign sd_sec_write_data_req = 1'b0;
assign sd_sec_write_end = 1'b0;
endmodule

module tb_sd_card_bmp_control;
reg clk = 1'b0;
always #1 clk = ~clk;
reg rst = 1'b1;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg auto_hold = 1'b0;
reg write_finish_toggle = 1'b0;
reg write_req_ack = 1'b0;
reg [15:0] bmp_width = 16'd640;
reg [15:0] bmp_height = 16'd480;
reg SD_MISO = 1'b1;
wire [3:0] state_code;
wire display_valid;
wire [1:0] write_buf_idx, disp_buf_idx;
wire [3:0] bank_valid;
wire frame_commit_toggle;
wire write_req, write_en, SD_nCS, SD_DCLK, SD_MOSI;
wire [31:0] write_data;
integer errors = 0;

sd_card_bmp #(
    .CLK_FREQ_HZ(1000),
    .LONG_PRESS_MS(50),
    .AUTO_PLAY_MS(100)
) dut(
    .clk(clk), .rst(rst), .sdram_init_done(1'b1), .key_next(key_next), .key_auto(key_auto),
    .auto_hold(auto_hold),
    .state_code(state_code), .bmp_width(bmp_width), .bmp_height(bmp_height),
    .display_valid(display_valid), .write_finish_toggle(write_finish_toggle),
    .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
    .bank_valid(bank_valid), .frame_commit_toggle(frame_commit_toggle),
    .write_req(write_req), .write_req_ack(write_req_ack), .write_en(write_en),
    .write_data(write_data), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO)
);

task wait_cycles(input integer count);
    begin repeat(count) @(posedge clk); end
endtask

task seed_two_images;
    begin
        force dut.scan_kicked = 1'b1;
        force dut.scan_done = 1'b1;
        force dut.img_found_count = 3'd2;
        force dut.img_idx = 2'd0;
        force dut.img_sector0 = 32'd100;
        force dut.img_sector1 = 32'd200;
        force dut.display_valid = 1'b1;
        force dut.first_image_committed = 1'b1;
        force dut.load_busy = 1'b0;
        #2;
        release dut.scan_kicked;
        release dut.scan_done;
        release dut.img_found_count;
        release dut.img_idx;
        release dut.img_sector0;
        release dut.img_sector1;
        release dut.display_valid;
        release dut.first_image_committed;
        release dut.load_busy;
    end
endtask

task reset_control;
    begin
        rst = 1'b1;
        key_auto = 1'b1;
        key_next = 1'b1;
        wait_cycles(3);
        rst = 1'b0;
        wait_cycles(5);
        seed_two_images();
    end
endtask

initial begin
    reset_control();

    // KEY1 短按：请求下一张并启动对应加载。
    key_next = 1'b0;
    wait_cycles(25);
    key_next = 1'b1;
    wait_cycles(25);
    if (dut.load_idx !== 2'd1 || dut.load_busy !== 1'b1) begin
        $display("FAIL KEY1: next-image load not started");
        errors = errors + 1;
    end

    // 忙时同时挂起上一张和下一张，空闲后必须先执行下一张。
    reset_control();
    force dut.load_busy = 1'b0;
    force dut.next_req_pending = 1'b1;
    force dut.prev_req_pending = 1'b1;
    #1;
    release dut.load_busy;
    wait_cycles(1);
    if (dut.load_idx !== 2'd1 || dut.load_sector !== 32'd200) begin
        $display("FAIL pending priority: next-image request did not win");
        errors = errors + 1;
    end
    release dut.next_req_pending;
    release dut.prev_req_pending;

    reset_control();

    // 短按 KEY2：释放后切换自动轮播，不请求上一张。
    key_auto = 1'b0;
    wait_cycles(25);
    key_auto = 1'b1;
    wait_cycles(25);
    if (dut.auto_play_en !== 1'b1) begin
        $display("FAIL short KEY2: auto_play_en did not toggle");
        errors = errors + 1;
    end
    if (dut.load_idx !== 2'd0 || dut.prev_req_pending !== 1'b0) begin
        $display("FAIL short KEY2: unexpected previous-image request");
        errors = errors + 1;
    end

    // 长按 KEY2：暂停自动计时，只请求一次上一张，释放后不再切换自动模式。
    key_auto = 1'b0;
    wait_cycles(80);
    if (dut.load_idx !== 2'd1 || dut.load_busy !== 1'b1) begin
        $display("FAIL long KEY2: previous-image load not started");
        errors = errors + 1;
    end
    if (dut.auto_play_en !== 1'b1) begin
        $display("FAIL long KEY2: long press toggled auto mode");
        errors = errors + 1;
    end
    key_auto = 1'b1;
    wait_cycles(25);
    // 模拟 SDRAM 写完成 toggle，确认原子提交后 state_code 跟随图片编号。
    write_finish_toggle = 1'b1;
    wait_cycles(4);
    write_finish_toggle = 1'b0;
    wait_cycles(4);
    if (state_code !== 4'd2 || display_valid !== 1'b1) begin
        $display("FAIL commit: state_code/display_valid not updated for previous image");
        errors = errors + 1;
    end

    // 复位后验证 AUTO_PLAY_MS 参数触发下一张。
    reset_control();
    force dut.auto_play_en = 1'b1;
    wait_cycles(110);
    if (dut.load_idx !== 2'd1 || dut.load_busy !== 1'b1) begin
        $display("FAIL auto-play: parameterized period did not start next image");
        errors = errors + 1;
    end
    release dut.auto_play_en;

    // 管理模式 auto_hold：暂停自动轮播但保留 auto_play_en 记忆，释放后继续。
    reset_control();
    force dut.auto_play_en = 1'b1;
    auto_hold = 1'b1;
    wait_cycles(150);
    if (dut.load_idx !== 2'd0 || dut.load_busy !== 1'b0 || dut.auto_cnt !== 32'd0) begin
        $display("FAIL auto_hold: auto advance not paused (load_idx=%0d busy=%0d cnt=%0d)",
                 dut.load_idx, dut.load_busy, dut.auto_cnt);
        errors = errors + 1;
    end
    if (dut.auto_play_en !== 1'b1) begin
        $display("FAIL auto_hold: auto_play_en memory changed");
        errors = errors + 1;
    end
    auto_hold = 1'b0;
    wait_cycles(110);
    if (dut.load_idx !== 2'd1 || dut.load_busy !== 1'b1) begin
        $display("FAIL auto_hold release: auto advance did not resume");
        errors = errors + 1;
    end
    release dut.auto_play_en;

    // Four-bank cache hit: an already valid next image commits its Bank index
    // without starting a new TF write transaction.
    reset_control();
    force dut.bank_valid = 4'b0011;
    force dut.img_idx = 2'd0;
    force dut.display_valid = 1'b1;
    force dut.first_image_committed = 1'b1;
    force dut.load_busy = 1'b0;
    #2;
    release dut.img_idx;
    release dut.display_valid;
    release dut.first_image_committed;
    release dut.load_busy;
    key_next = 1'b0;
    wait_cycles(25);
    key_next = 1'b1;
    wait_cycles(25);
    if (dut.load_busy !== 1'b0 || dut.disp_buf_idx !== 2'd1 ||
        dut.frame_commit_toggle !== 1'b1) begin
        $display("FAIL four-bank cache hit: reload or commit behavior incorrect");
        errors = errors + 1;
    end
    release dut.bank_valid;

    // Startup preload must fill the next Bank without changing the displayed image.
    reset_control();
    force dut.img_found_count = 3'd4;
    force dut.bank_valid = 4'b0001;
    force dut.bank_blocked = 4'b0000;
    force dut.img_idx = 2'd0;
    force dut.disp_buf_idx = 2'd0;
    force dut.display_valid = 1'b1;
    force dut.first_image_committed = 1'b1;
    force dut.load_busy = 1'b0;
    #2;
    release dut.img_found_count;
    release dut.bank_valid;
    release dut.bank_blocked;
    release dut.img_idx;
    release dut.disp_buf_idx;
    release dut.display_valid;
    release dut.first_image_committed;
    release dut.load_busy;
    wait_cycles(4);
    if (dut.load_idx !== 2'd1 || dut.load_busy !== 1'b1) begin
        $display("FAIL preload: next Bank load did not start");
        errors = errors + 1;
    end
    write_finish_toggle = 1'b1;
    wait_cycles(4);
    write_finish_toggle = 1'b0;
    wait_cycles(4);
    if (dut.img_idx !== 2'd0 || dut.disp_buf_idx !== 2'd0 ||
        dut.state_code !== 4'd1 || dut.frame_commit_toggle !== 1'b0 ||
        dut.bank_valid[1] !== 1'b1) begin
        $display("FAIL preload: background load changed displayed image");
        errors = errors + 1;
    end

    // 只有一张图片时，KEY2 短按不能开启轮播或切换图片。
    reset_control();
    force dut.img_found_count = 3'd1;
    #2;
    release dut.img_found_count;
    key_auto = 1'b0;
    wait_cycles(25);
    key_auto = 1'b1;
    wait_cycles(25);
    if (dut.auto_play_en !== 1'b0 || dut.load_idx !== 2'd0) begin
        $display("FAIL single-image guard: KEY2 changed state");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS control: KEY2 short/long behavior and AUTO_PLAY_MS");
    else
        $display("FAIL control: %0d assertion(s)", errors);
    $finish;
end

initial begin
    #2000;
    $fatal(1, "control test timeout");
end
endmodule
