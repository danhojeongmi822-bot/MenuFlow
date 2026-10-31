`timescale 1ns/1ps

// A completed-bank request is transferred as a toggle.  The index and valid
// mask are held stable in the source domain until the next request.
module four_bank_frame_commit (
    input       pix_clk,
    input       pix_rst,
    input       frame_start,
    input       commit_toggle_mem,
    input [1:0] pending_index_mem,
    input [3:0] bank_valid_mem,
    output reg [1:0] active_index
);
    (* ASYNC_REG = "TRUE" *) reg toggle_meta, toggle_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] index_meta, index_sync;
    (* ASYNC_REG = "TRUE" *) reg [3:0] valid_meta, valid_sync;
    reg toggle_seen;

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            toggle_meta <= 1'b0;
            toggle_sync <= 1'b0;
            index_meta  <= 2'd0;
            index_sync  <= 2'd0;
            valid_meta  <= 4'd0;
            valid_sync  <= 4'd0;
        end else begin
            toggle_meta <= commit_toggle_mem;
            toggle_sync <= toggle_meta;
            index_meta  <= pending_index_mem;
            index_sync  <= index_meta;
            valid_meta  <= bank_valid_mem;
            valid_sync  <= valid_meta;
        end
    end

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            active_index <= 2'd0;
            toggle_seen  <= 1'b0;
        end else if (frame_start && toggle_sync != toggle_seen) begin
            if (valid_sync[index_sync]) begin
                active_index <= index_sync;
                toggle_seen  <= toggle_sync;
            end
        end
    end
endmodule
