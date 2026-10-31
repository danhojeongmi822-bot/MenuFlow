`timescale 1ns/1ps

// Stage-3 boundary test: CMD17 failures are observable, held for one event
// cycle, and cannot retrigger while the legacy level request remains high.
module tb_sd_error_events;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg sd_read = 0;
    reg [31:0] sd_addr = 0;
    reg sd_write = 0;
    reg [31:0] sd_write_addr = 0;
    reg [7:0] sd_write_data = 0;
    wire init_done;
    wire [7:0] read_data;
    wire read_valid, read_end;
    wire [7:0] read_error;
    wire read_abort;
    wire write_req, write_end;
    reg cmd_ack = 0, cmd_error = 0;
    wire [15:0] spi_div;
    wire cmd_req;
    wire [47:0] cmd;
    wire [7:0] cmd_r1;
    wire [15:0] cmd_len;
    wire block_read_req;
    reg block_read_valid = 0;
    reg [7:0] block_read_data = 0;
    reg block_read_ack = 0;
    wire block_write_req;
    wire [7:0] block_write_data;
    reg block_write_rd = 0, block_write_ack = 0;

    sd_card_sec_read_write dut (
        .clk(clk), .rst(rst), .sd_init_done(init_done),
        .sd_sec_read(sd_read), .sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(read_data), .sd_sec_read_data_valid(read_valid),
        .sd_sec_read_end(read_end), .sd_sec_read_error(read_error),
        .sd_sec_read_abort(read_abort), .sd_sec_write(sd_write),
        .sd_sec_write_addr(sd_write_addr), .sd_sec_write_data(sd_write_data),
        .sd_sec_write_data_req(write_req), .sd_sec_write_end(write_end),
        .spi_clk_div(spi_div), .cmd_req(cmd_req), .cmd_req_ack(cmd_ack),
        .cmd_req_error(cmd_error), .cmd(cmd), .cmd_r1(cmd_r1),
        .cmd_data_len(cmd_len), .block_read_req(block_read_req),
        .block_read_valid(block_read_valid), .block_read_data(block_read_data),
        .block_read_req_ack(block_read_ack), .block_write_req(block_write_req),
        .block_write_data(block_write_data), .block_write_data_rd(block_write_rd),
        .block_write_req_ack(block_write_ack)
    );

    reg saw_error;
    integer error_count;
    initial begin
        saw_error = 0;
        error_count = 0;
        #22 rst = 0;
        // Put the reader at CMD17 response handling; this isolates the new
        // event contract from the physical SPI initialization sequence.
        @(negedge clk);
        dut.state = 5;
        sd_read = 1;
        cmd_ack = 1;
        cmd_error = 1;
        @(posedge clk); #1;
        if (read_error !== 8'h01) begin
            $display("FAIL CMD17 error not exposed: %h", read_error);
            $fatal;
        end
        saw_error = 1;
        error_count = error_count + 1;
        cmd_ack = 0;
        cmd_error = 0;
        // Keep the old level request asserted.  The block must not issue a
        // second error until the owner releases it.
        repeat (3) begin
            @(posedge clk); #1;
            if (read_error != 0) error_count = error_count + 1;
        end
        if (error_count != 1 || !saw_error || cmd_req) begin
            $display("FAIL stale CMD17 retry count=%0d cmd_req=%b", error_count, cmd_req);
            $fatal;
        end
        sd_read = 0;
        @(posedge clk);
        $display("SD_ERROR_EVENTS_PASS");
        $finish;
    end
endmodule

// Wrapper-side recovery event test.  The SPI model is intentionally absent;
// only the local transaction latch and abort pulse are under test.
module tb_sd_top_abort;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, recover = 0, sd_read = 0;
    wire init_done, sd_ncs, sd_dclk, sd_mosi;
    wire [7:0] data, err;
    wire valid, done, abort;
    wire wr_req, wr_end;
    sd_card_top dut (
        .clk(clk), .rst(rst), .sd_recover_req(recover),
        .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(1'b1),
        .sd_init_done(init_done), .sd_sec_read(sd_read), .sd_sec_read_addr(0),
        .sd_sec_read_data(data), .sd_sec_read_data_valid(valid),
        .sd_sec_read_end(done), .sd_sec_read_error(err), .sd_sec_read_abort(abort),
        .sd_sec_write(0), .sd_sec_write_addr(0), .sd_sec_write_data(0),
        .sd_sec_write_data_req(wr_req), .sd_sec_write_end(wr_end)
    );
    initial begin
        #22 rst = 0;
        @(posedge clk); sd_read = 1;
        @(posedge clk); recover = 1;
        @(posedge clk); #1;
        if (!abort) begin $display("FAIL recovery abort pulse missing"); $fatal; end
        recover = 0; sd_read = 0;
        @(posedge clk); #1;
        if (abort) begin $display("FAIL recovery abort pulse stuck"); $fatal; end
        $display("SD_TOP_ABORT_PASS");
        $finish;
    end
endmodule
