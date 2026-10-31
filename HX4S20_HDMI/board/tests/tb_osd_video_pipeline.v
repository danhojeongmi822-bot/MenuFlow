`timescale 1ns/1ps

// OSD 视频流水线验证：
// 真实 video_timing_data + video_delay 产生 640x480 时序和像素，
// 同一份输入并行送入“OSD 使能”和“OSD 禁用”两个实例：
//  - 禁用实例必须与输入逐位一致（纯延迟基线）；
//  - 使能实例只在模型预测的 OSD 像素上改变颜色，其余像素必须与基线完全一致；
//  - 状态只在帧边界生效，滚动偏移按帧递增，多帧无坐标漂移；
//  - 每帧有效像素数为 307200。
module tb_osd_video_pipeline;

    reg         clk;
    reg         rst;
    reg  [9:0]  status_in;
    reg  [1:0]  idx_in;

    // ---------------- 真实视频时序链 ----------------
    wire        rd_req;
    wire        hs0, vs0, de0;
    reg  [23:0] rd_data;
    wire        hs, vs, de;
    wire [23:0] vout;

    video_timing_data u_timing (
        .video_clk    (clk),
        .rst          (rst),
        .read_req     (rd_req),
        .read_req_ack (1'b0),
        .hs           (hs0),
        .vs           (vs0),
        .de           (de0)
    );

    video_delay u_delay (
        .video_clk (clk),
        .rst       (rst),
        .read_en   (),
        .read_data (rd_data),
        .hs        (hs0),
        .vs        (vs0),
        .de        (de0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout)
    );

    // 伪随机背景，保证“透传”不是常量掩盖。
    reg [23:0] lfsr;
    always @(posedge clk or posedge rst) begin
        if (rst)
            lfsr <= 24'hA5C3E1;
        else
            lfsr <= {lfsr[22:0], lfsr[23] ^ lfsr[21] ^ lfsr[20] ^ lfsr[16]};
    end
    always @* rd_data = lfsr;

    // ---------------- 双 OSD 实例 ----------------
    wire [23:0] on_rgb, off_rgb;
    wire        on_de, on_hs, on_vs, on_fs, on_active;
    wire        off_de, off_hs, off_vs, off_fs, off_active;
    wire [9:0]  on_x, on_y, off_x, off_y;
    wire [10:0] on_scroll, off_scroll;

    osd_overlay #(
        .H_ACTIVE(640), .V_ACTIVE(480),
        .STATUS_X(8), .STATUS_Y(8), .SUBTITLE_Y(448),
        .SCROLL_STEP(2), .TEXT_LEN(40), .TEXT_WIDTH(640),
        .OSD_ENABLE(1)
    ) u_on (
        .clk(clk), .rst(rst), .hs(hs), .vs(vs), .de(de), .rgb_in(vout),
        .active_index(idx_in), .status(status_in),
        .rgb_out(on_rgb), .de_out(on_de), .hs_out(on_hs), .vs_out(on_vs),
        .frame_start(on_fs), .pixel_x(on_x), .pixel_y(on_y),
        .scroll_offset(on_scroll), .osd_active(on_active)
    );

    osd_overlay #(
        .H_ACTIVE(640), .V_ACTIVE(480),
        .STATUS_X(8), .STATUS_Y(8), .SUBTITLE_Y(448),
        .SCROLL_STEP(2), .TEXT_LEN(40), .TEXT_WIDTH(640),
        .OSD_ENABLE(0)
    ) u_off (
        .clk(clk), .rst(rst), .hs(hs), .vs(vs), .de(de), .rgb_in(vout),
        .active_index(idx_in), .status(status_in),
        .rgb_out(off_rgb), .de_out(off_de), .hs_out(off_hs), .vs_out(off_vs),
        .frame_start(off_fs), .pixel_x(off_x), .pixel_y(off_y),
        .scroll_offset(off_scroll), .osd_active(off_active)
    );

    // ---------------- 帧边界模型（与 DUT 同沿锁存） ----------------
    reg [9:0]  m_status;
    reg [1:0]  m_idx;
    reg [10:0] m_scroll;

    wire [10:0] m_scroll_next = (m_scroll + 2 >= 11'd1280) ? 11'd0 : m_scroll + 2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_status <= 10'h0E1;
            m_idx    <= 2'd0;
            m_scroll <= 11'd0;
        end else if (on_fs) begin
            m_status <= status_in;
            m_idx    <= idx_in;
            m_scroll <= m_scroll_next;
        end
    end

    // ---------------- 期望字符与字模 ----------------
    function [6:0] hex_char;
        input [3:0] v;
        begin
            if (v < 4'd10)
                hex_char = 7'h30 + {3'd0, v};
            else
                hex_char = 7'h41 + {3'd0, v} - 7'd10;
        end
    endfunction

    function [6:0] status_char;
        input [1:0] cell_sel;
        input [9:0] st;
        input [1:0] idx;
        begin
            case (cell_sel)
                2'd0: status_char = st[9] ? (7'h31 + {5'd0, idx}) : 7'h2D;
                2'd1: status_char = st[8] ? 7'h41 : 7'h4D;
                2'd2: status_char = hex_char(st[7:4]);
                2'd3: status_char = hex_char(st[3:0]);
                default: status_char = 7'h20;
            endcase
        end
    endfunction

    function [6:0] text_char;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  text_char = 7'h48; 6'd1:  text_char = 7'h58;
                6'd2:  text_char = 7'h34; 6'd3:  text_char = 7'h53;
                6'd4:  text_char = 7'h32; 6'd5:  text_char = 7'h30;
                6'd6:  text_char = 7'h20; 6'd7:  text_char = 7'h46;
                6'd8:  text_char = 7'h50; 6'd9:  text_char = 7'h47;
                6'd10: text_char = 7'h41; 6'd11: text_char = 7'h20;
                6'd12: text_char = 7'h48; 6'd13: text_char = 7'h44;
                6'd14: text_char = 7'h4D; 6'd15: text_char = 7'h49;
                6'd16: text_char = 7'h20; 6'd17: text_char = 7'h50;
                6'd18: text_char = 7'h48; 6'd19: text_char = 7'h4F;
                6'd20: text_char = 7'h54; 6'd21: text_char = 7'h4F;
                6'd22: text_char = 7'h20; 6'd23: text_char = 7'h50;
                6'd24: text_char = 7'h4C; 6'd25: text_char = 7'h41;
                6'd26: text_char = 7'h59; 6'd27: text_char = 7'h45;
                6'd28: text_char = 7'h52; 6'd29: text_char = 7'h20;
                6'd30: text_char = 7'h2D; 6'd31: text_char = 7'h20;
                6'd32: text_char = 7'h4F; 6'd33: text_char = 7'h53;
                6'd34: text_char = 7'h44; 6'd35: text_char = 7'h20;
                6'd36: text_char = 7'h44; 6'd37: text_char = 7'h45;
                6'd38: text_char = 7'h4D; 6'd39: text_char = 7'h4F;
                default: text_char = 7'h20;
            endcase
        end
    endfunction

    wire [9:0] cx = on_x;
    wire [9:0] cy = on_y;

    // 状态条区域
    wire       in_status = (cx >= 10'd8) && (cx < 10'd72) &&
                           (cy >= 10'd8) && (cy < 10'd24);
    wire [9:0] sx = cx - 10'd8;
    wire [9:0] sy = cy - 10'd8;
    wire [1:0] scell = sx[5:4];
    wire [3:0] scol  = sx[3:0];
    wire [3:0] srow  = sy[3:0];
    wire [2:0] s_fy  = srow[3:1];
    wire [1:0] s_fx  = scol[3:1];
    wire [6:0] s_char = status_char(scell, m_status, m_idx);
    wire [4:0] s_glyph;
    osd_font_rom u_ref_s (.ch(s_char), .row(s_fy), .glyph(s_glyph));
    wire s_hit = in_status && (scol < 4'd10) && (srow < 4'd14) &&
                 s_glyph[3'd4 - {1'b0, s_fx}];

    // 滚动字幕区域
    wire [10:0] txsum  = {1'b0, cx} + m_scroll;
    wire [10:0] tlocal = txsum - 11'd640;
    wire [9:0]  ty     = cy - 10'd448;
    wire        t_in_y = (cy >= 10'd448) && (cy < 10'd464);
    wire [5:0]  tcell  = tlocal[9:4];
    wire [3:0]  tcol   = tlocal[3:0];
    wire [2:0]  t_fy   = ty[3:1];
    wire [1:0]  t_fx   = tcol[3:1];
    wire        t_vis  = (txsum >= 11'd640) && (tlocal < 11'd640) && t_in_y;
    wire [6:0]  t_char = text_char(tcell);
    wire [4:0]  t_glyph;
    osd_font_rom u_ref_t (.ch(t_char), .row(t_fy), .glyph(t_glyph));
    wire t_hit = t_vis && (tcell < 6'd40) && (tcol < 4'd10) &&
                 t_glyph[3'd4 - {1'b0, t_fx}];

    wire        exp_active = on_de && (s_hit || t_hit);
    wire        exp_err    = (m_status[7:0] != 8'd0);
    wire [23:0] exp_color  = s_hit ? (exp_err ? 24'hFF3030 : 24'hFFFF00)
                                   : 24'h00FFFF;

    // ---------------- 检查器 ----------------
    integer fails;
    integer checks;
    integer frames;
    integer pix_cnt;
    integer pix_frames;
    reg     frame_seen;
    reg     de_prev;
    reg     vs_prev;
    reg [9:0] x_acc;
    reg [9:0] y_acc;
    reg [23:0] vout_d;
    reg        de_in_d, vs_in_d;

    initial begin
        clk       = 1'b0;
        rst       = 1'b1;
        status_in = 10'h0E1;
        idx_in    = 2'd0;
        fails     = 0;
        checks    = 0;
        frames    = 0;
        pix_cnt   = 0;
        pix_frames= 0;
        frame_seen= 1'b0;
        de_prev   = 1'b0;
        vs_prev   = 1'b0;
        x_acc     = 10'd0;
        y_acc     = 10'd0;
        vout_d    = 24'd0;
        de_in_d   = 1'b0;
        vs_in_d   = 1'b0;
    end

    always #20 clk = ~clk;   // 25 MHz

    always @(posedge clk) begin
        vout_d  <= vout;
        de_in_d <= de;
        vs_in_d <= vs;
    end

    // 逐像素检查（在时钟下降沿读取已稳定的输出）
    always @(negedge clk) begin
        if (!rst) begin
            checks = checks + 1;

            if (off_rgb !== vout_d || off_de !== de_in_d || off_vs !== vs_in_d) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("FAIL pipe: disabled OSD is not a pure delay at x=%0d y=%0d",
                             off_x, off_y);
            end

            if (on_de !== off_de || on_vs !== off_vs ||
                on_x !== off_x || on_y !== off_y) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("FAIL pipe: enabled/disabled sync or coordinates differ");
            end

            if (on_scroll !== m_scroll) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("FAIL pipe: scroll %0d != model %0d", on_scroll, m_scroll);
            end

            if (on_active !== exp_active) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("FAIL pipe: osd_active %b != expected %b at (%0d,%0d)",
                             on_active, exp_active, on_x, on_y);
            end else if (exp_active) begin
                if (on_rgb !== exp_color) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL pipe: OSD color %06h != %06h at (%0d,%0d)",
                                 on_rgb, exp_color, on_x, on_y);
                end
            end else begin
                if (on_rgb !== off_rgb) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL pipe: non-OSD pixel changed at (%0d,%0d): %06h != %06h",
                                 on_x, on_y, on_rgb, off_rgb);
                end
            end

            // 独立坐标累加器
            if (off_de) begin
                if (!de_prev && (off_x !== 10'd0)) begin
                    fails = fails + 1;
                    if (fails <= 10) $display("FAIL pipe: first pixel x=%0d", off_x);
                end
                if (de_prev && (off_x !== (x_acc + 10'd1))) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL pipe: x=%0d expected %0d", off_x, x_acc + 10'd1);
                end
                if (off_y !== y_acc) begin
                    fails = fails + 1;
                    if (fails <= 10)
                        $display("FAIL pipe: y=%0d expected %0d", off_y, y_acc);
                end
                x_acc = off_x;
                pix_cnt = pix_cnt + 1;
            end else begin
                x_acc = 10'd0;
            end

            // 行计数：de 下降沿
            if (de_prev && !off_de)
                y_acc = y_acc + 10'd1;

            // 帧边界：vs 下降沿
            if (vs_prev && !off_vs) begin
                y_acc = 10'd0;
                frames = frames + 1;
                if (frame_seen) begin
                    if (pix_cnt != 307200) begin
                        fails = fails + 1;
                        $display("FAIL pipe: frame %0d has %0d active pixels", frames, pix_cnt);
                    end else begin
                        pix_frames = pix_frames + 1;
                    end
                end
                frame_seen = 1'b1;
                pix_cnt = 0;
                if (!on_fs) begin
                    fails = fails + 1;
                    $display("FAIL pipe: missing frame_start at vs falling edge");
                end
            end

            de_prev = off_de;
            vs_prev = off_vs;
        end else begin
            de_prev = 1'b0;
            vs_prev = 1'b0;
            x_acc = 10'd0;
            y_acc = 10'd0;
            pix_cnt = 0;
            frame_seen = 1'b0;
        end
    end

    task wait_frames;
        input integer n;
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(posedge clk);
                if (on_fs)
                    k = k + 1;
            end
        end
    endtask

    initial begin
        #400;
        rst = 1'b0;

        wait_frames(3);

        // 1) 正常：图片 2、手动、无错误 -> 黄色状态条。
        @(negedge clk);
        status_in = {1'b1, 1'b0, 8'h00};
        idx_in    = 2'd1;
        wait_frames(4);

        // 2) 帧中途切到自动 + 错误 03；数值只能在下一帧生效。
        wait_frames(1);
        #2000;
        status_in = {1'b1, 1'b1, 8'h03};
        idx_in    = 2'd2;
        #4000;
        wait_frames(5);

        // 3) 错误清除，自动模式保持。
        @(negedge clk);
        status_in = {1'b1, 1'b1, 8'h00};
        wait_frames(4);

        // 4) 无有效图像：编号显示 '-'。
        @(negedge clk);
        status_in = {1'b0, 1'b1, 8'h00};
        wait_frames(4);

        // 5) 运行中复位：恢复到默认快照并继续工作。
        wait_frames(1);
        #3000;
        rst = 1'b1;
        #400;
        @(negedge clk);
        status_in = {1'b1, 1'b0, 8'h00};
        idx_in    = 2'd3;
        rst = 1'b0;
        wait_frames(3);

        if (fails == 0) begin
            $display("PASS osd_video_pipeline: %0d checks, %0d frames (%0d full 307200-pixel frames)",
                     checks, frames, pix_frames);
            $finish;
        end else begin
            $display("FAIL osd_video_pipeline: %0d failure(s) over %0d checks", fails, checks);
            $fatal(1);
        end
    end

endmodule
