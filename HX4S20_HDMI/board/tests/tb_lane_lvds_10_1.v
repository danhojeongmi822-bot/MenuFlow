`timescale 1ns/1ps

module EG_LOGIC_ODDR(
    input wire clk,
    input wire rst,
    input wire d1,
    input wire d0,
    output reg q
);
    always @(posedge clk or posedge rst) begin
        if (rst)
            q <= 1'b0;
        else
            q <= d0;
    end

    always @(negedge clk or posedge rst) begin
        if (rst)
            q <= 1'b0;
        else
            q <= d1;
    end
endmodule

module tb_lane_lvds_10_1;
    reg pixel_clk = 1'b0;
    reg serial_clk = 1'b0;
    reg rst = 1'b1;
    reg [9:0] data_in;
    wire serial_out;
    integer bit_index;
    integer checked_bits;
    integer first_error;
    reg [19:0] observed;
    reg [9:0] expected_word;
    reg [9:0] expected_second;

    always #20 pixel_clk = ~pixel_clk;
    initial begin
        #3;
        forever #4 serial_clk = ~serial_clk;
    end

    lane_lvds_10_1 #(.DEVICE("EG")) dut (
        .I_pixel_clk(pixel_clk),
        .I_serial_clk(serial_clk),
        .I_rst(rst),
        .I_data_in(data_in),
        .O_serial_out(serial_out)
    );

    initial begin
        data_in = reverse10(10'b1011000110);
        expected_word = 10'b1011000110;
        expected_second = 10'b0101101011;
        checked_bits = 0;
        #43 rst = 1'b0;
        wait (dut.S_load_en_2d === 1'b1);
        @(posedge serial_clk);
        // The observed serial word begins one serial cycle after the load edge.
        for (bit_index = 0; bit_index < 10; bit_index = bit_index + 1) begin
            @(posedge serial_clk);
            #1;
            observed[bit_index] = serial_out;
            @(negedge serial_clk);
            #1;
            observed[bit_index+1] = serial_out;
            bit_index = bit_index + 1;
        end
        // Capture the next 10-bit group after the next pixel load interval.
        for (bit_index = 10; bit_index < 20; bit_index = bit_index + 2) begin
            @(posedge serial_clk);
            #1;
            observed[bit_index] = serial_out;
            @(negedge serial_clk);
            #1;
            observed[bit_index+1] = serial_out;
        end

        first_error = -1;
        for (bit_index = 0; bit_index < 20; bit_index = bit_index + 1) begin
            if (bit_index < 10) begin
                if (observed[bit_index] !== expected_word[bit_index] && first_error < 0)
                    first_error = bit_index;
            end else begin
                if (observed[bit_index] !== expected_second[bit_index-10] && first_error < 0)
                    first_error = bit_index;
            end
        end
        $display("OBSERVED first=%b second=%b expected_first=%b expected_second=%b",
                 observed[9:0], observed[19:10], expected_word, expected_second);
        if (first_error >= 0) begin
            $display("FAIL modeled serializer mismatch at stream bit %0d phase=3ns",
                     first_error);
            $fatal(1);
        end
        checked_bits = 20;
        $display("PASS modeled serializer checked_bits=%0d phase=3ns", checked_bits);
        $finish;
    end

    initial begin
        @(posedge pixel_clk);
        @(posedge pixel_clk);
        #1 data_in = reverse10(10'b0101101011);
    end

    function [9:0] reverse10(input [9:0] value);
        integer i;
        begin
            for (i = 0; i < 10; i = i + 1)
                reverse10[i] = value[9-i];
        end
    endfunction
endmodule
