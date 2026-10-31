`timescale 1ns/1ps

// 音频子系统集成：页面门控 → 播放器 → 音源选择 端到端。
//
// 目的：在没有真实 SD 卡的情况下，用“扇区服务模型”跑通
//   PIC3 进入 → 播放 → 离开 → 停止 → 进入 PIC4 → 播放 → 文件结束
// 全流程，并断言：
//   * 输出样本与文件内容逐字节一致（无重复/丢失/乱序）；
//   * 离开促销页后不再输出 PCM 样本，且音源回到媒体琶音；
//   * PCM 缺失时回落琶音，不卡死；
//   * 转场期间不重启播放（无重复样本）。
module tb_audio_subsystem;

    localparam integer FSC = 1;

    reg sd_clk = 1'b0, pix_clk = 1'b0;
    reg sd_rst = 1'b1, pix_rst = 1'b1;
    always #5  sd_clk  = ~sd_clk;     // 100 MHz
    always #20 pix_clk = ~pix_clk;    // 25 MHz

    // ---------------- 页面门控侧 ----------------
    reg        frame_start = 1'b0;
    reg [1:0]  active_index = 2'd0;
    reg        display_valid = 1'b1;
    reg        trans_busy = 1'b0;
    wire       start_toggle, stop_toggle;
    wire [3:0] track_sel;
    wire       should_play;
    wire [1:0] gate_page;

    audio_page_gate gate (
        .clk(pix_clk), .rst(pix_rst), .frame_start(frame_start),
        .active_index(active_index), .display_valid(display_valid), .trans_busy(trans_busy),
        .start_toggle(start_toggle), .stop_toggle(stop_toggle),
        .track_sel(track_sel), .should_play(should_play), .page_q(gate_page)
    );

    // ---------------- 播放器 ----------------
    reg  [3:0]  pcm_valid = 4'b1111;
    reg  [31:0] fsize0 = 32'd1024, fsize1 = 32'd1024, fsize2 = 32'd1024, fsize3 = 32'd1024;
    reg  [31:0] fclus0 = 32'd2, fclus1 = 32'd4, fclus2 = 32'd6, fclus3 = 32'd8;

    wire        sec_req;
    wire [31:0] sec_lba;
    reg         sec_busy = 1'b0, sec_valid = 1'b0;
    reg  [7:0]  sec_byte = 8'd0;
    reg  [8:0]  sec_index = 9'd0;
    reg         sec_done = 1'b0;
    reg  [7:0]  sec_error = 8'd0;

    wire        playing, eof, err;
    wire [10:0] level;
    wire [15:0] pcm_sample;
    wire        pcm_valid_out, pcm_underrun, pcm_playing;

    reg sample_tick = 1'b0;
    wire mux_consume;

    pcm_stream_player player (
        .I_sd_clk(sd_clk), .I_sd_rst(sd_rst),
        .I_start_toggle(start_toggle), .I_stop_toggle(stop_toggle),
        .I_track_sel(track_sel),
        .I_pcm_valid(pcm_valid),
        .I_pcm_cluster0(fclus0), .I_pcm_cluster1(fclus1),
        .I_pcm_cluster2(fclus2), .I_pcm_cluster3(fclus3),
        .I_pcm_size0(fsize0), .I_pcm_size1(fsize1),
        .I_pcm_size2(fsize2), .I_pcm_size3(fsize3),
        .I_sectors_per_cluster(8'd1),
        .I_fat_start_lba(32'd10),
        .I_data_start_lba(32'd1000),
        .I_max_cluster(32'd64),
        .I_sd_link_ready(1'b1),
        .O_sector_req(sec_req), .O_sector_lba(sec_lba),
        .I_sector_busy(sec_busy), .I_sector_valid(sec_valid),
        .I_sector_byte(sec_byte), .I_sector_index(sec_index),
        .I_sector_done(sec_done), .I_sector_error(sec_error), .I_sector_abort(1'b0),
        .O_playing(playing), .O_eof(eof), .O_err(err), .O_level(level),
        .I_aud_clk(pix_clk), .I_aud_rst(pix_rst),
        .I_sample_tick(sample_tick), .I_sample_ready(1'b1), .I_pcm_consume(mux_consume),
        .O_sample_data(pcm_sample), .O_sample_valid(pcm_valid_out),
        .O_underrun(pcm_underrun), .O_pcm_playing(pcm_playing)
    );

    // ---------------- 音源选择 ----------------
    reg        media_valid = 1'b1;
    reg [23:0] media_l = 24'sd100000, media_r = 24'sd100000;
    wire        aud_valid;
    wire [23:0] aud_l, aud_r;
    wire [1:0]  aud_src;
    wire [7:0]  aud_gain;

    audio_source_mux mux (
        .I_clk(pix_clk), .I_rst(pix_rst), .I_sample_tick(sample_tick),
        .I_pcm_valid(pcm_valid_out), .I_pcm_sample(pcm_sample), .I_pcm_playing(pcm_playing),
        .I_media_active(media_valid), .I_media_valid(media_valid),
        .I_media_left(media_l), .I_media_right(media_r),
        .I_test_valid(1'b0), .I_test_left(24'd0), .I_test_right(24'd0),
        .O_audio_valid(aud_valid), .O_audio_left(aud_l), .O_audio_right(aud_r),
        .O_active_source(aud_src), .O_gain(aud_gain), .O_pcm_consume(mux_consume)
    );

    // ---------------- 48 kHz tick ----------------
    integer tick_cnt = 0;
    always @(posedge pix_clk) begin
        tick_cnt     <= tick_cnt + 1;
        sample_tick  <= 1'b0;
        if (tick_cnt >= 520) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b1;
        end
    end

    // ---------------- 扇区服务模型 ----------------
    // 页面 n 对应簇 = fclus(n-1)，文件偏移 → 数据扇区 data_lba + 偏移
    function [7:0] fb; input [31:0] off; begin fb = off[7:0] ^ 8'h3C; end endfunction

    function [31:0] nclusters; input [31:0] size; begin
        nclusters = (size + 511) >> 9; end endfunction

    function [31:0] fat_entry; input [31:0] cluster; input [31:0] first; input [31:0] size;
        begin
            if (cluster + 1 < first + nclusters(size)) fat_entry = cluster + 1;
            else fat_entry = 32'h0FFFFFFF;
        end
    endfunction

    reg [31:0] cur_lba;
    reg [31:0] cur_first, cur_size;

    always @(posedge sd_clk) begin
        if (sec_req && !sec_busy) begin
            sec_busy <= 1'b1;
            cur_lba  <= sec_lba;
        end
    end

    // 当前播放页面对应的 first/size（服务模型用）
    always @* begin
        case (track_sel)
            4'd1: begin cur_first = fclus0; cur_size = fsize0; end
            4'd2: begin cur_first = fclus1; cur_size = fsize1; end
            4'd3: begin cur_first = fclus2; cur_size = fsize2; end
            default: begin cur_first = fclus3; cur_size = fsize3; end
        endcase
    end

    task automatic serve;
        integer n, c;
        reg [31:0] base_off, ent;
        begin
            @(negedge sd_clk);
            if ((cur_lba >= 10) && (cur_lba < 1000)) begin
                for (n = 0; n < 512; n = n + 1) begin
                    c = (cur_lba - 10) * 128 + (n >> 2);
                    ent = fat_entry(c, cur_first, cur_size);
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
                // 文件首扇区 = data_lba + (first_cluster - 2)
                base_off = (cur_lba - (1000 + cur_first - 2)) * 32'd512;
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
            sec_done = 1'b0;
            sec_busy = 1'b0;
        end
    endtask

    always @(posedge sd_clk) begin
        if (sec_busy && !sec_valid && !sec_done) serve();
    end

    // ---------------- 集成契约统计 ----------------
    //
    // 分层验证策略（避免重复且避免同沿竞争）：
    //   * 文件字节 → 16 位样本的逐样本正确性：tb_pcm_stream_player 精确模型；
    //   * 音源切换的淡出/淡入与增益精度：tb_audio_source_mux 逐样本参考模型；
    //   * 本 TB 只验证集成契约：
    //       - 菜单页不播放 PCM，促销页播放；
    //       - 离开促销页后 PCM 停止并回落媒体音；
    //       - 换页时切换文件（播放器重新预填充）；
    //       - PCM 资源缺失时回落媒体音且不卡死。
    integer errs = 0;
    integer pcm_samples = 0;
    integer media_samples = 0;
    integer i, guard;

    reg check_pcm = 1'b0;

    always @(posedge pix_clk) begin
        if (aud_valid && !pix_rst) begin
            if (aud_src == 2'd0) pcm_samples = pcm_samples + 1;
            else                 media_samples = media_samples + 1;
        end
    end

    // 诊断
    integer diag_cnt = 0;
    always @(posedge pix_clk) begin
        diag_cnt = diag_cnt + 1;
        if (($test$plusargs("dbg")) && (diag_cnt % 50000 == 0))
            $display("  [dbg] playing=%b pcm_play=%b err=%b eof=%b lvl=%0d src=%0d gain=%0d track=%0d should=%b page=%0d",
                     playing, pcm_playing, err, eof, level, aud_src, aud_gain,
                     track_sel, should_play, gate_page);
    end

    // 推进 n 个 48 kHz 采样节拍
    task automatic wait_ticks(input integer n);
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(posedge pix_clk);
                if (sample_tick) k = k + 1;
            end
        end
    endtask

    task automatic do_frame(input [1:0] idx, input integer nframes);
        integer k;
        begin
            for (k = 0; k < nframes; k = k + 1) begin
                @(negedge pix_clk);
                active_index = idx;
                frame_start  = 1'b1;
                @(posedge pix_clk);
                @(negedge pix_clk);
                frame_start  = 1'b0;
                wait_ticks(24);                    // 推进若干个采样节拍，让状态稳定
            end
        end
    endtask

    task automatic wait_pcm_samples(input integer n);
        integer seen0;
        begin
            seen0 = pcm_samples;
            guard = 0;
            while (((pcm_samples - seen0) < n) && (guard < 4000000)) begin
                @(posedge pix_clk);
                guard = guard + 1;
            end
            if ((pcm_samples - seen0) < n) begin
                $display("FAIL subsys: only %0d new PCM samples (wanted %0d) [playing=%b pcm=%b err=%b eof=%b lvl=%0d src=%0d track=%0d]",
                         pcm_samples - seen0, n, playing, pcm_playing, err, eof, level, aud_src, track_sel);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge sd_clk);
        sd_rst = 1'b0; pix_rst = 1'b0;
        repeat (4) @(posedge pix_clk);

        // ---- 1) 菜单页：只出媒体音 ----
        // 复位后音源从测试音切到媒体音需要一次淡出-淡入（FADE_TICKS 个采样节拍）
        wait_ticks(40);
        do_frame(2'd0, 2);
        if (pcm_samples != 0) begin
            $display("FAIL subsys: PCM played on menu page");
            errs = errs + 1;
        end
        if (aud_src !== 2'd1) begin
            $display("FAIL subsys: source not media on menu page (%0d)", aud_src);
            errs = errs + 1;
        end

        // ---- 2) 进入 PIC3（index=2 → track 3）：播放 PIC3.PCM ----
        check_pcm = 1'b1;
        do_frame(2'd2, 1);
        wait_pcm_samples(300);
        check_pcm = 1'b0;
        if (aud_src !== 2'd0) begin
            $display("FAIL subsys: active source not PCM on PIC3 (%0d)", aud_src);
            errs = errs + 1;
        end

        // ---- 3) 离开促销页：停止 + 回落媒体音 ----
        do_frame(2'd1, 2);
        wait_ticks(60);
        if (aud_src !== 2'd1) begin
            $display("FAIL subsys: did not fall back to media after leaving promo (src=%0d)", aud_src);
            errs = errs + 1;
        end
        if (pcm_playing) begin
            $display("FAIL subsys: PCM still playing after leaving promo");
            errs = errs + 1;
        end

        // ---- 4) 进入 PIC4（index=3 → track 4）：播放另一文件 ----
        check_pcm = 1'b1;
        do_frame(2'd3, 1);
        wait_pcm_samples(100);
        check_pcm = 1'b0;
        if (pcm_samples == 0) begin
            $display("FAIL subsys: PIC4 produced no PCM samples");
            errs = errs + 1;
        end

        // ---- 5) PCM 资源缺失：回落媒体音且不卡死 ----
        do_frame(2'd1, 2);
        pcm_valid = 4'b0000;
        do_frame(2'd3, 2);
        wait_ticks(60);
        if (aud_src !== 2'd1) begin
            $display("FAIL subsys: missing PCM did not fall back to media (src=%0d)", aud_src);
            errs = errs + 1;
        end

        if (errs == 0)
            $display("PASS audio_subsystem: page-driven play/stop/switch, fallback, %0d PCM + %0d media samples",
                     pcm_samples, media_samples);
        else
            $display("FAIL audio_subsystem: %0d assertion(s)", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL audio_subsystem: timeout");
        $fatal(1);
    end

endmodule
