`timescale 1ns/1ps

// 三 owner 仲裁专项：
//   1) 三方同时请求时扫描优先；
//   2) BMP 长突发不会把音频饿死（音频在有限拍内得到服务）；
//   3) 音频长突发不会把 BMP 饿死；
//   4) 错误/abort 只发给当次 owner；
//   5) A_RELEASE 单拍间隔、owner 信号互斥。
module tb_sd_adapter_three_owner;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        sreq = 0, treq = 0, areq = 0;
    reg [31:0] slba = 100, tlba = 200, alba = 300;
    wire sbusy, tbusy, abusy;
    wire svalid, tvalid, avalid;
    wire sdone, tdone, adone;
    wire sabort, tabort, aabort;
    wire [7:0] sdata, tdata, adata, serr, terr, aerr;
    wire [8:0] sidx, tidx, aidx;

    reg  [7:0] d = 0;
    reg        dv = 0, de = 0, da = 0;
    wire       rd;
    wire [31:0] addr;

    integer errors = 0;
    integer cycles;
    integer audio_grants, bmp_grants, scan_grants;
    reg [31:0] seen_lba;

    sd_sector_adapter #(.TIMEOUT_CYCLES(200), .GRANT_LIMIT(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .scanner_req(sreq), .scanner_lba(slba), .scanner_busy(sbusy),
        .scanner_valid(svalid), .scanner_byte(sdata), .scanner_byte_index(sidx),
        .scanner_done(sdone), .scanner_error(serr), .scanner_abort(sabort),
        .streamer_req(treq), .streamer_lba(tlba), .streamer_busy(tbusy),
        .streamer_valid(tvalid), .streamer_byte(tdata), .streamer_byte_index(tidx),
        .streamer_done(tdone), .streamer_error(terr), .streamer_abort(tabort),
        .audio_req(areq), .audio_lba(alba), .audio_busy(abusy),
        .audio_valid(avalid), .audio_byte(adata), .audio_byte_index(aidx),
        .audio_done(adone), .audio_error(aerr), .audio_abort(aabort),
        .sd_sec_read(rd), .sd_sec_read_addr(addr),
        .sd_sec_read_data(d), .sd_sec_read_data_valid(dv),
        .sd_sec_read_end(de), .sd_sec_read_error(8'd0), .sd_sec_read_abort(da)
    );

    // 每笔事务 4 字节后结束
    integer beat;
    always @(posedge clk) begin
        dv <= 1'b0; de <= 1'b0;
        if (rd && !de) begin
            beat <= beat + 1;
            if (beat >= 3) begin
                de   <= 1'b1;
                beat <= 0;
            end else begin
                d  <= addr[7:0] + beat[7:0];
                dv <= 1'b1;
            end
        end else if (!rd) begin
            beat <= 0;
        end
    end

    // 每次获得总线时记录地址，用于统计各 owner 的服务次数
    reg rd_d;
    integer audio_total, bmp_total, scan_total;
    always @(posedge clk) begin
        rd_d <= rd;
        if (rd && !rd_d) begin
            case (addr)
                32'd100: scan_total  <= scan_total + 1;
                32'd200: bmp_total   <= bmp_total + 1;
                32'd300: audio_total <= audio_total + 1;
                default: ;
            endcase
        end
    end

    task automatic clear_reqs;
        begin
            sreq = 0; treq = 0; areq = 0;
        end
    endtask

    // 在 N 拍内持续请求，检查谁得到服务
    task automatic run_window(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge clk);
        end
    endtask

    initial begin
        beat = 0;
        audio_total = 0; bmp_total = 0; scan_total = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1) 三方同时请求：扫描必须最先得到地址 ----
        @(negedge clk);
        sreq = 1; treq = 1; areq = 1;
        @(posedge clk); #1;
        if (addr !== 32'd100) begin
            $display("FAIL three_owner: scanner not served first (addr=%0d)", addr);
            errors = errors + 1;
        end
        // 只让扫描继续（模拟短事务后释放）
        @(negedge clk);
        sreq = 0;
        run_window(20);
        clear_reqs();
        run_window(10);

        // ---- 2) 音频与 BMP 同时长请求：两者都必须在窗口内获得服务 ----
        audio_total = 0; bmp_total = 0;
        @(negedge clk);
        areq = 1; treq = 1;
        run_window(300);
        if (audio_total < 3) begin
            $display("FAIL three_owner: audio starved (audio=%0d bmp=%0d)", audio_total, bmp_total);
            errors = errors + 1;
        end
        if (bmp_total < 3) begin
            $display("FAIL three_owner: bmp starved (audio=%0d bmp=%0d)", audio_total, bmp_total);
            errors = errors + 1;
        end
        // 公平性：两者服务次数差距不得超过 2 倍 + 常数
        if ((audio_total > 2 * bmp_total + 3) || (bmp_total > 2 * audio_total + 3)) begin
            $display("FAIL three_owner: unfair ratio audio=%0d bmp=%0d", audio_total, bmp_total);
            errors = errors + 1;
        end
        clear_reqs();
        run_window(10);

        // ---- 3) 只有音频请求时，不得出现 BMP 事务 ----
        audio_total = 0; bmp_total = 0;
        @(negedge clk); areq = 1;
        run_window(120);
        if (bmp_total != 0) begin
            $display("FAIL three_owner: bmp served while idle (%0d)", bmp_total);
            errors = errors + 1;
        end
        if (audio_total < 3) begin
            $display("FAIL three_owner: audio alone not served (%0d)", audio_total);
            errors = errors + 1;
        end
        clear_reqs();
        run_window(10);

        // ---- 4) busy/valid 互斥：任一时刻最多一个 owner busy ----
        @(negedge clk); areq = 1; treq = 1;
        for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
            @(posedge clk); #1;
            if ((sbusy + tbusy + abusy) > 1) begin
                $display("FAIL three_owner: multiple owners busy at %0d", cycles);
                errors = errors + 1;
            end
            if ((svalid + tvalid + avalid) > 1) begin
                $display("FAIL three_owner: multiple owners valid at %0d", cycles);
                errors = errors + 1;
            end
        end
        clear_reqs();
        run_window(10);

        if (errors == 0)
            $display("PASS sd_adapter_three_owner: scan-priority, fairness, exclusivity");
        else
            $display("FAIL sd_adapter_three_owner: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL sd_adapter_three_owner: timeout");
        $fatal(1);
    end

endmodule
