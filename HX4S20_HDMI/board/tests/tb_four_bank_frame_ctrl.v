`timescale 1ns/1ps
module tb_four_bank_frame_ctrl;
reg clk = 1'b0;
always #1 clk = ~clk;
reg rst = 1'b1;
reg frame_boundary = 1'b0;
reg request_valid = 1'b0;
reg [1:0] request_index = 2'd0;
reg source_done = 1'b0;
reg write_done = 1'b0;
reg load_error = 1'b0;
wire load_start, busy, cache_hit, request_rejected;
wire [1:0] load_index, pending_bank, active_bank;
wire pending_valid, commit_pulse;
wire [3:0] image_valid;
wire [31:0] commit_count, reject_count;
integer errors = 0;

four_bank_frame_ctrl dut(.*);

task tick; begin @(posedge clk); #0.1; end endtask
task request(input [1:0] idx);
    begin request_index=idx; request_valid=1'b1; tick; request_valid=1'b0; end
endtask

initial begin
    repeat (2) tick; rst=1'b0;
    request(2'd0);
    if (!load_start || load_index !== 2'd0 || !busy) begin $display("FAIL load0"); errors=errors+1; end
    source_done=1'b1; write_done=1'b0; tick; source_done=1'b0;
    if (image_valid !== 4'b0) begin $display("FAIL premature valid"); errors=errors+1; end
    write_done=1'b1; tick; write_done=1'b0;
    if (image_valid[0] !== 1'b1 || busy) begin $display("FAIL write commit"); errors=errors+1; end
    frame_boundary=1'b1; tick; frame_boundary=1'b0;
    if (active_bank !== 2'd0 || commit_count !== 0) begin $display("FAIL frame commit0 active=%0d count=%0d pending=%b valid=%b", active_bank, commit_count, pending_valid, image_valid); errors=errors+1; end

    // Bank1 首次加载，帧边界前 active_bank 必须保持 0。
    request(2'd1);
    if (!load_start || load_index !== 2'd1) begin $display("FAIL load1"); errors=errors+1; end
    source_done=1'b1; write_done=1'b1; tick; source_done=1'b0; write_done=1'b0;
    if (image_valid !== 4'b0011 || active_bank !== 2'd0) begin $display("FAIL bank1 ready"); errors=errors+1; end
    tick;
    if (active_bank !== 2'd0) begin $display("FAIL early switch"); errors=errors+1; end
    frame_boundary=1'b1; tick; frame_boundary=1'b0;
    if (active_bank !== 2'd1 || commit_count !== 1) begin $display("FAIL frame commit1 active=%0d count=%0d pending=%b valid=%b", active_bank, commit_count, pending_valid, image_valid); errors=errors+1; end

    // 命中缓存不重新 load；只允许在帧边界切换。
    request(2'd0);
    if (!cache_hit || load_start || pending_bank !== 2'd0) begin $display("FAIL cache hit"); errors=errors+1; end
    frame_boundary=1'b1; tick; frame_boundary=1'b0;
    if (active_bank !== 2'd0) begin $display("FAIL cache switch"); errors=errors+1; end

    // 当前 Bank 未失效时，错误重载请求被拒绝；错误加载不置 valid。
    request(2'd2);
    if (!load_start) begin $display("FAIL load2"); errors=errors+1; end
    load_error=1'b1; tick; load_error=1'b0;
    if (image_valid[2] || busy) begin $display("FAIL error recovery"); errors=errors+1; end
    request(2'd0);
    if (!cache_hit || load_start || request_rejected) begin $display("FAIL current cache"); errors=errors+1; end

    if (errors == 0) $display("PASS four-bank control");
    else $display("FAIL four-bank control: %0d", errors);
    $finish;
end
initial begin #1000; $fatal(1, "timeout"); end
endmodule
