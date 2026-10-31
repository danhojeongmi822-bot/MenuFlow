`timescale 1ns/1ps
module tb_video_axis;
reg clk=0, rst=1, vs=0, de=0, ready=1;
reg [23:0] rgb=0;
reg src_user=0, src_last=0;
wire user, valid, last, overflow;
wire [23:0] data;
integer exp_data [0:4095];
integer exp_user [0:4095];
integer exp_last [0:4095];
integer wr=0, rd=0, accepted=0, users=0, lasts=0, pixels=0;
integer full_exchange_seen=0;
reg expect_full_exchange=0;
reg stalled_d=0;
reg [25:0] held_d=0;
integer f, row, x;
always #20 clk=~clk;

video_rgb_to_axis_640x480 dut(
    .I_clk(clk), .I_rst(rst), .I_vs(vs), .I_de(de), .I_rgb(rgb),
    .I_ready(ready), .O_video_user(user), .O_video_valid(valid),
    .O_video_last(last), .O_video_data(data), .O_overflow(overflow)
);

always @(posedge clk) begin
    if (rst) begin
        wr=0; rd=0; accepted=0; users=0; lasts=0; pixels=0;
        stalled_d=0;
    end else begin
        if (stalled_d && (!valid || {user,last,data} !== held_d))
            $fatal(1,"AXIS output changed while stalled");
        stalled_d = valid && !ready;
        if (stalled_d) held_d = {user,last,data};

        if (valid && ready) begin
            if (dut.S_count == 16 && de && expect_full_exchange) begin
                full_exchange_seen=full_exchange_seen+1;
                expect_full_exchange=0;
            end
            if (rd >= wr) $fatal(1,"unexpected AXIS beat");
            if (data !== exp_data[rd][23:0]) $fatal(1,"pixel order mismatch at %0d",accepted);
            if (user !== exp_user[rd][0]) $fatal(1,"SOF mismatch at beat %0d",accepted);
            if (last !== exp_last[rd][0]) $fatal(1,"TLAST mismatch at beat %0d",accepted);
            rd=rd+1; accepted=accepted+1;
            if (user) users=users+1;
            if (last) lasts=lasts+1;
        end

        if (de) begin
            exp_data[wr] = rgb;
            exp_user[wr] = src_user;
            exp_last[wr] = src_last;
            wr=wr+1; pixels=pixels+1;
        end
    end
end

task send_pixel;
    input integer frame_id;
    input integer row_id;
    input integer x_id;
    begin
        @(negedge clk);
        de=1;
        rgb=frame_id*100000+row_id*640+x_id;
        src_user=(row_id == 0 && x_id == 0);
        src_last=(x_id == 639);
        if (frame_id == 1 && row_id == 0 && x_id == 16) begin
            if (dut.S_count != 16 || dut.S_wr_ptr != dut.S_rd_ptr)
                $fatal(1,"16-cycle stall did not fill FIFO or wrap pointers");
            expect_full_exchange=1;
            ready=1;
        end else if (frame_id == 1 && row_id == 0 && x_id < 16) ready=0;
        else if (frame_id == 1 && row_id == 1 && x_id >= 632 && x_id < 640) ready=0;
        else ready=1;
    end
endtask

initial begin
    repeat(3) @(negedge clk);
    rst=0;
    for (f=0; f<2; f=f+1) begin
        @(negedge clk); vs=1; de=0; ready=1;
        repeat(3) @(negedge clk);
        vs=0;
        repeat(3) @(negedge clk);
        for (row=0; row<3; row=row+1) begin
            for (x=0; x<640; x=x+1) send_pixel(f,row,x);
            @(negedge clk); de=0; ready=1;
            repeat(20) @(negedge clk);
        end
    end
    @(negedge clk); de=0; ready=1;
    repeat(40) @(negedge clk);
    if (overflow) $fatal(1,"unexpected FIFO overflow");
    if (pixels!=3840 || accepted!=3840 || lasts!=6 || users!=2 || rd!=wr || full_exchange_seen!=1)
        $fatal(1,"counts mismatch in=%0d out=%0d last=%0d sof=%0d pending=%0d",
               pixels,accepted,lasts,users,wr-rd);
    $display("PASS video AXIS: %0d pixels, 16-cycle full pop/push, blanking drain, %0d TLAST, %0d SOF",accepted,lasts,users);
    $finish;
end
endmodule
