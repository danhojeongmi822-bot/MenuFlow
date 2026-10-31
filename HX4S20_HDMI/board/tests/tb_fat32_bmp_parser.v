`timescale 1ns/1ps
module tb_fat32_bmp_parser;
    localparam integer W = 4;
    localparam integer H = 2;
    localparam integer N = W*H;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg file_valid = 1'b0;
    reg [7:0] file_byte = 0;
    reg [31:0] file_byte_offset = 0;
    reg file_done = 1'b0;
    wire pixel_valid;
    wire [23:0] pixel_rgb;
    wire [31:0] pixel_index;
    wire bmp_done, bmp_load_success;
    wire [7:0] bmp_error;

    fat32_bmp_parser #(.EXPECTED_WIDTH(W), .EXPECTED_HEIGHT(H)) dut (
        .clk(clk), .rst_n(rst_n), .file_valid(file_valid), .file_byte(file_byte),
        .file_byte_offset(file_byte_offset), .file_done(file_done),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .pixel_index(pixel_index),
        .bmp_done(bmp_done), .bmp_load_success(bmp_load_success), .bmp_error(bmp_error));

    reg [7:0] image [0:77]; // 54-byte header + 24 bytes of BGR data
    integer i, pixels, valid_pixels, successes, errors, stage;

    task send_byte;
        input [31:0] off;
        input [7:0] value;
        begin
            @(negedge clk); file_byte_offset = off; file_byte = value; file_valid = 1'b1;
            @(negedge clk); file_valid = 1'b0;
        end
    endtask

    task send_done;
        begin
            @(negedge clk); file_done = 1'b1;
            @(negedge clk); file_done = 1'b0;
        end
    endtask

    task make_valid;
        integer p;
        begin
            for (p = 0; p < 78; p = p + 1) image[p] = 8'd0;
            image[0] = 8'h42; image[1] = 8'h4d;
            image[2] = 8'd78; image[10] = 8'd54;
            image[14] = 8'd40; image[18] = W; image[22] = H;
            image[26] = 8'd1; image[28] = 8'd24;
            for (p = 0; p < N; p = p + 1) begin
                image[54+p*3] = p + 8'h10;       // B
                image[55+p*3] = p + 8'h20;       // G
                image[56+p*3] = p + 8'h30;       // R
            end
        end
    endtask

    always @(posedge clk) begin
        if (pixel_valid) begin
            if ((stage == 0) && (pixel_rgb !== {8'h30 + pixels[7:0],
                               8'h20 + pixels[7:0],
                               8'h10 + pixels[7:0]})) begin
                $display("pixel mismatch stage=%0d index=%0d rgb=%h", stage, pixels, pixel_rgb);
                $fatal;
            end
            pixels = pixels + 1;
        end
        if (bmp_load_success) successes = successes + 1;
        if (bmp_error != 0) errors = errors + 1;
    end

    task stream_image;
        integer k;
        begin
            for (k = 0; k < 78; k = k + 1) send_byte(k, image[k]);
            send_done;
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        pixels = 0; successes = 0; errors = 0; stage = 0;
        make_valid;
        repeat (3) @(negedge clk); rst_n = 1'b1;
        stream_image;
        valid_pixels = pixels;
        if (valid_pixels != N || successes != 1) begin
            $display("valid image failed pixels=%0d success=%0d error=%0d", pixels, successes, errors);
            $fatal;
        end

        // Invalid signature must produce no pixels and no success.
        stage = 1; image[0] = 8'h58;
        stream_image;
        if (successes != 1 || pixels != valid_pixels || errors == 0) begin
            $display("invalid signature was accepted");
            $fatal;
        end

        // Restore signature and truncate before the required payload.
        stage = 2; make_valid;
        for (i = 0; i < 60; i = i + 1) send_byte(i, image[i]);
        send_done;
        repeat (3) @(negedge clk);
        if (successes != 1 || pixels < valid_pixels || errors == 0) begin
            $display("truncated image changed success/pixel count");
            $fatal;
        end
        $display("tb_fat32_bmp_parser PASS pixels=%0d success=%0d errors=%0d", pixels, successes, errors);
        $finish;
    end
endmodule
