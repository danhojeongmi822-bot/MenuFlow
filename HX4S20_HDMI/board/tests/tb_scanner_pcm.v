`timescale 1ns/1ps

// 扫描器 PCM 可选资源专项：
//   * 只放 4 个 BMP（无 PCM）：fs_ready 仍为 1，pcm_valid 全 0；
//   * 追加 PIC3.PCM / PIC4.PCM：pcm_valid[2]/[3] 置位，簇号/大小正确；
//   * 追加 PIC1.PCM：四个都识别；
//   * 大小字段必须 32 位完整（> 16 MB 的低位拼接不能截断）；
//   * 长文件名 / 非 8.3 名的 PCM 不得误匹配。
//
// 镜像在 TB 内构造（super-floppy FAT32，1 扇区/簇），不依赖外部 fixture。
module tb_scanner_pcm;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  scan_start = 1'b0;
    reg  link_ready = 1'b1;
    wire scan_busy, scan_done, fs_ready;
    wire [7:0]  fs_error;
    wire [3:0]  resource_valid;
    wire [31:0] resource_c0, resource_c1, resource_c2, resource_c3;
    wire [31:0] resource_s0, resource_s1, resource_s2, resource_s3;
    wire [3:0]  pcm_valid;
    wire [31:0] pcm_c0, pcm_c1, pcm_c2, pcm_c3;
    wire [31:0] pcm_s0, pcm_s1, pcm_s2, pcm_s3;

    reg         sector_req;
    wire [31:0] sector_lba;
    reg         sector_busy = 1'b0;
    reg         sector_valid = 1'b0;
    reg  [7:0]  sector_byte = 8'd0;
    reg  [8:0]  sector_byte_index = 9'd0;
    reg         sector_done = 1'b0;
    reg  [7:0]  sector_error = 8'd0;

    // 镜像：LBA0 BPB，LBA1 FAT，LBA2 根目录，LBA3.. 数据
    localparam integer IMG_SECTORS = 64;
    reg [7:0] img [0:IMG_SECTORS*512-1];
    integer i, k;
    integer errors = 0;
    integer case_id = 0;

    fat32_volume_scanner dut (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .sector_link_ready(link_ready),
        .scan_busy(scan_busy), .scan_done(scan_done), .fs_ready(fs_ready), .fs_error(fs_error),
        .partition_lba(), .root_cluster(), .sectors_per_cluster(),
        .fat_start_lba(), .data_start_lba(), .max_cluster(),
        .resource_valid(resource_valid),
        .resource_cluster0(resource_c0), .resource_cluster1(resource_c1),
        .resource_cluster2(resource_c2), .resource_cluster3(resource_c3),
        .resource_size0(resource_s0), .resource_size1(resource_s1),
        .resource_size2(resource_s2), .resource_size3(resource_s3),
        .pcm_valid(pcm_valid),
        .pcm_cluster0(pcm_c0), .pcm_cluster1(pcm_c1), .pcm_cluster2(pcm_c2), .pcm_cluster3(pcm_c3),
        .pcm_size0(pcm_s0), .pcm_size1(pcm_s1), .pcm_size2(pcm_s2), .pcm_size3(pcm_s3),
        .sector_req(sector_req), .sector_lba(sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error), .sector_abort(1'b0)
    );

    // 扇区服务：在 negedge 驱动，完整周期保持，避免与 DUT 的 posedge 采样竞争
    integer pos;
    reg [31:0] cur_lba;

    always @(posedge clk) begin
        if (sector_req && !sector_busy) begin
            sector_busy <= 1'b1;
            cur_lba     <= sector_lba;
        end
    end

    task automatic serve;
        integer n;
        begin
            // 等一拍让 cur_lba 就绪
            @(negedge clk);
            sector_byte_index = 9'd0;
            sector_byte       = img[cur_lba*512];
            sector_valid      = 1'b1;
            @(posedge clk);
            for (n = 1; n < 512; n = n + 1) begin
                @(negedge clk);
                sector_byte_index = n[8:0];
                sector_byte       = img[cur_lba*512 + n];
                sector_valid      = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            sector_valid = 1'b0;
            sector_done  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sector_done = 1'b0;
            sector_busy = 1'b0;
        end
    endtask

    integer srv_n;
    always @(posedge clk) begin
        if (sector_busy && !sector_valid && !sector_done) begin
            serve();
        end
    end

    // ---------------- 镜像构造 ----------------
    task automatic put32(input integer a, input [31:0] v);
        begin
            img[a] = v[7:0]; img[a+1] = v[15:8]; img[a+2] = v[23:16]; img[a+3] = v[31:24];
        end
    endtask

    task automatic put16(input integer a, input [15:0] v);
        begin
            img[a] = v[7:0]; img[a+1] = v[15:8];
        end
    endtask

    // 8.3 名字：base "PICn    " + ext "BMP"/"PCM"
    task automatic put_entry(input integer slot, input [7:0] p3,
                             input [7:0] e8, input [7:0] e9, input [7:0] e10,
                             input [31:0] cluster, input [31:0] size);
        integer a;
        begin
            a = 2*512 + slot*32;
            img[a+0] = "P"; img[a+1] = "I"; img[a+2] = "C"; img[a+3] = p3;
            img[a+4] = 8'h20; img[a+5] = 8'h20; img[a+6] = 8'h20; img[a+7] = 8'h20;
            img[a+8] = e8; img[a+9] = e9; img[a+10] = e10;
            img[a+11] = 8'h01;                 // attr = read-only+archive（不是目录）
            put16(a+26, 16'd0);                // 高 16 位簇号
            // FAT32 目录项：簇号低 16 位在 +26，高 16 位在 +20
            put16(a+26, cluster[15:0]);
            put16(a+20, cluster[31:16]);
            put32(a+28, size);
        end
    endtask

    task automatic build_image(input integer n_pcm);
        integer c;
        begin
            for (i = 0; i < IMG_SECTORS*512; i = i + 1) img[i] = 8'd0;
            // BPB（super-floppy）
            img[0] = 8'hEB; img[1] = 8'h3C; img[2] = 8'h90;
            put16(11, 16'd512);
            img[13] = 8'd1;                    // sectors per cluster
            put16(14, 16'd1);                  // reserved
            img[16] = 8'd1;                    // FAT count
            put32(32, 32'd64);                 // total sectors
            put32(36, 32'd1);                  // FAT size
            put32(44, 32'd2);                  // root cluster
            img[510] = 8'h55; img[511] = 8'hAA;
            // FAT：簇 2 为根目录（EOC），3..10 各自 EOC
            for (c = 2; c <= 10; c = c + 1) put32(512 + c*4, 32'h0FFFFFF8);
            // 4 个 BMP
            put_entry(0, "1", "B", "M", "P", 32'd3, 32'd921654);
            put_entry(1, "2", "B", "M", "P", 32'd4, 32'd921654);
            put_entry(2, "3", "B", "M", "P", 32'd5, 32'd921654);
            put_entry(3, "4", "B", "M", "P", 32'd6, 32'd921654);
            // PCM（按需）
            if (n_pcm >= 1) put_entry(4, "1", "P", "C", "M", 32'd7, 32'd4096);
            if (n_pcm >= 2) put_entry(5, "2", "P", "C", "M", 32'd8, 32'h01234567);
            // 注：32 位大小取自目录项 +28..+31，TB 已按小端写入，扫描器按
            // {sector_byte, ent_size[23:0]} 拼接，因此 >16 MB 的大小也可完整保留。
            if (n_pcm >= 3) put_entry(6, "3", "P", "C", "M", 32'd9, 32'd196608);
            if (n_pcm >= 4) put_entry(7, "4", "P", "C", "M", 32'd10, 32'd98304);
        end
    endtask

    // 每次扫描之间完整复位：扫描器没有“重新扫描”入口，靠复位回到 ST_IDLE。
    task automatic do_scan;
        begin
            // 复位 DUT 前先清理服务模型，避免残留 busy/valid 把首扇区读错位
            sector_valid = 1'b0;
            sector_done  = 1'b0;
            sector_busy  = 1'b0;
            @(negedge clk); rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk); scan_start = 1'b1;
            @(negedge clk); scan_start = 1'b0;
            // 收集诊断：看扫描结束时资源与错误
            wait (scan_done);
            @(posedge clk); #1;
            if ($test$plusargs("dbg"))
                $display("  [scan] case=%0d ready=%b err=%0d res=%b pcmv=%b c=%0d,%0d sizes=%0d,%0d",
                         case_id, fs_ready, fs_error, resource_valid, pcm_valid, pcm_c0, pcm_c1, pcm_s0, pcm_s1);
                $display("  [scan] case=%0d ready=%b err=%0d res=%b pcmv=%b c=%0d,%0d sizes=%0d,%0d", case_id,
                         fs_ready, fs_error, resource_valid, pcm_valid,
                         pcm_c0, pcm_c1, pcm_s0, pcm_s1);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        case_id = 1;
        // ---- 1) 只有 BMP ----
        build_image(0);
        do_scan();
        if (!fs_ready || fs_error != 0 || resource_valid !== 4'b1111) begin
            $display("FAIL pcm_scan: BMP-only fs_ready=%b err=%0d res=%b", fs_ready, fs_error, resource_valid);
            errors = errors + 1;
        end
        if (resource_s0 !== 32'd921654 || resource_c0 !== 32'd3) begin
            $display("FAIL pcm_scan: BMP size/cluster wrong s0=%0d c0=%0d", resource_s0, resource_c0);
            errors = errors + 1;
        end
        if (pcm_valid !== 4'b0000) begin
            $display("FAIL pcm_scan: pcm_valid should be 0 without PCM (%b)", pcm_valid);
            errors = errors + 1;
        end

        case_id = 2;
        // ---- 2) BMP + 两个 PCM ----
        build_image(2);
        do_scan();
        if (!fs_ready || pcm_valid !== 4'b0011) begin
            $display("FAIL pcm_scan: two PCM ready=%b pcmv=%b", fs_ready, pcm_valid);
            errors = errors + 1;
        end
        if (pcm_c0 !== 32'd7 || pcm_s0 !== 32'd4096) begin
            $display("FAIL pcm_scan: pcm0 c=%0d s=%0d", pcm_c0, pcm_s0);
            errors = errors + 1;
        end
        // 32 位大小不得截断
        if (pcm_s1 !== 32'h01234567) begin
            $display("FAIL pcm_scan: pcm1 size truncated (%h)", pcm_s1);
            errors = errors + 1;
        end

        case_id = 3;
        // ---- 3) 四页 PCM 齐全 ----
        build_image(4);
        do_scan();
        if (pcm_valid !== 4'b1111 || pcm_c3 !== 32'd10 || pcm_s3 !== 32'd98304) begin
            $display("FAIL pcm_scan: four PCM pcmv=%b c3=%0d s3=%0d", pcm_valid, pcm_c3, pcm_s3);
            errors = errors + 1;
        end
        if (!fs_ready) begin
            $display("FAIL pcm_scan: fs_ready dropped with PCM present");
            errors = errors + 1;
        end

        case_id = 4;
        // ---- 4) 非 8.3 名（PIC33.PCM）不得误匹配 ----
        build_image(0);
        // slot 4 放一个 "PIC33  PCM"，第 3 字节为 '3'，第 4 字节为 '3'（应为空格）
        put_entry_patch();
        do_scan();
        if (pcm_valid !== 4'b0000) begin
            $display("FAIL pcm_scan: non-8.3 name matched (%b)", pcm_valid);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS scanner_pcm: optional PCM resources, 32-bit sizes, 8.3 strictness");
        else
            $display("FAIL scanner_pcm: %0d assertion(s)", errors);
        $finish;
    end

    task automatic put_entry_patch;
        integer a;
        begin
            a = 2*512 + 4*32;
            img[a+0] = "P"; img[a+1] = "I"; img[a+2] = "C"; img[a+3] = "3";
            img[a+4] = "3"; img[a+5] = 8'h20; img[a+6] = 8'h20; img[a+7] = 8'h20;
            img[a+8] = "P"; img[a+9] = "C"; img[a+10] = "M";
            img[a+11] = 8'h20;
            put16(a+26, 16'd9);
            put32(a+28, 32'd4096);
        end
    endtask

    initial begin
        #20_000_000;
        $display("FAIL scanner_pcm: timeout");
        $fatal(1);
    end

endmodule
