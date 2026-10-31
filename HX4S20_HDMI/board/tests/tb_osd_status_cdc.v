`timescale 1ns/1ps

// 状态快照 CDC 验证：
// - dst_status 只能在帧边界变化；
// - 每次变化必须是完整快照（不能出现半新半旧值）；
// - 源域 req 有效期间 tx_data 必须稳定；
// - 连续变化、帧中途变化、双方复位后都能收敛到最新值。
module tb_osd_status_cdc;

    reg         src_clk;
    reg         dst_clk;
    reg         src_rst;
    reg         dst_rst;
    reg  [9:0]  src_status;
    reg  [7:0]  frame_cnt;
    wire        dst_frame_start;
    wire [9:0]  dst_status;

    integer fails;
    reg [9:0] dst_prev;
    reg [9:0] known [0:15];
    integer   n_known;
    integer   changes;
    reg       req_d;
    reg [9:0] tx_d;
    reg       fs_edge;

    osd_status_cdc dut (
        .src_clk         (src_clk),
        .src_rst         (src_rst),
        .src_status      (src_status),
        .dst_clk         (dst_clk),
        .dst_rst         (dst_rst),
        .dst_frame_start (dst_frame_start),
        .dst_status      (dst_status)
    );

    assign dst_frame_start = (frame_cnt == 8'd0);

    initial begin
        src_clk   = 1'b0;
        dst_clk   = 1'b0;
        src_rst   = 1'b1;
        dst_rst   = 1'b1;
        src_status = 10'h0E1;
        frame_cnt = 8'd0;
        fails     = 0;
        changes   = 0;
        dst_prev  = 10'h0E1;
        n_known   = 0;
        req_d     = 1'b0;
        tx_d      = 10'd0;
        fs_edge   = 1'b0;
        known[0]  = 10'h0E1;
        n_known   = 1;
    end

    always #5  src_clk = ~src_clk;   // 100 MHz
    always #20 dst_clk = ~dst_clk;   // 25 MHz

    // 目标域：每 64 个像素时钟产生一个帧边界
    always @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst)
            frame_cnt <= 8'd0;
        else
            frame_cnt <= frame_cnt + 8'd1;
    end

    function known_value;
        input [9:0] v;
        integer k;
        begin
            known_value = 1'b0;
            for (k = 0; k < n_known; k = k + 1)
                if (known[k] == v)
                    known_value = 1'b1;
        end
    endfunction

    task add_known;
        input [9:0] v;
        begin
            if (!known_value(v) && (n_known < 16)) begin
                known[n_known] = v;
                n_known = n_known + 1;
            end
        end
    endtask

    // 目标域检查：任何变化都必须发生在帧边界，且必须是已知完整快照。
    always @(posedge dst_clk)
        fs_edge <= dst_frame_start;

    always @(negedge dst_clk) begin
        if (!dst_rst) begin
            if (dst_status !== dst_prev) begin
                changes = changes + 1;
                if (!fs_edge) begin
                    fails = fails + 1;
                    if (fails <= 8)
                        $display("FAIL cdc: dst_status %03h -> %03h outside frame_start",
                                 dst_prev, dst_status);
                end
                if (!known_value(dst_status)) begin
                    fails = fails + 1;
                    if (fails <= 8)
                        $display("FAIL cdc: dst_status %03h is not a complete committed snapshot",
                                 dst_status);
                end
                dst_prev = dst_status;
            end
        end else begin
            dst_prev = 10'h0E1;
        end
    end

    // 源域检查：req 有效期间数据必须保持稳定。
    always @(posedge src_clk) begin
        if (!src_rst) begin
            if (dut.req) begin
                if (req_d && (dut.tx_data !== tx_d)) begin
                    fails = fails + 1;
                    if (fails <= 8)
                        $display("FAIL cdc: tx_data changed while req high (%03h -> %03h)",
                                 tx_d, dut.tx_data);
                end
                tx_d  = dut.tx_data;
                req_d = 1'b1;
            end else begin
                req_d = 1'b0;
            end
        end else begin
            req_d = 1'b0;
        end
    end

    task drive_status;
        input [9:0] v;
        begin
            @(negedge src_clk);
            src_status = v;
            add_known(v);
        end
    endtask

    task wait_frames;
        input integer n;
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(posedge dst_clk);
                if (dst_frame_start)
                    k = k + 1;
            end
        end
    endtask

    initial begin
        #200;
        src_rst = 1'b0;
        dst_rst = 1'b0;

        // 1) 复位后默认值在第一个帧边界提交。
        wait_frames(2);
        if (dst_status !== 10'h0E1) begin
            fails = fails + 1;
            $display("FAIL cdc: reset value not committed, got %03h", dst_status);
        end

        // 2) 正常变化：帧内驱动，只在下一帧生效。
        drive_status(10'h001);
        wait_frames(4);
        if (dst_status !== 10'h001) begin
            fails = fails + 1;
            $display("FAIL cdc: expected 001, got %03h", dst_status);
        end

        // 3) 帧中途变化：在帧边界后 100ns 驱动，下一帧前反复采样不得改变。
        wait_frames(1);
        #100;
        drive_status(10'h2C3);
        #800;
        if (dst_status !== 10'h001) begin
            fails = fails + 1;
            $display("FAIL cdc: mid-frame change leaked early, got %03h", dst_status);
        end
        wait_frames(4);
        if (dst_status !== 10'h2C3) begin
            fails = fails + 1;
            $display("FAIL cdc: expected 2C3, got %03h", dst_status);
        end

        // 4) 连续快速变化：最终必须收敛到最后一个值。
        drive_status(10'h300);
        drive_status(10'h041);
        drive_status(10'h0FF);
        drive_status(10'h1AA);
        drive_status(10'h255);
        wait_frames(8);
        if (dst_status !== 10'h255) begin
            fails = fails + 1;
            $display("FAIL cdc: rapid updates did not converge, got %03h", dst_status);
        end

        // 5) 双方同时复位：立即回到默认值后仍可继续更新。
        src_status = 10'h0E1;
        src_rst = 1'b1;
        dst_rst = 1'b1;
        #200;
        src_rst = 1'b0;
        dst_rst = 1'b0;
        #1;
        if (dst_status !== 10'h0E1) begin
            fails = fails + 1;
            $display("FAIL cdc: async reset did not restore default, got %03h", dst_status);
        end
        wait_frames(3);
        if (dst_status !== 10'h0E1) begin
            fails = fails + 1;
            $display("FAIL cdc: default after reset, got %03h", dst_status);
        end
        drive_status(10'h123);
        wait_frames(5);
        if (dst_status !== 10'h123) begin
            fails = fails + 1;
            $display("FAIL cdc: update after reset failed, got %03h", dst_status);
        end

        if (fails == 0) begin
            $display("PASS osd_status_cdc: %0d committed changes, all frame-aligned and complete", changes);
            $finish;
        end else begin
            $display("FAIL osd_status_cdc: %0d failure(s)", fails);
            $fatal(1);
        end
    end

endmodule
