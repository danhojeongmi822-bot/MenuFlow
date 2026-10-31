`timescale 1ns/1ps

// FAT32 图片读取引擎。外部契约与 bmp_read 保持一致，便于 sd_card_bmp
// 在仿真和真板之间保留旧路径回退；文件系统细节只存在于本模块内部。
module fat32_bmp_engine #(
    parameter integer SD_TIMEOUT_CYCLES = 50_000_000,
    parameter integer EXPECTED_WIDTH = 640,
    parameter integer EXPECTED_HEIGHT = 480
) (
    input                       clk,
    input                       rst,
    output reg                  ready,
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,
    input                       load_start,
    input  [31:0]               load_sector,
    output                      sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  write_req,
    input                       write_req_ack,
    output                      bmp_data_wr_en,
    output [23:0]               bmp_data,
    output reg [2:0]            bmp_error,
    output reg                  load_error,
    output reg                  load_success,
    output reg                  sd_recover_req,
    // 可选 PCM 资源（PIC1..4.PCM）与音频 owner 扇区总线
    output reg  [3:0]           pcm_valid,
    output reg  [31:0]          pcm_cluster0, pcm_cluster1, pcm_cluster2, pcm_cluster3,
    output reg  [31:0]          pcm_size0, pcm_size1, pcm_size2, pcm_size3,
    output wire [7:0]           fs_sectors_per_cluster,
    output wire [31:0]          fs_fat_start_lba,
    output wire [31:0]          fs_data_start_lba,
    output wire [31:0]          fs_max_cluster,
    output wire [31:0]          fs_root_cluster,
    input                       audio_req,
    input  [31:0]               audio_lba,
    output wire                 audio_busy,
    output wire                 audio_valid,
    output wire [7:0]           audio_byte,
    output wire [8:0]           audio_byte_index,
    output wire                 audio_done,
    output wire [7:0]           audio_error,
    output wire                 audio_abort,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);
    localparam E_IDLE=3'd0, E_SCAN=3'd1, E_EMIT=3'd2, E_WAIT_ACK=3'd3,
               E_LOAD=3'd4;
    localparam [2:0] BMP_ERR_HEADER=3'd1, BMP_ERR_LENGTH=3'd2,
                     BMP_ERR_PIXEL=3'd3, BMP_ERR_SD=3'd4;

    wire scanner_req, scanner_busy, scanner_valid, scanner_done;
    wire [31:0] scanner_lba;
    wire [7:0] scanner_byte, scanner_error;
    wire [8:0] scanner_index;
    wire scanner_abort;
    wire streamer_req, streamer_busy, streamer_valid, streamer_done;
    wire [31:0] streamer_lba, streamer_offset;
    wire [7:0] streamer_byte, streamer_error;
    wire [8:0] streamer_index;
    wire streamer_abort;
    wire adapter_scanner_busy, adapter_streamer_busy;
    wire adapter_scanner_valid, adapter_streamer_valid;
    wire [7:0] adapter_scanner_byte, adapter_streamer_byte;
    wire [8:0] adapter_scanner_index, adapter_streamer_index;
    wire adapter_scanner_done, adapter_streamer_done;
    wire [7:0] adapter_scanner_error, adapter_streamer_error;
    wire adapter_scanner_abort, adapter_streamer_abort;
    wire adapter_sd_read;
    wire [31:0] adapter_sd_addr;
    wire [7:0] card_read_data;
    wire card_read_valid, card_read_end;
    wire sd_init_done_i;
    wire [7:0] sd_read_error;
    wire sd_read_abort;
    wire fs_ready;
    wire [7:0] fs_error;
    wire [3:0] resource_valid;
    wire [31:0] resource_cluster0, resource_cluster1, resource_cluster2, resource_cluster3;
    wire [31:0] resource_size0, resource_size1, resource_size2, resource_size3;
    wire [3:0]  pcm_valid_i;
    wire [31:0] pcm_cluster0_i, pcm_cluster1_i, pcm_cluster2_i, pcm_cluster3_i;
    wire [31:0] pcm_size0_i, pcm_size1_i, pcm_size2_i, pcm_size3_i;
    wire        adapter_audio_busy, adapter_audio_valid;
    wire [7:0]  adapter_audio_byte, adapter_audio_error;
    wire [8:0]  adapter_audio_index;
    wire        adapter_audio_done, adapter_audio_abort;
    wire [7:0] sectors_per_cluster;
    wire [31:0] fat_start_lba, data_start_lba, max_cluster;
    wire [31:0] root_cluster, partition_lba;
    wire parser_pixel_valid, parser_done, parser_success;
    wire [23:0] parser_rgb;
    wire [31:0] parser_pixel_index;
    wire [7:0] parser_error;

    reg scanner_start_pulse, file_start_pulse;
    reg [2:0] state;
    reg [2:0] emit_idx;
    reg [2:0] emitted_count;
    reg [31:0] load_size;
    reg [31:0] load_cluster;
    // Snapshot directory metadata before starting a file stream.
    reg [3:0]  resource_valid_latched;
    reg [31:0] resource_cluster0_latched, resource_cluster1_latched;
    reg [31:0] resource_cluster2_latched, resource_cluster3_latched;
    reg [31:0] resource_size0_latched, resource_size1_latched;
    reg [31:0] resource_size2_latched, resource_size3_latched;
    reg stream_error_seen;
    reg scanner_error_seen;

    assign sd_init_done = sd_init_done_i;
    assign bmp_data_wr_en = parser_pixel_valid && (state == E_LOAD);
    assign bmp_data = parser_rgb;

    fat32_volume_scanner scanner_i (
        .clk(clk), .rst_n(~rst), .scan_start(scanner_start_pulse),
        .sector_link_ready(sd_init_done_i && !sd_recover_req),
        .scan_busy(), .scan_done(scanner_done), .fs_ready(fs_ready), .fs_error(fs_error),
        .partition_lba(partition_lba), .root_cluster(root_cluster),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource_cluster0(resource_cluster0), .resource_cluster1(resource_cluster1),
        .resource_cluster2(resource_cluster2), .resource_cluster3(resource_cluster3),
        .resource_size0(resource_size0), .resource_size1(resource_size1),
        .resource_size2(resource_size2), .resource_size3(resource_size3),
        .pcm_valid(pcm_valid_i),
        .pcm_cluster0(pcm_cluster0_i), .pcm_cluster1(pcm_cluster1_i),
        .pcm_cluster2(pcm_cluster2_i), .pcm_cluster3(pcm_cluster3_i),
        .pcm_size0(pcm_size0_i), .pcm_size1(pcm_size1_i),
        .pcm_size2(pcm_size2_i), .pcm_size3(pcm_size3_i),
        .sector_req(scanner_req), .sector_lba(scanner_lba),
        .sector_busy(adapter_scanner_busy), .sector_valid(adapter_scanner_valid),
        .sector_byte(adapter_scanner_byte), .sector_byte_index(adapter_scanner_index),
        .sector_done(adapter_scanner_done), .sector_error(adapter_scanner_error),
        .sector_abort(adapter_scanner_abort)
    );

    fat32_file_streamer streamer_i (
        .clk(clk), .rst_n(~rst), .file_start(file_start_pulse),
        .first_cluster(load_cluster), .file_size(load_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(), .file_done(streamer_done), .file_valid(streamer_valid),
        .file_byte(streamer_byte), .file_byte_offset(streamer_offset),
        .fs_error(streamer_error), .sector_req(streamer_req), .sector_lba(streamer_lba),
        .sector_busy(adapter_streamer_busy), .sector_valid(adapter_streamer_valid),
        .sector_byte(adapter_streamer_byte), .sector_byte_index(adapter_streamer_index),
        .sector_done(adapter_streamer_done), .sector_error(adapter_streamer_error),
        .sector_abort(adapter_streamer_abort),
        .stream_abort(1'b0)          // BMP 路径不需要中止
    );

    sd_sector_adapter #(.TIMEOUT_CYCLES(SD_TIMEOUT_CYCLES)) adapter_i (
        .clk(clk), .rst_n(~rst),
        .scanner_req(scanner_req), .scanner_lba(scanner_lba),
        .scanner_busy(adapter_scanner_busy), .scanner_valid(adapter_scanner_valid),
        .scanner_byte(adapter_scanner_byte), .scanner_byte_index(adapter_scanner_index),
        .scanner_done(adapter_scanner_done), .scanner_error(adapter_scanner_error),
        .scanner_abort(adapter_scanner_abort),
        .streamer_req(streamer_req), .streamer_lba(streamer_lba),
        .streamer_busy(adapter_streamer_busy), .streamer_valid(adapter_streamer_valid),
        .streamer_byte(adapter_streamer_byte), .streamer_byte_index(adapter_streamer_index),
        .streamer_done(adapter_streamer_done), .streamer_error(adapter_streamer_error),
        .streamer_abort(adapter_streamer_abort),
        .audio_req(audio_req), .audio_lba(audio_lba),
        .audio_busy(adapter_audio_busy), .audio_valid(adapter_audio_valid),
        .audio_byte(adapter_audio_byte), .audio_byte_index(adapter_audio_index),
        .audio_done(adapter_audio_done), .audio_error(adapter_audio_error),
        .audio_abort(adapter_audio_abort),
        .sd_sec_read(adapter_sd_read),
        .sd_sec_read_addr(adapter_sd_addr), .sd_sec_read_data(card_read_data),
        .sd_sec_read_data_valid(card_read_valid), .sd_sec_read_end(card_read_end),
        .sd_sec_read_error(sd_read_error), .sd_sec_read_abort(sd_read_abort)
    );

    fat32_bmp_parser #(
        .EXPECTED_WIDTH(EXPECTED_WIDTH), .EXPECTED_HEIGHT(EXPECTED_HEIGHT)
    ) parser_i (
        .clk(clk), .rst_n(~rst), .file_valid(streamer_valid), .file_byte(streamer_byte),
        .file_byte_offset(streamer_offset), .file_done(streamer_done),
        .pixel_valid(parser_pixel_valid), .pixel_rgb(parser_rgb),
        .pixel_index(parser_pixel_index), .bmp_done(parser_done),
        .bmp_load_success(parser_success), .bmp_error(parser_error)
    );

    sd_card_top sd_i (
        .clk(clk), .rst(rst), .sd_recover_req(sd_recover_req), .SD_nCS(SD_nCS),
        .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .sd_init_done(sd_init_done_i), .sd_sec_read(adapter_sd_read),
        .sd_sec_read_addr(adapter_sd_addr), .sd_sec_read_data(card_read_data),
        .sd_sec_read_data_valid(card_read_valid), .sd_sec_read_end(card_read_end),
        .sd_sec_read_error(sd_read_error), .sd_sec_read_abort(sd_read_abort),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(), .sd_sec_write_end()
    );

    assign fs_sectors_per_cluster = sectors_per_cluster;
    assign fs_fat_start_lba       = fat_start_lba;
    assign fs_data_start_lba      = data_start_lba;
    assign fs_max_cluster         = max_cluster;
    assign fs_root_cluster        = root_cluster;

    assign audio_busy       = adapter_audio_busy;
    assign audio_valid      = adapter_audio_valid;
    assign audio_byte       = adapter_audio_byte;
    assign audio_byte_index = adapter_audio_index;
    assign audio_done       = adapter_audio_done;
    assign audio_error      = adapter_audio_error;
    assign audio_abort      = adapter_audio_abort;

    function automatic [31:0] cluster_lut(input [2:0] idx);
        begin case(idx)
            3'd0: cluster_lut=resource_cluster0_latched;
            3'd1: cluster_lut=resource_cluster1_latched;
            3'd2: cluster_lut=resource_cluster2_latched;
            default: cluster_lut=resource_cluster3_latched;
        endcase end
    endfunction
    function automatic [31:0] size_lut(input [2:0] idx);
        begin case(idx)
            3'd0: size_lut=resource_size0_latched;
            3'd1: size_lut=resource_size1_latched;
            3'd2: size_lut=resource_size2_latched;
            default: size_lut=resource_size3_latched;
        endcase end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= E_IDLE; ready<=1'b0; scanner_start_pulse<=0; file_start_pulse<=0;
            scan_done<=0; scan_found_valid<=0; scan_found_sector<=0; scan_found_total<=0;
            emit_idx<=0; emitted_count<=0; load_size<=0; load_cluster<=0;
            resource_valid_latched<=0;
            resource_cluster0_latched<=0; resource_cluster1_latched<=0;
            resource_cluster2_latched<=0; resource_cluster3_latched<=0;
            resource_size0_latched<=0; resource_size1_latched<=0;
            resource_size2_latched<=0; resource_size3_latched<=0;
            write_req<=0; state_code<=4'd1; bmp_error<=0; load_error<=0;
            load_success<=0; sd_recover_req<=0; stream_error_seen<=0; scanner_error_seen<=0;
            pcm_valid<=0;
            pcm_cluster0<=0; pcm_cluster1<=0; pcm_cluster2<=0; pcm_cluster3<=0;
            pcm_size0<=0; pcm_size1<=0; pcm_size2<=0; pcm_size3<=0;
        end else begin
            scanner_start_pulse<=0; file_start_pulse<=0; scan_done<=0;
            scan_found_valid<=0; load_error<=0; load_success<=0; sd_recover_req<=0;
            // Register the external admission signal so the SD adapter owner
            // state cannot form a same-cycle feedback path into sd_card_bmp's
            // load_sector priority chain.
            ready <= sd_init_done_i && (state == E_IDLE) &&
                     !adapter_scanner_busy && !adapter_streamer_busy && !adapter_audio_busy;
            if (parser_error != 0) bmp_error <= parser_error[2:0];
            case (state)
                E_IDLE: begin
                    state_code <= 4'd1;
                    if (scan_start && sd_init_done_i && !adapter_scanner_busy && !adapter_streamer_busy) begin
                        scanner_start_pulse<=1; state<=E_SCAN; emitted_count<=0;
                        bmp_error<=0; scanner_error_seen<=0;
                    end else if (load_start && fs_ready && !adapter_scanner_busy && !adapter_streamer_busy) begin
                        load_cluster<=load_sector;
                        if (load_sector==resource_cluster0_latched) load_size<=resource_size0_latched;
                        else if (load_sector==resource_cluster1_latched) load_size<=resource_size1_latched;
                        else if (load_sector==resource_cluster2_latched) load_size<=resource_size2_latched;
                        else if (load_sector==resource_cluster3_latched) load_size<=resource_size3_latched;
                        else load_size<=0;
                        write_req<=1; state_code<=4'd2; state<=E_WAIT_ACK;
                        bmp_error<=0; stream_error_seen<=0;
                    end
                end
                E_SCAN: begin
                    if (fs_error!=0 && !scanner_error_seen) begin
                        scanner_error_seen<=1; load_error<=1; bmp_error<=BMP_ERR_SD;
                        if (fs_error==8'h03 || fs_error==8'h08) sd_recover_req<=1;
                        state<=E_IDLE;
                    end else if (scanner_done) begin
                        resource_valid_latched<=resource_valid;
                        resource_cluster0_latched<=resource_cluster0;
                        resource_cluster1_latched<=resource_cluster1;
                        resource_cluster2_latched<=resource_cluster2;
                        resource_cluster3_latched<=resource_cluster3;
                        resource_size0_latched<=resource_size0;
                        resource_size1_latched<=resource_size1;
                        resource_size2_latched<=resource_size2;
                        resource_size3_latched<=resource_size3;
                        pcm_valid              <= pcm_valid_i;
                        pcm_cluster0           <= pcm_cluster0_i;
                        pcm_cluster1           <= pcm_cluster1_i;
                        pcm_cluster2           <= pcm_cluster2_i;
                        pcm_cluster3           <= pcm_cluster3_i;
                        pcm_size0              <= pcm_size0_i;
                        pcm_size1              <= pcm_size1_i;
                        pcm_size2              <= pcm_size2_i;
                        pcm_size3              <= pcm_size3_i;
                        if (fs_ready) begin emit_idx<=0; emitted_count<=0; state<=E_EMIT; end
                        else begin load_error<=1; bmp_error<=BMP_ERR_SD; state<=E_IDLE; end
                    end
                end
                E_EMIT: begin
                    if (emit_idx < 4) begin
                        if (resource_valid_latched[emit_idx]) begin
                            scan_found_valid<=1; scan_found_sector<=cluster_lut(emit_idx);
                            emitted_count<=emitted_count+1'b1;
                        end
                        emit_idx<=emit_idx+1'b1;
                    end else if (!adapter_scanner_busy && !adapter_streamer_busy) begin
                        scan_found_total<=emitted_count;
                        scan_done<=1; state<=E_IDLE;
                    end
                end
                E_WAIT_ACK: begin
                    if (load_size==0) begin
                        write_req<=0; load_error<=1; bmp_error<=BMP_ERR_LENGTH; state<=E_IDLE;
                    end else if (write_req_ack) begin
                        write_req<=0; file_start_pulse<=1; state_code<=4'd3; state<=E_LOAD;
                    end
                end
                E_LOAD: begin
                    state_code<=4'd4;
                    if (streamer_error!=0 || adapter_streamer_error!=0 || parser_error!=0) begin
                        if (!stream_error_seen) begin
                            stream_error_seen<=1; write_req<=0; load_error<=1;
                            bmp_error<= (parser_error!=0) ? parser_error[2:0] : BMP_ERR_SD;
                            if (streamer_error==8'h03 || adapter_streamer_error==8'h08) sd_recover_req<=1;
                            state<=E_IDLE;
                        end
                    end else if (parser_success) begin
                        load_success<=1; write_req<=0; state<=E_IDLE;
                    end
                end
                default: state<=E_IDLE;
            endcase
        end
    end
endmodule
