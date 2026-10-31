`timescale 1ns/1ps

// PCM 环形缓冲：写侧 = SD 字节流（100 MHz），读侧 = 视频/音频域（25 MHz）。
//
// 结构：
//   * BRAM DEPTH x 16（默认 1024 样本），写口同步写、读口同步读（1 拍延迟）。
//   * 指针 AW+1 位（含回绕位），格雷码 + 2FF 跨域；满/空由回绕位区分。
//
// 读契约（重要）：
//   * 读侧是 4 深 show-ahead FIFO：O_rd_valid/O_rd_data/O_rd_underrun 都是
//     **组合输出**，在 I_rd_req 当拍即有效，与 pcm_test_tone/pcm_media_tone 的
//     “tick 当拍 valid”语义完全一致；消费在同一个时钟沿完成（FIFO 头出队）。
//   * 每个 I_rd_req 恰好消费一个样本；FIFO 空时输出静音 0 且 valid 仍断言，
//     下游 HDMI 音频链永不停顿。
//   * I_rd_flush（读域单拍）前跳到写侧已发布位置，丢弃未播数据，同时清空预取。
module pcm_ring_buffer #(
    parameter integer AW = 10               // 深度 = 2**AW 个 16 位样本
)(
    // ---------------- 写侧（SD 域） ----------------
    input  wire         I_wr_clk,
    input  wire         I_wr_rst,
    input  wire         I_wr_en,
    input  wire [15:0]  I_wr_data,
    output wire         O_wr_full,
    output wire [AW:0]  O_wr_level,

    // ---------------- 读侧（音频域） ----------------
    input  wire         I_rd_clk,
    input  wire         I_rd_rst,
    input  wire         I_rd_req,
    input  wire         I_rd_flush,
    output wire [15:0]  O_rd_data,
    output wire         O_rd_valid,
    output wire         O_rd_underrun,      // 与 O_rd_valid 同拍：该样本是下溢静音
    output wire [AW:0]  O_rd_level,
    output wire         O_rd_empty
);
    localparam integer DEPTH = (1 << AW);

    // 读侧 show-ahead FIFO 参数（需在写侧水位判断前声明）
    localparam integer QAW    = 2;
    localparam integer QDEPTH = (1 << QAW);

    function [AW:0] bin2gray;
        input [AW:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        reg [AW:0] b;
        begin
            b[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            gray2bin = b;
        end
    endfunction

    (* ram_style = "block" *) reg [15:0] mem [0:DEPTH-1];

    // 指针与跨域同步（集中声明，避免两个 always 块互相前向引用）
    reg [AW:0] wr_bin, wr_gray;
    reg [AW:0] rd_bin, rd_gray;
    reg [AW:0] rd_gray_wr1, rd_gray_wr2;   // 读指针 → 写域
    reg [AW:0] wr_gray_rd1, wr_gray_rd2;   // 写指针 → 读域

    wire [AW:0] rd_bin_wr = gray2bin(rd_gray_wr2);
    wire [AW:0] wr_bin_rd = gray2bin(wr_gray_rd2);

    // =======================================================================
    // 写侧
    // =======================================================================
    // 环形区容量 DEPTH；读侧 FIFO 最多再暂存 QDEPTH 个已取出的样本，
    // 因此“未消费样本总数”上限为 DEPTH + QDEPTH。wr_full 只保护环形区。
    wire [AW:0] wr_level  = wr_bin - rd_bin_wr;
    wire        wr_full   = (wr_level >= DEPTH);
    wire        wr_fire   = I_wr_en && !wr_full;

    // 对外 full 也寄存一拍（内部写入仍用实时 wr_full 保护环形区）
    reg wr_full_q;
    always @(posedge I_wr_clk or posedge I_wr_rst) begin
        if (I_wr_rst) wr_full_q <= 1'b0;
        else          wr_full_q <= wr_full;
    end
    assign O_wr_full  = wr_full_q;

    // 对外水位寄存一拍：gray2bin 是 11 级 XOR 链，若组合导出到 100 MHz 域的
    // 请求/仲裁逻辑，会形成跨模块长路径（实测 SWNS -1.08 ns）。
    // 内部 wr_full 仍用实时值保护环形区；外部使用 1 拍前的水位做流量控制，
    // 误差 <= 几个样本，远小于 GRANT_LIMIT 预留的 32 样本余量。
    reg [AW:0] wr_level_q;
    always @(posedge I_wr_clk or posedge I_wr_rst) begin
        if (I_wr_rst) wr_level_q <= {(AW+1){1'b0}};
        else          wr_level_q <= wr_level;
    end
    assign O_wr_level = wr_level_q;

    always @(posedge I_wr_clk) begin
        if (wr_fire)
            mem[wr_bin[AW-1:0]] <= I_wr_data;
    end

    always @(posedge I_wr_clk or posedge I_wr_rst) begin
        if (I_wr_rst) begin
            wr_bin      <= {(AW+1){1'b0}};
            wr_gray     <= {(AW+1){1'b0}};
            rd_gray_wr1 <= {(AW+1){1'b0}};
            rd_gray_wr2 <= {(AW+1){1'b0}};
        end else begin
            rd_gray_wr1 <= rd_gray;
            rd_gray_wr2 <= rd_gray_wr1;
            if (wr_fire) begin
                wr_bin  <= wr_bin + 1'b1;
                wr_gray <= bin2gray(wr_bin + 1'b1);
            end
        end
    end

    // =======================================================================
    // 读侧
    // =======================================================================
    wire [AW:0] rd_level = wr_bin_rd - rd_bin;
    wire        rd_empty = (rd_level == {(AW+1){1'b0}});

    reg  [15:0] q_mem [0:QDEPTH-1];
    reg  [QAW-1:0] q_wp, q_rp;
    reg  [QAW:0]   q_cnt;
    wire        q_full  = (q_cnt >= QDEPTH);
    wire        q_empty = (q_cnt == 0);
    wire [15:0] q_head  = q_mem[q_rp];

    reg         q_pending;             // 已发地址，本拍 BRAM 数据有效
    reg  [15:0] q_raw;
    wire        q_issue = !q_pending && !q_full && (rd_level != {(AW+1){1'b0}});
    // flush 当拍不能把在途数据写进 FIFO（否则会残留 1 个旧样本）
    wire        q_push  = q_pending && !I_rd_flush;
    wire        q_pop   = I_rd_req && !q_empty && !I_rd_flush;

    always @(posedge I_rd_clk) begin
        if (q_issue)
            q_raw <= mem[rd_bin[AW-1:0]];
        if (q_push)
            q_mem[q_wp] <= q_raw;
    end

    always @(posedge I_rd_clk or posedge I_rd_rst) begin
        if (I_rd_rst) begin
            rd_bin      <= {(AW+1){1'b0}};
            rd_gray     <= {(AW+1){1'b0}};
            wr_gray_rd1 <= {(AW+1){1'b0}};
            wr_gray_rd2 <= {(AW+1){1'b0}};
            q_wp        <= {QAW{1'b0}};
            q_rp        <= {QAW{1'b0}};
            q_cnt       <= {(QAW+1){1'b0}};
            q_pending   <= 1'b0;
        end else begin
            wr_gray_rd1 <= wr_gray;
            wr_gray_rd2 <= wr_gray_rd1;

            if (I_rd_flush) begin
                // 前跳到写侧已发布位置；若此时仍在途（已发地址未收数据），
                // 也要把该拍读指针前移一并丢弃，否则会残留 1 个旧样本。
                rd_bin        <= wr_bin_rd;
                rd_gray       <= bin2gray(wr_bin_rd);
                q_wp          <= {QAW{1'b0}};
                q_rp          <= {QAW{1'b0}};
                q_cnt         <= {(QAW+1){1'b0}};
                q_pending     <= 1'b0;
            end else begin
                // 取数流水
                if (q_issue) begin
                    rd_bin    <= rd_bin + 1'b1;
                    rd_gray   <= bin2gray(rd_bin + 1'b1);
                end
                // q_pending 必须无条件跟随 q_issue（否则会在下一拍被旧值覆盖，
                // 造成数据重复入队）。
                q_pending <= q_issue;

                case ({q_push, q_pop})
                    2'b10: begin q_wp <= q_wp + 1'b1; q_cnt <= q_cnt + 1'b1; end
                    2'b01: begin q_rp <= q_rp + 1'b1; q_cnt <= q_cnt - 1'b1; end
                    2'b11: begin q_wp <= q_wp + 1'b1; q_rp <= q_rp + 1'b1; end
                    default: ;
                endcase
            end
        end
    end

    // 组合输出：请求当拍即返回 FIFO 头（q_head 是出队前的值，正是本拍样本）。
    assign O_rd_valid    = I_rd_req;
    assign O_rd_data     = q_empty ? 16'd0 : q_head;
    assign O_rd_underrun = I_rd_req && q_empty;

    // 同理，读侧对外水位也寄存一拍（只用于状态观察与排空判断）。
    reg [AW:0] rd_level_q;
    always @(posedge I_rd_clk or posedge I_rd_rst) begin
        if (I_rd_rst) rd_level_q <= {(AW+1){1'b0}};
        else          rd_level_q <= rd_level + q_cnt;
    end
    assign O_rd_level = rd_level_q;
    assign O_rd_empty = rd_empty && q_empty;

endmodule
