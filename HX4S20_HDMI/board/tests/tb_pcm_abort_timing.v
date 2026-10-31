`timescale 1ns/1ps

// 停止时机专项：stop 精确落在 fat32_file_streamer 的 S_DATA_WAIT / S_FAT_WAIT 期间。
//
// 实板缺陷：连续切页 3~4 次后音频永久失效、波形变平。
// 根因：播放器停止时撤回扇区请求，但 fat32_file_streamer 每个扇区只发一拍
//       sector_req，随后在 S_DATA_WAIT 等 sector_done；请求被撤回后它永远等不到，
//       file_busy 恒为 1，之后所有 file_start 都被忽略。
// 修复：给 streamer 增加 stream_abort 输入，stop 时发单拍中止脉冲。
//
// 本 TB 在多个不同的 streamer 状态下各停一次，每次都必须满足：
//   1) stop 后 streamer 脱离 busy；
//   2) 重新 start 后能恢复输出样本。
module tb_pcm_abort_timing;

    reg sd = 1'b0, au = 1'b0;
    reg sdrst = 1'b1, aurst = 1'b1;
    always #5  sd = ~sd;
    always #20 au = ~au;

    reg        st = 1'b0, sp = 1'b0;
    reg [3:0]  ts = 4'd4;

    wire        sec_req;
    wire [31:0] sec_lba;
    reg         busy = 1'b0, valid = 1'b0, done = 1'b0;
    reg  [7:0]  sbyte = 8'd0;
    reg  [8:0]  idx = 9'd0;

    wire        playing, eof, errf;
    wire [10:0] lvl;
    wire [15:0] sd16;
    wire        sv, un, pp;
    reg         tick = 1'b0;

    integer errors = 0;

    pcm_stream_player dut (
        .I_sd_clk(sd), .I_sd_rst(sdrst),
        .I_start_toggle(st), .I_stop_toggle(sp),
        .I_track_sel(ts), .I_pcm_valid(4'b1000),
        .I_pcm_cluster0(32'd0), .I_pcm_cluster1(32'd0),
        .I_pcm_cluster2(32'd0), .I_pcm_cluster3(32'd2),
        .I_pcm_size0(32'd0), .I_pcm_size1(32'd0),
        .I_pcm_size2(32'd0), .I_pcm_size3(32'd8192),
        .I_sectors_per_cluster(8'd1),
        .I_fat_start_lba(32'd10), .I_data_start_lba(32'd1000),
        .I_max_cluster(32'd64), .I_sd_link_ready(1'b1),
        .O_sector_req(sec_req), .O_sector_lba(sec_lba),
        .I_sector_busy(busy), .I_sector_valid(valid), .I_sector_byte(sbyte),
        .I_sector_index(idx), .I_sector_done(done),
        .I_sector_error(8'd0), .I_sector_abort(1'b0),
        .O_playing(playing), .O_eof(eof), .O_err(errf), .O_level(lvl),
        .I_aud_clk(au), .I_aud_rst(aurst),
        .I_sample_tick(tick), .I_sample_ready(1'b1),
        .I_pcm_consume(1'b1),
        .O_sample_data(sd16), .O_sample_valid(sv),
        .O_underrun(un), .O_pcm_playing(pp)
    );

    // 带固定延迟的扇区服务（用计数器实现，避免 task 重入）
    localparam integer LAT = 200;
    localparam ST_IDLE_S = 0, ST_WAITLAT = 1, ST_DATA = 2, ST_DONE = 3;
    reg [1:0]  srv = ST_IDLE_S;
    integer    cnt = 0, bcnt = 0;

    always @(posedge sd) begin
        if (sdrst) begin
            srv <= ST_IDLE_S; cnt <= 0; bcnt <= 0;
            busy <= 1'b0; valid <= 1'b0; done <= 1'b0;
        end else begin
            valid <= 1'b0;
            done  <= 1'b0;
            case (srv)
                ST_IDLE_S: begin
                    busy <= 1'b0;
                    if (sec_req) begin
                        busy <= 1'b1;
                        cnt  <= 0;
                        srv  <= ST_WAITLAT;
                    end
                end
                ST_WAITLAT: begin
                    if (cnt >= LAT) begin
                        cnt    <= 0;
                        bcnt   <= 0;
                        srv    <= ST_DATA;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
                ST_DATA: begin
                    valid  <= 1'b1;
                    idx    <= bcnt[8:0];
                    sbyte  <= bcnt[7:0] ^ 8'h3C;
                    bcnt   <= bcnt + 1;
                    if (bcnt >= 511) srv <= ST_DONE;
                end
                ST_DONE: begin
                    done <= 1'b1;
                    srv  <= ST_IDLE_S;
                end
            endcase
        end
    end

    // 48 kHz
    integer tc = 0;
    always @(posedge au) begin
        tc <= tc + 1;
        tick <= 1'b0;
        if (tc >= 520) begin tc <= 0; tick <= 1'b1; end
    end

    // FAT 状态只持续一两拍，轮询抓不到；改为盯住状态跳变。
    task automatic wait_streamer_state(input [3:0] want, output integer ok);
        integer g;
        reg [3:0] prev;
        begin
            g = 0;
            ok = 1'b0;
            prev = dut.u_file_streamer.state;
            while ((g < 400000) && !ok) begin
                @(posedge sd);
                if (dut.u_file_streamer.state == want) ok = 1'b1;
                prev = dut.u_file_streamer.state;
                g = g + 1;
            end
        end
    endtask

    task automatic count_pcm(input integer n_ticks, output integer n_pcm);
        integer k;
        begin
            k = 0; n_pcm = 0;
            while (k < n_ticks) begin
                @(posedge au);
                if (tick) k = k + 1;
                if (sv && !un) n_pcm = n_pcm + 1;
            end
        end
    endtask

    integer ok, got, round;
    reg [3:0] targets [0:3];

    initial begin
        // 只覆盖会“停留等候”的状态：S_DATA_WAIT 等 sector_done、
        // S_DATA_REQ 等扇区乘加完成。FAT 两个状态只持续 1~2 拍，
        // 由 tb_fat32_file_streamer 的常规用例覆盖。
        targets[0] = 4'd5;   // S_DATA_WAIT
        targets[1] = 4'd1;   // S_DATA_REQ
        targets[2] = 4'd5;   // 再来一次 DATA_WAIT（连续两次快速停止）
        targets[3] = 4'd1;

        repeat (4) @(posedge sd);
        sdrst = 1'b0; aurst = 1'b0;
        repeat (6) @(posedge au);

        for (round = 0; round < 4; round = round + 1) begin
            // 启动播放
            @(negedge sd); st = ~st; @(posedge sd);

            wait_streamer_state(targets[round], ok);
            if (!ok) begin
                $display("FAIL abort: round %0d never reached streamer state %0d",
                         round, targets[round]);
                errors = errors + 1;
            end

            // 在此状态停止
            @(negedge sd); sp = ~sp; @(posedge sd);
            repeat (4000) @(posedge sd);

            if (dut.streamer_busy) begin
                $display("FAIL abort: round %0d (state %0d) streamer still busy after stop",
                         round, targets[round]);
                errors = errors + 1;
            end
            if (dut.u_file_streamer.state != 4'd0) begin
                $display("FAIL abort: round %0d streamer not back to IDLE (state=%0d)",
                         round, dut.u_file_streamer.state);
                errors = errors + 1;
            end

            // 重新启动必须能输出样本
            @(negedge sd); st = ~st; @(posedge sd);
            count_pcm(1200, got);
            if (got < 50) begin
                $display("FAIL abort: round %0d did not resume after abort (pcm=%0d busy=%b wstate=%0d)",
                         round, got, dut.streamer_busy, dut.wstate);
                errors = errors + 1;
            end
            @(negedge sd); sp = ~sp; @(posedge sd);
            repeat (4000) @(posedge sd);
        end

        if (errors == 0)
            $display("PASS pcm_abort_timing: abort during DATA_WAIT/DATA_REQ all recover");
        else
            $display("FAIL pcm_abort_timing: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #300_000_000;
        $display("FAIL pcm_abort_timing: timeout");
        $fatal(1);
    end

endmodule
