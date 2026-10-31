`timescale 1ns/1ps

module tb_audio_media_cdc;
reg src_clk = 1'b0;
reg dst_clk = 1'b0;
reg src_rst = 1'b1;
reg dst_rst = 1'b1;
reg [3:0] state_code = 4'd1;
wire [1:0] media_id;
wire media_valid;
wire update_pulse;
integer pulse_count;
integer errors;

always #5 src_clk = ~src_clk; // 100 MHz
always #20 dst_clk = ~dst_clk; // 25 MHz

state_code_media_cdc dut(
    .I_src_clk(src_clk), .I_src_rst(src_rst), .I_state_code(state_code),
    .I_dst_clk(dst_clk), .I_dst_rst(dst_rst),
    .O_media_id(media_id), .O_media_valid(media_valid), .O_update_pulse(update_pulse)
);

task wait_for_media;
    input [1:0] expected;
    integer i;
    begin
        for (i = 0; i < 30; i = i + 1) begin
            @(posedge dst_clk);
            #1;
            if (update_pulse) begin
                pulse_count = pulse_count + 1;
                if (!media_valid || media_id !== expected) begin
                    $display("FAIL media expected %0d got valid=%b id=%0d", expected, media_valid, media_id);
                    errors = errors + 1;
                end
                disable wait_for_media;
            end
        end
        $display("FAIL timeout waiting media %0d", expected);
        errors = errors + 1;
    end
endtask

initial begin
    pulse_count = 0;
    errors = 0;
    repeat (4) @(posedge dst_clk);
    src_rst = 1'b0;
    dst_rst = 1'b0;
    wait_for_media(2'd0);
    repeat (8) @(posedge dst_clk);
    if (update_pulse) begin
        $display("FAIL repeated initial update");
        errors = errors + 1;
    end

    state_code = 4'd2;
    wait_for_media(2'd1);
    state_code = 4'd3;
    wait_for_media(2'd2);
    state_code = 4'd4;
    wait_for_media(2'd3);
    state_code = 4'd1;
    wait_for_media(2'd0);

    state_code = 4'd0;
    repeat (20) begin
        @(posedge dst_clk);
        #1;
        if (update_pulse || media_id !== 2'd0) begin
            $display("FAIL illegal state 0 changed media");
            errors = errors + 1;
        end
    end
    state_code = 4'd5;
    repeat (20) begin
        @(posedge dst_clk);
        #1;
        if (update_pulse || media_id !== 2'd0) begin
            $display("FAIL illegal state 5 changed media");
            errors = errors + 1;
        end
    end

    if (pulse_count != 5) begin
        $display("FAIL pulse count=%0d", pulse_count);
        errors = errors + 1;
    end
    if (errors == 0)
        $display("PASS state_code CDC media mapping");
    $finish;
end
endmodule
