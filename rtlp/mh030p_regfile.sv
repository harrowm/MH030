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
// reads to three: rd_prev_a/b/c in the old file exist solely to serve the
// zero-gap preview mechanism this core deliberately does not have. The third
// port here is a genuine need -- an indexed EA reads base, index and ALU
// operand in the same cycle.
//
// The read port is WRITE-FIRST: a read issued in the same cycle as a write to
// the same register returns the new value. That is not cosmetic. With four
// stages the read-to-use distance is long enough that an instruction three
// behind its producer would otherwise miss it entirely -- its read is issued
// in the very cycle the producer commits, and by the time it reaches EX the
// commit has fallen out of both forwarding levels. Bypassing here keeps the
// core's forwarding at two levels instead of three.
//
// The bypass compares addresses and muxes write data into the READ REGISTER's
// input, so the output is still a plain flip-flop -- no combinational path
// from write data to read data.
// =============================================================================

module mh030p_regfile (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Read: address in this cycle, data out the next. rd_en must go low
    // whenever the consuming stage is stalled -- these outputs are single
    // registers shared by the whole pipeline, so a stalled instruction's
    // operand is otherwise overwritten by the read the NEXT instruction
    // issues while it waits.
    input  wire        rd_en,
    // Port C has its OWN enable. The A and B ports must freeze during a stall
    // so a held instruction's operands are not overwritten, but a MOVEM walks
    // a different register through C on every cycle OF that stall -- a shared
    // enable would hand it the same register every time.
    input  wire        rd_c_en,
    input  wire [3:0]  rd_a_sel,
    input  wire [3:0]  rd_b_sel,
    // Third port, for the index register of an indexed effective address:
    // (d8,An,Xn) needs the base, the index AND the ALU operand at once.
    input  wire [3:0]  rd_c_sel,
    // Fourth port, for the index register of an indexed DESTINATION effective
    // address. A memory-to-memory MOVE with (d8,An,Xn) at both ends needs four
    // registers in the same cycle -- two bases and two indices -- and the port
    // is the cheap way to have them: one more 16-to-1 mux and one more
    // register, against a stall on an instruction that already costs several
    // cycles. It freezes with A and B, since it belongs to the same held
    // instruction's operands.
    input  wire [3:0]  rd_d_sel,
    output reg  [31:0] rd_a_data,
    output reg  [31:0] rd_b_data,
    output reg  [31:0] rd_c_data,
    output reg  [31:0] rd_d_data,

    // Write (commit stage).
    input  wire        wr_en,
    input  wire [3:0]  wr_sel,
    input  wire [31:0] wr_data,
    // SECOND write port. Three instructions genuinely commit two registers at
    // once and cannot be expressed with one: EXG swaps a pair, LINK sets both
    // the frame pointer and the stack pointer, UNLK restores both. Sequencing
    // them over two cycles instead was the alternative, and it would have cost
    // a stall on every one of them to save a port the device has 74,000 spare
    // flip-flops' worth of room for.
    //
    // Port 1 WINS a same-register conflict, which is not arbitrary: UNLK A7
    // sets A7 from An and then pops into An, and since they are the same
    // register the popped value -- port 1 -- is the architectural result.
    input  wire        wr2_en,
    input  wire [3:0]  wr2_sel,
    input  wire [31:0] wr2_data
);

    reg [31:0] regs [0:15];

    integer i;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) regs[i] <= 32'h0;
        end else begin
            if (wr2_en) regs[wr2_sel] <= wr2_data;
            if (wr_en)  regs[wr_sel]  <= wr_data;   // port 1 wins; see above
        end
    end

    // Registered, write-first reads (see the header).
    wire hit_a  = wr_en && (wr_sel == rd_a_sel);
    wire hit_b  = wr_en && (wr_sel == rd_b_sel);
    wire hit_c  = wr_en && (wr_sel == rd_c_sel);
    wire hit_d  = wr_en && (wr_sel == rd_d_sel);
    wire hit2_a = wr2_en && (wr2_sel == rd_a_sel);
    wire hit2_b = wr2_en && (wr2_sel == rd_b_sel);
    wire hit2_c = wr2_en && (wr2_sel == rd_c_sel);
    wire hit2_d = wr2_en && (wr2_sel == rd_d_sel);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rd_a_data <= 32'h0;
            rd_b_data <= 32'h0;
            rd_c_data <= 32'h0;
            rd_d_data <= 32'h0;
        end else begin
            if (rd_en) begin
                rd_a_data <= hit_a ? wr_data
                           : hit2_a ? wr2_data : regs[rd_a_sel];
                rd_b_data <= hit_b ? wr_data
                           : hit2_b ? wr2_data : regs[rd_b_sel];
                rd_d_data <= hit_d ? wr_data
                           : hit2_d ? wr2_data : regs[rd_d_sel];
            end
            if (rd_c_en) rd_c_data <= hit_c ? wr_data
                                    : hit2_c ? wr2_data : regs[rd_c_sel];
        end
    end

endmodule

`default_nettype wire
