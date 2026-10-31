`timescale 1ns/1ps

// 商品管理模式状态机测试（设计 design.md §5.2 的转移表逐行覆盖）。
// 参数化：1 MHz 时钟，消抖 1 ms，长按 8 ms，短按上限 6 ms，退出守卫 2 ms。
module tb_menu_control;

    localparam integer CLK_HZ = 1_000_000;
    localparam integer DB     = 1000;   // 消抖拍数
    localparam integer GUARD  = 2000;   // 退出守卫拍数

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg key_next = 1'b1;
    reg key_prev = 1'b1;
    reg key_menu = 1'b1;

    reg [1:0] active_index = 2'd0;
    reg       frame_start  = 1'b0;
    reg       trans_busy   = 1'b0;
    reg       display_valid = 1'b0;

    wire        menu_active;
    wire [1:0]  sel_idx;
    wire [7:0]  soldout_mask;
    wire [1:0]  page_q;
    wire        keys_blocked;

    integer errors = 0;
    integer seed;

    menu_control #(
        .CLK_HZ (CLK_HZ), .DEBOUNCE_MS (1), .LONG_MS (8),
        .SHORT_MAX_MS (6), .GUARD_MS (2), .DEMO_SOLDOUT (8'h00)
    ) dut (
        .clk (clk), .rst (rst),
        .key_next (key_next), .key_prev (key_prev), .key_menu (key_menu),
        .active_index (active_index), .frame_start (frame_start),
        .trans_busy (trans_busy), .display_valid (display_valid),
        .menu_active (menu_active), .sel_idx (sel_idx),
        .soldout_mask (soldout_mask), .page_q (page_q), .keys_blocked (keys_blocked)
    );

    always #500 clk = ~clk;

    task wait_cycles(input integer n);
        begin repeat (n) @(posedge clk); end
    endtask

    task chk(input cond, input [511:0] msg);
        begin
            if (!cond) begin
                $display("FAIL %0s (menu=%b sel=%0d mask=%02x page=%0d blocked=%b)",
                         msg, menu_active, sel_idx, soldout_mask, page_q, keys_blocked);
                errors = errors + 1;
            end
        end
    endtask

    task do_frame(input [1:0] idx);
        begin
            active_index = idx;
            @(negedge clk) frame_start = 1'b1;
            @(negedge clk) frame_start = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // which: 0=key_next(KEY2) 1=key_prev(KEY3) 2=key_menu(KEY4)；hold=按下拍数
    task press_key(input integer which, input integer hold_cycles);
        begin
            @(negedge clk);
            if (which == 0) key_next = 1'b0;
            else if (which == 1) key_prev = 1'b0;
            else key_menu = 1'b0;
            repeat (hold_cycles) @(posedge clk);
            @(negedge clk);
            if (which == 0) key_next = 1'b1;
            else if (which == 1) key_prev = 1'b1;
            else key_menu = 1'b1;
            repeat (DB + 10) @(posedge clk);
        end
    endtask

    task short_press(input integer which);
        begin press_key(which, 2 * DB); end
    endtask

    task do_reset;
        begin
            rst = 1'b1;
            key_next = 1'b1; key_prev = 1'b1; key_menu = 1'b1;
            display_valid = 1'b0; trans_busy = 1'b0;
            wait_cycles(4);
            rst = 1'b0;
            wait_cycles(4);
            display_valid = 1'b1;
            do_frame(2'd0);
        end
    endtask

    initial begin
        // ---- 0. 复位 ----
        do_reset();
        chk(menu_active === 1'b0, "reset: menu_active should be 0");
        chk(soldout_mask === 8'h00, "reset: mask should be 0");
        chk(keys_blocked === 1'b0, "reset: keys_blocked should be 0");
        chk(page_q === 2'd0, "reset: page_q should be 0");

        // ---- 1. 无画面时拒绝进入 ----
        display_valid = 1'b0;
        short_press(2);
        chk(menu_active === 1'b0, "enter refused when display_valid=0");
        display_valid = 1'b1;

        // ---- 2. 转场中拒绝进入 ----
        trans_busy = 1'b1;
        short_press(2);
        chk(menu_active === 1'b0, "enter refused when trans_busy=1");
        trans_busy = 1'b0;

        // ---- 3. 其它键按住时拒绝进入 ----
        @(negedge clk) key_next = 1'b0;
        repeat (2 * DB) @(posedge clk);
        short_press(2);
        chk(menu_active === 1'b0, "enter refused while KEY2 held");
        @(negedge clk) key_next = 1'b1;
        repeat (DB + 10) @(posedge clk);

        // ---- 4. 正常进入：选中号归零 ----
        short_press(2);
        chk(menu_active === 1'b1, "enter accepted");
        chk(sel_idx === 2'd0, "enter resets selection");

        // ---- 5. 选择循环 0->1->2->3->0 ----
        short_press(0);
        chk(sel_idx === 2'd1, "select 1");
        short_press(0);
        chk(sel_idx === 2'd2, "select 2");
        short_press(0);
        chk(sel_idx === 2'd3, "select 3");
        short_press(0);
        chk(sel_idx === 2'd0, "select wraps to 0");

        // ---- 6. 单商品置售罄/恢复 ----
        short_press(1);
        chk(soldout_mask === 8'h01, "toggle product0 sold out");
        short_press(1);
        chk(soldout_mask === 8'h00, "toggle product0 back in sale");

        // ---- 7. 页号只在帧边界更新 ----
        active_index = 2'd1;
        wait_cycles(3);
        chk(page_q === 2'd0, "page_q must not change without frame_start");
        do_frame(2'd1);
        chk(page_q === 2'd1, "page_q follows frame boundary");

        // ---- 8. 第 2 页独立状态 ----
        short_press(0);             // sel=1
        short_press(0);             // sel=2
        short_press(1);             // mask[{1,2}] = bit6
        chk(soldout_mask === 8'h40, "page2 product2 sold out -> bit6");
        short_press(1);
        chk(soldout_mask === 8'h00, "page2 product2 restore");

        // ---- 9. 多商品独立（同一页两位） ----
        short_press(0);             // sel=3
        short_press(1);             // bit7
        short_press(0);             // sel=0
        short_press(1);             // bit4
        chk(soldout_mask === 8'h90, "page2 product3+product0 independent");
        do_frame(2'd0);
        chk(soldout_mask === 8'h90, "page change keeps mask");
        short_press(1);             // page1/product0 -> bit0
        chk(soldout_mask === 8'h91, "page1 bit0 does not touch page2 bits");
        short_press(1);
        chk(soldout_mask === 8'h90, "page1 bit0 restore keeps page2 bits");

        // ---- 10. 促销页：选择与切换无效 ----
        do_frame(2'd2);
        short_press(0);
        chk(sel_idx === 2'd0, "promo page: select ignored");
        short_press(1);
        chk(soldout_mask === 8'h90, "promo page: toggle ignored");
        do_frame(2'd3);
        short_press(1);
        chk(soldout_mask === 8'h90, "promo page 4: toggle ignored");
        do_frame(2'd0);

        // ---- 11. 转场中禁止编辑 ----
        trans_busy = 1'b1;
        short_press(1);
        chk(soldout_mask === 8'h90, "edit ignored while trans_busy");
        short_press(0);
        chk(sel_idx === 2'd0, "select ignored while trans_busy");
        trans_busy = 1'b0;

        // ---- 12. 长按与死区不产生动作 ----
        press_key(1, 10000);        // 长按：无 short，long 被忽略
        chk(soldout_mask === 8'h90, "long press must not toggle");
        press_key(0, 7200);         // 死区：无 short
        chk(sel_idx === 2'd0, "dead-zone press must not select");
        chk(menu_active === 1'b1, "long/dead-zone press must not exit");

        // ---- 13. 退出与守卫 ----
        short_press(2);
        chk(menu_active === 1'b0, "exit accepted");
        chk(keys_blocked === 1'b1, "guard asserts after exit");
        wait_cycles(GUARD + 200);
        chk(keys_blocked === 1'b0, "guard releases after GUARD_MS");
        chk(soldout_mask === 8'h90, "exit keeps mask");

        // ---- 14. 退出后普通按键恢复（由顶层门控，此处只验证状态不再变化） ----
        short_press(1);
        chk(soldout_mask === 8'h90, "normal mode: KEY3 must not toggle mask");

        // ---- 15. 复位清除状态 ----
        do_reset();
        chk(soldout_mask === 8'h00, "reset clears mask");
        chk(menu_active === 1'b0, "reset leaves management");
        chk(keys_blocked === 1'b0, "reset clears guard");

        // ---- 16. 随机压力：固定种子，检查不变量 ----
        seed = 32'h20261020;
        begin : random_stress
            integer i, which, hold, prev_mask, prev_sel, prev_menu, prev_page;
            for (i = 0; i < 60; i = i + 1) begin
                prev_mask = soldout_mask;
                prev_sel  = sel_idx;
                prev_menu = menu_active;
                prev_page = page_q;
                which = {$random(seed)} % 4;      // 0..3（3=不按键）
                hold  = 100 + ({$random(seed)} % 9000);
                if (which < 3)
                    press_key(which, hold);
                else
                    wait_cycles(2000 + ({$random(seed)} % 4000));
                if (({$random(seed)} % 5) == 0) do_frame({$random(seed)} % 4);
                if (({$random(seed)} % 11) == 0) trans_busy = ~trans_busy;
                // 不变量
                if (^{menu_active, sel_idx, soldout_mask, page_q} === 1'bx) begin
                    $display("FAIL stress: X on control outputs");
                    errors = errors + 1;
                end
                if (!prev_menu && (soldout_mask !== prev_mask)) begin
                    $display("FAIL stress: mask changed outside management (%02x->%02x)",
                             prev_mask, soldout_mask);
                    errors = errors + 1;
                end
                if (!prev_menu && (sel_idx !== prev_sel)) begin
                    $display("FAIL stress: selection changed outside management");
                    errors = errors + 1;
                end
                if ((prev_page >= 2'd2) && (page_q === prev_page) && (prev_mask !== soldout_mask) && prev_menu) begin
                    $display("FAIL stress: promo page changed mask");
                    errors = errors + 1;
                end
            end
            trans_busy = 1'b0;
        end

        if (errors == 0)
            $display("PASS menu_control: entry/exit, select, toggle, pages, promo, guard, stress");
        else
            $display("FAIL menu_control: %0d assertion(s)", errors);
        $finish;
    end

    initial begin
        #800000000;
        $fatal(1, "menu_control timeout");
    end

endmodule
