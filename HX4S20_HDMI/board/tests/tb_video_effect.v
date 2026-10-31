`timescale 1ns/1ps

// video_effect 单元验证：
//  - 旁路模式逐位透传（含消隐像素）；
//  - Alpha 端点与中间值：0/1/16/128/254/255 × 黑/白/红/绿/蓝/混合色，
//    期望值用整数除法 floor(v*a/255) 独立建模，验证 RTL 的加法/移位实现等价；
//  - 幕布边界：cover_x 取 0/1/中间/639/640/越界，逐像素检查 x=0 与 x=639；
//  - RGB/DE/HS/VS 同拍延迟 1 级，坐标与像素对齐；
//  - 复位后输出确定。
module tb_video_effect;

    localparam integer W = 16;

    reg         clk;
    reg         rst;
    reg         de;
    reg         hs;
    reg         vs;
    reg  [23:0] rgb_in;
    reg  [1:0]  mode;
    reg  [7:0]  alpha;
    reg  [10:0] cover_x;
    reg         wipe_reveal;

    wire [23:0] rgb_out;
    wire        de_out;
    wire        hs_out;
    wire        vs_out;

    video_effect #(.H_ACTIVE(640), .COVER_COLOR(24'h000000)) dut (
        .clk(clk), .rst(rst), .de(de), .hs(hs), .vs(vs), .rgb_in(rgb_in),
        .mode(mode), .alpha(alpha), .cover_x(cover_x), .wipe_reveal(wipe_reveal),
        .rgb_out(rgb_out), .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out)
    );

    localparam [1:0] M_PASS = 2'd0;
    localparam [1:0] M_FADE = 2'd1;
    localparam [1:0] M_WIPE = 2'd2;

    integer fails;
    integer checks;

    // 期望值寄存：在 negedge 驱动本拍输入时同时算好下一拍应看到的输出
    reg [23:0] exp_rgb;
    reg        exp_de, exp_hs, exp_vs;
    reg        exp_valid;

    always #20 clk = ~clk;   // 25 MHz

    function [7:0] scale_model;
        input [7:0] v;
        input [7:0] a;
        begin
            scale_model = (v * a) / 255;   // 整数除法，独立于 RTL 的加法/移位实现
        end
    endfunction

    function [23:0] model_rgb;
        input [23:0] c;
        input [10:0] px;
        input        de_v;
        begin
            if (!de_v)
                model_rgb = c;                       // 消隐透传
            else if (mode == M_PASS)
                model_rgb = c;
            else if (mode == M_FADE)
                model_rgb = (alpha == 8'd255) ? c :
                            {scale_model(c[23:16], alpha),
                             scale_model(c[15:8],  alpha),
                             scale_model(c[7:0],   alpha)};
            else begin
                if (wipe_reveal)
                    model_rgb = (px < cover_x) ? c : 24'h000000;
                else
                    model_rgb = (px < cover_x) ? 24'h000000 : c;
            end
        end
    endfunction

    // 驱动一个像素，同时校验上一拍输出
    task drive_pixel;
        input [23:0] c;
        input [10:0] px;
        input        de_v;
        begin
            @(negedge clk);
            if (!rst && exp_valid) begin
                checks = checks + 1;
                if (rgb_out !== exp_rgb || de_out !== exp_de ||
                    hs_out !== exp_hs || vs_out !== exp_vs) begin
                    fails = fails + 1;
                    if (fails <= 12)
                        $display("FAIL effect: got %06h/%b/%b/%b, expected %06h/%b/%b/%b (px=%0d mode=%0d a=%0d cover=%0d)",
                                 rgb_out, de_out, hs_out, vs_out,
                                 exp_rgb, exp_de, exp_hs, exp_vs,
                                 px, mode, alpha, cover_x);
                end
            end
            de     = de_v;
            hs     = ~px[0];
            vs     = 1'b1;
            rgb_in = c;
            exp_rgb   = model_rgb(c, px, de_v);
            exp_de    = de_v;
            exp_hs    = ~px[0];
            exp_vs    = 1'b1;
            exp_valid = 1'b1;
        end
    endtask

    function [23:0] color_at;
        input integer i;
        begin
            case (i % 8)
                0: color_at = 24'h000000;   // 黑
                1: color_at = 24'hFFFFFF;   // 白
                2: color_at = 24'hFF0000;   // 红
                3: color_at = 24'h00FF00;   // 绿
                4: color_at = 24'h0000FF;   // 蓝
                5: color_at = 24'h123456;   // 混合
                6: color_at = 24'h010203;   // 极小值（检查不截断为 0 的边界）
                default: color_at = 24'hFEFDFC;
            endcase
        end
    endfunction

    // 跑一行：每个像素后插一个 de=0 的空拍以复位 x 计数
    task run_row;
        input integer width;
        integer i;
        begin
            for (i = 0; i < width; i = i + 1)
                drive_pixel(color_at(i), i[10:0], 1'b1);
            drive_pixel(24'h000000, 11'd0, 1'b0);
            drive_pixel(24'h000000, 11'd0, 1'b0);
        end
    endtask

    integer a;
    integer k;

    initial begin
        clk         = 1'b0;
        rst         = 1'b1;
        de          = 1'b0;
        hs          = 1'b0;
        vs          = 1'b0;
        rgb_in      = 24'd0;
        mode        = M_PASS;
        alpha       = 8'd255;
        cover_x     = 11'd0;
        wipe_reveal = 1'b0;
        fails       = 0;
        checks      = 0;
        exp_rgb     = 24'd0;
        exp_de      = 1'b0;
        exp_hs      = 1'b0;
        exp_vs      = 1'b0;
        exp_valid   = 1'b0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // 0) 复位刚释放：输出为 0，不可能是 X
        if (rgb_out !== 24'h000000 || de_out !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL effect: outputs not defined after reset");
        end

        // 1) 旁路：逐位透传
        mode = M_PASS; alpha = 8'd255; cover_x = 11'd0; wipe_reveal = 1'b0;
        run_row(W);
        run_row(W);

        // 2) 淡入淡出端点与中间值
        for (k = 0; k < 6; k = k + 1) begin
            case (k)
                0: a = 0;
                1: a = 1;
                2: a = 16;
                3: a = 128;
                4: a = 254;
                default: a = 255;
            endcase
            mode  = M_FADE;
            alpha = a[7:0];
            run_row(W);
        end

        // 3) 幕布遮挡：边界 0/1/中间/越界（W 宽度内）
        mode = M_WIPE; alpha = 8'd255; wipe_reveal = 1'b0;
        for (k = 0; k < 6; k = k + 1) begin
            case (k)
                0: cover_x = 11'd0;
                1: cover_x = 11'd1;
                2: cover_x = 11'd5;
                3: cover_x = 11'd15;
                4: cover_x = 11'd16;
                default: cover_x = 11'd17;
            endcase
            run_row(W);
        end

        // 4) 幕布揭示：同一组边界
        wipe_reveal = 1'b1;
        for (k = 0; k < 6; k = k + 1) begin
            case (k)
                0: cover_x = 11'd0;
                1: cover_x = 11'd1;
                2: cover_x = 11'd5;
                3: cover_x = 11'd15;
                4: cover_x = 11'd16;
                default: cover_x = 11'd17;
            endcase
            run_row(W);
        end

        // 5) 640 像素整行：x=639 与 cover_x=639/640 的最后一列
        cover_x = 11'd639;
        run_row(640);
        cover_x = 11'd640;
        run_row(640);
        wipe_reveal = 1'b0;
        cover_x = 11'd639;
        run_row(640);
        cover_x = 11'd640;
        run_row(640);

        // 6) 复位：输出立即归零
        mode = M_FADE; alpha = 8'd0; cover_x = 11'd0;
        @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        #1;
        if (rgb_out !== 24'h000000 || de_out !== 1'b0 || hs_out !== 1'b0 || vs_out !== 1'b0) begin
            fails = fails + 1;
            $display("FAIL effect: reset did not clear outputs");
        end
        rst = 1'b0;
        exp_valid = 1'b0;
        repeat (2) @(negedge clk);
        mode = M_PASS; alpha = 8'd255;
        run_row(W);

        if (fails == 0) begin
            $display("PASS video_effect: %0d pixel checks", checks);
            $finish;
        end else begin
            $display("FAIL video_effect: %0d failure(s) over %0d checks", fails, checks);
            $fatal(1);
        end
    end

endmodule
