`timescale 1ns/1ps

// 10 位 OSD 状态快照跨时钟域。
// 源域：数据稳定后拉高 req，保持到 ack 拉高；随后撤销 req，等待 ack 撤销。
// 目标域：req 经 2 级同步后采样数据并应答；数据只在帧边界提交。
// 该四相握手保证多位数据在整个采样窗口内稳定，不是“只同步 toggle”。
module osd_status_cdc (
    input  wire        src_clk,
    input  wire        src_rst,          // 高有效
    input  wire [9:0]  src_status,       // {display_valid, auto_enable, error_code[7:0]}
    input  wire        dst_clk,
    input  wire        dst_rst,          // 高有效
    input  wire        dst_frame_start,  // 视频帧边界单拍脉冲
    output reg  [9:0]  dst_status
);

    localparam [9:0] STATUS_RESET = {1'b0, 1'b0, 8'hE1};

    localparam [1:0] S_IDLE        = 2'd0,
                     S_WAIT_ACK_HI = 2'd1,
                     S_WAIT_ACK_LO = 2'd2;

    // ---------------- 源域寄存器 ----------------
    reg [9:0] tx_data;
    reg       req;
    reg       ack_meta;
    reg       ack_sync;
    reg [1:0] src_state;

    // ---------------- 目标域寄存器 ----------------
    (* ASYNC_REG = "TRUE" *) reg req_meta;
    (* ASYNC_REG = "TRUE" *) reg req_sync;
    reg       ack;
    reg [9:0] capture;
    reg       pending;

    // ---------------- 源域 ----------------
    always @(posedge src_clk or posedge src_rst) begin
        if (src_rst) begin
            tx_data   <= 10'd0;
            req       <= 1'b0;
            ack_meta  <= 1'b0;
            ack_sync  <= 1'b0;
            src_state <= S_IDLE;
        end else begin
            ack_meta <= ack;
            ack_sync <= ack_meta;

            case (src_state)
                S_IDLE: begin
                    if (src_status != tx_data) begin
                        tx_data   <= src_status;
                        req       <= 1'b1;
                        src_state <= S_WAIT_ACK_HI;
                    end
                end
                S_WAIT_ACK_HI: begin
                    if (ack_sync) begin
                        req       <= 1'b0;
                        src_state <= S_WAIT_ACK_LO;
                    end
                end
                S_WAIT_ACK_LO: begin
                    if (!ack_sync)
                        src_state <= S_IDLE;
                end
                default: src_state <= S_IDLE;
            endcase
        end
    end

    // ---------------- 目标域 ----------------
    always @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) begin
            req_meta   <= 1'b0;
            req_sync   <= 1'b0;
            ack        <= 1'b0;
            capture    <= 10'd0;
            pending    <= 1'b0;
            dst_status <= STATUS_RESET;
        end else begin
            req_meta <= req;
            req_sync <= req_meta;

            if (req_sync && !ack) begin
                // req 已稳定至少两个目标时钟，源域在 ack 拉高前不会改写 tx_data。
                capture <= tx_data;
                ack     <= 1'b1;
                pending <= 1'b1;
            end else if (!req_sync && ack) begin
                ack <= 1'b0;
            end

            // 帧边界只提交已经完整捕获的快照；同一拍有新捕获时推迟一帧。
            if (dst_frame_start && pending && !(req_sync && !ack)) begin
                dst_status <= capture;
                pending    <= 1'b0;
            end
        end
    end

endmodule
