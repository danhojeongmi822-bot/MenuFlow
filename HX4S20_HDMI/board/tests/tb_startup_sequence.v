`timescale 1ns/1ps

// 第五课启动顺序验证：覆盖锁定、按域复位释放、SDRAM 完成门控和运行中复位。
// bmp_read/sd_card_top 的协议细节仍由现有回归覆盖；这里仅对 sd_card_bmp
// 的启动边界施加可控桩信号，避免依赖厂商加密 IP。
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
    output [2:0] bmp_error, output load_error, output load_success,
    output sd_recover_req
);
assign ready = 1'b1;
assign scan_done = 1'b0;
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
assign load_success = 1'b0;
assign sd_recover_req = 1'b0;
endmodule

module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV = 248,
    parameter SPI_HIGH_SPEED_DIV = 0
)(
    input clk, input rst, input sd_recover_req,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output sd_init_done, input sd_sec_read, input [31:0] sd_sec_read_addr,
    output [7:0] sd_sec_read_data, output sd_sec_read_data_valid,
    output sd_sec_read_end, input sd_sec_write, input [31:0] sd_sec_write_addr,
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

module tb_startup_sequence;
reg clk = 1'b0;
reg rst_n = 1'b0;
reg sys_lock = 1'b0;
reg video_lock = 1'b0;
reg sdram_done_mem = 1'b0;
reg write_finish_toggle = 1'b0;
reg bmp_load_success = 1'b0;
reg key_next = 1'b1;
reg key_auto = 1'b1;
integer cycle_count = 0;
integer scan_count = 0;
integer load_count = 0;
integer commit_count = 0;
integer reset_count = 0;
reg reset_seen = 1'b0;
reg lock_seen = 1'b0;
reg domain_release_seen = 1'b0;
reg sdram_seen = 1'b0;
reg display_valid_d = 1'b0;

wire rst_all = !rst_n || !sys_lock || !video_lock;
wire rst_sd;
wire [1:0] sdram_done_sync;
reg [1:0] sdram_done_sync_r;
wire sdram_done_sd = sdram_done_sync_r[1];

wire [3:0] state_code;
wire display_valid;
wire [1:0] write_buf_idx, disp_buf_idx;
wire write_req, write_en, SD_nCS, SD_DCLK, SD_MOSI;
wire [31:0] write_data;

assign sdram_done_sync = sdram_done_sync_r;

reset_release u_reset_release(.clk(clk), .arst(rst_all), .rst(rst_sd));

always #5 clk = ~clk;

always @(posedge clk or posedge rst_sd) begin
    if (rst_sd)
        sdram_done_sync_r <= 2'b00;
    else
        sdram_done_sync_r <= {sdram_done_sync_r[0], sdram_done_mem};
end

sd_card_bmp #(
    .CLK_FREQ_HZ(1000),
    .LONG_PRESS_MS(20),
    .AUTO_PLAY_MS(40),
    .SD_TIMEOUT_CYCLES(32)
) dut(
    .clk(clk), .rst(rst_sd), .sdram_init_done(sdram_done_sd),
    .key_next(key_next), .key_auto(key_auto),
    .auto_hold(1'b0),
    .state_code(state_code), .bmp_width(16'd640), .bmp_height(16'd480),
    .display_valid(display_valid), .write_finish_toggle(write_finish_toggle),
    .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
    .write_req(write_req), .write_req_ack(1'b0), .write_en(write_en),
    .write_data(write_data), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI), .SD_MISO(1'b0)
);

// 只替换 SD/BMP 完成边界，保留 sd_card_bmp 的真实控制状态机。
initial begin
    force dut.sd_init_done = 1'b1;
    force dut.bmp_ready = 1'b1;
    force dut.bmp_load_error = 1'b0;
    force dut.sd_recover_req = 1'b0;
    force dut.scan_done = 1'b0;
    force dut.img_found_count = 3'd1;
    force dut.img_sector0 = 32'd100;
    force dut.bmp_load_success = bmp_load_success;
end

always @(negedge clk) begin
    cycle_count = cycle_count + 1;

    if (!rst_n && !reset_seen) begin
        reset_count = reset_count + 1;
        reset_seen = 1'b1;
        $display("EVENT %0d EXT_RESET_ASSERT cycle=%0d", reset_count, cycle_count);
    end
    if (rst_n)
        reset_seen = 1'b0;

    if (sys_lock && video_lock && !lock_seen) begin
        lock_seen = 1'b1;
        $display("EVENT PLL_LOCK_BOTH cycle=%0d", cycle_count);
    end
    if (!rst_sd && !domain_release_seen) begin
        domain_release_seen = 1'b1;
        $display("EVENT DOMAIN_RESET_RELEASE cycle=%0d", cycle_count);
    end
    if (sdram_done_sd && !sdram_seen) begin
        sdram_seen = 1'b1;
        $display("EVENT SDRAM_INIT_DONE cycle=%0d", cycle_count);
    end
    if (dut.scan_start_pulse) begin
        if (rst_sd || !sdram_done_sd)
            $fatal(1, "scan started before reset/SDRAM release at cycle %0d", cycle_count);
        scan_count = scan_count + 1;
        $display("EVENT SCAN_START #%0d cycle=%0d", scan_count, cycle_count);
    end
    if (dut.load_start_pulse) begin
        if (rst_sd || !sdram_done_sd)
            $fatal(1, "load started before reset/SDRAM release at cycle %0d", cycle_count);
        load_count = load_count + 1;
        $display("EVENT LOAD_START #%0d cycle=%0d", load_count, cycle_count);
    end
    if (display_valid && !display_valid_d) begin
        if (!sdram_done_sd)
            $fatal(1, "frame committed before SDRAM init at cycle %0d", cycle_count);
        commit_count = commit_count + 1;
        $display("EVENT FRAME_COMMIT #%0d cycle=%0d", commit_count, cycle_count);
    end
    display_valid_d = display_valid;

    if (!rst_sd && !sys_lock)
        $fatal(1, "domain reset released while PLL lock is absent");
    if (!rst_n && (dut.scan_start_pulse || dut.load_start_pulse || display_valid))
        $fatal(1, "activity crossed external reset boundary");
end

task wait_for_scan;
    integer n;
    begin
        for (n = 0; n < 200; n = n + 1) begin
            @(negedge clk);
            if (dut.scan_start_pulse)
                disable wait_for_scan;
        end
        $fatal(1, "scan start timeout");
    end
endtask

task wait_for_load;
    integer n;
    begin
        for (n = 0; n < 50; n = n + 1) begin
            @(negedge clk);
            if (dut.load_start_pulse)
                disable wait_for_load;
        end
        $fatal(1, "load start timeout");
    end
endtask

task wait_for_commit;
    integer n;
    begin
        for (n = 0; n < 100; n = n + 1) begin
            @(negedge clk);
            if (display_valid)
                disable wait_for_commit;
        end
        $fatal(1, "frame commit timeout");
    end
endtask

initial begin
    sdram_done_sync_r = 2'b00;
    repeat (4) @(negedge clk);

    // 外部复位释放但 PLL 未锁定：域复位必须保持有效且无启动事件。
    rst_n = 1'b1;
    repeat (20) @(negedge clk);
    if (!rst_sd || scan_count != 0 || load_count != 0)
        $fatal(1, "activity occurred before PLL lock");

    sys_lock = 1'b1;
    video_lock = 1'b1;
    repeat (18) @(negedge clk);
    if (rst_sd)
        $fatal(1, "domain reset did not release after both PLLs locked");
    if (scan_count != 0)
        $fatal(1, "scan occurred before SDRAM done");

    // SDRAM 完成经过两级同步后才允许扫描。
    sdram_done_mem = 1'b1;
    wait_for_scan();
    // 模拟 FAT32 引擎的真实边界：scan_done 只脉冲一拍，而 ready
    // 在下一拍才恢复。顶层必须锁存扫描完成事件，不能依赖同拍 ready。
    force dut.bmp_ready = 1'b0;
    force dut.scan_done = 1'b1;
    @(negedge clk);
    release dut.scan_done;
    force dut.bmp_ready = 1'b1;
    wait_for_load();
    bmp_load_success = 1'b1;
    wait (dut.source_done_seen);
    write_finish_toggle = ~write_finish_toggle;
    wait_for_commit();
    bmp_load_success = 1'b0;

    // 运行中重新复位：旧显示和启动脉冲必须清除，随后可再次完整启动。
    rst_n = 1'b0;
    sys_lock = 1'b0;
    video_lock = 1'b0;
    sdram_done_mem = 1'b0;
    repeat (4) @(negedge clk);
    if (rst_sd !== 1'b1 || display_valid || dut.scan_start_pulse || dut.load_start_pulse)
        $fatal(1, "re-reset did not return to safe state");

    rst_n = 1'b1;
    repeat (20) @(negedge clk);
    if (!rst_sd)
        $fatal(1, "reset released while PLLs were still unlocked");
    sys_lock = 1'b1;
    video_lock = 1'b1;
    repeat (18) @(negedge clk);
    sdram_done_mem = 1'b1;
    wait_for_scan();

    if (reset_count != 2 || scan_count != 2 || load_count < 1 || commit_count != 1)
        $fatal(1, "unexpected event counts reset=%0d scan=%0d load=%0d commit=%0d",
               reset_count, scan_count, load_count, commit_count);
    $display("PASS startup sequence: reset/PLL lock/domain release/SDRAM gate/restart");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "startup sequence timeout");
end

endmodule
