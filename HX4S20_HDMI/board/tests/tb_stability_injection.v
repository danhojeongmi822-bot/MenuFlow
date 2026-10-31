`timescale 1ns/1ps

// 第四课异常注入平台：使用可控 bmp_read/SD 桩驱动真实 sd_card_bmp 控制层。
// 桩只模拟事务边界，所有恢复、候选遍历、双缓冲提交和 state_code 语义均来自 RTL。
module bmp_read #(
    parameter integer SD_TIMEOUT_CYCLES = 50_000_000
)(
    input clk, input rst, output ready,
    input scan_start, input [31:0] scan_start_sector, input [31:0] scan_max_sector,
    input [2:0] scan_target_count, output reg scan_done, output reg scan_found_valid,
    output reg [31:0] scan_found_sector, output reg [2:0] scan_found_total,
    input load_start, input [31:0] load_sector, input sd_init_done,
    output [3:0] state_code, input [15:0] bmp_width, input [15:0] bmp_height,
    output reg write_req, input write_req_ack, output sd_sec_read,
    output [31:0] sd_sec_read_addr, input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, input sd_sec_read_end,
    output bmp_data_wr_en, output [23:0] bmp_data,
    output reg [2:0] bmp_error, output reg load_error,
    output reg load_success, output reg sd_recover_req
);
integer attempts;
integer fail_remaining;
integer result_pending;
integer result_countdown;
integer ack_wait;
reg scan_active;
reg load_active;
reg result_started;
assign ready = sd_init_done;
assign state_code = 4'd0;
assign sd_sec_read = 1'b0;
assign sd_sec_read_addr = 32'd0;
assign bmp_data_wr_en = 1'b0;
assign bmp_data = 24'd0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_done <= 1'b0;
        scan_found_valid <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total <= 3'd0;
        write_req <= 1'b0;
        bmp_error <= 3'd0;
        load_error <= 1'b0;
        load_success <= 1'b0;
        sd_recover_req <= 1'b0;
        attempts <= 0;
        fail_remaining <= tb_stability_injection.cfg_fail_count;
        result_pending <= 0;
        result_countdown <= 0;
        ack_wait <= 0;
        scan_active <= 1'b0;
        load_active <= 1'b0;
        result_started <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error <= 1'b0;
        load_success <= 1'b0;
        sd_recover_req <= 1'b0;

        if (scan_start) begin
            scan_active <= 1'b1;
            scan_done <= 1'b0;
            scan_found_total <= 3'd0;
        end
        if (scan_active && (scan_found_total < 3'd4)) begin
            scan_found_valid <= 1'b1;
            scan_found_sector <= 32'd100 + (scan_found_total * 32'd100);
            scan_found_total <= scan_found_total + 3'd1;
            if (scan_found_total == 3'd3) begin
                scan_done <= 1'b1;
                scan_active <= 1'b0;
            end
        end

        if (load_start && !load_active) begin
            attempts <= attempts + 1;
            load_active <= 1'b1;
            write_req <= 1'b1;
            ack_wait <= 0;
            result_started <= 1'b0;
        end
        if (load_active && write_req) begin
            if (write_req_ack && !tb_stability_injection.cfg_block_ack) begin
                write_req <= 1'b0;
                result_started <= 1'b1;
                result_countdown <= tb_stability_injection.cfg_result_delay;
            end else begin
                ack_wait <= ack_wait + 1;
                if (tb_stability_injection.cfg_block_ack && (ack_wait >= 8)) begin
                    write_req <= 1'b0;
                    load_active <= 1'b0;
                    bmp_error <= 3'd5;
                    load_error <= 1'b1;
                end
            end
        end else if (load_active && result_started) begin
            if (result_countdown > 0)
                result_countdown <= result_countdown - 1;
            else begin
                load_active <= 1'b0;
                result_started <= 1'b0;
                if (fail_remaining > 0) begin
                    fail_remaining <= fail_remaining - 1;
                    bmp_error <= tb_stability_injection.cfg_error_code;
                    load_error <= 1'b1;
                end else begin
                    load_success <= 1'b1;
                end
            end
        end
    end
end
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

module tb_stability_injection;
reg clk = 1'b0;
always #1 clk = ~clk;
reg rst = 1'b1;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg write_finish_toggle = 1'b0;
reg write_req_ack = 1'b1;
reg [15:0] bmp_width = 16'd640;
reg [15:0] bmp_height = 16'd480;
reg SD_MISO = 1'b1;

integer cfg_fail_count = 0;
integer cfg_result_delay = 2;
integer cfg_error_code = 1;
reg cfg_block_ack = 1'b0;
integer scenario_id;
integer errors = 0;
integer loads = 0;
integer error_events = 0;
integer commits = 0;
integer media_updates = 0;
integer bad_commits = 0;
integer deadlocks = 0;
reg source_seen_d;
reg [1:0] disp_buf_d;
reg [3:0] state_code_d;
reg display_valid_d;

wire [3:0] state_code;
wire display_valid;
wire [1:0] write_buf_idx, disp_buf_idx;
wire write_req, write_en, SD_nCS, SD_DCLK, SD_MOSI;
wire [31:0] write_data;
wire [1:0] media_id;
wire media_valid;
wire media_update_pulse;

sd_card_bmp #(
    .CLK_FREQ_HZ(1000), .LONG_PRESS_MS(20), .AUTO_PLAY_MS(40),
    .SD_TIMEOUT_CYCLES(32)
) dut(
    .clk(clk), .rst(rst), .sdram_init_done(1'b1), .key_next(key_next), .key_auto(key_auto),
    .auto_hold(1'b0),
    .state_code(state_code), .bmp_width(bmp_width), .bmp_height(bmp_height),
    .display_valid(display_valid), .write_finish_toggle(write_finish_toggle),
    .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
    .write_req(write_req), .write_req_ack(write_req_ack), .write_en(write_en),
    .write_data(write_data), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO)
);

state_code_media_cdc u_media_cdc(
    .I_src_clk(clk), .I_src_rst(rst), .I_state_code(state_code),
    .I_dst_clk(clk), .I_dst_rst(rst), .O_media_id(media_id),
    .O_media_valid(media_valid), .O_update_pulse(media_update_pulse)
);

always @(posedge clk) begin
    if (rst) begin
        source_seen_d <= 1'b0;
        disp_buf_d <= 2'd0;
        state_code_d <= 4'd1;
        display_valid_d <= 1'b0;
    end else begin
        if (dut.load_start_pulse)
            loads <= loads + 1;
        if (dut.bmp_load_error)
            error_events <= error_events + 1;
        if (scenario_id != 11 && dut.source_done_seen && !source_seen_d)
            write_finish_toggle <= ~write_finish_toggle;
        source_seen_d <= dut.source_done_seen;
        if ((display_valid && !display_valid_d) ||
            (state_code != state_code_d && state_code >= 4'd1 && state_code <= 4'd4)) begin
            commits <= commits + 1;
            if (!dut.display_valid || dut.bmp_load_error)
                bad_commits <= bad_commits + 1;
        end
        if (media_update_pulse)
            media_updates <= media_updates + 1;
        disp_buf_d <= dut.disp_buf_idx;
        state_code_d <= state_code;
        display_valid_d <= display_valid;
    end
end

task wait_case;
    input integer max_cycles;
    integer j;
    begin
        for (j = 0; j < max_cycles; j = j + 1) begin
            @(posedge clk);
            if (dut.load_busy === 1'bx)
                $fatal(1, "deadlock/unknown load state in scenario %0d", scenario_id);
        end
        if (dut.load_busy)
            deadlocks = deadlocks + 1;
    end
endtask

task reset_case;
    input integer id;
    input integer fail_count;
    input integer error_code;
    input integer result_delay;
    input reg block_ack;
    begin
        scenario_id = id;
        cfg_fail_count = fail_count;
        cfg_error_code = error_code;
        cfg_result_delay = result_delay;
        cfg_block_ack = block_ack;
        key_next = 1'b1;
        key_auto = 1'b1;
        write_req_ack = 1'b1;
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
    end
endtask

task report_case;
    input [255:0] name;
    integer base_error;
    integer base_load;
    integer base_commit;
    integer base_media;
    begin
        base_error = error_events;
        base_load = loads;
        base_commit = commits;
        base_media = media_updates;
        wait_case(220);
        $display("CASE %0d %-16s errors=%0d loads=%0d commits=%0d media=%0d display=%0d state=%0d", scenario_id,
                 name, error_events-base_error, loads-base_load, commits-base_commit,
                 media_updates-base_media, display_valid, state_code);
    end
endtask

initial begin
    // 1 延迟响应；2 无响应/事务终止；3 中途停止 valid；4 坏头；5 像素截断。
    reset_case(1, 0, 1, 12, 0); report_case("delayed-response");
    reset_case(2, 99, 4, 2, 1); report_case("no-response");
    reset_case(3, 99, 3, 2, 0); report_case("stop-valid");
    reset_case(4, 99, 1, 2, 0); report_case("bad-header");
    reset_case(5, 99, 3, 2, 0); report_case("truncated-pixel");
    // 6 写应答缺失。
    reset_case(6, 99, 5, 2, 1); report_case("write-ack-missing");
    // 7 第一次失败、第二次成功。
    reset_case(7, 1, 1, 2, 0); report_case("retry-success");
    if (!display_valid || loads < 2) errors = errors + 1;
    // 8 先成功显示，再手动请求失败，必须保持 state_code 和显示帧。
    reset_case(8, 0, 1, 2, 0);
    wait_case(120);
    dut.bmp_read_m0.fail_remaining = 99;
    key_next = 1'b0;
    repeat (25) @(posedge clk);
    key_next = 1'b1;
    wait_case(220);
    if (!display_valid || state_code !== 4'd1) errors = errors + 1;
    $display("CASE 8 manual-hold display=%0d state=%0d", display_valid, state_code);
    // 9 首图全部候选失败，必须有界停止且不提交错误帧。
    reset_case(9, 99, 2, 2, 0); report_case("all-candidates-fail");
    if (display_valid || dut.load_busy) errors = errors + 1;
    // 10 恢复后重新正常读取。
    reset_case(10, 1, 1, 2, 0); report_case("recovery-normal");
    if (!display_valid || loads < 2) errors = errors + 1;

    // 写完成早于 BMP 源数据结束：只允许这一笔早到 toggle，不能由
    // source_done_seen 再补发第二笔，否则旧实现会被测试掩盖。
    reset_case(11, 0, 0, 40, 0);
    wait (dut.load_start_pulse);
    @(negedge clk);
    write_finish_toggle = ~write_finish_toggle;
    wait_case(120);
    if (!display_valid) begin
        $display("FAIL early write finish: display was not committed");
        errors = errors + 1;
    end else begin
        $display("PASS early write finish: early toggle was retained");
    end

    if (bad_commits != 0 || deadlocks != 0 || errors != 0)
        $fatal(1, "FAIL stability injection: errors=%0d bad_commits=%0d deadlocks=%0d", errors, bad_commits, deadlocks);
    $display("PASS stability injection: error_events=%0d loads=%0d commits=%0d", error_events, loads, commits);
    $finish;
end

initial begin
    #200000;
    $fatal(1, "stability injection watchdog timeout");
end
endmodule
