`timescale 1ns/1ps

// 验证“OSD 显示的 Bank”与“Reader 实际读取的 Bank”一致：
// video_timing_data 的 read_req 比 vs_0 下降沿早一拍；
// four_bank_frame_commit 在 vs_0 下降沿提交 active_index；
// frame_fifo_read 在 mem_clk 域锁存基地址。
// TB 用与 OSD 相同的 vs_r（vs_0 再延迟 21 拍）锁存 active_index，
// 并在每帧读取开始时记录第一次 App_rd_en 的地址，检查它等于锁存 Bank 的基地址。
module tb_commit_read_index;

    reg  video_clk;
    reg  mem_clk;
    reg  rst;

    wire read_req;
    wire read_req_ack;
    wire hs0, vs0, de0;

    video_timing_data u_timing (
        .video_clk    (video_clk),
        .rst          (rst),
        .read_req     (read_req),
        .read_req_ack (read_req_ack),
        .hs           (hs0),
        .vs           (vs0),
        .de           (de0)
    );

    // 与 video_delay 相同的 21 拍 vs 延迟
    reg [20:0] vs_pipe;
    reg        vs_r_d;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_pipe <= 21'd0;
            vs_r_d  <= 1'b0;
        end else begin
            vs_pipe <= {vs_pipe[19:0], vs0};
            vs_r_d  <= vs_pipe[20];
        end
    end
    wire vs_r = vs_pipe[20];

    // 帧提交：在 vs_0 下降沿
    reg vs0_d;
    always @(posedge video_clk or posedge rst) begin
        if (rst)
            vs0_d <= 1'b0;
        else
            vs0_d <= vs0;
    end
    wire frame_start = vs0_d & ~vs0;

    reg        commit_toggle;
    reg [1:0]  pending_index;
    wire [1:0] active_index;

    four_bank_frame_commit u_commit (
        .pix_clk           (video_clk),
        .pix_rst           (rst),
        .frame_start       (frame_start),
        .commit_toggle_mem (commit_toggle),
        .pending_index_mem (pending_index),
        .bank_valid_mem    (4'b1111),
        .active_index      (active_index)
    );

    wire        app_rd_en;
    wire [20:0] app_rd_addr;

    frame_fifo_read #(
        .BURST_BITS (9),
        .BURST_SIZE (256)
    ) u_read (
        .rst             (rst),
        .mem_clk         (mem_clk),
        .Sdr_init_done   (1'b1),
        .Sdr_init_ref_vld(1'b0),
        .Sdr_busy        (1'b0),
        .Sdr_rd_en       (1'b0),
        .App_wr_busy     (1'b0),
        .O_rd_busy       (),
        .App_rd_en       (app_rd_en),
        .App_rd_addr     (app_rd_addr),
        .read_req        (read_req),
        .read_req_ack    (read_req_ack),
        .read_finish     (),
        .read_addr_0     (21'd0),
        .read_addr_1     (21'd307200),
        .read_addr_2     (21'd614400),
        .read_addr_3     (21'd921600),
        .read_addr_index (active_index),
        .read_len        (21'd307200),
        .fifo_aclr       (),
        .wrusedw         (10'd0)
    );

    // OSD 视角：vs_r 下降沿锁存 active_index（与 osd_overlay 相同）
    reg [1:0] osd_index;
    always @(posedge video_clk or posedge rst) begin
        if (rst)
            osd_index <= 2'd0;
        else if (vs_r_d & ~vs_r)
            osd_index <= active_index;
    end

    // 每帧第一次 App_rd_en 的地址必然等于四个 Bank 基址之一；
    // 帧内后续 burst 的地址从基址递增，不会与其它基址重合。
    reg        rd_en_d;
    reg        captured;
    reg [20:0] captured_base;

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            rd_en_d       <= 1'b0;
            captured      <= 1'b0;
            captured_base <= 21'd0;
        end else begin
            rd_en_d <= app_rd_en;
            if (app_rd_en && !rd_en_d && !captured &&
                (app_rd_addr == 21'd0 || app_rd_addr == 21'd307200 ||
                 app_rd_addr == 21'd614400 || app_rd_addr == 21'd921600)) begin
                captured_base <= app_rd_addr;
                captured      <= 1'b1;
            end
        end
    end

    always @(posedge video_clk) begin
        if (!rst && frame_start)
            $display("INFO commit edge: active=%0d pending=%0d seen=%b sync=%b",
                     active_index, pending_index, u_commit.toggle_seen, u_commit.toggle_sync);
    end

    // 每帧在 vs_r 下降沿后的下一个 negedge 检查：
    // osd_overlay 的帧边界锁存在 posedge 更新，必须等它完成后再比较。
    reg        vs_r_prev;
    reg        check_pending;
    integer    fails;
    integer    checked;
    integer    edges;
    reg [20:0] exp_base;

    always @(negedge video_clk) begin
        if (!rst) begin
            if (check_pending) begin
                if (captured) begin
                    case (osd_index)
                        2'd0: exp_base = 21'd0;
                        2'd1: exp_base = 21'd307200;
                        2'd2: exp_base = 21'd614400;
                        default: exp_base = 21'd921600;
                    endcase
                    checked = checked + 1;
                    if (captured_base !== exp_base) begin
                        fails = fails + 1;
                        $display("FAIL commit-read: frame %0d reader base %0d != OSD bank %0d base %0d",
                                 checked, captured_base, osd_index, exp_base);
                    end else begin
                        $display("INFO commit-read: frame %0d reader base %0d matches OSD bank %0d",
                                 checked, captured_base, osd_index);
                    end
                    captured = 1'b0;
                end else begin
                    fails = fails + 1;
                    $display("FAIL commit-read: no reader burst captured before vs_r falling");
                end
                check_pending = 1'b0;
            end
            if (vs_r_prev && !vs_r) begin
                edges = edges + 1;
                check_pending = 1'b1;
            end
            vs_r_prev = vs_r;
        end else begin
            vs_r_prev = 1'b0;
            check_pending = 1'b0;
        end
    end

    initial begin
        video_clk      = 1'b0;
        mem_clk        = 1'b0;
        rst            = 1'b1;
        commit_toggle  = 1'b0;
        pending_index  = 2'd0;
        fails          = 0;
        checked        = 0;
        edges          = 0;
        captured       = 1'b0;
        osd_index      = 2'd0;
        vs_r_prev      = 1'b0;
        check_pending  = 1'b0;
    end

    always #20 video_clk = ~video_clk;   // 25 MHz
    always #12 mem_clk   = ~mem_clk;     // ~41.7 MHz

    task wait_vs_r_fall;
        integer k;
        begin
            k = edges;
            while (edges == k)
                @(negedge video_clk);
        end
    endtask

    initial begin
        integer k;
        #400;
        rst = 1'b0;

        // 第 1 帧：Bank0
        wait_vs_r_fall();

        // 第 2 帧：Bank2
        @(negedge video_clk);
        pending_index = 2'd2;
        commit_toggle = ~commit_toggle;
        wait_vs_r_fall();

        // 第 3 帧：Bank1
        @(negedge video_clk);
        pending_index = 2'd1;
        commit_toggle = ~commit_toggle;
        wait_vs_r_fall();

        // 检查在下降沿后的下一个 negedge 执行，等它完成再汇总。
        k = 0;
        while ((checked < 3) && (k < 10)) begin
            @(negedge video_clk);
            k = k + 1;
        end

        if (fails == 0 && checked >= 3) begin
            $display("PASS commit-read: %0d frames, reader address == OSD committed bank", checked);
            $finish;
        end else begin
            $display("FAIL commit-read: %0d failure(s), %0d frames checked", fails, checked);
            $fatal(1);
        end
    end

endmodule
