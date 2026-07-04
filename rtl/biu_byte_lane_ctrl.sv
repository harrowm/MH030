`default_nettype none

// MC68030 BIU — Byte Lane Controller (Phase 8)
//
// The 68030 uses a single /DS pin (not /UDS+/LDS like the 68000).
// Byte-lane selection is conveyed to peripherals via SIZ[1:0] + A[1:0].
// This module steers EU write data to the correct bus lane position so
// that a peripheral reading D[31:0] sees the byte/word on the correct pins:
//
//   Byte:  replicate byte[7:0] on all four D[31:0] positions
//   Word:  replicate word[15:0] on both D[31:16] and D[15:0] halves
//   LW:    pass through unchanged
//   Line:  pass through unchanged (burst beat is always a longword)
//
// EU convention: byte in wdata_in[31:24], word in wdata_in[31:16], LW full.

module biu_byte_lane_ctrl (
    // Transfer descriptor
    input  logic [1:0]  siz,        // SIZ[1:0] from current cycle
    input  logic [1:0]  addr,       // A[1:0] from current cycle address (unused here,
                                    // retained for future byte-enable mask output)

    // EU write data (byte in [31:24], word in [31:16], LW in [31:0])
    input  logic [31:0] wdata_in,

    // Write data placed on the correct bus lane
    output logic [31:0] wdata_out
);

    always_comb begin
        case (siz)
            2'b00, 2'b11: wdata_out = wdata_in;  // LW / Line: no steering needed
            2'b10: begin  // Word: replicate word on both halves
                wdata_out = {wdata_in[31:16], wdata_in[31:16]};
            end
            2'b01: begin  // Byte: replicate byte on all four positions
                wdata_out = {wdata_in[31:24], wdata_in[31:24],
                             wdata_in[31:24], wdata_in[31:24]};
            end
            default: wdata_out = wdata_in;
        endcase
    end

endmodule

`default_nettype wire
