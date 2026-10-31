`timescale 1ns/1ps
// Real fixture bytes drive both production RTL modules; no filesystem model
// substitutes for either scanner or streamer. Python checks captured bytes.
module tb_fat32_fixture_matrix;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, scan_start=0, file_start=0, stream_owner=0;
  wire scan_busy,scan_done,fs_ready,scan_req,file_busy,file_done,file_valid,file_req;
  wire [7:0] scan_error,file_error,file_byte;
  wire [31:0] scan_lba,file_lba,file_offset,part,root,fat,data_start,max_cluster;
  wire [7:0] spc; wire [3:0] resources;
  wire [31:0] c0,c1,c2,c3,s0,s1,s2,s3;
  reg [31:0] first_cluster,file_size;
  reg [7:0] mem[0:65535];
  reg serving=0; integer pos=0,base=0,requests=0,cycle=0;
  integer image_bytes,expect_scan_error,expect_file_error,expect_root;
  wire req=stream_owner ? file_req : scan_req;
  wire [31:0] lba=stream_owner ? file_lba : scan_lba;
  wire sector_done=serving && pos==511;
  wire [7:0] sector_byte=serving ? mem[base+pos] : 8'd0;
  wire [8:0] sector_index=pos;
  fat32_volume_scanner #(.MAX_DIR_CLUSTERS(8)) scanner(
    .clk(clk),.rst_n(rst_n),.scan_start(scan_start),.sector_link_ready(1'b1),
    .scan_busy(scan_busy),.scan_done(scan_done),.fs_ready(fs_ready),.fs_error(scan_error),
    .partition_lba(part),.root_cluster(root),.sectors_per_cluster(spc),
    .fat_start_lba(fat),.data_start_lba(data_start),.max_cluster(max_cluster),
    .resource_valid(resources),.resource_cluster0(c0),.resource_cluster1(c1),
    .resource_cluster2(c2),.resource_cluster3(c3),.resource_size0(s0),
    .resource_size1(s1),.resource_size2(s2),.resource_size3(s3),
    .sector_req(scan_req),.sector_lba(scan_lba),.sector_busy(serving),
    .sector_valid(serving && !stream_owner),.sector_byte(sector_byte),
    .sector_byte_index(sector_index),.sector_done(sector_done && !stream_owner),
    .sector_error(8'd0),.sector_abort(1'b0));
  fat32_file_streamer #(.MAX_VISITED_CLUSTERS(8)) streamer(
    .clk(clk),.rst_n(rst_n),.file_start(file_start),.first_cluster(first_cluster),
    .file_size(file_size),.sectors_per_cluster(spc),.fat_start_lba(fat),
    .data_start_lba(data_start),.max_cluster(max_cluster),.file_busy(file_busy),
    .file_done(file_done),.file_valid(file_valid),.file_byte(file_byte),
    .file_byte_offset(file_offset),.fs_error(file_error),.sector_req(file_req),
    .sector_lba(file_lba),.sector_busy(serving),.sector_valid(serving && stream_owner),
    .sector_byte(sector_byte),.sector_byte_index(sector_index),
    .sector_done(sector_done && stream_owner),.sector_error(8'd0),.sector_abort(1'b0));
  always @(posedge clk) begin
    cycle<=cycle+1;
    if(cycle>200000) $fatal(1,"fixture watchdog");
    if(req) begin
      if(serving) $fatal(1,"request overlaps active sector");
      if(lba*512+511>=image_bytes) $fatal(1,"LBA outside actual image: %0d",lba);
      serving<=1; pos<=0; base<=lba*512; requests<=requests+1;
    end else if(serving) begin
      if(pos==511) serving<=0; else pos<=pos+1;
    end
  end
  string image_path,output_path;
  integer fd,i,n,count,total=0,done_seen;
  initial begin
    if(!$value$plusargs("IMAGE=%s",image_path) ||
       !$value$plusargs("OUTPUT=%s",output_path) ||
       !$value$plusargs("IMAGE_BYTES=%d",image_bytes) ||
       !$value$plusargs("SCAN_ERROR=%d",expect_scan_error) ||
       !$value$plusargs("FILE_ERROR=%d",expect_file_error) ||
       !$value$plusargs("ROOT=%d",expect_root)) $fatal(1,"missing fixture arguments");
    $readmemh(image_path,mem,0,image_bytes-1);
    fd=$fopen(output_path,"wb"); if(!fd) $fatal(1,"cannot open capture");
    repeat(4) @(negedge clk); rst_n=1;
    @(negedge clk); scan_start=1;
    @(negedge clk); scan_start=0;
    wait(scan_done); @(negedge clk);
    if(scan_busy || scan_error!==expect_scan_error[7:0])
      $fatal(1,"scanner error got=%0d expected=%0d busy=%b",scan_error,expect_scan_error,scan_busy);
    if(expect_scan_error!=0) begin
      if(fs_ready) $fatal(1,"invalid scan declared ready");
      $display("FIXTURE_PASS scan_error=%0d bytes=0 requests=%0d",scan_error,requests);
      $fclose(fd); $finish;
    end
    if(!fs_ready || resources!==4'b1111 || root!=expect_root)
      $fatal(1,"layout/resources rejected ready=%b mask=%b root=%0d",fs_ready,resources,root);
    $display("LAYOUT part=%0d root=%0d fat=%0d data=%0d max=%0d",part,root,fat,data_start,max_cluster);
    // A directory end marker may finish parsing before its sector transport
    // drains. Preserve transaction ownership until the complete sector ends.
    wait(!serving); @(negedge clk);
    stream_owner=1;
    for(n=0;n<4;n=n+1) begin
      case(n)
        0: begin first_cluster=c0; file_size=s0; end
        1: begin first_cluster=c1; file_size=s1; end
        2: begin first_cluster=c2; file_size=s2; end
        3: begin first_cluster=c3; file_size=s3; end
      endcase
      count=0; done_seen=0;
      @(negedge clk); file_start=1;
      @(negedge clk); file_start=0;
      wait(file_busy);
      while(file_busy || file_valid || file_done) begin
        @(negedge clk);
        if(file_valid) begin
          if(file_offset!=count || count>=file_size) $fatal(1,"file offset/size mismatch");
          $fwrite(fd,"%c",file_byte); count=count+1; total=total+1;
        end
        if(file_done) done_seen=done_seen+1;
      end
      $display("FILE index=%0d cluster=%0d size=%0d bytes=%0d error=%0d done=%0d",n,first_cluster,file_size,count,file_error,done_seen);
      if(expect_file_error!=0 && n==0) begin
        if(file_error!==expect_file_error[7:0] || done_seen!=0)
          $fatal(1,"corrupt chain reported success or wrong error");
        n=4;
      end else if(file_error!=0 || done_seen!=1 || count!=file_size)
        $fatal(1,"valid file failed or truncated");
    end
    repeat(3) @(negedge clk);
    if(file_valid || file_done || file_busy) $fatal(1,"late file activity");
    $display("FIXTURE_PASS scan_error=%0d bytes=%0d requests=%0d",scan_error,total,requests);
    $fclose(fd); $finish;
  end
endmodule
