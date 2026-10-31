`timescale 1ns/1ps

// 商品管理模式控制（像素时钟域 25 MHz）。
//
// 设计要点：
//  * 售罄状态与选中号全部留在像素域，**不做多位跨时钟域**；
//  * 只有 keys_blocked / menu_active 两个单比特电平去 sd 域（调用方 2FF 同步）；
//  * page_q 只在 frame_start 更新，保证状态写入目标页在一帧内不变；
//  * 按键短按在释放时生效，长按/死区不产生动作，按住不重复触发。
//
// 模式表见 .trellis/tasks/10-20-menuflow-v1/design.md §5。
module menu_control #(
    parameter integer CLK_HZ        = 25_000_000,
    parameter integer DEBOUNCE_MS   = 20,
    parameter integer LONG_MS       = 800,
    parameter integer SHORT_MAX_MS  = 600,
    parameter integer GUARD_MS      = 200,
    parameter [7:0]   DEMO_SOLDOUT  = 8'h00
)(
    input  wire       clk,
    input  wire       rst,            // 高有效
    input  wire       key_next,       // KEY2，低有效
    input  wire       key_prev,       // KEY3，低有效
    input  wire       key_menu,       // KEY4，低有效
    input  wire [1:0] active_index,   // 已提交显示 Bank
    input  wire       frame_start,
    input  wire       trans_busy,
    input  wire       display_valid,
    output reg        menu_active,
    output reg  [1:0] sel_idx,
    output reg  [7:0] soldout_mask,
    output reg  [1:0] page_q,
    output reg        keys_blocked
);

    localparam integer GUARD_CYC = (CLK_HZ / 1000) * GUARD_MS;
    localparam        S_NORMAL   = 1'b0;
    localparam        S_MANAGE   = 1'b1;

    wire next_stable, prev_stable;
    wire next_short,  prev_short,  menu_short;

    key_event #(
        .CLK_HZ (CLK_HZ), .DEBOUNCE_MS (DEBOUNCE_MS),
        .LONG_MS (LONG_MS), .SHORT_MAX_MS (SHORT_MAX_MS)
    ) u_key_next (
        .clk (clk), .rst (rst), .key_in (key_next),
        .stable_out (next_stable), .press_pulse (),
        .short_pulse (next_short), .long_pulse ()
    );

    key_event #(
        .CLK_HZ (CLK_HZ), .DEBOUNCE_MS (DEBOUNCE_MS),
        .LONG_MS (LONG_MS), .SHORT_MAX_MS (SHORT_MAX_MS)
    ) u_key_prev (
        .clk (clk), .rst (rst), .key_in (key_prev),
        .stable_out (prev_stable), .press_pulse (),
        .short_pulse (prev_short), .long_pulse ()
    );

    key_event #(
        .CLK_HZ (CLK_HZ), .DEBOUNCE_MS (DEBOUNCE_MS),
        .LONG_MS (LONG_MS), .SHORT_MAX_MS (SHORT_MAX_MS)
    ) u_key_menu (
        .clk (clk), .rst (rst), .key_in (key_menu),
        .stable_out (), .press_pulse (),
        .short_pulse (menu_short), .long_pulse ()
    );

    reg        state;
    reg [20:0] guard_cnt;

    wire in_manage   = (state == S_MANAGE);
    wire page_is_menu = (page_q < 2'd2);
    wire keys_idle   = next_stable && prev_stable;
    wire can_enter   = display_valid && !trans_busy && keys_idle;
    wire edit_ok     = in_manage && page_is_menu && !trans_busy;

    wire enter_fire  = menu_short && !in_manage && can_enter;
    wire exit_fire   = menu_short && in_manage;
    wire manage_next = enter_fire ? 1'b1 : (exit_fire ? 1'b0 : in_manage);

    wire [3:0] mask_idx = {page_q, sel_idx};

    // 退出后 GUARD_CYC 内继续屏蔽 sd 域按键，覆盖“按键尚未完全释放”的残留。
    wire [20:0] guard_next = exit_fire ? (GUARD_CYC - 1) :
                             ((guard_cnt != 21'd0) ? (guard_cnt - 21'd1) : 21'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= S_NORMAL;
            menu_active  <= 1'b0;
            sel_idx      <= 2'd0;
            soldout_mask <= DEMO_SOLDOUT;
            page_q       <= 2'd0;
            guard_cnt    <= 21'd0;
            keys_blocked <= 1'b1;
        end else begin
            state     <= manage_next;
            guard_cnt <= guard_next;
            menu_active  <= manage_next;
            keys_blocked <= (manage_next == S_MANAGE) || (guard_next != 21'd0);

            if (frame_start)
                page_q <= active_index;

            if (enter_fire) begin
                sel_idx <= 2'd0;
            end else if (in_manage && !exit_fire && edit_ok) begin
                if (next_short)
                    sel_idx <= sel_idx + 2'd1;

                if (prev_short) begin
                    case (mask_idx)
                        4'd0: soldout_mask[0] <= ~soldout_mask[0];
                        4'd1: soldout_mask[1] <= ~soldout_mask[1];
                        4'd2: soldout_mask[2] <= ~soldout_mask[2];
                        4'd3: soldout_mask[3] <= ~soldout_mask[3];
                        4'd4: soldout_mask[4] <= ~soldout_mask[4];
                        4'd5: soldout_mask[5] <= ~soldout_mask[5];
                        4'd6: soldout_mask[6] <= ~soldout_mask[6];
                        4'd7: soldout_mask[7] <= ~soldout_mask[7];
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
