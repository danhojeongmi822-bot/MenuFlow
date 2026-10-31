`timescale 1ns/1ps

// 端到端快速切页压力：page_gate + player + ring + mux 全链路。
//
// 复现实板现象：连续快速翻页 3~4 次后 PCM 永久失效、波形变平。
//
// 关键：扇区服务带随机延迟，且 stop 可能落在任意阶段（等待请求 / 传输中 / 预填充后）。
module tb_audio_repeat_switch;

    localparam [31:0] DATA_LBA = 32'd1000;
    localparam [31:0] FAT_LBA  = 32'd10;

    reg sd_clk = 1'b0, pix_clk = 1'b0;
    reg sd_rst = 1'b1, pix_rst = 1'b1;
    always #5  sd_clk  = ~sd_clk;     // 100 MHz
    always #20 pix_clk = ~pix_clk;    // 25 MHz

    // ---------------- 页面门控 ----------------
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
    // 四路 PCM 资源：PIC3 → cluster 2，PIC4 → cluster 6
    reg  [31:0] fsize = 32'd8192;
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
    wire        pcm_valid, pcm_underrun, pcm_playing;
    reg         sample_tick = 1'b0;
    wire        mux_consume;

    pcm_stream_player player (
        .I_sd_clk(sd_clk), .I_sd_rst(sd_rst),
        .I_start_toggle(start_toggle), .I_stop_toggle(stop_toggle),
        .I_track_sel(track_sel),
        .I_pcm_valid(4'b1111),
        .I_pcm_cluster0(32'd2), .I_pcm_cluster1(32'd4),
        .I_pcm_cluster2(32'd6), .I_pcm_cluster3(32'd8),
        .I_pcm_size0(fsize), .I_pcm_size1(fsize),
        .I_pcm_size2(fsize), .I_pcm_size3(fsize),
        .I_sectors_per_cluster(8'd1),
        .I_fat_start_lba(FAT_LBA), .I_data_start_lba(DATA_LBA),
        .I_max_cluster(32'd64),
        .I_sd_link_ready(1'b1),
        .O_sector_req(sec_req), .O_sector_lba(sec_lba),
        .I_sector_busy(sec_busy), .I_sector_valid(sec_valid),
        .I_sector_byte(sec_byte), .I_sector_index(sec_index),
        .I_sector_done(sec_done), .I_sector_error(sec_error),
        .I_sector_abort(1'b0),
        .O_playing(playing), .O_eof(eof), .O_err(err), .O_level(level),
        .I_aud_clk(pix_clk), .I_aud_rst(pix_rst),
        .I_sample_tick(sample_tick), .I_sample_ready(1'b1),
        .I_pcm_consume(mux_consume),
        .O_sample_data(pcm_sample), .O_sample_valid(pcm_valid),
        .O_underrun(pcm_underrun), .O_pcm_playing(pcm_playing)
    );

    // ---------------- 音源选择 ----------------
    wire        aud_valid;
    wire [23:0] aud_l, aud_r;
    wire [1:0]  aud_src;
    wire [7:0]  aud_gain;

    audio_source_mux mux (
        .I_clk(pix_clk), .I_rst(pix_rst), .I_sample_tick(sample_tick),
        .I_pcm_valid(pcm_valid), .I_pcm_sample(pcm_sample), .I_pcm_playing(pcm_playing),
        .I_media_active(1'b1), .I_media_valid(1'b1),
        .I_media_left(24'sd100000), .I_media_right(24'sd100000),
        .I_test_valid(1'b0), .I_test_left(24'd0), .I_test_right(24'd0),
        .O_audio_valid(aud_valid), .O_audio_left(aud_l), .O_audio_right(aud_r),
        .O_active_source(aud_src), .O_gain(aud_gain), .O_pcm_consume(mux_consume)
    );

    // ---------------- 48 kHz ----------------
    integer tick_cnt = 0;
    always @(posedge pix_clk) begin
        tick_cnt    <= tick_cnt + 1;
        sample_tick <= 1'b0;
        if (tick_cnt >= 520) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b1;
        end
    end

    // ---------------- 带随机延迟的扇区服务 ----------------
    function [7:0] fb; input [31:0] off; begin fb = off[7:0] ^ 8'h3C; end endfunction
    function [31:0] nclu; input [31:0] s; begin nclu = (s + 511) >> 9; end endfunction

    reg [31:0] cur_lba;
    reg [31:0] cur_first;
    integer d, n, c;
    integer lat_seed = 12345;
    integer lat;

    always @* begin
        case (track_sel)
            4'd1: cur_first = 32'd2;
            4'd2: cur_first = 32'd4;
            4'd3: cur_first = 32'd6;
            default: cur_first = 32'd8;
        endcase
    end

    always @(posedge sd_clk) begin
        if (sec_req && !sec_busy) begin
            sec_busy <= 1'b1;
            cur_lba  <= sec_lba;
        end
    end

    task automatic serve;
        reg [31:0] base_off, ent;
        begin
            // 随机延迟 50..600 个 SD 周期，覆盖各种 stop 时机
            lat_seed = (lat_seed * 1103515245 + 12345) & 32'h7FFFFFFF;
            lat = 50 + (lat_seed % 550);
            for (d = 0; d < lat; d = d + 1) @(posedge sd_clk);

            @(negedge sd_clk);
            if ((cur_lba >= FAT_LBA) && (cur_lba < DATA_LBA)) begin
                for (n = 0; n < 512; n = n + 1) begin
                    c = (cur_lba - FAT_LBA) * 128 + (n >> 2);
                    ent = (c + 1 < cur_first + nclu(fsize)) ? (c + 1) : 32'h0FFFFFFF;
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
                base_off = (cur_lba - (DATA_LBA + cur_first - 2)) * 32'd512;
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

    // ---------------- 统计与判定 ----------------
    integer errors = 0;
    integer pcm_after_settle;

    task automatic do_frame(input [1:0] idx);
        begin
            @(negedge pix_clk);
            active_index = idx;
            frame_start  = 1'b1;
            @(posedge pix_clk);
            @(negedge pix_clk);
            frame_start  = 1'b0;
        end
    endtask

    // 等待 n 个 48 kHz 节拍
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

    // 统计一段时间内 PCM 是否真的在输出
    task automatic count_pcm(input integer ticks, output integer n_pcm);
        integer k, seen0;
        begin
            k = 0; n_pcm = 0;
            while (k < ticks) begin
                @(posedge pix_clk);
                if (sample_tick) k = k + 1;
                if (aud_valid && (aud_src == 2'd0) && !pcm_underrun) n_pcm = n_pcm + 1;
            end
        end
    endtask

    integer r, got, s0, st0;

    initial begin
        repeat (4) @(posedge sd_clk);
        sd_rst = 1'b0; pix_rst = 1'b0;
        repeat (6) @(posedge pix_clk);

        // 先建立一次正常播放作为基准
        do_frame(2'd2);
        wait_ticks(200);
        count_pcm(200, got);
        if (got < 50) begin
            $display("FAIL repeat: baseline PIC3 produced only %0d PCM samples", got);
            errors = errors + 1;
        end

        // ---- 连续快速切页，模拟用户连点 ----
        for (r = 0; r < 6; r = r + 1) begin
            do_frame(2'd0);  wait_ticks(6);     // 回菜单页
            do_frame(2'd2);  wait_ticks(6);     // 快速进 PIC3
            do_frame(2'd3);  wait_ticks(6);     // 立刻切 PIC4
            do_frame(2'd1);  wait_ticks(6);     // 再回菜单
            do_frame(2'd3);  wait_ticks(6);     // 再进 PIC4
        end

        // ---- 稳定停在 PIC3，必须恢复出声 ----
        do_frame(2'd2);
        wait_ticks(400);                        // 给足预填充时间
        count_pcm(300, got);
        if (got < 100) begin
            $display("FAIL repeat: after 6 rapid-switch rounds PIC3 silent (pcm=%0d, playing=%b err=%b eof=%b lvl=%0d track=%0d src=%0d busy=%b wstate=%0d)",
                     got, playing, err, eof, level, track_sel, aud_src,
                     player.streamer_busy, player.wstate);
            errors = errors + 1;
        end

        // ---- 稳定停在 PIC4，也必须恢复 ----
        do_frame(2'd3);
        wait_ticks(400);
        count_pcm(300, got);
        if (got < 100) begin
            $display("FAIL repeat: after rapid switching PIC4 silent (pcm=%0d, playing=%b err=%b eof=%b lvl=%0d track=%0d src=%0d busy=%b wstate=%0d)",
                     got, playing, err, eof, level, track_sel, aud_src,
                     player.streamer_busy, player.wstate);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS audio_repeat_switch: 6 rapid-switch rounds, playback recovers");
        else
            $display("FAIL audio_repeat_switch: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("FAIL audio_repeat_switch: timeout");
        $fatal(1);
    end

endmodule
