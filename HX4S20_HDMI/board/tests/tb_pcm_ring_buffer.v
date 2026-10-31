`timescale 1ns/1ps

// pcm_ring_buffer 自检 TB。
//
// 判定方式：TB 自带参考队列（与 RTL 无关），写入值按顺序入队；读侧只在
// “已提交写入数 > 已消费数”时请求，逐样本比对，任何重复、丢失、乱序都判 FAIL。
// 覆盖：空缓冲静音、满缓冲、回绕（多圈）、同时读写、读停顿、flush、复位。
//
// 读侧契约（与 RTL 一致）：请求当拍返回样本（4 深 show-ahead FIFO），
// 空时返回 0 且 valid 仍断言。
module tb_pcm_ring_buffer;

    localparam integer AW     = 5;          // 32 样本，便于快速回绕
    localparam integer DEPTH  = (1 << AW);
    localparam integer QDEPTH = 4;

    reg wr_clk = 1'b0, rd_clk = 1'b0;
    reg wr_rst = 1'b1, rd_rst = 1'b1;
    reg wr_en = 1'b0;
    reg [15:0] wr_data = 16'd0;
    reg rd_req = 1'b0, rd_flush = 1'b0;
    wire wr_full;
    wire [AW:0] wr_level, rd_level;
    wire [15:0] rd_data;
    wire rd_valid, rd_underrun, rd_empty;

    integer errors = 0;
    // 起步阶段允许下溢静音（FIFO 首次填充需要 2 个读时钟）；一旦有真实样本
    // 输出，后续任何下溢都判错误。
    reg started = 1'b0;
    integer committed = 0;
    integer consumed = 0;
    integer underruns = 0;
    integer i, guard;

    reg [15:0] exp_q [0:65535];
    integer q_wp = 0, q_rp = 0;

    always #5   wr_clk = ~wr_clk;    // 100 MHz
    always #20  rd_clk = ~rd_clk;    // 25 MHz

    pcm_ring_buffer #(.AW(AW)) dut (
        .I_wr_clk(wr_clk), .I_wr_rst(wr_rst), .I_wr_en(wr_en), .I_wr_data(wr_data),
        .O_wr_full(wr_full), .O_wr_level(wr_level),
        .I_rd_clk(rd_clk), .I_rd_rst(rd_rst), .I_rd_req(rd_req), .I_rd_flush(rd_flush),
        .O_rd_data(rd_data), .O_rd_valid(rd_valid), .O_rd_underrun(rd_underrun),
        .O_rd_level(rd_level), .O_rd_empty(rd_empty)
    );

    task automatic write_sample(input [15:0] v);
        begin
            // 内部实时满（外部 O_wr_full 寄存一拍，供跨模块用；TB 直接用实时值）
            guard = 0;
            while (dut.wr_full) begin
                @(posedge wr_clk);
                guard = guard + 1;
                if (guard > 500) begin
                    $display("FAIL ring: write stalled (level=%0d)", wr_level);
                    errors = errors + 1;
                    disable write_sample;
                end
            end
            @(negedge wr_clk);
            wr_en   = 1'b1;
            wr_data = v;
            @(posedge wr_clk);
            @(negedge wr_clk);
            wr_en   = 1'b0;
            exp_q[q_wp % 65536] = v;
            q_wp = q_wp + 1;
            committed = committed + 1;
        end
    endtask

    // 等读侧 FIFO 真正有数据。真实消费是 48 kHz tick（每样本 520 个读时钟），
    // 预取有充足时间；本 TB 会背靠背读，因此显式等 FIFO 非空，避免把
    // “预取尚未回填”误判成数据丢失。
    task automatic wait_available;
        begin
            guard = 0;
            while (dut.q_empty) begin
                @(posedge rd_clk);
                guard = guard + 1;
                if (guard > 2000) begin
                    $display("FAIL ring: buffer never became non-empty");
                    errors = errors + 1;
                    disable wait_available;
                end
            end
        end
    endtask

    task automatic read_sample(input integer expect_valid);
        begin
            if (expect_valid) wait_available;
            @(negedge rd_clk);
            rd_req = 1'b1;
            #1;                        // 组合输出，驱动后立即可采样
            if (!rd_valid) begin
                $display("FAIL ring: no valid on request cycle");
                errors = errors + 1;
            end else if (expect_valid) begin
                if (rd_underrun && started) begin
                    $display("FAIL ring: unexpected underrun at read #%0d (rl=%0d q=%0d wr=%0d rdbin=%0d wrbin=%0d)",
                             consumed, rd_level, dut.q_cnt, dut.wr_level, dut.rd_bin, dut.wr_bin_rd);
                    errors = errors + 1;
                end else if (!rd_underrun) begin
                    started = 1'b1;
                end
                if (!rd_underrun && (rd_data !== exp_q[q_rp % 65536])) begin
                    $display("FAIL ring: data mismatch got %04x exp %04x (read #%0d)",
                             rd_data, exp_q[q_rp % 65536], consumed);
                    errors = errors + 1;
                end
                if (!rd_underrun) begin
                    q_rp = q_rp + 1;
                    consumed = consumed + 1;
                end
            end
            @(posedge rd_clk);
            @(negedge rd_clk);
            rd_req = 1'b0;
        end
    endtask

    task automatic check_silence;
        begin
            guard = 0;
            while (!rd_empty && guard < 2000) begin
                @(posedge rd_clk);
                guard = guard + 1;
            end
            @(negedge rd_clk);
            rd_req = 1'b1;
            #1;
            if (!rd_valid) begin
                $display("FAIL ring: silent read must keep valid");
                errors = errors + 1;
            end
            if (rd_data !== 16'd0) begin
                $display("FAIL ring: silent read data %04x", rd_data);
                errors = errors + 1;
            end
            if (!rd_underrun) begin
                $display("FAIL ring: silence should report underrun");
                errors = errors + 1;
            end
            underruns = underruns + 1;
            @(posedge rd_clk);
            @(negedge rd_clk);
            rd_req = 1'b0;
        end
    endtask

    integer fill_count;
    integer wi, ri;

    initial begin
        // ---- 1) 复位后空 ----
        repeat (4) @(posedge rd_clk);
        wr_rst = 1'b0; rd_rst = 1'b0;
        repeat (4) @(posedge rd_clk);
        check_silence();

        // ---- 2) 写满：总可写量 = DEPTH（环形区 + 读侧 FIFO）----
        fill_count = 0;
        while (!dut.wr_full && fill_count < DEPTH + 8) begin
            write_sample(16'h1000 + fill_count[15:0]);
            fill_count = fill_count + 1;
        end
        if (fill_count < DEPTH + QDEPTH - 2) begin
            $display("FAIL ring: writable capacity %0d < %0d", fill_count, DEPTH + QDEPTH - 2);
            errors = errors + 1;
        end

        // ---- 3) 全读出 ----
        for (i = 0; i < fill_count; i = i + 1) read_sample(1);
        check_silence();

        // ---- 4) 同时读写 + 多圈回绕 ----
        fork
            begin : wr_side
                for (wi = 0; wi < DEPTH * 8; wi = wi + 1)
                    write_sample((wi * 16'd4051) ^ 16'h5A5A);
            end
            begin : rd_side
                for (ri = 0; ri < DEPTH * 8; ri = ri + 1)
                    read_sample(1);
            end
        join

        // ---- 5) 读停顿 ----
        for (i = 0; i < DEPTH; i = i + 1) write_sample(16'hC000 + i[15:0]);
        repeat (40) @(posedge rd_clk);
        for (i = 0; i < DEPTH; i = i + 1) read_sample(1);

        // ---- 6) flush ----
        for (i = 0; i < 8; i = i + 1) write_sample(16'hD000 + i[15:0]);
        // 写侧不必等到 8：读域看到多少就丢多少。直接 flush，之后所有旧数据
        // 都必须消失（包括尚在环内/在途的部分）。
        repeat (8) @(posedge rd_clk);
        if ($test$plusargs("dbg"))
            $display("  [dbg] pre-flush: rd_level=%0d q_cnt=%0d (waited %0d)",
                     dut.rd_level, dut.q_cnt, guard);
        @(negedge rd_clk);
        rd_flush = 1'b1;
        @(posedge rd_clk); #1;
        rd_flush = 1'b0;
        repeat (2) @(posedge rd_clk);
        // flush 丢弃所有未消费样本（环内 + FIFO 内 + 在途）。
        // 参考队列以“已写入总量”为新的起点，读侧从 0 个旧样本重新开始。
        q_rp = q_wp;
        consumed = committed;
        started = 1'b0;
        if ($test$plusargs("dbg"))
            $display("  [dbg] flush done: rd_level=%0d q_cnt=%0d rd_bin=%0d wr_bin_rd=%0d",
                     dut.rd_level, dut.q_cnt, dut.rd_bin, dut.wr_bin_rd);
        for (i = 0; i < 6; i = i + 1) write_sample(16'hE000 + i[15:0]);
        for (i = 0; i < 6; i = i + 1) read_sample(1);

        // ---- 7) 复位后重启 ----
        @(negedge wr_clk); wr_rst = 1'b1;
        @(negedge rd_clk); rd_rst = 1'b1;
        repeat (3) @(posedge rd_clk);
        wr_rst = 1'b0; rd_rst = 1'b0;
        committed = 0; consumed = 0; q_wp = 0; q_rp = 0; started = 1'b0;
        repeat (6) @(posedge rd_clk);
        check_silence();
        write_sample(16'h1234);
        read_sample(1);
        write_sample(16'hABCD);
        read_sample(1);

        if (errors == 0)
            $display("PASS pcm_ring_buffer: %0d writes, capacity %0d, %0d wraps, %0d silent reads",
                     committed, fill_count, (DEPTH * 8) / DEPTH, underruns);
        else
            $display("FAIL pcm_ring_buffer: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL pcm_ring_buffer: timeout");
        $fatal(1);
    end

endmodule
