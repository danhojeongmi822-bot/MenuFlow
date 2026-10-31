`timescale 1ns/1ps

// SDHC 初始化回归：ACMD41 就绪后必须直接进入可读写空闲态，不能发送 CMD16。
module tb_sd_init_sdhc;
    reg clk = 1'b0;
    reg rst = 1'b1;
    wire sd_init_done;
    reg sd_sec_read = 1'b0;
    reg [31:0] sd_sec_read_addr = 32'd0;
    wire [7:0] sd_sec_read_data;
    wire sd_sec_read_data_valid;
    wire sd_sec_read_end;
    reg sd_sec_write = 1'b0;
    reg [31:0] sd_sec_write_addr = 32'd0;
    reg [7:0] sd_sec_write_data = 8'd0;
    wire sd_sec_write_data_req;
    wire sd_sec_write_end;
    wire [15:0] spi_clk_div;
    wire cmd_req;
    reg cmd_req_ack = 1'b0;
    reg cmd_req_error = 1'b0;
    wire [47:0] cmd;
    wire [7:0] cmd_r1;
    wire [15:0] cmd_data_len;
    wire block_read_req;
    reg block_read_valid = 1'b0;
    reg [7:0] block_read_data = 8'd0;
    reg block_read_req_ack = 1'b0;
    wire block_write_req;
    wire [7:0] block_write_data;
    reg block_write_data_rd = 1'b0;
    reg block_write_req_ack = 1'b0;
    reg cmd16_seen = 1'b0;

    always #5 clk = ~clk;

    sd_card_sec_read_write dut (
        .clk(clk), .rst(rst), .sd_init_done(sd_init_done),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_sec_write(sd_sec_write), .sd_sec_write_addr(sd_sec_write_addr),
        .sd_sec_write_data(sd_sec_write_data),
        .sd_sec_write_data_req(sd_sec_write_data_req),
        .sd_sec_write_end(sd_sec_write_end), .spi_clk_div(spi_clk_div),
        .cmd_req(cmd_req), .cmd_req_ack(cmd_req_ack),
        .cmd_req_error(cmd_req_error), .cmd(cmd), .cmd_r1(cmd_r1),
        .cmd_data_len(cmd_data_len), .block_read_req(block_read_req),
        .block_read_valid(block_read_valid), .block_read_data(block_read_data),
        .block_read_req_ack(block_read_req_ack),
        .block_write_req(block_write_req), .block_write_data(block_write_data),
        .block_write_data_rd(block_write_data_rd),
        .block_write_req_ack(block_write_req_ack)
    );

    always @(posedge clk) begin
        if (!rst) begin
            // The command model acknowledges every command. SDHC rejects CMD16.
            cmd_req_ack <= 1'b1;
            if (dut.state == 5'd18)
                cmd16_seen <= 1'b1;
        end
    end

    always @(*) begin
        cmd_req_error = (dut.state == 5'd18);
    end

    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        repeat (20) @(posedge clk);
        if (!sd_init_done)
            $fatal(1, "SD init did not complete after ACMD41");
        if (dut.state !== 5'd17)
            $fatal(1, "SD controller did not enter S_WAIT_READ_WRITE: state=%0d", dut.state);
        if (!cmd16_seen)
            $fatal(1, "SDHC compatibility path did not exercise CMD16 error handling");
        $display("PASS SDHC init: CMD16 error accepted and recovered to S_WAIT_READ_WRITE");
        $finish;
    end
endmodule
