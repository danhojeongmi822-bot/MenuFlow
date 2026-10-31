`timescale 1ns/1ps

// 快速启停鲁棒性：模拟用户连续翻页（播放中反复 stop/start）。
//
// 关键场景（实板已复现的缺陷）：
//   在扇区事务进行中停止播放 → fat32_file_streamer 停在 S_DATA_WAIT 等 sector_done，
//   若此时撤回请求，它将永远等待，file_busy 永久为 1，后续 start 全部无法生效。
//
// 本 TB 用“慢扇区服务模型”（每个扇区固定延迟）确保 stop 一定落在事务中间。
module tb_pcm_player_restart;

    localparam [31:0] DATA_LBA = 32'd1000;
    localparam [31:0] FAT_LBA  = 32'd10;
    localparam integer SECTOR_DELAY = 400;   // 每扇区延迟（SD 周期）

    reg sd_clk = 1'b0, aud_clk = 1'b0;
    reg sd_rst = 1'b1, aud_rst = 1'b1;
    always #5  sd_clk  = ~sd_clk;    // 100 MHz
    always #20 aud_clk = ~aud_clk;   // 25 MHz

    reg        start_toggle = 1'b0, stop_toggle = 1'b0;
    reg [3:0]  track_sel = 4'd4;
    reg [31:0] file_size = 32'd4096;
    reg [31:0] first_cluster = 32'd2;

    wire        sec_req;
    wire [31:0] sec_lba;
    reg         sec_busy = 1'b0, sec_valid = 1'b0;
    reg  [7:0]  sec_byte = 8'd0;
    reg  [8:0]  sec_index = 9'd0;
    reg         sec_done = 1'b0, sec_abort = 1'b0;
    reg  [7:0]  sec_error = 8'd0;

    wire        playing, eof, err;
    wire [10:0] level;
    wire [15:0] sample_data;
    wire        sample_valid, underrun, pcm_playing;

    reg sample_tick = 1'b0, sample_ready = 1'b1;

    integer errors = 0;

    pcm_stream_player dut (
        .I_sd_clk(sd_clk), .I_sd_rst(sd_rst),
        .I_start_toggle(start_toggle), .I_stop_toggle(stop_toggle),
        .I_track_sel(track_sel),
        .I_pcm_valid(4'b1000),
        .I_pcm_cluster0(32'd0), .I_pcm_cluster1(32'd0),
        .I_pcm_cluster2(32'd0), .I_pcm_cluster3(first_cluster),
        .I_pcm_size0(32'd0), .I_pcm_size1(32'd0),
        .I_pcm_size2(32'd0), .I_pcm_size3(file_size),
        .I_sectors_per_cluster(8'd1),
        .I_fat_start_lba(FAT_LBA), .I_data_start_lba(DATA_LBA),
        .I_max_cluster(32'd64),
        .I_sd_link_ready(1'b1),
        .O_sector_req(sec_req), .O_sector_lba(sec_lba),
        .I_sector_busy(sec_busy), .I_sector_valid(sec_valid),
        .I_sector_byte(sec_byte), .I_sector_index(sec_index),
        .I_sector_done(sec_done), .I_sector_error(sec_error),
        .I_sector_abort(sec_abort),
        .O_playing(playing), .O_eof(eof), .O_err(err), .O_level(level),
        .I_aud_clk(aud_clk), .I_aud_rst(aud_rst),
        .I_sample_tick(sample_tick), .I_sample_ready(sample_ready),
        .I_pcm_consume(1'b1),
        .O_sample_data(sample_data), .O_sample_valid(sample_valid),
        .O_underrun(underrun), .O_pcm_playing(pcm_playing)
    );

    // ---------------- 慢扇区服务模型 ----------------
    function [7:0] fb; input [31:0] off; begin fb = off[7:0] ^ 8'h3C; end endfunction
    function [31:0] nclu; input [31:0] s; begin nclu = (s + 511) >> 9; end endfunction
    function [31:0] fat_entry; input [31:0] c;
        begin
            if (c + 1 < first_cluster + nclu(file_size)) fat_entry = c + 1;
            else fat_entry = 32'h0FFFFFFF;
        end
    endfunction

    reg [31:0] cur_lba;
    integer d, n, c;

    // 仲裁侧响应延迟：真实 SD 卡有命令/CS 开销，请求拉高后不会当拍被接受。
    // 这个窗口正是 stop 可能把在途请求吞掉的区间。
    localparam integer ARB_DELAY = 60;
    integer arb_cnt = 0;
    always @(posedge sd_clk) begin
        if (sec_req && !sec_busy) begin
            if (arb_cnt >= ARB_DELAY) begin
                arb_cnt  <= 0;
                sec_busy <= 1'b1;
                cur_lba  <= sec_lba;
            end else begin
                arb_cnt <= arb_cnt + 1;
            end
        end else begin
            arb_cnt <= 0;
        end
    end

    task automatic serve;
        reg [31:0] base_off, ent;
        begin
            // 延迟：保证 stop 有机会落在事务中间
            for (d = 0; d < SECTOR_DELAY; d = d + 1) @(posedge sd_clk);
            @(negedge sd_clk);
            if ((cur_lba >= FAT_LBA) && (cur_lba < DATA_LBA)) begin
                for (n = 0; n < 512; n = n + 1) begin
                    c = (cur_lba - FAT_LBA) * 128 + (n >> 2);
                    ent = fat_entry(c);
                    case (n[1:0])
                        2'd0: sec_byte = ent[7:0];
                        2'd1: sec_byte = ent[15:8];
                        2'd2: sec_byte = ent[23:16];
                        default: sec_byte = ent[31:24];
                    endcase
                    sec_index = n[8:0];
                    sec_valid = 1'b1;
                    @(negedge sd_clk);
                end
            end else begin
                base_off = (cur_lba - (DATA_LBA + first_cluster - 2)) * 32'd512;
                for (n = 0; n < 512; n = n + 1) begin
                    sec_byte  = fb(base_off + n);
                    sec_index = n[8:0];
                    sec_valid = 1'b1;
                    @(negedge sd_clk);
                end
            end
            sec_valid = 1'b0;
            sec_done  = 1'b1;
            @(negedge sd_clk);
            sec_done  = 1'b0;
            sec_busy  = 1'b0;
        end
    endtask

    always @(posedge sd_clk) begin
        if (sec_busy && !sec_valid && !sec_done) serve();
    end

    // ---------------- 48 kHz tick ----------------
    integer tick_cnt = 0;
    always @(posedge aud_clk) begin
        tick_cnt    <= tick_cnt + 1;
        sample_tick <= 1'b0;
        if (tick_cnt >= 520) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b1;
        end
    end

    // ---------------- 统计 ----------------
    integer samples_seen = 0;
    always @(posedge aud_clk) begin
        if (sample_valid && !underrun && !aud_rst) samples_seen = samples_seen + 1;
    end

    task automatic do_start;
        begin
            @(negedge sd_clk); start_toggle = ~start_toggle;
            @(posedge sd_clk);
        end
    endtask

    task automatic do_stop;
        begin
            @(negedge sd_clk); stop_toggle = ~stop_toggle;
            @(posedge sd_clk);
        end
    endtask

    // 等待若干采样点被消费
    task automatic wait_samples(input integer n, output integer got);
        integer k, guard;
        begin
            k = 0; guard = 0;
            got = 0;
            while ((k < n) && (guard < 3000000)) begin
                @(posedge aud_clk);
                if (sample_valid && !underrun) k = k + 1;
                guard = guard + 1;
            end
            got = k;
        end
    endtask

    integer got, round;
    integer fail_at = -1;
    reg     abort_case = 1'b0;

    initial begin
        repeat (4) @(posedge sd_clk);
        sd_rst = 1'b0; aud_rst = 1'b0;
        repeat (6) @(posedge aud_clk);

        // 连续 6 轮“播放 → 立刻停止 → 再播放”，每轮都必须恢复出声
        for (round = 1; round <= 6; round = round + 1) begin
            if (!abort_case) begin
                do_start();
                // 只消费少量样本就停止，确保停止时扇区事务仍在进行
                wait_samples(64, got);
                if (got < 64) begin
                    $display("FAIL restart: round %0d no samples (got %0d, playing=%b err=%b lvl=%0d busy=%b wstate=%0d fsize=%0d fclu=%0d streamer_err=%0d)",
                             round, got, playing, err, level, dut.streamer_busy,
                             dut.wstate, dut.file_size_lat, dut.file_cluster_lat, dut.streamer_error);
                    errors = errors + 1;
                    if (fail_at < 0) fail_at = round;
                    abort_case = 1'b1;
                end
            end

            if (!abort_case) begin
                do_stop();
                repeat (20) @(posedge sd_clk);

                // 停止后重新播放必须恢复
                do_start();
                wait_samples(64, got);
                if (got < 64) begin
                    $display("FAIL restart: round %0d did NOT resume (got %0d, playing=%b err=%b eof=%b lvl=%0d busy=%b)",
                             round, got, playing, err, eof, level, dut.streamer_busy);
                    errors = errors + 1;
                    if (fail_at < 0) fail_at = round;
                    abort_case = 1'b1;
                end
            end

            if (!abort_case) begin
                do_stop();
                repeat (20) @(posedge sd_clk);
            end
        end

        if (errors == 0)
            $display("PASS pcm_player_restart: 6 start/stop rounds all resumed playback");
        else
            $display("FAIL pcm_player_restart: %0d assertion(s), first failing round %0d", errors, fail_at);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL pcm_player_restart: timeout");
        $fatal(1);
    end

endmodule
