`timescale 1ns/1ps

// OSD 错误码来源验证：实例化真实 sd_card_bmp（legacy 分支），
// 通过 force 驱动 SD/BMP 内部状态，检查 E1/00/01..04/E0 的优先级与粘滞语义。
// 该测试只验证“状态→错误码”映射，不替代 FAT32/BMP 数据通路测试。
module tb_osd_error_code;

    reg         clk;
    reg         rst;
    reg         key1;
    reg         key2;
    reg         wfin;
    wire [3:0]  state_code;
    wire        display_valid;
    wire [1:0]  wbuf, dbuf;
    wire [3:0]  bank_valid;
    wire        commit_toggle;
    wire        auto_play_en;
    wire [7:0]  osd_error_code;
    wire        wr_req, wr_en;
    wire [31:0] wr_data;
    wire        sd_ncs, sd_dclk, sd_mosi;

    integer fails;

    sd_card_bmp #(
        .CLK_FREQ_HZ       (100_000_000),
        .SCAN_START_SECTOR (32'd0),
        .SCAN_MAX_SECTOR   (32'd131071),
        .SCAN_TARGET_COUNT (3'd4),
        .USE_FAT32         (1'b0)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .sdram_init_done   (1'b1),
        .key_next          (key1),
        .key_auto          (key2),
        .auto_hold         (1'b0),
        .state_code        (state_code),
        .bmp_width         (16'd640),
        .bmp_height        (16'd480),
        .display_valid     (display_valid),
        .write_finish_toggle(wfin),
        .write_buf_idx     (wbuf),
        .disp_buf_idx      (dbuf),
        .bank_valid        (bank_valid),
        .frame_commit_toggle(commit_toggle),
        .auto_play_en      (auto_play_en),
        .osd_error_code    (osd_error_code),
        .write_req         (wr_req),
        .write_req_ack     (1'b1),
        .write_en          (wr_en),
        .write_data        (wr_data),
        .SD_nCS            (sd_ncs),
        .SD_DCLK           (sd_dclk),
        .SD_MOSI           (sd_mosi),
        .SD_MISO           (1'b1)
    );

    initial begin
        clk  = 1'b0;
        rst  = 1'b1;
        key1 = 1'b1;
        key2 = 1'b1;
        wfin = 1'b0;
        fails = 0;
        #200;
        rst = 1'b0;
    end

    always #5 clk = ~clk;   // 100 MHz

    task expect_code;
        input [7:0] exp;
        input integer step;
        begin
            #1;
            if (osd_error_code !== exp) begin
                fails = fails + 1;
                $display("FAIL error-code: step %0d expected %02h got %02h",
                         step, exp, osd_error_code);
            end else begin
                $display("INFO error-code: step %0d = %02h", step, osd_error_code);
            end
        end
    endtask

    initial begin
        @(negedge rst);   // 等复位释放后再开始状态序列
        // 1) SD 初始化中
        force dut.sd_init_done = 1'b0;
        @(posedge clk); @(posedge clk);
        expect_code(8'hE1, 1);

        // 2) 初始化完成，E1 自动清除
        force dut.sd_init_done = 1'b1;
        @(posedge clk); @(posedge clk);
        expect_code(8'h00, 2);

        // 3) BMP 错误码 1..4
        force dut.bmp_error = 3'd1;
        @(posedge clk); @(posedge clk);
        expect_code(8'h01, 3);

        force dut.bmp_error = 3'd4;
        @(posedge clk); @(posedge clk);
        expect_code(8'h04, 4);

        // 4) 错误码粘滞：bmp_error 撤销后仍保留，直到成功事件
        release dut.bmp_error;
        @(posedge clk); @(posedge clk);
        expect_code(8'h04, 5);

        force dut.bmp_load_success = 1'b1;
        @(posedge clk); @(posedge clk);
        expect_code(8'h00, 6);
        release dut.bmp_load_success;

        // 5) 扫描完成但无图片 -> E0
        force dut.img_found_count = 3'd0;
        force dut.scan_done = 1'b1;
        @(posedge clk); @(posedge clk);
        expect_code(8'hE0, 7);
        release dut.scan_done;

        // 6) 扫描完成且有图片 -> 00
        force dut.img_found_count = 3'd3;
        force dut.scan_done = 1'b1;
        @(posedge clk); @(posedge clk);
        expect_code(8'h00, 8);
        release dut.scan_done;
        release dut.img_found_count;

        // 7) 运行中 SD 失联 -> E1
        force dut.sd_init_done = 1'b0;
        @(posedge clk); @(posedge clk);
        expect_code(8'hE1, 9);
        release dut.sd_init_done;

        if (fails == 0) begin
            $display("PASS error-code: E1/00/01/04/E0 priority and sticky behavior");
            $finish;
        end else begin
            $display("FAIL error-code: %0d failure(s)", fails);
            $fatal(1);
        end
    end

endmodule
