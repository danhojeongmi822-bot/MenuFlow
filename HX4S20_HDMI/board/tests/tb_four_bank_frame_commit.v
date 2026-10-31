`timescale 1ns/1ps

module tb_four_bank_frame_commit;
    reg pix_clk = 1'b0;
    reg pix_rst = 1'b1;
    reg frame_start = 1'b0;
    reg commit_toggle_mem = 1'b0;
    reg [1:0] pending_index_mem = 2'd0;
    reg [3:0] bank_valid_mem = 4'b0000;
    wire [1:0] active_index;

    always #5 pix_clk = ~pix_clk;

    four_bank_frame_commit dut(
        .pix_clk(pix_clk), .pix_rst(pix_rst), .frame_start(frame_start),
        .commit_toggle_mem(commit_toggle_mem),
        .pending_index_mem(pending_index_mem),
        .bank_valid_mem(bank_valid_mem), .active_index(active_index)
    );

    task pulse_frame;
        begin
            @(negedge pix_clk); frame_start = 1'b1;
            @(negedge pix_clk); frame_start = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge pix_clk);
        pix_rst = 1'b0;

        // An invalid Bank cannot be committed.
        pending_index_mem = 2'd2;
        commit_toggle_mem = 1'b1;
        pulse_frame();
        repeat (3) @(negedge pix_clk);
        if (active_index !== 2'd0) $fatal(1, "invalid Bank was committed");

        // Once valid, the same pending request commits at a frame boundary.
        bank_valid_mem = 4'b0100;
        repeat (3) @(negedge pix_clk);
        pulse_frame();
        repeat (2) @(negedge pix_clk);
        if (active_index !== 2'd2) $fatal(1, "valid Bank did not commit");

        // A new request is held until the next frame and remains stable inside it.
        pending_index_mem = 2'd3;
        bank_valid_mem = 4'b1100;
        commit_toggle_mem = 1'b0;
        repeat (3) @(negedge pix_clk);
        if (active_index !== 2'd2) $fatal(1, "Bank changed outside frame boundary");
        pulse_frame();
        repeat (2) @(negedge pix_clk);
        if (active_index !== 2'd3) $fatal(1, "second valid Bank did not commit");

        $display("PASS four-bank frame commit: invalid guard, frame boundary, CDC hold");
        $finish;
    end
endmodule
