`timescale 1ns/1ps

// 按键事件单元测试：消抖、短按、死区、长按、按住不重复、复位。
// 参数化时钟：CLK_HZ=1 MHz，DEBOUNCE=1 ms(1000 拍)，LONG=8 ms，SHORT_MAX=6 ms，死区 6~8 ms。
module tb_key_event;

    localparam integer CLK_HZ       = 1_000_000;
    localparam integer DEBOUNCE_MS  = 1;
    localparam integer LONG_MS      = 8;
    localparam integer SHORT_MAX_MS = 6;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg key_in = 1'b1;

    wire stable_out, press_pulse, short_pulse, long_pulse;

    integer errors = 0;
    integer presses = 0, shorts = 0, longs = 0;

    key_event #(
        .CLK_HZ (CLK_HZ), .DEBOUNCE_MS (DEBOUNCE_MS),
        .LONG_MS (LONG_MS), .SHORT_MAX_MS (SHORT_MAX_MS)
    ) dut (
        .clk (clk), .rst (rst), .key_in (key_in),
        .stable_out (stable_out), .press_pulse (press_pulse),
        .short_pulse (short_pulse), .long_pulse (long_pulse)
    );

    always #500 clk = ~clk;   // 1 MHz

    always @(posedge clk) begin
        if (press_pulse) presses = presses + 1;
        if (short_pulse) shorts = shorts + 1;
        if (long_pulse)  longs  = longs + 1;
    end

    task wait_cycles(input integer n);
        begin repeat (n) @(posedge clk); end
    endtask

    task expect_counts(input integer p, input integer s, input integer l, input [127:0] tag);
        begin
            if (presses !== p || shorts !== s || longs !== l) begin
                $display("FAIL %0s: counts press=%0d short=%0d long=%0d, expected %0d/%0d/%0d",
                         tag, presses, shorts, longs, p, s, l);
                errors = errors + 1;
            end
        end
    endtask

    task clear_counts;
        begin presses = 0; shorts = 0; longs = 0; end
    endtask

    initial begin
        // ---- 1. 复位与上电 ----
        wait_cycles(3);
        rst = 1'b0;
        wait_cycles(5);
        expect_counts(0, 0, 0, "reset");
        if (stable_out !== 1'b1) begin
            $display("FAIL reset: stable_out != 1");
            errors = errors + 1;
        end

        // ---- 2. 抖动：1 ms 内多次翻转，稳定按下后只产生 1 次 press ----
        clear_counts();
        key_in = 1'b0; wait_cycles(300);
        key_in = 1'b1; wait_cycles(100);
        key_in = 1'b0; wait_cycles(200);
        key_in = 1'b1; wait_cycles(150);
        key_in = 1'b0;
        wait_cycles(DEBOUNCE_MS * 1000 + 10);
        if (presses !== 1) begin
            $display("FAIL bounce: press pulse count %0d (expected 1)", presses);
            errors = errors + 1;
        end
        if (stable_out !== 1'b0) begin
            $display("FAIL bounce: stable_out should be 0 after hold");
            errors = errors + 1;
        end
        wait_cycles(3000);              // 总时长 ~3.8 ms < 6 ms
        key_in = 1'b1;
        wait_cycles(DEBOUNCE_MS * 1000 + 10);
        expect_counts(1, 1, 0, "short press");

        // ---- 3. 死区 6~8 ms：既不短按也不长按 ----
        clear_counts();
        key_in = 1'b0;
        wait_cycles(7200);
        key_in = 1'b1;
        wait_cycles(DEBOUNCE_MS * 1000 + 10);
        expect_counts(1, 0, 0, "dead zone");

        // ---- 4. 长按：到 8 ms 只发一次 long，释放不产生 short ----
        clear_counts();
        key_in = 1'b0;
        wait_cycles(10000);
        if (longs !== 1) begin
            $display("FAIL long: long pulse count %0d (expected 1)", longs);
            errors = errors + 1;
        end
        wait_cycles(4000);              // 继续按住，不能再触发
        key_in = 1'b1;
        wait_cycles(DEBOUNCE_MS * 1000 + 10);
        expect_counts(1, 0, 1, "long press held");

        // ---- 5. 极短毛刺（< 消抖）不产生任何事件 ----
        clear_counts();
        key_in = 1'b0; wait_cycles(300);
        key_in = 1'b1; wait_cycles(2000);
        expect_counts(0, 0, 0, "glitch");

        // ---- 6. 复位打断按压（未完成消抖）：不产生事件，且复位后电平为松开 ----
        clear_counts();
        key_in = 1'b0;
        wait_cycles(500);
        rst = 1'b1;
        wait_cycles(3);
        key_in = 1'b1;
        wait_cycles(5);
        rst = 1'b0;
        wait_cycles(DEBOUNCE_MS * 1000 + 20);
        expect_counts(0, 0, 0, "reset during press");
        if (stable_out !== 1'b1) begin
            $display("FAIL reset during press: stable_out != 1");
            errors = errors + 1;
        end

        // ---- 7. 复位释放时按键已按住：稳定后应产生 1 次 press ----
        clear_counts();
        key_in = 1'b0;
        rst = 1'b1; wait_cycles(3);
        rst = 1'b0;
        wait_cycles(DEBOUNCE_MS * 1000 + 20);
        if (presses !== 1 || stable_out !== 1'b0) begin
            $display("FAIL held at reset release: press=%0d stable=%0d", presses, stable_out);
            errors = errors + 1;
        end
        key_in = 1'b1;
        wait_cycles(DEBOUNCE_MS * 1000 + 20);

        if (errors == 0)
            $display("PASS key_event: debounce, short, dead zone, long, glitch, reset");
        else
            $display("FAIL key_event: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "key_event timeout");
    end

endmodule
