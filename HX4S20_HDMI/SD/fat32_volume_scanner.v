`timescale 1ns/1ps
// Streaming FAT32 volume/root-directory scanner.  This module is intentionally
// independent of the legacy SPI driver; one sector is presented as indexed bytes.
module fat32_volume_scanner #(
    parameter integer MAX_DIR_CLUSTERS = 256
) (
    input wire clk, input wire rst_n,
    input wire scan_start, input wire sector_link_ready,
    output reg scan_busy, output reg scan_done, output reg fs_ready,
    output reg [7:0] fs_error,
    output reg [31:0] partition_lba, output reg [31:0] root_cluster,
    output reg [7:0] sectors_per_cluster, output reg [31:0] fat_start_lba,
    output reg [31:0] data_start_lba, output reg [31:0] max_cluster,
    output reg [3:0] resource_valid,
    output reg [31:0] resource_cluster0, resource_cluster1, resource_cluster2, resource_cluster3,
    output reg [31:0] resource_size0, resource_size1, resource_size2, resource_size3,
    // 可选资源：PIC1..4.PCM（裸 PCM 音频流）。缺失不影响 fs_ready。
    output reg [3:0]  pcm_valid,
    output reg [31:0] pcm_cluster0, pcm_cluster1, pcm_cluster2, pcm_cluster3,
    output reg [31:0] pcm_size0, pcm_size1, pcm_size2, pcm_size3,
    output reg sector_req, output reg [31:0] sector_lba,
    input wire sector_busy, input wire sector_valid, input wire [7:0] sector_byte,
    input wire [8:0] sector_byte_index, input wire sector_done,
    input wire [7:0] sector_error, input wire sector_abort
);
    localparam ST_IDLE=0, ST_REQ=1, ST_WAIT=2, ST_VALIDATE0=3, ST_BPB_REQ=4, ST_BPB_WAIT=5, ST_VALIDATE_BPB=6,
               ST_DIR_REQ=7, ST_DIR_WAIT=8, ST_FAT_REQ=9, ST_FAT_WAIT=10, ST_FAT_DECODE=11,
               ST_DONE=12, ST_ERR=13, ST_CALC_DATA=14, ST_CALC_MAX=15, ST_CALC_CHECK=16,
               ST_DIR_CALC=17, ST_DIR_OFFSET=18, ST_CALC_CLUSTER=19, ST_FAT_DECIDE=20;
    localparam E_NO_VOLUME=8'h01, E_BPB=8'h02, E_SD=8'h03, E_BAD_CLUSTER=8'h04,
               E_LOOP=8'h05, E_RANGE=8'h06;
    reg [4:0] state;
    reg [31:0] candidate_lba, mbr_start[0:3], mbr_size[0:3];
    reg [7:0] mbr_type[0:3];
    reg [1:0] candidate_idx;
    reg [15:0] bps, reserved;
    reg [7:0] fat_count, spc;
    reg [31:0] total_sectors, fat_size, bpb_root;
    reg [31:0] bpb_fat_start, bpb_data_start, bpb_max_cluster;
    reg [15:0] bpb_sig;
    reg [31:0] dir_cluster, dir_sector;
    reg [31:0] dir_cluster_base;
    reg [31:0] dir_data_offset;
    reg [31:0] dir_count;
    reg [31:0] fat_next;
    reg [31:0] fat_cluster_q;
    reg        fat_is_eoc_q, fat_is_bad_q, fat_loop_q;
    reg [8:0] fat_base, entry_byte;
    reg [31:0] entry_value;
    reg [7:0] ent_name[0:10];
    reg [7:0] ent_attr;
    reg [31:0] ent_first, ent_size;
    reg [4:0] ent_pos;
    reg [15:0] bpb_reserved_tmp;
    reg [7:0] bpb_spc_tmp, bpb_fats_tmp;
    reg [31:0] bpb_total_tmp, bpb_fatsz_tmp, bpb_root_tmp;
    reg [31:0] visited[0:15];
    reg [4:0] visited_count;
    reg dir_end_seen;
    reg calc_mbr_mode;
    reg [31:0] calc_fat_span, calc_data_offset, calc_max_cluster;
    reg [31:0] calc_available_sectors;
    reg [32:0] calc_volume_end_wide, calc_partition_end_wide, calc_data_offset_wide;
    wire [63:0] fat_span_wide = {56'd0, fat_count} * {32'd0, fat_size};
    wire [63:0] data_offset_wide = {48'd0, reserved} + fat_span_wide;
    wire [63:0] volume_end_wide = {32'd0, candidate_lba} + {32'd0, total_sectors};
    wire [63:0] partition_end_wide = {32'd0, mbr_start[candidate_idx]} + {32'd0, mbr_size[candidate_idx]};
    wire [31:0] fat_span = fat_span_wide[31:0];
    wire [31:0] data_offset = data_offset_wide[31:0];
    integer i;

    function automatic bpb_ok;
        input [15:0] vbps; input [7:0] vspc, vfats; input [15:0] vres;
        input [31:0] vtotal, vfatsz, vroot;
        begin
            bpb_ok = (vbps == 16'd512) && (vspc != 0) && ((vspc & (vspc-1'b1)) == 0) &&
                     (vfats != 0) && (vres != 0) && (vtotal != 0) && (vfatsz != 0) && (vroot >= 2);
        end
    endfunction
    function automatic [31:0] le32;
        input [7:0] a,b,c,d; begin le32={d,c,b,a}; end
    endfunction
    function automatic [15:0] le16;
        input [7:0] a,b; begin le16={b,a}; end
    endfunction
    // FAT32 sectors-per-cluster is validated as a power of two.  Keep the
    // cluster bound calculation as a small decode/shift network instead of
    // inferring a variable divider in the 100 MHz control path.
    function automatic [31:0] cluster_limit;
        input [31:0] available_sectors;
        input [7:0]  vspc;
        begin
            case (vspc)
                8'd1:   cluster_limit = available_sectors;
                8'd2:   cluster_limit = available_sectors >> 1;
                8'd4:   cluster_limit = available_sectors >> 2;
                8'd8:   cluster_limit = available_sectors >> 3;
                8'd16:  cluster_limit = available_sectors >> 4;
                8'd32:  cluster_limit = available_sectors >> 5;
                8'd64:  cluster_limit = available_sectors >> 6;
                8'd128: cluster_limit = available_sectors >> 7;
                default: cluster_limit = 32'd0;
            endcase
        end
    endfunction

    function automatic [31:0] cluster_sector_offset;
        input [31:0] vcluster;
        input [7:0]  vspc;
        begin
            case (vspc)
                8'd1:   cluster_sector_offset = vcluster;
                8'd2:   cluster_sector_offset = vcluster << 1;
                8'd4:   cluster_sector_offset = vcluster << 2;
                8'd8:   cluster_sector_offset = vcluster << 3;
                8'd16:  cluster_sector_offset = vcluster << 4;
                8'd32:  cluster_sector_offset = vcluster << 5;
                8'd64:  cluster_sector_offset = vcluster << 6;
                8'd128: cluster_sector_offset = vcluster << 7;
                default: cluster_sector_offset = 32'd0;
            endcase
        end
    endfunction
    task automatic clear_resources;
        begin resource_valid<=0; resource_cluster0<=0; resource_cluster1<=0; resource_cluster2<=0; resource_cluster3<=0;
              resource_size0<=0; resource_size1<=0; resource_size2<=0; resource_size3<=0;
              pcm_valid<=0; pcm_cluster0<=0; pcm_cluster1<=0; pcm_cluster2<=0; pcm_cluster3<=0;
              pcm_size0<=0; pcm_size1<=0; pcm_size2<=0; pcm_size3<=0; end
    endtask

    // 8.3 名公共前缀："PIC" + 空格4 + 扩展名首字节由 case 区分 + 页号 '1'..'4'
    wire pic_prefix_ok = (ent_name[0]=="P") && (ent_name[1]=="I") && (ent_name[2]=="C") &&
                         (ent_name[4]==8'h20) && (ent_name[5]==8'h20) &&
                         (ent_name[6]==8'h20) && (ent_name[7]==8'h20) &&
                         (ent_name[3]>=8'h31) && (ent_name[3]<=8'h34) &&
                         ((ent_name[8]=="B") || (ent_name[8]=="P"));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=ST_IDLE; scan_busy<=0; scan_done<=0; fs_ready<=0; fs_error<=0; sector_req<=0;
            sector_lba<=0; partition_lba<=0; root_cluster<=0; sectors_per_cluster<=0;
            fat_start_lba<=0; data_start_lba<=0; max_cluster<=0; candidate_idx<=0; dir_count<=0; visited_count<=0;
            dir_data_offset<=0;
            dir_cluster_base<=0;
            calc_mbr_mode<=0; calc_fat_span<=0; calc_data_offset<=0; calc_max_cluster<=0;
            calc_available_sectors<=0;
            calc_volume_end_wide<=0; calc_partition_end_wide<=0; calc_data_offset_wide<=0;
            clear_resources();
            for (i=0;i<4;i=i+1) begin mbr_start[i]<=0; mbr_size[i]<=0; mbr_type[i]<=0; end
        end else begin
            scan_done<=0; sector_req<=0;
            case (state)
                ST_IDLE: begin
                    if (scan_start && sector_link_ready) begin
                        scan_busy<=1; fs_ready<=0; fs_error<=0; clear_resources(); candidate_idx<=0;
                        sector_lba<=0; state<=ST_REQ;
                    end
                end
                ST_REQ: begin sector_req<=1; state<=ST_WAIT; end
                ST_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=ST_ERR; end
                    else if (sector_valid) begin
                        if (sector_byte_index==9'd510) bpb_sig[7:0]<=sector_byte;
                        if (sector_byte_index==9'd511) bpb_sig[15:8]<=sector_byte;
                        if (sector_byte_index==9'd11) bps[7:0]<=sector_byte;
                        if (sector_byte_index==9'd12) bps[15:8]<=sector_byte;
                        if (sector_byte_index==9'd13) spc<=sector_byte;
                        if (sector_byte_index==9'd14) reserved[7:0]<=sector_byte;
                        if (sector_byte_index==9'd15) reserved[15:8]<=sector_byte;
                        if (sector_byte_index==9'd16) fat_count<=sector_byte;
                        if (sector_byte_index==9'd32) total_sectors[7:0]<=sector_byte;
                        if (sector_byte_index==9'd33) total_sectors[15:8]<=sector_byte;
                        if (sector_byte_index==9'd34) total_sectors[23:16]<=sector_byte;
                        if (sector_byte_index==9'd35) total_sectors[31:24]<=sector_byte;
                        if (sector_byte_index==9'd36) fat_size[7:0]<=sector_byte;
                        if (sector_byte_index==9'd37) fat_size[15:8]<=sector_byte;
                        if (sector_byte_index==9'd38) fat_size[23:16]<=sector_byte;
                        if (sector_byte_index==9'd39) fat_size[31:24]<=sector_byte;
                        if (sector_byte_index==9'd44) bpb_root[7:0]<=sector_byte;
                        if (sector_byte_index==9'd45) bpb_root[15:8]<=sector_byte;
                        if (sector_byte_index==9'd46) bpb_root[23:16]<=sector_byte;
                        if (sector_byte_index==9'd47) bpb_root[31:24]<=sector_byte;
                        if (sector_byte_index>=9'd446 && sector_byte_index<9'd510) begin
                            for (i=0;i<4;i=i+1) begin
                                if (sector_byte_index==9'd450+i*16) mbr_type[i]<=sector_byte;
                                if (sector_byte_index==9'd454+i*16) mbr_start[i][7:0]<=sector_byte;
                                if (sector_byte_index==9'd455+i*16) mbr_start[i][15:8]<=sector_byte;
                                if (sector_byte_index==9'd456+i*16) mbr_start[i][23:16]<=sector_byte;
                                if (sector_byte_index==9'd457+i*16) mbr_start[i][31:24]<=sector_byte;
                                if (sector_byte_index==9'd458+i*16) mbr_size[i][7:0]<=sector_byte;
                                if (sector_byte_index==9'd459+i*16) mbr_size[i][15:8]<=sector_byte;
                                if (sector_byte_index==9'd460+i*16) mbr_size[i][23:16]<=sector_byte;
                                if (sector_byte_index==9'd461+i*16) mbr_size[i][31:24]<=sector_byte;
                            end
                        end
                    end
                    if (sector_done) begin state<=ST_VALIDATE0; end
                end
                ST_VALIDATE0: begin
                        if (bpb_sig==16'haa55 && bpb_ok(bps,spc,fat_count,reserved,total_sectors,fat_size,bpb_root)) begin
                            calc_mbr_mode<=0;
                            calc_fat_span<=fat_span_wide[31:0];
                            state<=ST_CALC_DATA;
                        end else begin candidate_idx<=0; state<=ST_BPB_REQ; end
                end
                ST_BPB_REQ: begin
                    if (candidate_idx<4 && (mbr_type[candidate_idx]==8'h0b || mbr_type[candidate_idx]==8'h0c) && mbr_start[candidate_idx]!=0) begin
                        candidate_lba<=mbr_start[candidate_idx]; sector_lba<=mbr_start[candidate_idx];
                        bps<=0; reserved<=0; spc<=0; fat_count<=0; total_sectors<=0; fat_size<=0; bpb_root<=0; bpb_sig<=0; sector_req<=1; state<=ST_BPB_WAIT;
                    end else if (candidate_idx==3) begin fs_error<=E_NO_VOLUME; state<=ST_ERR; end
                    else candidate_idx<=candidate_idx+1'b1;
                end
                ST_BPB_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=ST_ERR; end
                    else begin
                        if (sector_valid) begin
                            if (sector_byte_index==9'd11) bps[7:0]<=sector_byte;
                            if (sector_byte_index==9'd12) bps[15:8]<=sector_byte;
                            if (sector_byte_index==9'd13) spc<=sector_byte;
                            if (sector_byte_index==9'd14) reserved[7:0]<=sector_byte;
                            if (sector_byte_index==9'd15) reserved[15:8]<=sector_byte;
                            if (sector_byte_index==9'd16) fat_count<=sector_byte;
                            if (sector_byte_index>=9'd32 && sector_byte_index<=9'd35) total_sectors[(sector_byte_index-9'd32)*8 +: 8]<=sector_byte;
                            if (sector_byte_index>=9'd36 && sector_byte_index<=9'd39) fat_size[(sector_byte_index-9'd36)*8 +: 8]<=sector_byte;
                            if (sector_byte_index>=9'd44 && sector_byte_index<=9'd47) bpb_root[(sector_byte_index-9'd44)*8 +: 8]<=sector_byte;
                            if (sector_byte_index==9'd510) bpb_sig[7:0]<=sector_byte;
                            if (sector_byte_index==9'd511) bpb_sig[15:8]<=sector_byte;
                        end
                        if (sector_done) begin state<=ST_VALIDATE_BPB; end
                    end
                end
                ST_VALIDATE_BPB: begin
                            if (bpb_sig==16'haa55 && bpb_ok(bps,spc,fat_count,reserved,total_sectors,fat_size,bpb_root)) begin
                                calc_mbr_mode<=1;
                                calc_fat_span<=fat_span_wide[31:0];
                                state<=ST_CALC_DATA;
                            end else if (candidate_idx==3) begin fs_error<=E_NO_VOLUME; state<=ST_ERR; end
                            else begin candidate_idx<=candidate_idx+1'b1; state<=ST_BPB_REQ; end
                end
                ST_CALC_DATA: begin
                    calc_data_offset_wide <= {17'd0,reserved} + {1'b0,calc_fat_span};
                    calc_volume_end_wide <= {1'b0,candidate_lba} + {1'b0,total_sectors};
                    calc_partition_end_wide <= {1'b0,mbr_start[candidate_idx]} + {1'b0,mbr_size[candidate_idx]};
                    state<=ST_CALC_MAX;
                end
                ST_CALC_MAX: begin
                    if (calc_data_offset_wide[32] || (calc_data_offset_wide[31:0] >= total_sectors)) begin
                        if (calc_mbr_mode && candidate_idx!=3) begin candidate_idx<=candidate_idx+1'b1; state<=ST_BPB_REQ; end
                        else begin fs_error<=calc_mbr_mode ? E_NO_VOLUME : E_BPB; state<=ST_ERR; end
                    end else begin
                        calc_data_offset<=calc_data_offset_wide[31:0];
                        calc_available_sectors<=total_sectors-calc_data_offset_wide[31:0];
                        state<=ST_CALC_CLUSTER;
                    end
                end
                ST_CALC_CLUSTER: begin
                    calc_max_cluster<=cluster_limit(calc_available_sectors, spc)+1;
                    state<=ST_CALC_CHECK;
                end
                ST_CALC_CHECK: begin
                    if ((bpb_root <= calc_max_cluster) &&
                        ((!calc_mbr_mode) ||
                         (!calc_volume_end_wide[32] && !calc_partition_end_wide[32] &&
                          (calc_volume_end_wide[31:0] <= calc_partition_end_wide[31:0])))) begin
                        partition_lba<=calc_mbr_mode ? candidate_lba : 0;
                        root_cluster<=bpb_root; sectors_per_cluster<=spc;
                        fat_start_lba<=(calc_mbr_mode ? candidate_lba : 0)+reserved;
                        data_start_lba<=(calc_mbr_mode ? candidate_lba : 0)+calc_data_offset;
                        max_cluster<=calc_max_cluster;
                        bpb_fat_start<=(calc_mbr_mode ? candidate_lba : 0)+reserved;
                        bpb_data_start<=(calc_mbr_mode ? candidate_lba : 0)+calc_data_offset;
                        bpb_max_cluster<=calc_max_cluster;
                        dir_cluster<=bpb_root; dir_sector<=0; dir_count<=0;
                        visited[0]<=bpb_root; visited_count<=1; state<=ST_DIR_REQ;
                    end else if (calc_mbr_mode && candidate_idx!=3) begin
                        candidate_idx<=candidate_idx+1'b1; state<=ST_BPB_REQ;
                    end else begin fs_error<=calc_mbr_mode ? E_NO_VOLUME : E_BPB; state<=ST_ERR; end
                end
                ST_DIR_REQ: begin
                    if (dir_count>=MAX_DIR_CLUSTERS) begin fs_error<=E_LOOP; state<=ST_ERR; end
                    else begin
                        dir_cluster_base<=dir_cluster-2;
                        ent_pos<=0; ent_attr<=0; dir_end_seen<=0; state<=ST_DIR_OFFSET;
                    end
                end
                ST_DIR_OFFSET: begin
                    // 保持原有乘法映射，避免移位译码改变 DSP/布局分布。
                    dir_data_offset<=(dir_cluster_base*spc)+dir_sector;
                    state<=ST_DIR_CALC;
                end
                ST_DIR_CALC: begin
                    sector_lba<=bpb_data_start + dir_data_offset;
                    sector_req<=1;
                    state<=ST_DIR_WAIT;
                end
                ST_DIR_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=ST_ERR; end
                    else begin
                        if (sector_valid) begin
                            if ((sector_byte_index[4:0])==0) ent_name[0]<=sector_byte;
                            else if (sector_byte_index[4:0]<11) ent_name[sector_byte_index[4:0]]<=sector_byte;
                            if (sector_byte_index[4:0]==11) ent_attr<=sector_byte;
                            if (sector_byte_index[4:0]==20) ent_first[23:16]<=sector_byte;
                            if (sector_byte_index[4:0]==21) ent_first[31:24]<=sector_byte;
                            if (sector_byte_index[4:0]==26) ent_first[7:0]<=sector_byte;
                            if (sector_byte_index[4:0]==27) ent_first[15:8]<=sector_byte;
                            if (sector_byte_index[4:0]>=28 && sector_byte_index[4:0]<=31) ent_size[(sector_byte_index[4:0]-28)*8 +: 8]<=sector_byte;
                            if (sector_byte_index[4:0]==0 && sector_byte==8'h00) dir_end_seen<=1;
                            if (sector_byte_index[4:0]==11 && sector_byte==8'h0f) ent_name[0]<=8'hf0;
                            if (sector_byte_index[4:0]==31) begin
                                if (ent_name[0]==8'h00) begin state<=ST_DONE; end
                                else if (ent_name[0]!=8'he5 && ent_name[0]!=8'hf0 &&
                                         (ent_attr & 8'h18)==0 && sector_byte_index[4:0]==31) begin
                                    // 名字前缀只比较一次，供 BMP / PCM 两个分支复用，
                                    // 避免把两组完整比较串进同一条 100 MHz 组合路径。
                                    if (pic_prefix_ok) begin
                                        case ({ent_name[8], ent_name[9], ent_name[10]})
                                            {8'h42, 8'h4D, 8'h50}: begin   // "BMP"
                                                case (ent_name[3])
                                                    "1": begin resource_valid[0]<=1; resource_cluster0<=ent_first; resource_size0<={sector_byte,ent_size[23:0]}; end
                                                    "2": begin resource_valid[1]<=1; resource_cluster1<=ent_first; resource_size1<={sector_byte,ent_size[23:0]}; end
                                                    "3": begin resource_valid[2]<=1; resource_cluster2<=ent_first; resource_size2<={sector_byte,ent_size[23:0]}; end
                                                    "4": begin resource_valid[3]<=1; resource_cluster3<=ent_first; resource_size3<={sector_byte,ent_size[23:0]}; end
                                                    default: ;
                                                endcase
                                            end
                                            {8'h50, 8'h43, 8'h4D}: begin   // "PCM"（可选音频资源）
                                                case (ent_name[3])
                                                    "1": begin pcm_valid[0]<=1; pcm_cluster0<=ent_first; pcm_size0<={sector_byte,ent_size[23:0]}; end
                                                    "2": begin pcm_valid[1]<=1; pcm_cluster1<=ent_first; pcm_size1<={sector_byte,ent_size[23:0]}; end
                                                    "3": begin pcm_valid[2]<=1; pcm_cluster2<=ent_first; pcm_size2<={sector_byte,ent_size[23:0]}; end
                                                    "4": begin pcm_valid[3]<=1; pcm_cluster3<=ent_first; pcm_size3<={sector_byte,ent_size[23:0]}; end
                                                    default: ;
                                                endcase
                                            end
                                            default: ;
                                        endcase
                                    end
                                end
                            end
                        end
                        if (sector_done && state==ST_DIR_WAIT) begin
                            if (dir_end_seen) begin state<=ST_DONE; end
                            else if (dir_sector+1 < spc) begin dir_sector<=dir_sector+1; dir_count<=dir_count+1; state<=ST_DIR_REQ; end
                            else begin dir_sector<=0; state<=ST_FAT_REQ; end
                        end
                    end
                end
                ST_FAT_REQ: begin sector_lba<=bpb_fat_start + (dir_cluster>>7); fat_base<=(dir_cluster[6:0]<<2); sector_req<=1; state<=ST_FAT_WAIT; end
                ST_FAT_WAIT: begin
                    if (sector_error!=0 || sector_abort) begin fs_error<=E_SD; state<=ST_ERR; end
                    else begin
                        if (sector_valid && sector_byte_index==fat_base) entry_value[7:0]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_base+1) entry_value[15:8]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_base+2) entry_value[23:16]<=sector_byte;
                        if (sector_valid && sector_byte_index==fat_base+3) entry_value[31:24]<=sector_byte;
                        if (sector_done) state<=ST_FAT_DECODE;
                    end
                end
                ST_FAT_DECODE: begin
                    // 第一级：锁存解码标志（链尾 / 越界 / 环），把 32 位比较与
                    // 16 路 visited 搜索从“解码 + 判定 + 转移”长链中拆出来。
                    fat_cluster_q  <= entry_value & 32'h0fffffff;
                    fat_is_eoc_q   <= ((entry_value & 32'h0fffffff) >= 32'h0ffffff8);
                    fat_is_bad_q   <= ((entry_value & 32'h0fffffff) < 2) ||
                                      ((entry_value & 32'h0fffffff) > bpb_max_cluster);
                    fat_loop_q     <= 1'b0;
                    for (i=0;i<16;i=i+1)
                        if (visited[i] == (entry_value & 32'h0fffffff))
                            fat_loop_q <= 1'b1;
                    fat_next <= entry_value & 32'h0fffffff;
                    state <= ST_FAT_DECIDE;
                end
                ST_FAT_DECIDE: begin
                    if (fat_is_eoc_q) begin
                        state <= ST_DONE;
                    end else if (fat_is_bad_q) begin
                        fs_error <= E_BAD_CLUSTER; state <= ST_ERR;
                    end else if (fat_loop_q) begin
                        fs_error <= E_LOOP; state <= ST_ERR;
                    end else begin
                        visited[visited_count[3:0]] <= dir_cluster;
                        if (visited_count < 16) visited_count <= visited_count + 1;
                        dir_cluster <= fat_cluster_q;
                        dir_count   <= dir_count + 1;
                        state       <= ST_DIR_REQ;
                    end
                end
                ST_DONE: begin
                    scan_busy<=0; if (resource_valid==4'b1111) begin fs_ready<=1; fs_error<=0; end else begin fs_ready<=0; fs_error<=E_NO_VOLUME; end scan_done<=1; state<=ST_IDLE; end
                ST_ERR: begin scan_busy<=0; fs_ready<=0; scan_done<=1; state<=ST_IDLE; end
                default: state<=ST_IDLE;
            endcase
        end
    end
endmodule
