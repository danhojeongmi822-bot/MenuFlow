`timescale 1ns/1ps
module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 4096
) (
    input wire clk, input wire rst_n,
    input wire file_start, input wire [31:0] first_cluster, input wire [31:0] file_size,
    input wire [7:0] sectors_per_cluster, input wire [31:0] fat_start_lba,
    input wire [31:0] data_start_lba, input wire [31:0] max_cluster,
    output reg file_busy, output reg file_done, output reg file_valid, output reg [7:0] file_byte,
    output reg [31:0] file_byte_offset, output reg [7:0] fs_error,
    output reg sector_req, output reg [31:0] sector_lba,
    input wire sector_busy, input wire sector_valid, input wire [7:0] sector_byte,
    input wire [8:0] sector_byte_index, input wire sector_done,
    input wire [7:0] sector_error, input wire sector_abort,
    // 可选中止：用于流式音频在播放中途停止时释放状态机。
    // BMP 路径固定接 0，行为与原实现完全一致。
    // 中止后不再发起新事务，等当前扇区结束即回 IDLE，避免永久卡在
    // S_DATA_WAIT / S_FAT_WAIT（实板表现为连续切页后音频永久失效）。
    input wire stream_abort
);
    localparam S_IDLE=0,S_DATA_REQ=1,S_DATA_MUL=2,S_DATA_OFFSET=3,S_DATA_CHECK=4,S_DATA_WAIT=5,S_FAT_REQ=6,S_FAT_WAIT=7,S_FAT_DECODE=8,S_DONE=9,S_ERR=10,S_ABORT=11;
    localparam E_SD=8'h03,E_BAD_CLUSTER=8'h04,E_LOOP=8'h05,E_RANGE=8'h06,E_EOF=8'h07;
    reg [3:0] state;
    reg [31:0] cluster, remaining, fat_lba, entry_value, cluster_count;
    reg [7:0] sector_in_cluster;
    // A FAT32 sector contains 128 four-byte entries, so the byte offset
    // spans 0..508 and must retain nine bits. Seven bits wrapped at entry 32.
    reg [8:0] fat_offset;
    integer i;
    reg [31:0] visited[0:15];
    reg [4:0] visited_count;
    reg [31:0] data_offset;
    reg [31:0] cluster_base_offset;
    reg [31:0] offset_counter;
    // Calculate (cluster - 2) * sectors_per_cluster over several cycles.
    // This keeps the 100 MHz data path to a single 32-bit add instead of
    // inferring a wide multiply-plus-add in S_DATA_REQ.
    reg [31:0] mul_acc;
    reg [31:0] mul_mcand;
    reg [7:0] mul_multiplier;
    reg [3:0] mul_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; file_busy<=0; file_done<=0; file_valid<=0; file_byte<=0; file_byte_offset<=0; offset_counter<=0;
            fs_error<=0; sector_req<=0; sector_lba<=0; cluster<=0; remaining<=0; cluster_count<=0; visited_count<=0;
            data_offset<=0; cluster_base_offset<=0;
            mul_acc<=0; mul_mcand<=0; mul_multiplier<=0; mul_count<=0;
            for(i=0;i<16;i=i+1) visited[i]<=0;
        end else begin
            file_done<=0; file_valid<=0; sector_req<=0;

            // 中止请求：在等扇区的两个状态里立即退出，其余状态在下一拍生效
            if (stream_abort && (state != S_IDLE) && (state != S_ABORT)) begin
                state     <= S_ABORT;
                sector_req<= 0;
                file_busy <= 0;
            end else case(state)
                S_IDLE: if (file_start) begin
                    file_busy<=1; fs_error<=0; file_byte_offset<=0; offset_counter<=0; remaining<=file_size; cluster<=first_cluster;
                    sector_in_cluster<=0; cluster_count<=0; visited_count<=0;
                    if (file_size==0) state<=S_DONE;
                    else if (first_cluster<2 || first_cluster>max_cluster) begin fs_error<=E_BAD_CLUSTER; state<=S_ERR; end
                    else state<=S_DATA_REQ;
                end
                S_DATA_REQ: begin
                    mul_acc<=0;
                    mul_mcand<=cluster-2;
                    mul_multiplier<=sectors_per_cluster;
                    mul_count<=0;
                    state<=S_DATA_MUL;
                end
                S_DATA_MUL: begin
                    if (mul_count==7) begin
                        cluster_base_offset<=mul_acc + (mul_multiplier[0] ? mul_mcand : 32'd0);
                        state<=S_DATA_OFFSET;
                    end else begin
                        if (mul_multiplier[0]) mul_acc<=mul_acc + mul_mcand;
                        mul_mcand<=mul_mcand<<1;
                        mul_multiplier<=mul_multiplier>>1;
                        mul_count<=mul_count+1;
                    end
                end
                S_DATA_OFFSET: begin
                    data_offset<=cluster_base_offset + sector_in_cluster;
                    state<=S_DATA_CHECK;
                end
                S_DATA_CHECK: begin
                    if ((data_start_lba + data_offset) < data_start_lba) begin
                        fs_error<=E_RANGE; state<=S_ERR;
                    end else begin
                        sector_lba<=data_start_lba + data_offset;
                        sector_req<=1; state<=S_DATA_WAIT;
                    end
                end
                S_DATA_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=S_ERR; end
                    else begin
                        if (sector_valid && remaining!=0) begin
                            file_valid<=1; file_byte<=sector_byte; file_byte_offset<=offset_counter;
                            offset_counter<=offset_counter+1; remaining<=remaining-1;
                        end
                        if (sector_done) begin
                            if (remaining<=1) state<=S_DONE;
                            else if (sector_in_cluster+1 < sectors_per_cluster) begin sector_in_cluster<=sector_in_cluster+1; state<=S_DATA_REQ; end
                            else state<=S_FAT_REQ;
                        end
                    end
                end
                S_FAT_REQ: begin
                    fat_lba<=fat_start_lba + (cluster>>7); fat_offset<=cluster[6:0]<<2;
                    sector_lba<=fat_start_lba + (cluster>>7); sector_req<=1; state<=S_FAT_WAIT; end
                S_FAT_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=S_ERR; end
                    else begin
                        if (sector_valid && sector_byte_index==fat_offset) entry_value[7:0]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_offset+1) entry_value[15:8]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_offset+2) entry_value[23:16]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_offset+3) entry_value[31:24]<=sector_byte;
                        if (sector_done) state<=S_FAT_DECODE;
                    end
                end
                S_FAT_DECODE: begin
                    if ((entry_value & 32'h0fffffff)>=32'h0ffffff8) begin
                        if (remaining==0) state<=S_DONE; else begin fs_error<=E_EOF; state<=S_ERR; end
                    end else if ((entry_value & 32'h0fffffff)==32'h0ffffff7 || (entry_value & 32'h0fffffff)<2 || (entry_value & 32'h0fffffff)>max_cluster) begin fs_error<=E_BAD_CLUSTER; state<=S_ERR; end
                    else if ((entry_value & 32'h0fffffff)==cluster) begin fs_error<=E_LOOP; state<=S_ERR; end
                    else if (cluster_count>=MAX_VISITED_CLUSTERS) begin fs_error<=E_LOOP; state<=S_ERR; end
                    else begin
                        cluster<=(entry_value & 32'h0fffffff); cluster_count<=cluster_count+1; sector_in_cluster<=0; state<=S_DATA_REQ;
                    end
                end
                S_DONE: begin file_busy<=0; file_done<=1; state<=S_IDLE; end
                S_ERR: begin file_busy<=0; state<=S_IDLE; end
                S_ABORT: begin
                    // 丢弃在途事务，回空闲；不置 done/valid/error
                    file_busy <= 0;
                    file_valid<= 0;
                    sector_req<= 0;
                    state     <= S_IDLE;
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
