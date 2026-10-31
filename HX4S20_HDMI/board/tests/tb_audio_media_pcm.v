`timescale 1ns/1ps

module tb_audio_media_pcm;
reg clk = 1'b0;
reg rst = 1'b1;
reg sample_valid = 1'b0;
reg media_valid = 1'b0;
reg [1:0] media_id = 2'd0;
reg test_valid = 1'b0;
reg [23:0] test_left = 24'd0;
reg [23:0] test_right = 24'd0;
wire media_sample_valid;
wire [23:0] media_left;
wire [23:0] media_right;
wire [1:0] current_media_id;
wire [2:0] note_index;
wire audio_valid;
wire [23:0] audio_left;
wire [23:0] audio_right;
integer i;
integer errors = 0;
integer saw_zero = 0;
integer saw_positive = 0;
integer saw_negative = 0;
integer saw_positive_peak = 0;
integer saw_negative_peak = 0;
integer note_changes = 0;
reg [2:0] previous_note = 3'd0;
reg [3:0] expected_lut_index;

always #10 clk = ~clk;

pcm_media_tone #(.NOTE_SAMPLES(12)) u_media_tone (
    .I_clk(clk), .I_rst(rst), .I_sample_valid(sample_valid),
    .I_media_valid(media_valid), .I_media_id(media_id),
    .O_sample_valid(media_sample_valid), .O_sample_left(media_left),
    .O_sample_right(media_right), .O_media_id(current_media_id),
    .O_note_index(note_index)
);

media_hdmi_audio_bridge u_bridge (
    .I_rst(rst), .I_sample_valid(test_valid),
    .I_test_left(test_left), .I_test_right(test_right),
    .I_media_valid(media_valid), .I_media_sample_valid(media_sample_valid),
    .I_media_left(media_left), .I_media_right(media_right),
    .O_audio_valid(audio_valid), .O_audio_left(audio_left),
    .O_audio_right(audio_right)
);

task send_sample;
    begin
        @(negedge clk);
        expected_lut_index = u_media_tone.S_phase_acc[31:28];
        sample_valid = 1'b1;
        @(posedge clk);
        #1;
        sample_valid = 1'b0;
    end
endtask

task select_media;
    input [1:0] id;
    begin
        @(negedge clk);
        media_id = id;
        media_valid = 1'b1;
        @(posedge clk);
        #1;
        media_valid = 1'b0;
    end
endtask

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
    repeat (4) @(posedge clk);
    #1;
    if (media_sample_valid !== 1'b0 || media_left !== 24'd0 || media_right !== 24'd0) begin
        $display("FAIL media tone reset outputs");
        errors = errors + 1;
    end
    rst = 1'b0;

    // Check media-source samples against the complete scaled LUT value set.
    for (i = 0; i < 144; i = i + 1) begin
        send_sample;
        if (media_sample_valid !== 1'b1) begin
            $display("FAIL media sample-valid missing at sample %0d", i);
            errors = errors + 1;
        end
        if ($signed(media_left) !== expected_sample(expected_lut_index) ||
            media_left !== media_right) begin
            $display("FAIL media PCM sample L=%0d R=%0d", $signed(media_left), $signed(media_right));
            errors = errors + 1;
        end
        if ($signed(media_left) == 0) saw_zero = 1;
        if ($signed(media_left) > 0) saw_positive = 1;
        if ($signed(media_left) < 0) saw_negative = 1;
        if ($signed(media_left) == 24'sd3072000) saw_positive_peak = 1;
        if ($signed(media_left) == -24'sd3072000) saw_negative_peak = 1;
        if (i > 0 && note_index != previous_note)
            note_changes = note_changes + 1;
        if (note_index !== ((i / 12) % 6)) begin
            $display("FAIL note index sample=%0d got=%0d expected=%0d", i, note_index, ((i / 12) % 6));
            errors = errors + 1;
        end
        previous_note = note_index;
        if (current_media_id !== 2'd0) begin
            $display("FAIL default media id=%0d", current_media_id);
            errors = errors + 1;
        end
    end

    if (!saw_zero || !saw_positive || !saw_negative || !saw_positive_peak || !saw_negative_peak) begin
        $display("FAIL media LUT coverage zero=%0d pos=%0d neg=%0d +peak=%0d -peak=%0d",
                 saw_zero, saw_positive, saw_negative, saw_positive_peak, saw_negative_peak);
        errors = errors + 1;
    end
    if (note_changes < 5) begin
        $display("FAIL note advancement count=%0d", note_changes);
        errors = errors + 1;
    end

    // Selecting media 2 resets note/phase, then emits a fresh zero sample.
    select_media(2'd2);
    if (current_media_id !== 2'd2 || note_index !== 3'd0) begin
        $display("FAIL media selection did not reset to media 2 / note 0");
        errors = errors + 1;
    end
    send_sample;
    if (media_left !== 24'd0 || media_right !== 24'd0 || note_index !== 3'd0) begin
        $display("FAIL selected media did not restart phase/note");
        errors = errors + 1;
    end

    // The bridge chooses media PCM while media mode is active, and test PCM otherwise.
    test_valid = 1'b1;
    test_left = 24'h123456;
    test_right = 24'h654321;
    media_valid = 1'b1;
    #1;
    if (audio_valid !== media_sample_valid || audio_left !== media_left || audio_right !== media_right) begin
        $display("FAIL bridge did not select media source");
        errors = errors + 1;
    end
    media_valid = 1'b0;
    #1;
    if (audio_valid !== test_valid || audio_left !== test_left || audio_right !== test_right) begin
        $display("FAIL bridge did not select test source");
        errors = errors + 1;
    end

    if (errors == 0) begin
        $display("PASS media PCM scale/stereo/note/media/bridge");
        $finish;
    end else begin
        $display("FAIL media PCM errors=%0d", errors);
        $fatal(1);
    end
end

initial begin
    #100000;
    $fatal(1, "media PCM timeout");
end
endmodule
