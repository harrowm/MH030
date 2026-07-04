`default_nettype none
`timescale 1ns / 1ps

// Parameterised memory model for MC68030 BIU testbench
//
// Responds with DSACK0/DSACK1 rather than DTACK (BIU-013).
// Port width and latency are set per instance via parameters.
//
// Response modes (set by PORT_WIDTH parameter):
//   32  → DSACK1=0, DSACK0=0 (32-bit port, cycle complete)
//   16  → DSACK1=0, DSACK0=1 (16-bit port — triggers sizing FSM in Phase 3)
//    8  → DSACK1=1, DSACK0=0 ( 8-bit port — triggers sizing FSM in Phase 3)
//
// WAIT_STATES controls how many extra bus clocks the model holds DSACK=11
// before asserting the real response (simulates slow memory).
//
// For reads, the model returns the data at the requested word address.
// For writes, the model stores data to the internal memory array.
// The model assumes a 32-bit bus; for sub-longword transfers, the caller
// is responsible for presenting the correct lanes (SIZ/A tracking is
// future work in Phase 3).

module mem_model #(
    parameter int DEPTH      = 256,   // words (32-bit longwords)
    parameter int PORT_WIDTH = 32,    // 8, 16, or 32
    parameter int WAIT_STATES = 0     // extra wait states before DSACK
) (
    input  logic        clk_4x,
    input  logic        rst_n,

    // External bus inputs (driven by biu_cycle_gen)
    input  logic [31:0] ext_a,
    input  logic        ext_as_n,
    input  logic        ext_ds_n,       // Data Strobe (68030 single DS pin)
    input  logic        ext_rw,
    input  logic [1:0]  ext_siz,

    // External bus outputs (driven by this model to the BIU)
    output logic [31:0] ext_d_in,    // read data presented to BIU
    output logic        dsack0_n,    // DSACK0 to BIU (active-low)
    output logic        dsack1_n,    // DSACK1 to BIU (active-low)

    // Write data from BIU (valid when ext_d_oe=1 from cycle_gen)
    input  logic [31:0] ext_d_write, // write data to capture
    input  logic        ext_d_oe     // 1 = BIU is driving write data
);

    // -----------------------------------------------------------------------
    // Memory array (word-addressed, 32-bit wide)
    // Pre-load index 0 with a recognisable SSP and index 1 with a PC
    // -----------------------------------------------------------------------
    logic [31:0] mem [0:DEPTH-1];

    initial begin : mem_init
        integer i;
        for (i = 0; i < DEPTH; i++) mem[i] = 32'h0;
        mem[0] = 32'hDEAD_BEF0;   // SSP (loaded from addr $00000000)
        mem[1] = 32'hCAFE_0010;   // PC  (loaded from addr $00000004)
    end

    // -----------------------------------------------------------------------
    // Response state machine
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        MS_IDLE   = 2'd0,
        MS_WAIT   = 2'd1,   // holding DSACK=11 for WAIT_STATES clocks
        MS_ACK    = 2'd2    // driving real DSACK response
    } mem_state_t;

    mem_state_t ms, ms_nxt;
    int         wait_cnt;
    logic [31:0] d_latch;
    logic        active;    // AS and DS both asserted

    assign active = !ext_as_n & !ext_ds_n;

    // Address decomposition for sub-longword and narrow-port accesses
    logic [31:0] word_addr;    // longword index (byte_addr >> 2)
    logic [31:0] half_addr;    // halfword index (byte_addr >> 1)
    logic [31:0] byte_addr_w;  // byte index

    assign word_addr   = ext_a[31:2];
    assign half_addr   = ext_a[31:1];
    assign byte_addr_w = ext_a[31:0];

    // Data extracted from memory for the current sub-cycle, placed on the
    // correct bus lane for the port width.
    function automatic logic [31:0] read_lane(
        input logic [31:0] mem_word,
        input logic [1:0]  byte_off  // ext_a[1:0]
    );
        case (PORT_WIDTH)
            16: begin
                // Upper halfword when A[1]=0, lower when A[1]=1 — both on D[31:16]
                if (!byte_off[1])
                    read_lane = {mem_word[31:16], 16'h0};
                else
                    read_lane = {mem_word[15:0],  16'h0};
            end
            8: begin
                // One byte on D[31:24]
                case (byte_off)
                    2'b00: read_lane = {mem_word[31:24], 24'h0};
                    2'b01: read_lane = {mem_word[23:16], 24'h0};
                    2'b10: read_lane = {mem_word[15:8],  24'h0};
                    2'b11: read_lane = {mem_word[7:0],   24'h0};
                    default: read_lane = 32'h0;
                endcase
            end
            default: read_lane = mem_word;  // 32-bit: full word
        endcase
    endfunction

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ms       <= MS_IDLE;
            wait_cnt <= 0;
            d_latch  <= 32'h0;
        end else begin
            ms <= ms_nxt;
            case (ms)
                MS_IDLE: begin
                    if (active) begin
                        wait_cnt <= WAIT_STATES;
                        if (ext_rw) begin // read
                            if (word_addr < DEPTH)
                                d_latch <= read_lane(mem[word_addr], ext_a[1:0]);
                            else
                                d_latch <= 32'hDEAD_DEAD;
                        end
                    end
                end
                MS_WAIT: begin
                    if (wait_cnt > 0)
                        wait_cnt <= wait_cnt - 1;
                end
                MS_ACK: begin
                    // Write: capture the correct lane from the BIU's write bus
                    if (!ext_rw && active && ext_d_oe && word_addr < DEPTH) begin
                        case (PORT_WIDTH)
                            16: begin
                                // Data always on D[31:16]; write to correct half by A[1]
                                if (!ext_a[1])
                                    mem[word_addr][31:16] <= ext_d_write[31:16];
                                else
                                    mem[word_addr][15:0]  <= ext_d_write[31:16];
                            end
                            8: begin
                                // Data always on D[31:24]; write to correct byte by A[1:0]
                                case (ext_a[1:0])
                                    2'b00: mem[word_addr][31:24] <= ext_d_write[31:24];
                                    2'b01: mem[word_addr][23:16] <= ext_d_write[31:24];
                                    2'b10: mem[word_addr][15:8]  <= ext_d_write[31:24];
                                    2'b11: mem[word_addr][7:0]   <= ext_d_write[31:24];
                                endcase
                            end
                            default: begin
                                // 32-bit port: biu_byte_lane_ctrl replicates data on all
                                // active lanes; use SIZ+A[1:0] for byte-selective writes.
                                // Data convention: byte in [31:24], word in [31:16], LW in [31:0].
                                case ({ext_siz, ext_a[1:0]})
                                    // Longword: write all four bytes
                                    4'b0000: mem[word_addr] <= ext_d_write;
                                    // Line burst (SIZ=11): always full longword per beat
                                    4'b1100, 4'b1101, 4'b1110, 4'b1111:
                                        mem[word_addr] <= ext_d_write;
                                    // Word at A[1]=0 (upper half)
                                    4'b1000: mem[word_addr][31:16] <= ext_d_write[31:16];
                                    // Word at A[1]=1 (lower half); data replicated on [15:0] too
                                    4'b1010: mem[word_addr][15:0]  <= ext_d_write[15:0];
                                    // Bytes: replicated on all lanes; use A[1:0] to select target
                                    4'b0100: mem[word_addr][31:24] <= ext_d_write[31:24];
                                    4'b0101: mem[word_addr][23:16] <= ext_d_write[23:16];
                                    4'b0110: mem[word_addr][15:8]  <= ext_d_write[15:8];
                                    4'b0111: mem[word_addr][7:0]   <= ext_d_write[7:0];
                                    default: mem[word_addr] <= ext_d_write;
                                endcase
                            end
                        endcase
                    end
                end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------------
    always_comb begin
        ms_nxt = ms;
        case (ms)
            MS_IDLE: if (active) ms_nxt = (WAIT_STATES > 0) ? MS_WAIT : MS_ACK;
            MS_WAIT: if (wait_cnt == 0) ms_nxt = MS_ACK;
            MS_ACK:  if (!active) ms_nxt = MS_IDLE;  // deassert when AS/DS release
            default: ms_nxt = MS_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Output drive
    // -----------------------------------------------------------------------
    always_comb begin
        dsack0_n = 1'b1;   // deasserted
        dsack1_n = 1'b1;
        ext_d_in = 32'h0;

        case (ms)
            MS_ACK: begin
                // Drive DSACK based on port width
                case (PORT_WIDTH)
                    32: begin dsack0_n = 1'b0; dsack1_n = 1'b0; end  // 32-bit
                    16: begin dsack0_n = 1'b0; dsack1_n = 1'b1; end  // 16-bit
                     8: begin dsack0_n = 1'b1; dsack1_n = 1'b0; end  //  8-bit
                    default: begin dsack0_n = 1'b0; dsack1_n = 1'b0; end
                endcase
                // Provide read data (write data is provided by BIU on ext_d_out)
                if (ext_rw) ext_d_in = d_latch;
            end
            default: ; // MS_IDLE, MS_WAIT: DSACK held deasserted (wait state)
        endcase
    end

    // -----------------------------------------------------------------------
    // Write capture (for Phase 3+ write testing)
    // -----------------------------------------------------------------------
    // The write data from the BIU is on a separate port (ext_d_out / ext_d_oe
    // in m68030_biu). For the testbench, the tb wires ext_d_out directly to
    // ext_d_in of the memory model when ext_d_oe is high.

endmodule

`default_nettype wire
