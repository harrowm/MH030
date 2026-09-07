`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Exception Frame Capture
//
// Captures fault snapshot from biu_cycle_gen at the moment fault_valid asserts
// and determines which of the 9 68030 exception stack frame formats applies.
//
// Frame format determination:
//   !fault_rw                            →  $B  (bus error during write)
//   otherwise (read or fetch BERR)       →  $A  (bus error during read/fetch)
//
// docs/*.md review (Phase 250 F5): mmu_fault previously selected a
// fabricated $9 ("MMU short bus fault", 12 words) that does not exist on
// real MC68030 silicon -- confirmed directly against MC68030UM.pdf Table
// 8-6: the real Format $9 is the unrelated 10-word Coprocessor
// Mid-Instruction frame (Coprocessor Mid-Instruction / Main-Detected
// Protocol Violation / Interrupt Detected During Coprocessor Instruction
// -- none of which this project implements). Real MMU-detected bus faults
// use the SAME ordinary $A/$B bus-fault frames as any other bus error --
// the MMU has no dedicated frame format of its own; it's distinguished
// only by the fault having originated from a translation failure, not by
// a different stack frame shape. mmu_fault is therefore now simply
// ignored by determine_format() below (an MMU fault selects $A/$B via the
// exact same fault_rw rule every other bus error already uses); the port
// is left in place since biu_mmu_if.sv still needs to report the fault
// upstream for other purposes (SSW's DF bit etc.), just no longer feeds a
// format decision.
//
// SSW (Special Status Word) for bus-fault formats $A/$B.
//
// SSW bit layout (68030 hardware definition):
//   [15:13] FC[2:0]         — function code at fault time
//   [12]    RW              — 1=read, 0=write
//   [11]    DF              — data fault: 1 if FC==user_data(001) or sup_data(101)
//   [10]    RM              — read-modify-write: 1 if fault in RMW write phase
//   [9:8]   SZ[1:0]         — transfer size (SIZ encoding)
//   [7:6]   0               — reserved
//   [5]     FC (pipe C)     — pipeline stage C active (0 until EU integrated)
//   [4]     FB (pipe B)     — pipeline stage B active (0 until EU integrated)
//   [3]     RC              — retry cycle: 1 if this was a BERR on a retry
//   [2:0]   0               — reserved

module biu_exc_capture (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Fault snapshot from biu_cycle_gen
    input  logic        fault_valid,
    input  logic [31:0] fault_addr,
    input  logic [31:0] fault_data,
    input  logic [2:0]  fault_fc,
    input  logic        fault_rw,
    input  logic [1:0]  fault_siz,

    // Fault qualifiers (from biu_cycle_gen)
    input  logic        fault_retry,     // 1 = fault occurred during a retry cycle (RC bit)
    input  logic        fault_is_rmw,    // 1 = fault occurred during RMW write phase (RM bit)

    // Pipeline stage activity (stub: tie to 0 until EU is integrated)
    input  logic        pipe_b_active,   // 1 = pipeline stage B was active (FB bit)
    input  logic        pipe_c_active,   // 1 = pipeline stage C was active (FC bit)

    // MMU fault (from biu_mmu_if)
    input  logic        mmu_fault,

    // Captured outputs (registered, hold until fault_valid deasserts)
    output logic [3:0]  frame_format,
    output logic        frame_valid,
    output logic [31:0] frame_fault_addr,
    output logic [31:0] frame_fault_data,
    output logic [2:0]  frame_fault_fc,
    output logic        frame_fault_rw,
    output logic [1:0]  frame_fault_siz,

    // Pre-formatted frame word 0 (format/vector offset word pushed to stack):
    //   [15:12] = format code
    //   [11:0]  = vector offset (bus error = 0x008)
    output logic [15:0] frame_word0,

    // Special Status Word for stack frame population
    output logic [15:0] ssw
);

    function automatic logic [3:0] determine_format(
        input logic [2:0] fc,
        input logic       rw
    );
        if (!rw)        determine_format = 4'hB;   // bus error during write
        else            determine_format = 4'hA;   // bus error during read/fetch
    endfunction

    // DF bit: asserted for user data (001) or supervisor data (101) accesses
    logic data_fault;
    assign data_fault = (fault_fc == 3'b001) | (fault_fc == 3'b101);

    logic [15:0] ssw_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            frame_valid      <= 1'b0;
            frame_format     <= 4'h0;
            frame_fault_addr <= 32'h0;
            frame_fault_data <= 32'h0;
            frame_fault_fc   <= 3'b0;
            frame_fault_rw   <= 1'b1;
            frame_fault_siz  <= 2'b0;
            ssw_r            <= 16'h0;
        end else begin
            if (fault_valid) begin
                // frame_valid is sticky: once set it holds until reset.
                // The else-clear is intentionally absent — frame_valid must
                // not drop if fault_valid is ever deasserted externally.
                frame_valid      <= 1'b1;
                frame_format     <= determine_format(fault_fc, fault_rw);
                frame_fault_addr <= fault_addr;
                frame_fault_data <= fault_data;
                frame_fault_fc   <= fault_fc;
                frame_fault_rw   <= fault_rw;
                frame_fault_siz  <= fault_siz;
                ssw_r <= {fault_fc,
                          fault_rw,
                          data_fault,
                          fault_is_rmw,
                          fault_siz,
                          2'b00,
                          pipe_c_active,
                          pipe_b_active,
                          fault_retry,
                          3'b000};
            end
        end
    end

    assign frame_word0 = {frame_format, 12'h008};
    assign ssw         = ssw_r;

endmodule

`default_nettype wire
