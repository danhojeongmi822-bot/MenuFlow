`timescale 1ns/1ps

// 四 Bank 上层状态模型。它只管理 Bank 所有权和提交，不接触 SDRAM/IP。
// load_start 表示允许上层 BMP 引擎发起一次完整写入；写完成前 Bank 不可显示。
module four_bank_frame_ctrl #(
    parameter [20:0] BANK0_BASE = 21'd0,
    parameter [20:0] BANK1_BASE = 21'd307200,
    parameter [20:0] BANK2_BASE = 21'd614400,
    parameter [20:0] BANK3_BASE = 21'd921600,
    parameter [20:0] BANK_LENGTH = 21'd307200
)(
    input             clk,
    input             rst,
    input             frame_boundary,
    input             request_valid,
    input      [1:0]  request_index,
    input             source_done,
    input             write_done,
    input             load_error,
    output reg        load_start,
    output reg [1:0]  load_index,
    output reg        busy,
    output reg        cache_hit,
    output reg        request_rejected,
    output reg [3:0]  image_valid,
    output reg [1:0]  pending_bank,
    output reg        pending_valid,
    output reg [1:0]  active_bank,
    output reg        commit_pulse,
    output reg [31:0] commit_count,
    output reg [31:0] reject_count
);
reg source_done_seen;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_start       <= 1'b0;
        load_index       <= 2'd0;
        busy             <= 1'b0;
        cache_hit        <= 1'b0;
        request_rejected <= 1'b0;
        image_valid      <= 4'b0000;
        pending_bank     <= 2'd0;
        pending_valid    <= 1'b0;
        active_bank      <= 2'd0;
        commit_pulse     <= 1'b0;
        commit_count     <= 32'd0;
        reject_count     <= 32'd0;
        source_done_seen <= 1'b0;
    end else begin
        load_start       <= 1'b0;
        cache_hit        <= 1'b0;
        request_rejected <= 1'b0;
        commit_pulse     <= 1'b0;

        if (load_error) begin
            busy <= 1'b0;
            source_done_seen <= 1'b0;
            pending_valid <= 1'b0;
            image_valid[load_index] <= 1'b0;
        end

        if (request_valid && !busy) begin
            if (image_valid[request_index]) begin
                cache_hit <= 1'b1;
                pending_bank <= request_index;
                pending_valid <= (request_index != active_bank);
            end else if (request_index == active_bank && image_valid[active_bank]) begin
                // 当前显示 Bank 没有备用副本时禁止覆盖，保持旧帧。
                request_rejected <= 1'b1;
                reject_count <= reject_count + 32'd1;
            end else begin
                load_start <= 1'b1;
                load_index <= request_index;
                busy <= 1'b1;
                source_done_seen <= 1'b0;
                image_valid[request_index] <= 1'b0;
            end
        end

        if (busy && source_done)
            source_done_seen <= 1'b1;

        if (busy && (source_done_seen || source_done) && write_done) begin
            busy <= 1'b0;
            source_done_seen <= 1'b0;
            image_valid[load_index] <= 1'b1;
            pending_bank <= load_index;
            pending_valid <= (load_index != active_bank);
        end

        if (frame_boundary && pending_valid && image_valid[pending_bank]) begin
            active_bank <= pending_bank;
            pending_valid <= 1'b0;
            commit_pulse <= 1'b1;
            commit_count <= commit_count + 32'd1;
        end
    end
end

// Keep the fixed address contract visible to synthesis and standalone TBs.
wire [21:0] bank3_end = {1'b0, BANK3_BASE} + {1'b0, BANK_LENGTH};
always @* begin
    if (BANK1_BASE != BANK0_BASE + BANK_LENGTH ||
        BANK2_BASE != BANK1_BASE + BANK_LENGTH ||
        BANK3_BASE != BANK2_BASE + BANK_LENGTH ||
        bank3_end > 22'd2097152)
        $error("four_bank_frame_ctrl: invalid non-overlapping 21-bit bank map");
end

endmodule
