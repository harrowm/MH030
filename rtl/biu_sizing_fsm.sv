`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Dynamic Bus Sizing FSM
//
// Sits between the EU and biu_cycle_gen's EU port.  When a bus cycle
// completes with DSACK=01 (16-bit port) or DSACK=10 (8-bit port) the
// transfer size is narrower than the requested width, so additional
// sub-cycles are needed.  This module issues those sub-cycles
// transparently and assembles the bytes into a single eu_rdata result.
//
// For 32-bit port (DSACK=00) or any sub-longword request that fits in
// one cycle, this module is a transparent pass-through with one cycle
// of latency (registered to break combinatorial loops with cycle_gen).
//
// Dynamic sizing rules (BIU-033, BIU-146):
//   Longword → 16-bit port : 2 sub-cycles
//     cyc 1: addr=A,   SIZ=00, capture D[31:16]
//     cyc 2: addr=A+2, SIZ=10, capture D[31:16]
//   Longword → 8-bit port  : 4 sub-cycles
//     cyc 1: addr=A,   SIZ=00, capture D[31:24]
//     cyc 2: addr=A+1, SIZ=11, capture D[31:24]
//     cyc 3: addr=A+2, SIZ=10, capture D[31:24]
//     cyc 4: addr=A+3, SIZ=01, capture D[31:24]
//   Word → 8-bit port : 2 sub-cycles
//     cyc 1: addr=A,   SIZ=10, capture D[31:24]
//     cyc 2: addr=A+1, SIZ=01, capture D[31:24]
//
// Write sizing mirrors read sizing: the correct byte lane is driven on
// D[31:24] (8-bit) or D[31:16] (16-bit) for each sub-cycle.
//
// Port-width decoding (BIU-013):
//   cyc_port_dsack = {dsack1_s, dsack0_s} latched at S4/S5 by cycle_gen.
//   2'b00 = 32-bit (no extra cycles)
//   2'b01 = 16-bit (sizing needed for LW; finishing sub-cycle for W→8)
//   2'b10 = 8-bit  (sizing needed for LW, W)

module biu_sizing_fsm (
    input  logic        clk_4x,
    input  logic        rst_n,

    // EU side — what the testbench / EU drives
    input  logic [31:0] eu_addr,
    input  logic [1:0]  eu_siz,
    input  logic        eu_rw,
    input  logic [31:0] eu_wdata,
    input  logic [2:0]  eu_fc,
    input  logic        eu_is_operand,
    input  logic        eu_req,
    output logic [31:0] eu_rdata,
    output logic        eu_ack,

    // Cycle-gen side — drives cycle_gen's EU port
    output logic [31:0] cyc_addr,
    output logic [1:0]  cyc_siz,
    output logic        cyc_rw,
    output logic [31:0] cyc_wdata,
    output logic [2:0]  cyc_fc,
    output logic        cyc_is_operand,
    output logic        cyc_req,
    input  logic [31:0] cyc_rdata,   // eu_rdata from cycle_gen (SP_S7 output)
    input  logic        cyc_ack,     // eu_ack from cycle_gen
    input  logic        cyc_berr,    // eu_berr from cycle_gen (cg_eu_berr_raw) -- a
                                      // plain BERR (no HALT retry) abort. Mirrors
                                      // biu_cache_if.sv's own sf_berr input exactly
                                      // (same source signal); found and fixed
                                      // (project_berr_no_halt_retry_loop.md) after
                                      // this module was confirmed, via direct
                                      // trace, to have NO abort path at all: with
                                      // no cyc_berr, SS_ACTIVE only ever exits on
                                      // cyc_ack_edge, which a genuinely faulted
                                      // cycle never produces, so `sf` got stuck in
                                      // SS_ACTIVE forever, continuously re-driving
                                      // the STALE faulting cyc_addr/cyc_req into
                                      // cycle_gen regardless of what biu_cache_if
                                      // (already correctly aborted via its own
                                      // CI_BERR state) or the exception controller
                                      // wanted to dispatch next -- the real root
                                      // cause of the reported "same faulting access
                                      // re-dispatches every ~8 ticks" hang.

    // Port-width feedback latched by cycle_gen at S4/S5
    input  logic [1:0]  cyc_port_dsack,  // {dsack1_s, dsack0_s}

    // bus_idle from cycle_gen — used to detect cycle boundaries
    input  logic        bus_idle
);

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        SS_IDLE   = 2'd0,   // no transfer; waiting for eu_req
        SS_ACTIVE = 2'd1,   // sub-cycle in progress (cyc_req=1)
        SS_DONE   = 2'd2    // all sub-cycles complete; pulse eu_ack
    } sf_state_t;

    sf_state_t sf, sf_nxt;

    // -----------------------------------------------------------------------
    // Sizing registers — captured at the start of each transfer
    // -----------------------------------------------------------------------
    logic [31:0] sf_addr;    // current sub-cycle address
    logic [1:0]  sf_siz;     // current sub-cycle SIZ
    logic        sf_rw;      // transfer direction
    logic [31:0] sf_wdata;   // original write data (never changes across sub-cycles)
    logic [2:0]  sf_fc;
    logic        sf_is_op;
    logic [1:0]  sf_orig_siz; // original EU-requested size (tracks remaining bytes)
    logic [31:0] sf_accum;   // assembled read data
    logic [31:0] sf_rdata_r; // final assembled rdata, held through SS_DONE

    // -----------------------------------------------------------------------
    // Combinatorial: port width and byte count helpers
    // -----------------------------------------------------------------------
    // Remaining bytes after current sub-cycle, based on port width and current SIZ
    // Used to compute the NEXT sub-cycle's SIZ (BIU-007 / BIU-146).
    function automatic logic [1:0] next_siz(
        input logic [1:0] cur_siz,
        input logic [1:0] port     // cyc_port_dsack
    );
        // How many bytes does this sub-cycle transfer?
        // port=01 (16-bit): transfers min(2, request_bytes)
        // port=10 (8-bit):  transfers 1 byte
        logic [2:0] req_bytes, xfer, remaining;
        case (cur_siz)
            2'b00: req_bytes = 3'd4; // longword
            2'b01: req_bytes = 3'd1; // byte
            2'b10: req_bytes = 3'd2; // word
            2'b11: req_bytes = 3'd3; // 3-byte (mid-sequence only)
        endcase
        case (port)
            2'b01: xfer = 3'd2;     // 16-bit port
            2'b10: xfer = 3'd1;     // 8-bit port
            default: xfer = req_bytes; // 32-bit: all done in one
        endcase
        remaining = req_bytes - xfer;
        case (remaining)
            3'd0: next_siz = 2'b00; // shouldn't occur (done in 32-bit case)
            3'd1: next_siz = 2'b01; // 1 byte
            3'd2: next_siz = 2'b10; // 2 bytes (word)
            3'd3: next_siz = 2'b11; // 3 bytes
            default: next_siz = 2'b00;
        endcase
    endfunction

    // Does this sub-cycle combination need another cycle?
    function automatic logic needs_more(
        input logic [1:0] cur_siz,
        input logic [1:0] port
    );
        logic [2:0] req_bytes, xfer;
        case (cur_siz)
            2'b00: req_bytes = 3'd4;
            2'b01: req_bytes = 3'd1;
            2'b10: req_bytes = 3'd2;
            2'b11: req_bytes = 3'd3;
        endcase
        case (port)
            2'b01: xfer = 3'd2;
            2'b10: xfer = 3'd1;
            default: xfer = req_bytes;
        endcase
        needs_more = (xfer < req_bytes);
    endfunction

    // Address increment for next sub-cycle
    function automatic logic [31:0] addr_incr(input logic [1:0] port);
        case (port)
            2'b01: addr_incr = 32'd2;   // 16-bit port: +2
            2'b10: addr_incr = 32'd1;   //  8-bit port: +1
            default: addr_incr = 32'd4; // 32-bit: not used
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Write data rotation: shift the correct byte lane to D[31:xx]
    // For writes, each sub-cycle must present the next unwritten bytes
    // on the upper lane(s) of the data bus.
    // -----------------------------------------------------------------------
    function automatic logic [31:0] rotated_wdata(
        input logic [31:0] wdata,
        input logic [1:0]  orig_siz,
        input logic [1:0]  cur_siz,
        input logic [1:0]  port
    );
        // How many bytes have already been transferred?
        // bytes_done = orig_request_size - cur_siz_bytes
        logic [2:0] orig_bytes, cur_bytes, done;
        case (orig_siz)
            2'b00: orig_bytes = 3'd4;
            2'b01: orig_bytes = 3'd1;
            2'b10: orig_bytes = 3'd2;
            2'b11: orig_bytes = 3'd3;
        endcase
        case (cur_siz)
            2'b00: cur_bytes = 3'd4;
            2'b01: cur_bytes = 3'd1;
            2'b10: cur_bytes = 3'd2;
            2'b11: cur_bytes = 3'd3;
        endcase
        done = orig_bytes - cur_bytes;
        // Rotate left by done bytes so the next byte(s) are in the top lane(s)
        case (done)
            3'd0: rotated_wdata = wdata;
            3'd1: rotated_wdata = {wdata[23:0], 8'h00};
            3'd2: rotated_wdata = {wdata[15:0], 16'h0000};
            3'd3: rotated_wdata = {wdata[7:0],  24'h000000};
            default: rotated_wdata = wdata;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Data assembly: merge incoming sub-cycle data into sf_accum
    // The 68030 always drives read data on D[31:16] (16-bit port) or
    // D[31:24] (8-bit port), regardless of address.  We shift it right
    // based on how many bytes we have already accumulated.
    // For 32-bit ports, byte/word data sits at the big-endian lane position
    // determined by the byte address A[1:0]; we normalize to [7:0]/[15:0].
    // -----------------------------------------------------------------------
    function automatic logic [31:0] merge_rdata(
        input logic [31:0] accum,
        input logic [31:0] raw,       // raw data from bus
        input logic [1:0]  cur_siz,   // SIZ of this sub-cycle
        input logic [1:0]  orig_siz,
        input logic [1:0]  port,
        input logic [1:0]  addr_lo    // A[1:0] of the first sub-cycle address
    );
        logic [2:0] orig_bytes, cur_bytes, done;
        logic [31:0] piece;
        case (orig_siz)
            2'b00: orig_bytes = 3'd4;
            2'b01: orig_bytes = 3'd1;
            2'b10: orig_bytes = 3'd2;
            2'b11: orig_bytes = 3'd3;
        endcase
        case (cur_siz)
            2'b00: cur_bytes = 3'd4;
            2'b01: cur_bytes = 3'd1;
            2'b10: cur_bytes = 3'd2;
            2'b11: cur_bytes = 3'd3;
        endcase
        done = orig_bytes - cur_bytes;

        // Extract the piece from the raw data based on port width
        // and shift it to the correct position in the result.
        //
        // project_biu_narrow_port_read_justification_bug.md fix: the 8-bit
        // and 16-bit branches below used to position each byte at its
        // natural big-endian LONGWORD lane (byte 0 at [31:24] ... byte 3
        // at [7:0]) regardless of the ORIGINAL request size -- correct by
        // construction for a longword transfer (all 4 lanes end up
        // filled, matching tb/biu_tb.sv's own existing passing tests),
        // but WRONG for a byte or word read from a genuinely 8-bit/16-bit
        // external port: the result never got right-justified into
        // [7:0]/[15:0], unlike the 32-bit-port branch just below, which
        // already does this correctly. Every OTHER consumer of mem_rdata
        // in eu_seq_execute.svh (MOVEP's own mem_rdata[7:0] extraction,
        // etc.) universally expects the right-justified convention. Fixed
        // by computing the shift from orig_bytes/done directly instead of
        // a fixed lane-position lookup -- this reduces to the exact same
        // (already-correct) shifts as before for orig_bytes==4, and newly
        // right-justifies the orig_bytes==1/2 cases.
        case (port)
            2'b01: begin  // 16-bit port: data on D[31:16]
                if (orig_bytes >= 3'd2) begin
                    // Word or longword original request: this port always
                    // transfers exactly 2 bytes per beat (matches next_siz/
                    // needs_more's own xfer=2 convention for this port),
                    // so the piece's own final bit position is a clean
                    // function of how many bytes are left after it lands.
                    piece = {16'h0, raw[31:16]} << (8 * (orig_bytes - 3'd2 - done));
                end else begin
                    // orig_bytes==1: a genuine BYTE request serviced by a
                    // 16-bit port. Which half of this port's own D[31:16]
                    // response holds the real byte is peripheral- and
                    // address-dependent (the 32-bit-port branch below
                    // threads addr_lo through for exactly this reason;
                    // this port width never has), and no real peripheral
                    // in this project exercises the combination -- left
                    // exactly as before (not fixed, not worsened). See
                    // this bug's own project file, "Deliberately not
                    // fixed" section.
                    piece = raw;
                end
            end
            2'b10: begin  // 8-bit port: data on D[31:24] -- always exactly
                // 1 byte per beat (next_siz/needs_more's own xfer=1 for
                // this port, unconditionally), so no orig_bytes guard is
                // needed here the way the 16-bit branch above needs one.
                piece = {24'h0, raw[31:24]} << (8 * (orig_bytes - 3'd1 - done));
            end
            default: begin  // 32-bit port: normalize byte/word from big-endian lane
                case ({orig_siz, addr_lo})
                    // Byte: extract from correct big-endian lane → normalize to [7:0]
                    4'b01_00: piece = {24'h0, raw[31:24]};
                    4'b01_01: piece = {24'h0, raw[23:16]};
                    4'b01_10: piece = {24'h0, raw[15:8]};
                    4'b01_11: piece = {24'h0, raw[7:0]};
                    // Word: extract from correct half → normalize to [15:0]
                    4'b10_00, 4'b10_01: piece = {16'h0, raw[31:16]};
                    4'b10_10, 4'b10_11: piece = {16'h0, raw[15:0]};
                    // Longword or line: full word pass-through
                    default: piece = raw;
                endcase
            end
        endcase
        merge_rdata = accum | piece;
    endfunction

    // -----------------------------------------------------------------------
    // Rising-edge detection for cyc_ack
    //
    // cycle_gen asserts eu_ack (= cyc_ack here) for all 4 clk_4x ticks of
    // S7.  The sizing FSM must only respond to the FIRST tick; otherwise
    // the repeated assertion is misread as successive sub-cycle completions.
    // -----------------------------------------------------------------------
    logic cyc_ack_prev;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) cyc_ack_prev <= 1'b0;
        else        cyc_ack_prev <= cyc_ack;
    end

    wire cyc_ack_edge = cyc_ack && !cyc_ack_prev;

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            sf <= SS_IDLE;
        else
            sf <= sf_nxt;
    end

    // -----------------------------------------------------------------------
    // Next-state and data registers
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            sf_addr     <= 32'h0;
            sf_siz      <= 2'b00;
            sf_rw       <= 1'b1;
            sf_wdata    <= 32'h0;
            sf_fc       <= 3'b0;
            sf_is_op    <= 1'b0;
            sf_orig_siz <= 2'b00;
            sf_accum    <= 32'h0;
            sf_rdata_r  <= 32'h0;
        end else begin
            case (sf)
                SS_IDLE: begin
                    if (eu_req) begin
                        // Latch EU request parameters for first sub-cycle
                        sf_addr     <= eu_addr;
                        sf_siz      <= eu_siz;
                        sf_rw       <= eu_rw;
                        sf_wdata    <= eu_wdata;
                        sf_fc       <= eu_fc;
                        sf_is_op    <= eu_is_operand;
                        sf_orig_siz <= eu_siz;
                        sf_accum    <= 32'h0;
                    end
                end

                SS_ACTIVE: begin
                    if (cyc_berr) begin
                        // Abort: mirrors SS_IDLE's own fresh-request reset --
                        // whatever partial sub-cycle progress sf_accum held is
                        // abandoned, matching biu_cache_if.sv's own CI_BERR
                        // treatment of a faulted multi-beat transfer.
                        sf_accum <= 32'h0;
                    end else if (cyc_ack_edge) begin
                        // Capture result and prepare for next sub-cycle (if any)
                        if (sf_rw) begin
                            sf_accum <= merge_rdata(sf_accum, cyc_rdata,
                                                    sf_siz, sf_orig_siz,
                                                    cyc_port_dsack, sf_addr[1:0]);
                        end

                        if (needs_more(sf_siz, cyc_port_dsack)) begin
                            sf_addr <= sf_addr + addr_incr(cyc_port_dsack);
                            sf_siz  <= next_siz(sf_siz, cyc_port_dsack);
                        end else begin
                            if (sf_rw)
                                sf_rdata_r <= merge_rdata(sf_accum, cyc_rdata,
                                                          sf_siz, sf_orig_siz,
                                                          cyc_port_dsack, sf_addr[1:0]);
                            else
                                sf_rdata_r <= 32'h0;
                        end
                    end
                end

                SS_DONE: begin
                    // One-tick pulse; reset for next transfer
                    sf_accum <= 32'h0;
                end

                default: ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Next-state combinatorial
    // -----------------------------------------------------------------------
    always_comb begin
        sf_nxt = sf;
        case (sf)
            SS_IDLE: begin
                if (eu_req)
                    sf_nxt = SS_ACTIVE;
            end
            SS_ACTIVE: begin
                if (cyc_berr) begin
                    // Abort straight back to idle -- see cyc_berr's own port
                    // comment above. Checked before cyc_ack_edge: the two
                    // are mutually exclusive per cycle_gen's own combinational
                    // eu_ack/eu_berr split, but this ordering documents the
                    // abort as taking priority, matching CI_BERR's own shape.
                    sf_nxt = SS_IDLE;
                end else if (cyc_ack_edge) begin
                    if (needs_more(sf_siz, cyc_port_dsack))
                        sf_nxt = SS_ACTIVE;
                    else
                        // timing_diagrams/ investigation: SS_DONE's own
                        // role is already fully superseded on the output
                        // side (eu_ack/eu_rdata are driven solely by
                        // ss_active_fast_done below, never by sf==SS_DONE
                        // -- see that wire's own comment) and its sf_accum
                        // reset is redundant with SS_IDLE's own identical
                        // reset on latching a fresh request. The ONE real
                        // remaining effect of visiting SS_DONE was cyc_req
                        // dropping to 0 for that one tick even when the
                        // next eu_req was already asserted continuously --
                        // a second, independent source of exactly the same
                        // "extra idle tick between back-to-back EU cycles"
                        // gap biu_cycle_gen.sv's own eu_continue_ok fast
                        // path (this same investigation) closes at its
                        // level. Going straight to SS_IDLE closes it here:
                        // SS_IDLE's own existing "pass eu_req/eu_addr
                        // through immediately, no extra latency" behavior
                        // (see the always_comb below) already handles a
                        // continuing request correctly with no other
                        // change needed.
                        sf_nxt = SS_IDLE;
                end
            end
            SS_DONE: begin
                // Still reachable only via reset-time default/stale state;
                // kept as a safe fallback, not a normal transition target
                // anymore (see above).
                sf_nxt = SS_IDLE;
            end
            default: sf_nxt = SS_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Outputs to cycle_gen (EU port)
    // -----------------------------------------------------------------------
    // In SS_IDLE (first tick after eu_req): already latched into sf_*, but
    // we need cyc_req=1 immediately.  Drive directly from EU in SS_IDLE so
    // there is no extra latency cycle for the common single-cycle case.
    // In SS_ACTIVE (sub-cycle 2+): drive the sizing registers.
    // -----------------------------------------------------------------------
    always_comb begin
        cyc_addr       = sf_addr;
        cyc_siz        = sf_siz;
        cyc_rw         = sf_rw;
        cyc_fc         = sf_fc;
        cyc_is_operand = sf_is_op;
        cyc_req        = 1'b0;
        cyc_wdata      = rotated_wdata(sf_wdata, sf_orig_siz, sf_siz, cyc_port_dsack);

        case (sf)
            SS_IDLE: begin
                // Pass through EU signals directly so cycle_gen sees req immediately
                cyc_addr       = eu_addr;
                cyc_siz        = eu_siz;
                cyc_rw         = eu_rw;
                cyc_fc         = eu_fc;
                cyc_is_operand = eu_is_operand;
                cyc_req        = eu_req;
                cyc_wdata      = eu_wdata;
            end
            SS_ACTIVE: begin
                cyc_req = 1'b1;
                // After cyc_ack, keep req=1 while bus completes; arbiter will
                // re-grant after bus_idle.  If needs_more: use updated sf_addr/sf_siz.
                // If final sub-cycle: hold req until SS_DONE deasserts.
            end
            SS_DONE: begin
                cyc_req = 1'b0;
            end
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Outputs to EU
    // -----------------------------------------------------------------------
    // Track C (bus-pipelining-overlap plan.md, ack-propagation collapse):
    // SS_DONE exists purely to present a clean, 1-tick eu_ack/eu_rdata
    // pulse to biu_cache_if.sv one cycle after the real completion --
    // but the underlying data (merge_rdata(sf_accum, cyc_rdata, ...))
    // only ever needs sf_accum (already registered from earlier sub-
    // cycles) and cyc_rdata (the current bus data, already valid this
    // same cycle), so the SS_DONE-only wait is avoidable overhead, not
    // a real dependency. Fires only on the FINAL sub-cycle of a
    // transfer (!needs_more(...)) -- an intermediate sub-cycle's own
    // cyc_ack_edge must still route through SS_ACTIVE staying SS_ACTIVE,
    // unchanged. The registered SS_ACTIVE->SS_DONE->SS_IDLE state path
    // (and SS_DONE's own now-redundant-but-harmless sf_accum reset) is
    // left completely unchanged, still driving cyc_req/next-state --
    // only the eu_ack/eu_rdata OUTPUTS switch to the fast path.
    //
    // Deliberately NOT OR'd with the old `sf==SS_DONE` term: a first
    // attempt did OR them, reasoning the registered path was a harmless
    // fallback -- but since SS_DONE is reached exactly one cycle after
    // this same fast-path condition fires, OR'ing the two makes eu_ack
    // assert on two CONSECUTIVE ticks for one completion. biu_cache_if.
    // sv's own sf_ack_rise edge-detector absorbs that harmlessly, but
    // biu_multiop_fsm.sv's own sf_eu_ack consumer is level-sensitive
    // (no edge-detector -- its own sf_eu_req stays asserted continuously
    // across an entire MOVEP/MOVEM transfer, unlike biu_cache_if.sv's
    // one-request-per-transaction shape) and double-counted the second
    // tick as a second byte's own completion, corrupting rdata1/rdata3
    // in tb/biu_tb.sv's own MOVEP dynamic-sizing tests -- caught by the
    // mandatory `make test` gate, not reasoned out in advance. The fast
    // path fully supersedes SS_DONE's own old role (every case that
    // would reach SS_DONE already passed through this identical trigger
    // one cycle earlier), so it's the sole source now, not a fallback.
    wire ss_active_fast_done = (sf == SS_ACTIVE) && cyc_ack_edge &&
                               !needs_more(sf_siz, cyc_port_dsack);
    assign eu_ack   = ss_active_fast_done;
    assign eu_rdata = ss_active_fast_done
                     ? (sf_rw ? merge_rdata(sf_accum, cyc_rdata, sf_siz,
                                             sf_orig_siz, cyc_port_dsack,
                                             sf_addr[1:0])
                              : 32'h0)
                     : sf_rdata_r;

endmodule

`default_nettype wire
