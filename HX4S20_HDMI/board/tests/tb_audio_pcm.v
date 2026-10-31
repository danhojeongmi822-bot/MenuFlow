`timescale 1ns/1ps

module tb_audio_pcm;
reg clk = 1'b0;
reg rst = 1'b1;
wire sample_valid;
wire [23:0] left_data;
wire [23:0] right_data;
wire [3:0] lut_index;
wire acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

always #20 clk = ~clk; // 25 MHz

pcm_test_tone u_tone(
    .I_clk(clk), .I_rst(rst),
    .O_sample_valid(sample_valid),
    .O_sample_left(left_data), .O_sample_right(right_data),
    .O_lut_index(lut_index)
);

audio_arc_calculate #(.ACR_N(6144)) u_acr(
    .I_clk(clk), .I_rst(rst), .I_audio_valid(sample_valid),
    .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n)
);

integer cycle_count;
integer sample_count;
integer acr_count;
integer last_sample_cycle;
integer interval;
integer bad_interval;
integer bad_stereo;
integer bad_lut;
integer bad_acr;
integer first_acr_cts;
reg [15:0] seen_lut;

function signed [23:0] expected_sample;
    input [3:0] index;
    begin
        case (index)
            4'd0, 4'd8: expected_sample = 24'sd0;
            4'd1: expected_sample = 24'sd1175552;
            4'd2: expected_sample = 24'sd2172160;
            4'd3: expected_sample = 24'sd2838272;
            4'd4: expected_sample = 24'sd3072000;
            4'd5: expected_sample = 24'sd2838272;
            4'd6: expected_sample = 24'sd2172160;
            4'd7: expected_sample = 24'sd1175552;
            4'd9: expected_sample = -24'sd1175552;
            4'd10: expected_sample = -24'sd2172160;
            4'd11, 4'd13: expected_sample = -24'sd2838272;
            4'd12: expected_sample = -24'sd3072000;
            4'd14: expected_sample = -24'sd2172160;
            default: expected_sample = -24'sd1175552;
        endcase
    end
endfunction

initial begin
    cycle_count = 0;
    sample_count = 0;
    acr_count = 0;
    last_sample_cycle = -1;
    bad_interval = 0;
    bad_stereo = 0;
    bad_lut = 0;
    bad_acr = 0;
    first_acr_cts = 0;
    seen_lut = 0;
    repeat (5) @(posedge clk);
    #1;
    if (sample_valid !== 1'b0 || left_data !== 24'd0 || right_data !== 24'd0 || acr_valid !== 1'b0) begin
        $display("FAIL reset outputs not cleared");
        bad_lut = bad_lut + 1;
    end
    rst = 1'b0;
    repeat (1_300_000) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
        if (sample_valid) begin
            sample_count = sample_count + 1;
            if (last_sample_cycle >= 0) begin
                interval = cycle_count - last_sample_cycle;
                if (interval != 520 && interval != 521)
                    bad_interval = bad_interval + 1;
            end
            last_sample_cycle = cycle_count;
            if (left_data !== right_data)
                bad_stereo = bad_stereo + 1;
            if ($signed(left_data) !== expected_sample(lut_index)) begin
                $display("FAIL sample index=%0d value=%0d expected=%0d", lut_index,
                         $signed(left_data), expected_sample(lut_index));
                bad_lut = bad_lut + 1;
            end
            seen_lut[lut_index] = 1'b1;
        end
        if (acr_valid) begin
            acr_count = acr_count + 1;
            if (acr_n !== 20'd6144 || acr_cts < 20'd24960 || acr_cts > 20'd25008) begin
                $display("FAIL ACR N=%0d CTS=%0d", acr_n, acr_cts);
                bad_acr = bad_acr + 1;
            end
            if (first_acr_cts == 0)
                first_acr_cts = acr_cts;
        end
    end
    if (sample_count < 2_490 || sample_count > 2_510)
        $display("FAIL sample count=%0d", sample_count);
    if (bad_interval != 0)
        $display("FAIL bad sample intervals=%0d", bad_interval);
    if (bad_stereo != 0)
        $display("FAIL stereo mismatches=%0d", bad_stereo);
    if (bad_lut != 0)
        $display("FAIL LUT values=%0d", bad_lut);
    if (bad_acr != 0)
        $display("FAIL ACR values=%0d", bad_acr);
    if (acr_count < 45 || acr_count > 55)
        $display("FAIL ACR count=%0d", acr_count);
    if (first_acr_cts < 24_990 || first_acr_cts > 25_010)
        $display("FAIL first CTS=%0d", first_acr_cts);
    if (seen_lut !== 16'hffff)
        $display("FAIL incomplete LUT coverage=%04x", seen_lut);
    if (sample_count >= 2_490 && sample_count <= 2_510 && bad_interval == 0 &&
        bad_stereo == 0 && bad_lut == 0 && bad_acr == 0 && acr_count >= 45 && acr_count <= 55 &&
        first_acr_cts >= 24_990 && first_acr_cts <= 25_010 && seen_lut === 16'hffff)
        $display("PASS PCM 48kHz/LUT/ACR");
    else
        $fatal(1, "PCM/ACR regression failed");
    $finish;
end
endmodule
