`default_nettype none

// MC68030 BIU — Dynamic Bus Sizing FSM (Phase 3)
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
    // -----------------------------------------------------------------------
    function automatic logic [31:0] merge_rdata(
        input logic [31:0] accum,
        input logic [31:0] raw,       // raw data from bus
        input logic [1:0]  cur_siz,   // SIZ of this sub-cycle
        input logic [1:0]  orig_siz,
        input logic [1:0]  port
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
        // and shift it to the correct position in the result
        case ({port, done[1:0]})
            // 16-bit port: data on D[31:16]
            4'b01_00: piece = {raw[31:16], 16'h0};        // bytes 0,1 → top
            4'b01_10: piece = {16'h0, raw[31:16]};        // bytes 2,3 → bottom
            // 8-bit port: data on D[31:24]
            4'b10_00: piece = {raw[31:24], 24'h0};        // byte 0 → top
            4'b10_01: piece = {8'h0, raw[31:24], 16'h0};  // byte 1
            4'b10_10: piece = {16'h0, raw[31:24], 8'h0};  // byte 2
            4'b10_11: piece = {24'h0, raw[31:24]};        // byte 3
            default:  piece = raw;                         // 32-bit: full word
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
                    if (cyc_ack_edge) begin
                        // Capture result and prepare for next sub-cycle (if any)
                        if (sf_rw) begin
                            sf_accum <= merge_rdata(sf_accum, cyc_rdata,
                                                    sf_siz, sf_orig_siz,
                                                    cyc_port_dsack);
                        end

                        if (needs_more(sf_siz, cyc_port_dsack)) begin
                            sf_addr <= sf_addr + addr_incr(cyc_port_dsack);
                            sf_siz  <= next_siz(sf_siz, cyc_port_dsack);
                        end else begin
                            if (sf_rw)
                                sf_rdata_r <= merge_rdata(sf_accum, cyc_rdata,
                                                          sf_siz, sf_orig_siz,
                                                          cyc_port_dsack);
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
                if (cyc_ack_edge) begin
                    if (needs_more(sf_siz, cyc_port_dsack))
                        sf_nxt = SS_ACTIVE;
                    else
                        sf_nxt = SS_DONE;
                end
            end
            SS_DONE: begin
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
    assign eu_ack   = (sf == SS_DONE);
    assign eu_rdata = sf_rdata_r;

endmodule

`default_nettype wire
