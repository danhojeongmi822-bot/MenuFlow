`timescale 1ns/1ps
// 单扇区读取的仲裁器（唯一 SD 访问出口）。
//
// 三个 owner：
//   1 = scanner   目录 / FAT 扫描（启动与恢复时短暂的突发）
//   2 = audio     PCM 文件流（高水位自限，每次补读不超过若干扇区）
//   3 = bmp       BMP 文件流（加载期间接近连续的请求）
//
// 公平性：
//   * 仲裁粒度为“一个扇区”，因此任何 owner 都不会长期独占。
//   * 非扫描 owner 连续获准 GRANT_LIMIT 次后，若还有其他 owner 在请求，则让位一次，
//     防止 BMP 连续加载把音频压到 FIFO 下溢，也防止音频突发饿死 BMP。
//   * scanner 是短事务（数扇区），不参与计数，但同样受“每扇区重新仲裁”约束。
//
// 释放契约：A_RELEASE 保持完整一拍，避免恢复后残留 end/data 脉冲被重新认领。
module sd_sector_adapter #(
    parameter integer TIMEOUT_CYCLES = 200000,
    parameter integer GRANT_LIMIT    = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        scanner_req,
    input  wire [31:0] scanner_lba,
    output wire        scanner_busy,
    output wire        scanner_valid,
    output wire [7:0]  scanner_byte,
    output wire [8:0]  scanner_byte_index,
    output wire        scanner_done,
    output wire [7:0]  scanner_error,
    output wire        scanner_abort,

    input  wire        streamer_req,
    input  wire [31:0] streamer_lba,
    output wire        streamer_busy,
    output wire        streamer_valid,
    output wire [7:0]  streamer_byte,
    output wire [8:0]  streamer_byte_index,
    output wire        streamer_done,
    output wire [7:0]  streamer_error,
    output wire        streamer_abort,

    input  wire        audio_req,
    input  wire [31:0] audio_lba,
    output wire        audio_busy,
    output wire        audio_valid,
    output wire [7:0]  audio_byte,
    output wire [8:0]  audio_byte_index,
    output wire        audio_done,
    output wire [7:0]  audio_error,
    output wire        audio_abort,

    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,
    input  wire [7:0]  sd_sec_read_error,
    input  wire        sd_sec_read_abort
);
    localparam A_IDLE    = 2'd0;
    localparam A_ACTIVE  = 2'd1;
    localparam A_RELEASE = 2'd2;

    localparam OWN_NONE = 2'd0;
    localparam OWN_SCAN = 2'd1;
    localparam OWN_AUD  = 2'd2;
    localparam OWN_BMP  = 2'd3;

    reg [1:0]  state, owner;
    reg [31:0] timer;
    reg [8:0]  byte_index;
    reg        done_pulse, abort_pulse;
    reg [7:0]  error_pulse;

    // 公平性：rotate 只由“上一笔事务结束时锁存的计数”决定，避免把
    // grant_count 的比较直接并入 A_IDLE 的组合仲裁路径。
    reg [1:0]  last_owner;
    reg [3:0]  grant_count;
    reg        rotate_q;
    wire       rotate = rotate_q;

    assign scanner_busy  = (state != A_IDLE) && (owner == OWN_SCAN);
    assign streamer_busy = (state != A_IDLE) && (owner == OWN_BMP);
    assign audio_busy    = (state != A_IDLE) && (owner == OWN_AUD);

    assign scanner_valid  = (state == A_ACTIVE) && (owner == OWN_SCAN) && sd_sec_read_data_valid;
    assign streamer_valid = (state == A_ACTIVE) && (owner == OWN_BMP)  && sd_sec_read_data_valid;
    assign audio_valid    = (state == A_ACTIVE) && (owner == OWN_AUD)  && sd_sec_read_data_valid;

    assign scanner_byte  = sd_sec_read_data;
    assign streamer_byte = sd_sec_read_data;
    assign audio_byte    = sd_sec_read_data;

    assign scanner_byte_index  = byte_index;
    assign streamer_byte_index = byte_index;
    assign audio_byte_index    = byte_index;

    assign scanner_done  = (state == A_RELEASE) && (owner == OWN_SCAN) && done_pulse;
    assign streamer_done = (state == A_RELEASE) && (owner == OWN_BMP)  && done_pulse;
    assign audio_done    = (state == A_RELEASE) && (owner == OWN_AUD)  && done_pulse;

    assign scanner_abort  = (state == A_RELEASE) && (owner == OWN_SCAN) && abort_pulse;
    assign streamer_abort = (state == A_RELEASE) && (owner == OWN_BMP)  && abort_pulse;
    assign audio_abort    = (state == A_RELEASE) && (owner == OWN_AUD)  && abort_pulse;

    assign scanner_error  = ((state == A_RELEASE) && (owner == OWN_SCAN)) ? error_pulse : 8'd0;
    assign streamer_error = ((state == A_RELEASE) && (owner == OWN_BMP))  ? error_pulse : 8'd0;
    assign audio_error    = ((state == A_RELEASE) && (owner == OWN_AUD))  ? error_pulse : 8'd0;

    // ------------------------- 仲裁选择 -------------------------
    // 扫描优先（它的突发短且关系到开机可用性）；随后在音频与 BMP 之间轮转。
    reg [1:0] pick;
    always @* begin
        pick = OWN_NONE;
        if (rotate && (last_owner != OWN_NONE)) begin
            // 刚被连续服务过的 owner 让位一次
            if (last_owner == OWN_AUD) begin
                if (streamer_req) pick = OWN_BMP;
            end else if (last_owner == OWN_BMP) begin
                if (audio_req) pick = OWN_AUD;
            end
            if (pick == OWN_NONE) begin
                if (scanner_req)      pick = OWN_SCAN;
                else if (audio_req)   pick = OWN_AUD;
                else if (streamer_req) pick = OWN_BMP;
            end
        end else begin
            if (scanner_req)      pick = OWN_SCAN;
            else if (audio_req)   pick = OWN_AUD;
            else if (streamer_req) pick = OWN_BMP;
        end
    end

    wire [31:0] pick_lba = (pick == OWN_SCAN) ? scanner_lba :
                           (pick == OWN_AUD)  ? audio_lba   :
                           (pick == OWN_BMP)  ? streamer_lba : 32'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= A_IDLE;
            owner         <= OWN_NONE;
            sd_sec_read   <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            timer         <= 32'd0;
            byte_index    <= 9'd0;
            done_pulse    <= 1'b0;
            abort_pulse   <= 1'b0;
            error_pulse   <= 8'd0;
            last_owner    <= OWN_NONE;
            grant_count   <= 4'd0;
            rotate_q      <= 1'b0;
        end else begin
            case (state)
                A_IDLE: begin
                    sd_sec_read  <= 1'b0;
                    done_pulse   <= 1'b0;
                    abort_pulse  <= 1'b0;
                    error_pulse  <= 8'd0;
                    timer        <= 32'd0;
                    byte_index   <= 9'd0;
                    if (pick != OWN_NONE) begin
                        owner            <= pick;
                        sd_sec_read_addr <= pick_lba;
                        sd_sec_read      <= 1'b1;
                        state            <= A_ACTIVE;
                        if (pick != OWN_SCAN) begin
                            if (pick == last_owner)
                                grant_count <= grant_count + 4'd1;
                            else
                                grant_count <= 4'd1;
                            last_owner <= pick;
                        end
                        rotate_q <= (pick != OWN_SCAN) && (pick == last_owner) &&
                                    (grant_count + 4'd1 >= GRANT_LIMIT);
                    end
                end
                A_ACTIVE: begin
                    timer <= timer + 32'd1;
                    if (sd_sec_read_data_valid)
                        byte_index <= byte_index + 9'd1;
                    if (sd_sec_read_error != 8'd0) begin
                        error_pulse <= sd_sec_read_error;
                        sd_sec_read <= 1'b0;
                        state       <= A_RELEASE;
                    end else if (sd_sec_read_abort) begin
                        abort_pulse <= 1'b1;
                        sd_sec_read <= 1'b0;
                        state       <= A_RELEASE;
                    end else if (sd_sec_read_end) begin
                        done_pulse  <= 1'b1;
                        sd_sec_read <= 1'b0;
                        state       <= A_RELEASE;
                    end else if (timer >= TIMEOUT_CYCLES - 1) begin
                        error_pulse <= 8'h08;
                        abort_pulse <= 1'b1;
                        sd_sec_read <= 1'b0;
                        state       <= A_RELEASE;
                    end
                end
                A_RELEASE: begin
                    // 完整一拍间隔，防止恢复后的残留脉冲被新事务误认领
                    done_pulse  <= 1'b0;
                    abort_pulse <= 1'b0;
                    error_pulse <= 8'd0;
                    owner       <= OWN_NONE;
                    state       <= A_IDLE;
                end
                default: state <= A_IDLE;
            endcase
        end
    end

endmodule
