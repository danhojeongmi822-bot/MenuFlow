
module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,
    input  wire        I_ready,

    output wire        O_video_user,
    output wire        O_video_valid,
    output wire        O_video_last,
    output wire [23:0] O_video_data,
    output reg         O_overflow
);

localparam FIFO_DEPTH = 16;
localparam FIFO_PTR_W = 4;
localparam FIFO_COUNT_W = 5;

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;
reg [FIFO_PTR_W-1:0] S_wr_ptr;
reg [FIFO_PTR_W-1:0] S_rd_ptr;
reg [FIFO_COUNT_W-1:0] S_count;
reg [25:0] S_fifo [0:FIFO_DEPTH-1];
wire S_pop = (S_count != 0) && I_ready;
wire S_push = I_de && ((S_count < FIFO_DEPTH) || S_pop);

assign O_video_valid = (S_count != 0);
assign {O_video_user, O_video_last, O_video_data} = S_fifo[S_rd_ptr];

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        S_wr_ptr      <= {FIFO_PTR_W{1'b0}};
        S_rd_ptr      <= {FIFO_PTR_W{1'b0}};
        S_count       <= {FIFO_COUNT_W{1'b0}};
        O_overflow    <= 1'b0;
    end
    else begin
        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        if (I_de && !S_push) begin
            O_overflow <= 1'b1;
`ifndef SYNTHESIS
            $error("video AXIS FIFO overflow");
`endif
        end

        if (S_push) begin
            S_fifo[S_wr_ptr] <= {((!S_de_1d && S_frame_arm) ? 1'b1 : 1'b0),
                                 (I_de && (S_x_cnt == 11'd639)), I_rgb};
            S_wr_ptr <= S_wr_ptr + 1'b1;
        end
        if (S_pop)
            S_rd_ptr <= S_rd_ptr + 1'b1;
        case ({S_push, S_pop})
            2'b10: S_count <= S_count + 1'b1;
            2'b01: S_count <= S_count - 1'b1;
            default: S_count <= S_count;
        endcase

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                // Count the first pixel now; TLAST coincides with pixel 639.
                S_x_cnt <= 11'd1;
                if (S_frame_arm) begin
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule
