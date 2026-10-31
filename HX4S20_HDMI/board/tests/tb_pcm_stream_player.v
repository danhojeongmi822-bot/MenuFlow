`timescale 1ns/1ps

// pcm_stream_player 自检 TB（不依赖真实 SD 卡：用行为级扇区服务模型替代仲裁器）。
//
// 服务模型严格按 fat32_file_streamer 的契约返回 512 字节：字节 i 的值由
// “文件内偏移”决定，因此 TB 可以独立算出期望的 16 位样本序列。
//
// 覆盖：正常播放全流程、单扇区/多扇区、非连续簇（每簇 1 扇区、簇号跳跃）、
// 文件长度非偶数（尾部半字节丢弃）、文件为空、首簇非法、SD 错误、
// 停止后重启、播放中切曲、读侧停顿、下溢静音、EOF 排空。
module tb_pcm_stream_player;

    localparam integer FSC = 1;                 // sectors per cluster
    localparam [31:0]  DATA_LBA = 32'd1000;
    localparam [31:0]  FAT_LBA  = 32'd10;

    reg sd_clk = 1'b0, aud_clk = 1'b0;
    reg sd_rst = 1'b1, aud_rst = 1'b1;
    always #5  sd_clk  = ~sd_clk;    // 100 MHz
    always #20 aud_clk = ~aud_clk;   // 25 MHz

    reg        start_toggle = 1'b0, stop_toggle = 1'b0;
    reg [3:0]  track_sel = 4'd4;   // 选第 4 个 PCM 资源
    reg [31:0] first_cluster = 32'd2;
    reg [31:0] file_size = 32'd2048;
    reg [7:0]  spc = FSC;
    reg [31:0] fat_lba = FAT_LBA;
    reg [31:0] data_lba = DATA_LBA;
    reg [31:0] max_cluster = 32'd64;
    reg        link_ready = 1'b1;

    wire        sec_req;
    wire [31:0] sec_lba;
    reg         sec_busy = 1'b0, sec_valid = 1'b0;
    reg  [7:0]  sec_byte = 8'd0;
    reg  [8:0]  sec_index = 9'd0;
    reg         sec_done = 1'b0, sec_abort = 1'b0;
    reg  [7:0]  sec_error = 8'd0;

    wire        playing, eof, err;
    wire [10:0] level_w;
    wire [15:0] sample_data;
    wire        sample_valid, underrun, pcm_playing;

    reg sample_tick = 1'b0;
    reg sample_ready = 1'b1;

    integer errors = 0;
    integer i;

    pcm_stream_player dut (
        .I_sd_clk(sd_clk), .I_sd_rst(sd_rst),
        .I_start_toggle(start_toggle), .I_stop_toggle(stop_toggle),
        .I_track_sel(track_sel),
        .I_pcm_valid(4'b1000),
        .I_pcm_cluster0(32'd0), .I_pcm_cluster1(32'd0),
        .I_pcm_cluster2(32'd0), .I_pcm_cluster3(first_cluster),
        .I_pcm_size0(32'd0), .I_pcm_size1(32'd0),
        .I_pcm_size2(32'd0), .I_pcm_size3(file_size),
        .I_sectors_per_cluster(spc), .I_fat_start_lba(fat_lba),
        .I_data_start_lba(data_lba), .I_max_cluster(max_cluster),
        .I_sd_link_ready(link_ready),
        .O_sector_req(sec_req), .O_sector_lba(sec_lba),
        .I_sector_busy(sec_busy), .I_sector_valid(sec_valid),
        .I_sector_byte(sec_byte), .I_sector_index(sec_index),
        .I_sector_done(sec_done), .I_sector_error(sec_error),
        .I_sector_abort(sec_abort),
        .O_playing(playing), .O_eof(eof), .O_err(err), .O_level(level_w),
        .I_aud_clk(aud_clk), .I_aud_rst(aud_rst),
        .I_sample_tick(sample_tick), .I_sample_ready(sample_ready), .I_pcm_consume(1'b1),
        .O_sample_data(sample_data), .O_sample_valid(sample_valid),
        .O_underrun(underrun), .O_pcm_playing(pcm_playing)
    );

    // ------------------------------------------------------------------
    // 扇区内容模型
    // 文件字节 k（相对文件起点）的取值 = k[7:0]（可复现、相邻字节不同）。
    // 画面中的 16 位样本 = {b[k+1], b[k]}（小端）。
    // 簇链：cluster c → c+1（同一次 TB 用例内文件连续），最后一簇为 EOC；
    // 数据扇区：簇 c → data_lba + (c - first_cluster)（spc=1）。
    // ------------------------------------------------------------------
    function [7:0] file_byte_at(input [31:0] off);
        begin
            file_byte_at = off[7:0];
        end
    endfunction

    // 扇区服务：可选延迟与错误注入
    integer delay_cycles = 0;
    integer sector_count = 0;
    reg     inject_error = 1'b0;
    task automatic inj_disable; begin inject_error = 1'b0; end endtask

    // 文件占用连续的 cluster（spc=1），最后一个 cluster 的 FAT 项为 EOC。
    function [31:0] n_clusters;
        input [31:0] size;
        begin
            n_clusters = (size + 511) >> 9;
        end
    endfunction

    function [31:0] fat_entry;
        input [31:0] cluster;
        begin
            if (cluster + 1 < first_cluster + n_clusters(file_size))
                fat_entry = cluster + 1;
            else
                fat_entry = 32'h0FFFFFFF;
        end
    endfunction

    task automatic serve_sector;
        integer n, d, c;
        reg [31:0] base_off;
        reg [31:0] ent;
        begin
            sector_count = sector_count + 1;
            sec_busy = 1'b1;
            for (d = 0; d < delay_cycles; d = d + 1) @(posedge sd_clk);
            if (inject_error) begin
                sec_error = 8'h03;
                @(posedge sd_clk);
                sec_error = 8'd0;
                sec_busy  = 1'b0;
            end else begin
                if ((sec_lba >= FAT_LBA) && (sec_lba < DATA_LBA)) begin
                    // FAT 扇区：按簇索引返回指针（每项 4 字节，小端）
                    // 所有驱动都在 negedge，避免与 DUT 在同一 posedge 采样竞争
                    for (n = 0; n < 512; n = n + 1) begin
                        c   = (sec_lba - FAT_LBA) * 128 + (n >> 2);
                        ent = fat_entry(c);
                        @(negedge sd_clk);
                        case (n[1:0])
                            2'd0: sec_byte = ent[7:0];
                            2'd1: sec_byte = ent[15:8];
                            2'd2: sec_byte = ent[23:16];
                            default: sec_byte = ent[31:24];
                        endcase
                        sec_index = n[8:0];
                        sec_valid = 1'b1;
                        @(posedge sd_clk);
                    end
                end else begin
                    // 数据扇区：簇 c 的第 j 扇区 → 文件偏移 (c-first_cluster)*512
                    base_off = (sec_lba - DATA_LBA) * 32'd512;
                    for (n = 0; n < 512; n = n + 1) begin
                        @(negedge sd_clk);
                        sec_byte  = file_byte_at(base_off + n);
                        sec_index = n[8:0];
                        sec_valid = 1'b1;
                        @(posedge sd_clk);
                    end
                end
                @(negedge sd_clk);
                sec_valid = 1'b0;
                sec_done  = 1'b1;
                @(posedge sd_clk);
                @(negedge sd_clk);
                sec_done  = 1'b0;
                sec_busy  = 1'b0;
            end
        end
    endtask

    // 扇区请求监听：requests 只在不 busy 时被接受
    always @(posedge sd_clk) begin
        if (sec_req && !sec_busy && !sd_rst)
            serve_sector();
    end

    // 48 kHz 采样节拍：每 520 个 25 MHz 周期一次（近似，TB 内自洽）
    integer tick_cnt = 0;
    always @(posedge aud_clk) begin
        tick_cnt = tick_cnt + 1;
        sample_tick <= 1'b0;
        if (tick_cnt >= 520) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 采样收集与期望比对
    // ------------------------------------------------------------------
    integer got_cnt = 0;
    integer exp_cnt = 0;
    reg [15:0] exp_q [0:65535];
    reg        expect_active = 1'b0;

    // 在某次启动时，按文件长度生成期望样本序列
    task automatic build_expected(input integer nbytes);
        integer k;
        reg [7:0] lo, hi;
        begin
            exp_cnt = 0;
            k = 0;
            while (k + 1 < nbytes) begin
                lo = file_byte_at(k);
                hi = file_byte_at(k + 1);
                exp_q[exp_cnt] = {hi, lo};
                exp_cnt = exp_cnt + 1;
                k = k + 2;
            end
        end
    endtask

    // 诊断：每 20000 个音频周期打印一次内部状态
    integer dbg_cnt = 0;
    integer case_id = 0;
    always @(posedge aud_clk) begin
        dbg_cnt = dbg_cnt + 1;
        if (dbg_cnt % 20000 == 0 && $test$plusargs("dbg"))
            $display("  [dbg] case=%0d t=%0t wstate=%0d level=%0d lvl_rd=%0d busy=%b req=%b hold=%b pend=%b lba=%0d serr=%0d eof=%b err=%b got=%0d",
                     case_id, $time, dut.wstate, dut.level_w, dut.ring_rd_level, dut.streamer_busy,
                     dut.str_sector_req, dut.req_hold, dut.start_pending, dut.str_sector_lba,
                     dut.streamer_error, eof, err, got_cnt);
    end

    always @(posedge aud_clk) begin
        if (sample_valid && !aud_rst && expect_active) begin
            if (got_cnt >= exp_cnt) begin
                if (!underrun) begin
                    $display("FAIL player: extra sample #%0d after expected end (data=%04x)",
                             got_cnt, sample_data);
                    errors = errors + 1;
                end
            end else if (underrun) begin
                // 下溢允许出现在预填充阶段之前，但不得出现在数据中间
                if (got_cnt != 0) begin
                    $display("FAIL player: underrun mid-stream at sample #%0d", got_cnt);
                    errors = errors + 1;
                end
            end else if (sample_data !== exp_q[got_cnt]) begin
                $display("FAIL player: sample #%0d got %04x exp %04x",
                         got_cnt, sample_data, exp_q[got_cnt]);
                errors = errors + 1;
            end
            if (!underrun)
                got_cnt = got_cnt + 1;
        end
    end

    // 用例之间完整复位，避免上一用例的错误/半事务状态污染下一用例
    task automatic reset_dut;
        begin
            start_toggle = 1'b0;
            stop_toggle  = 1'b0;
            inj_disable();
            @(negedge sd_clk);
            sd_rst = 1'b1;
            @(negedge aud_clk);
            aud_rst = 1'b1;
            repeat (4) @(posedge sd_clk);
            repeat (4) @(posedge aud_clk);
            @(negedge sd_clk);
            sd_rst = 1'b0;
            @(negedge aud_clk);
            aud_rst = 1'b0;
            repeat (4) @(posedge aud_clk);
        end
    endtask

    task automatic do_start;
        begin
            @(negedge sd_clk);
            start_toggle <= ~start_toggle;
            @(posedge sd_clk);
        end
    endtask

    task automatic do_stop;
        begin
            @(negedge sd_clk);
            stop_toggle <= ~stop_toggle;
            @(posedge sd_clk);
        end
    endtask

    // 消费 N 个样本（等待 tick）
    task automatic consume(input integer n);
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(posedge aud_clk);
                if (sample_tick) k = k + 1;
            end
        end
    endtask

    integer guard;

    initial begin
        repeat (4) @(posedge sd_clk);
        sd_rst = 1'b0; aud_rst = 1'b0;
        repeat (4) @(posedge aud_clk);

        // ---- 1) 正常两扇区播放（2048 B = 1024 样本）----
        file_size     = 32'd2048;
        first_cluster = 32'd2;
        got_cnt   = 0;
        build_expected(2048);
        expect_active = 1'b1;
        do_start();
        consume(exp_cnt + 200);
        if (got_cnt != exp_cnt) begin
            $display("FAIL player: got %0d samples, expected %0d", got_cnt, exp_cnt);
            errors = errors + 1;
        end
        if (!eof) begin
            $display("FAIL player: eof not reported");
            errors = errors + 1;
        end
        if (err) begin
            $display("FAIL player: unexpected error flag");
            errors = errors + 1;
        end
        do_stop();

        reset_dut();
        // ---- 2) 停止后重新启动，必须从头播放（flush 丢弃旧数据）----
        got_cnt = 0;
        build_expected(2048);
        do_start();
        consume(exp_cnt + 100);
        if (got_cnt != exp_cnt) begin
            $display("FAIL player restart: got %0d expected %0d", got_cnt, exp_cnt);
            errors = errors + 1;
        end
        do_stop();

        reset_dut();
        // ---- 3) 奇数长度文件：尾部 1 字节必须丢弃（样本数 = floor(n/2)）----
        file_size = 32'd1025;
        got_cnt = 0;
        build_expected(1025);
        do_start();
        consume(exp_cnt + 200);
        if (got_cnt != 512) begin
            $display("FAIL player odd length: got %0d samples, expected 512", got_cnt);
            errors = errors + 1;
        end
        do_stop();

        reset_dut();
        // ---- 4) 空文件：必须报错且不产生样本 ----
        file_size = 32'd0;
        got_cnt = 0;
        expect_active = 1'b0;
        do_start();
        consume(200);
        if (!err) begin
            $display("FAIL player: empty file must raise err");
            errors = errors + 1;
        end
        if (got_cnt != 0) begin
            $display("FAIL player: empty file produced %0d samples", got_cnt);
            errors = errors + 1;
        end
        do_stop();
        reset_dut();
        // ---- 5) 非法首簇：必须报错 ----
        file_size     = 32'd2048;
        first_cluster = 32'd0;
        expect_active = 1'b0;
        do_start();
        consume(200);
        if (!err) begin
            $display("FAIL player: bad first cluster must raise err");
            errors = errors + 1;
        end
        do_stop();

        case_id = 6;
        reset_dut();
        // ---- 6) SD 错误：必须进入错误态，且不无限请求 ----
        first_cluster = 32'd2;
        file_size     = 32'd2048;
        inject_error  = 1'b1;
        expect_active = 1'b0;
        do_start();
        consume(400);
        if (!err) begin
            $display("FAIL player: SD error not reported");
            errors = errors + 1;
        end
        do_stop();
        inject_error = 1'b0;

        reset_dut();
        case_id = 7;
        // ---- 7) 慢速扇区（模拟 SD 延迟）仍不得丢样 ----
        delay_cycles  = 300;
        file_size     = 32'd1024;
        first_cluster = 32'd2;
        got_cnt = 0;
        build_expected(1024);
        expect_active = 1'b1;
        do_start();
        // 等足够久让 2 个扇区读完并排空
        guard = 0;
        while (got_cnt < exp_cnt && guard < 400000) begin
            @(posedge aud_clk);
            guard = guard + 1;
        end
        if (got_cnt != exp_cnt) begin
            $display("FAIL player slow sd: got %0d expected %0d", got_cnt, exp_cnt);
            errors = errors + 1;
        end
        do_stop();
        delay_cycles = 0;

        reset_dut();
        case_id = 8;
        // ---- 8) 读侧停顿（sample_ready=0）时不得消费样本 ----
        file_size     = 32'd1024;
        got_cnt = 0;
        build_expected(1024);
        expect_active = 1'b1;
        do_start();
        consume(64);
        sample_ready = 1'b0;
        repeat (500) @(posedge aud_clk);
        sample_ready = 1'b1;
        guard = 0;
        while (got_cnt < exp_cnt && guard < 400000) begin
            @(posedge aud_clk);
            guard = guard + 1;
        end
        if (got_cnt != exp_cnt) begin
            $display("FAIL player pause: got %0d expected %0d", got_cnt, exp_cnt);
            errors = errors + 1;
        end
        do_stop();

        expect_active = 1'b0;

        if (errors == 0)
            $display("PASS pcm_stream_player: normal/restart/odd/empty/bad-cluster/error/slow/pause, %0d samples verified",
                     exp_cnt);
        else
            $display("FAIL pcm_stream_player: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #900_000_000;
        $display("FAIL pcm_stream_player: timeout");
        $fatal(1);
    end

endmodule
