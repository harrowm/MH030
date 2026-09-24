`default_nettype none

// =============================================================================
// MH030-P register file: 16 x 32 (D0-D7 = 0-7, A0-A7 = 8-15).
//
// The one structural difference from rtl/eu_regfile.sv that matters, and the
// reason this file exists rather than reusing it: the read ports are
// REGISTERED. rtl/eu_regfile.sv reads combinationally, which puts the whole
// register file inside the same clock tick as the address ALU and the bus
// dispatch -- the ~3600-hop chain Phase 284 traced. Here the address is
// presented in ID and the data appears in EX, so the read is a clock boundary
// instead of part of a cone.
//
// That costs a cycle of latency, which is exactly what the forwarding network
// in mh030p_core.sv exists to hide. It also drops the port count from seven
// reads to two: rd_c and rd_prev_a/b/c in the old file exist solely to serve
// the zero-gap preview mechanism this core deliberately does not have.
//
// Write-during-read on the same register is resolved by the core's forwarding
// path, not here -- this file deliberately has no internal bypass, so the
// read port stays a plain registered read with no combinational path from
// write data to read data.
// =============================================================================

module mh030p_regfile (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Read: address in this cycle, data out the next.
    input  wire [3:0]  rd_a_sel,
    input  wire [3:0]  rd_b_sel,
    output reg  [31:0] rd_a_data,
    output reg  [31:0] rd_b_data,

    // Write (commit stage).
    input  wire        wr_en,
    input  wire [3:0]  wr_sel,
    input  wire [31:0] wr_data
);

    reg [31:0] regs [0:15];

    integer i;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) regs[i] <= 32'h0;
        end else if (wr_en) begin
            regs[wr_sel] <= wr_data;
        end
    end

    // Registered reads. No write-forwarding here on purpose; the core's
    // forwarding network covers the same-cycle case.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rd_a_data <= 32'h0;
            rd_b_data <= 32'h0;
        end else begin
            rd_a_data <= regs[rd_a_sel];
            rd_b_data <= regs[rd_b_sel];
        end
    end

endmodule

`default_nettype wire
