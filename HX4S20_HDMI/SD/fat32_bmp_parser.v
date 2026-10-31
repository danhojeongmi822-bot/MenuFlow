// FAT32 file-stream BMP parser.
// The parser is deliberately storage agnostic: file_byte_offset is the
// authoritative position, so sector and cluster boundaries are irrelevant.
module fat32_bmp_parser #(
    parameter integer EXPECTED_WIDTH  = 640,
    parameter integer EXPECTED_HEIGHT = 480
) (
    input              clk,
    input              rst_n,
    input              file_valid,
    input      [7:0]   file_byte,
    input      [31:0]  file_byte_offset,
    input              file_done,
    output reg         pixel_valid,
    output reg [23:0]  pixel_rgb,
    output reg [31:0]  pixel_index,
    output reg         bmp_done,
    output reg         bmp_load_success,
    output reg [7:0]   bmp_error
);

    localparam [7:0] BMP_ERR_NONE   = 8'd0;
    localparam [7:0] BMP_ERR_HEADER = 8'd1;
    localparam [7:0] BMP_ERR_LENGTH = 8'd2;
    localparam [7:0] BMP_ERR_PIXEL  = 8'd3;
    localparam [7:0] BMP_ERR_STREAM = 8'd4;

    localparam [31:0] EXPECTED_PIXELS = EXPECTED_WIDTH * EXPECTED_HEIGHT;
    localparam [31:0] EXPECTED_BYTES  = EXPECTED_PIXELS * 32'd3;

    reg [7:0] header [0:33];
    reg       active;
    reg       header_complete;
    reg       header_checked;
    reg       header_valid;
    reg       failed;
    reg [1:0] byte_phase;
    reg [7:0] blue_byte;
    reg [7:0] green_byte;
    reg [31:0] stream_last_offset;
    reg        stream_have_byte;

    wire [31:0] hdr_file_size   = {header[5],  header[4],  header[3],  header[2]};
    wire [31:0] hdr_pixel_offset= {header[13], header[12], header[11], header[10]};
    wire [31:0] hdr_dib_size    = {header[17], header[16], header[15], header[14]};
    wire [31:0] hdr_width       = {header[21], header[20], header[19], header[18]};
    wire [31:0] hdr_height      = {header[25], header[24], header[23], header[22]};
    wire [15:0] hdr_planes      = {header[27], header[26]};
    wire [15:0] hdr_bit_count   = {header[29], header[28]};
    wire [31:0] hdr_compression = {header[33], header[32], header[31], header[30]};

    wire header_shape_valid =
        (header[0] == 8'h42) && (header[1] == 8'h4d) &&
        (hdr_dib_size >= 32'd40) &&
        (hdr_width == EXPECTED_WIDTH) &&
        (hdr_height != 32'd0) && (hdr_height == EXPECTED_HEIGHT) &&
        (hdr_planes == 16'd1) && (hdr_bit_count == 16'd24) &&
        (hdr_compression == 32'd0);

    // Header length checks are separate so callers can distinguish malformed
    // fields from a file that cannot contain the required pixel payload.
    wire header_length_valid =
        (hdr_file_size != 32'd0) &&
        (hdr_pixel_offset >= 32'd54) &&
        (hdr_pixel_offset <= (32'hffff_ffff - EXPECTED_BYTES)) &&
        (hdr_file_size >= (hdr_pixel_offset + EXPECTED_BYTES));

    wire current_offset_ok = !stream_have_byte || (file_byte_offset == 32'd0) ||
                             (file_byte_offset == (stream_last_offset + 32'd1));

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active            <= 1'b0;
            header_complete   <= 1'b0;
            header_checked    <= 1'b0;
            header_valid      <= 1'b0;
            failed            <= 1'b0;
            byte_phase        <= 2'd0;
            blue_byte         <= 8'd0;
            green_byte        <= 8'd0;
            stream_last_offset<= 32'd0;
            stream_have_byte  <= 1'b0;
            pixel_valid       <= 1'b0;
            pixel_rgb         <= 24'd0;
            pixel_index       <= 32'd0;
            bmp_done          <= 1'b0;
            bmp_load_success  <= 1'b0;
            bmp_error         <= BMP_ERR_NONE;
            for (i = 0; i < 34; i = i + 1)
                header[i] <= 8'd0;
        end else begin
            pixel_valid      <= 1'b0;
            bmp_done         <= 1'b0;
            bmp_load_success <= 1'b0;

            // A zero-offset byte is an unambiguous new-file boundary. This
            // also permits a caller to recover by restarting without reset.
            if (file_valid && (file_byte_offset == 32'd0)) begin
                active          <= 1'b1;
                header_complete <= 1'b0;
                header_checked  <= 1'b0;
                header_valid    <= 1'b0;
                failed          <= 1'b0;
                byte_phase      <= 2'd0;
                pixel_index     <= 32'd0;
                pixel_valid     <= 1'b0;
                stream_have_byte <= 1'b0;
                bmp_error       <= BMP_ERR_NONE;
            end

            if (file_valid && !active && (file_byte_offset != 32'd0)) begin
                active       <= 1'b1;
                header_complete <= 1'b0;
                header_checked  <= 1'b0;
                header_valid    <= 1'b0;
                pixel_index  <= 32'd0;
                byte_phase   <= 2'd0;
                failed       <= 1'b0;
                bmp_error    <= BMP_ERR_NONE;
            end

            if (file_valid) begin
                stream_last_offset <= file_byte_offset;
                if (stream_have_byte && (file_byte_offset != 32'd0) &&
                    (file_byte_offset != (stream_last_offset + 32'd1))) begin
                    failed    <= 1'b1;
                    bmp_error <= BMP_ERR_STREAM;
                end
                stream_have_byte <= 1'b1;
                if (file_byte_offset < 32'd34)
                    header[file_byte_offset[5:0]] <= file_byte;
                if (file_byte_offset == 32'd33)
                    header_complete <= 1'b1;

                // Header validation is delayed one cycle after byte 33 so
                // the final nonblocking header register update is visible.
                if (header_complete && !header_checked) begin
                    header_checked <= 1'b1;
                    if (!header_shape_valid) begin
                        failed    <= 1'b1;
                        bmp_error <= BMP_ERR_HEADER;
                    end else if (!header_length_valid) begin
                        failed    <= 1'b1;
                        bmp_error <= BMP_ERR_LENGTH;
                    end else begin
                        header_valid <= 1'b1;
                    end
                end

                // Offset continuity is still latched as BMP_ERR_STREAM above.
                // Keep it out of the normal pixel enable path so the 32-bit
                // offset compare cannot become a 100 MHz pixel-index critical
                // path. A stream error remains sticky and prevents success or
                // frame submission.
                if (header_valid && !failed) begin
                    if (file_byte_offset >= hdr_file_size) begin
                        failed    <= 1'b1;
                        bmp_error <= BMP_ERR_LENGTH;
                    end else if (file_byte_offset >= hdr_pixel_offset &&
                                 file_byte_offset < (hdr_pixel_offset + EXPECTED_BYTES)) begin
                        case (byte_phase)
                            2'd0: begin
                                blue_byte <= file_byte;
                                byte_phase <= 2'd1;
                            end
                            2'd1: begin
                                green_byte <= file_byte;
                                byte_phase <= 2'd2;
                            end
                            2'd2: begin
                                pixel_rgb   <= {file_byte, green_byte, blue_byte};
                                pixel_valid <= 1'b1;
                                pixel_index <= pixel_index + 32'd1;
                                byte_phase  <= 2'd0;
                            end
                            default: byte_phase <= 2'd0;
                        endcase
                    end
                end
            end

            if (header_complete && !header_checked && !file_valid) begin
                header_checked <= 1'b1;
                if (!header_shape_valid) begin
                    failed    <= 1'b1;
                    bmp_error <= BMP_ERR_HEADER;
                end else if (!header_length_valid) begin
                    failed    <= 1'b1;
                    bmp_error <= BMP_ERR_LENGTH;
                end else begin
                    header_valid <= 1'b1;
                end
            end

            if (file_done) begin
                bmp_done <= 1'b1;
                active   <= 1'b0;
                header_complete <= 1'b0;
                header_checked  <= 1'b0;
                header_valid    <= 1'b0;
                byte_phase      <= 2'd0;
                pixel_valid     <= 1'b0;
                stream_have_byte<= 1'b0;
                if (!header_checked || !header_valid || failed) begin
                    if (bmp_error == BMP_ERR_NONE)
                        bmp_error <= header_checked ? BMP_ERR_PIXEL : BMP_ERR_HEADER;
                end else if (pixel_index != EXPECTED_PIXELS || byte_phase != 2'd0) begin
                    failed    <= 1'b1;
                    bmp_error <= BMP_ERR_PIXEL;
                end else begin
                    bmp_load_success <= 1'b1;
                end
            end
        end
    end
endmodule
