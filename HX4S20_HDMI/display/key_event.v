`timescale 1ns/1ps

// 单个按键的事件检测：2FF 同步 + 消抖 + 短按/长按判定。
//
// 语义（按键低有效，松开=1、按下=0）：
//   press_pulse : 稳定按下时 1 拍
//   short_pulse : 释放时产生 1 拍，且按下时长 <  SHORT_MAX_MS
//   long_pulse  : 按住达到 LONG_MS 时产生 1 拍，之后不再重复
//   [SHORT_MAX_MS, LONG_MS) 为死区：既不短按也不长按，避免临界误触
//
// 仅使用电平与计数，不做跨域多位传输；调用方负责把事件放到本时钟域使用。
module key_event #(
    parameter integer CLK_HZ       = 25_000_000,
    parameter integer DEBOUNCE_MS  = 20,
    parameter integer LONG_MS      = 800,
    parameter integer SHORT_MAX_MS = 600
)(
    input  wire clk,
    input  wire rst,            // 高有效
    input  wire key_in,
    output reg  stable_out,     // 消抖后的电平：1=松开
    output reg  press_pulse,
    output reg  short_pulse,
    output reg  long_pulse
);

    localparam integer DB_CYC    = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer LONG_CYC  = (CLK_HZ / 1000) * LONG_MS;
    localparam integer SHORT_CYC = (CLK_HZ / 1000) * SHORT_MAX_MS;

    (* ASYNC_REG = "TRUE" *) reg sync0;
    (* ASYNC_REG = "TRUE" *) reg sync1;

    reg [19:0] db_cnt;
    reg [24:0] dur_cnt;
    reg        long_fired;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync0       <= 1'b1;
            sync1       <= 1'b1;
            stable_out  <= 1'b1;
            db_cnt      <= 20'd0;
            dur_cnt     <= 25'd0;
            long_fired  <= 1'b0;
            press_pulse <= 1'b0;
            short_pulse <= 1'b0;
            long_pulse  <= 1'b0;
        end else begin
            sync0 <= key_in;
            sync1 <= sync0;

            press_pulse <= 1'b0;
            short_pulse <= 1'b0;
            long_pulse  <= 1'b0;

            // ---- 消抖：电平稳定 DB_CYC 个时钟才接受 ----
            if (sync1 == stable_out) begin
                db_cnt <= 20'd0;
            end else if (db_cnt >= DB_CYC - 1) begin
                db_cnt     <= 20'd0;
                stable_out <= sync1;
                if (!sync1) begin
                    // 稳定按下
                    press_pulse <= 1'b1;
                    dur_cnt     <= 25'd0;
                    long_fired  <= 1'b0;
                end else begin
                    // 稳定松开：只有未触发长按且时长在上限内才算短按
                    if (!long_fired && (dur_cnt < SHORT_CYC))
                        short_pulse <= 1'b1;
                end
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end

            // ---- 按住时长：达到阈值只发一次 long_pulse ----
            if (!stable_out && !long_fired) begin
                if (dur_cnt >= LONG_CYC - 1) begin
                    long_pulse <= 1'b1;
                    long_fired <= 1'b1;
                end else begin
                    dur_cnt <= dur_cnt + 25'd1;
                end
            end
        end
    end

endmodule
