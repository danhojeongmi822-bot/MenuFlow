`timescale 1ns/1ps

// 确定性检查帧缓存写入地址：输入流按行递增时，WRITE_V_FLIP=1
// 应把第 0 行写到最后一行地址，并在每个行尾向前跳一整行。
// 本 TB 只实例化明文 frame_fifo_write，不代表真实 SDRAM PHY。
module tb_frame_fifo_write_address;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg write_req = 1'b0;
    reg write_en = 1'b0;
    reg [31:0] write_data = 32'd0;
    wire write_req_ack;
    wire write_finish;
    wire app_wr_en;
    wire [20:0] app_wr_addr;
    wire fifo_aclr;
    wire busy;
    integer seen;
    integer errors;
    reg [20:0] first_addr;
    reg [20:0] row0_last_addr;
    reg [20:0] row1_first_addr;
    reg [20:0] prev_addr;

    always #12 clk = ~clk;

    frame_fifo_write #(
        .BURST_BITS   (9),
        .BURST_SIZE   (256),
        .WRITE_V_FLIP (1),
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) dut (
        .rst              (rst),
        .mem_clk          (clk),
        .Sdr_init_done    (1'b1),
        .Sdr_init_ref_vld (1'b0),
        .Sdr_busy         (1'b0),
        .App_rd_busy      (1'b0),
        .O_wr_busy        (busy),
        .App_wr_en        (app_wr_en),
        .App_wr_addr      (app_wr_addr),
        .write_req        (write_req),
        .write_req_ack    (write_req_ack),
        .write_finish     (write_finish),
        .write_addr_0     (21'd0),
        .write_addr_1     (21'd307200),
        .write_addr_2     (21'd614400),
        .write_addr_3     (21'd921600),
        .write_addr_index (2'd0),
        .write_len        (21'd307200),
        .fifo_aclr        (fifo_aclr),
        .rdusedw          (10'd512)
    );

    always @(negedge clk) begin
        if (!rst && app_wr_en) begin
            seen = seen + 1;
            if (seen == 1)
                first_addr = app_wr_addr;
            if (seen == 640)
                row0_last_addr = app_wr_addr;
            if (seen == 641)
                row1_first_addr = app_wr_addr;
            if (seen > 1 && seen != 641 && app_wr_addr !== prev_addr + 21'd1 &&
                (seen % 640) != 1) begin
                errors = errors + 1;
                $display("FAIL address increment at sample %0d: prev=%0d current=%0d",
                         seen, prev_addr, app_wr_addr);
            end
            prev_addr = app_wr_addr;
        end
    end

    initial begin
        seen = 0;
        errors = 0;
        first_addr = 0;
        row0_last_addr = 0;
        row1_first_addr = 0;
        prev_addr = 0;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Request one complete frame; the controller holds ACK until request drops.
        @(negedge clk);
        write_req = 1'b1;
        wait (write_req_ack);
        repeat (2) @(negedge clk);
        write_req = 1'b0;

        // Allow the first 641 memory writes to be emitted.
        while (seen < 641)
            @(negedge clk);

        if (first_addr !== 21'd306560)
            errors = errors + 1;
        if (row0_last_addr !== 21'd307199)
            errors = errors + 1;
        if (row1_first_addr !== 21'd305920)
            errors = errors + 1;

        if (errors == 0)
            $display("PASS frame write address: row0=%0d..%0d row1=%0d (vertical flip)",
                     first_addr, row0_last_addr, row1_first_addr);
        else
            $fatal(1, "frame write address errors=%0d first=%0d row0_last=%0d row1_first=%0d",
                   errors, first_addr, row0_last_addr, row1_first_addr);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "timeout waiting for address samples (seen=%0d)", seen);
    end
endmodule
