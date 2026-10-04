`default_nettype none

// =============================================================================
// MH030-P instruction fetch.
//
// Holds the PC, keeps a small prefetch queue full, and presents the opcode
// plus its extension words to decode. A taken branch flushes the queue and
// restarts at the target.
//
// EXTENSION-WORD CONVENTION. `ext` follows what the EU actually sees in rtl/,
// which is NOT the raw {q1,q2} the old IFU emits -- rtl/m68030_seq.sv:1160
// normalises it, and a SINGLE extension word arrives in the LOW half:
//
//     ext_words == 1 -> {16'h0, word1}
//     ext_words >= 2 -> {word1, word2}
//
// Reproducing that here rather than inventing a cleaner layout is deliberate:
// mh030p_decode.sv reads its displacements and register fields at those exact
// positions, having been corrected once already for getting this wrong.
//
// The queue does not know how many words an instruction needs -- only decode
// does. So this unit publishes how many words are AVAILABLE and the core
// gates on that against the decoded ext_words, then reports back how many to
// drain. That keeps the circular dependency out of the fetch path.
//
// A separate instruction memory port is used rather than sharing the data
// port. Real 68030 silicon arbitrates one bus between the IFU and the EU
// (rtl/biu_arbiter.sv); doing that here would add contention that has nothing
// to do with what this core is being built to measure. It is a deliberate
// simplification, not an oversight, and is the obvious thing to revisit when
// this core meets a real BIU.
// =============================================================================

module mh030p_ifu (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Instruction memory port.
    output reg         if_req,
    output reg  [31:0] if_addr,
    input  wire [31:0] if_rdata,
    input  wire        if_ack,

    // Redirect from a taken branch.
    input  wire        redirect,
    input  wire [31:0] redirect_pc,

    // To decode.
    output wire [15:0] instr,
    output wire [31:0] ext,
    // The same two words WITHOUT the one-word normalisation, for whoever needs
    // to decode the offered opcode before ext_words is known. See the note on
    // ext below: taking the normalised `ext` there closes a combinational loop.
    output wire [31:0] ext_raw,
    output wire [15:0] q3,
    // Fourth extension word, for the one combination that genuinely needs it:
    // a long immediate (2 words) feeding an absolute-long EA (2 more words) --
    // see mh030p_decode.sv's own xword()/rawword() for the consumer.
    output wire [15:0] q4,
    output wire [2:0]  words_avail,
    output wire [31:0] pc_out,

    // From the core: words consumed this cycle.
    input  wire [2:0]  drain,
    // How many extension words the instruction being offered needs, so the
    // low-half convention above can be applied.
    input  wire [2:0]  ext_words
);

    localparam QD = 8;

    reg [15:0] q [0:QD-1];
    reg [3:0]  count;

    // THE QUEUE SHIFTS, AND THAT IS DELIBERATE -- but on weaker evidence than
    // this comment first claimed; see the correction at the end.
    // Retiring words assigns all QD entries from a variable-distance shift, so
    // every entry carries a five-way mux driven by `drain`, which decode
    // produces. That looks like an obvious thing to fix, and a head-pointer
    // circular buffer was written and measured: the fetch unit's deepest
    // endpoint fell 50 -> 32 levels and the design-wide population at or above
    // 35 levels fell 679 -> 402, while Fmax came out at 21.80 MHz against a
    // baseline then believed to be 22.93.
    //
    // CORRECTION: that comparison does not hold. The baseline's own spread over
    // nine placement seeds is 21.81-23.13 MHz, and seeds 1-3 (the three used
    // here) are its three best -- so 21.80 is inside the baseline's range and
    // the change is UNRESOLVED, not a measured regression. It stays reverted
    // because it showed no benefit either and the existing code is simpler, not
    // because it was shown to be worse.
    //
    // The structural argument for preferring the shift is still worth keeping,
    // even though the measurement cannot confirm it: the shift network
    // terminates at FLIP-FLOPS, which have a whole clock to settle, whereas a
    // head pointer puts a variable eight-way read mux on instr/ext/q3 --
    // directly in front of the decoder, the one consumer with no slack to
    // spare. And the logic-depth proxy is not evidence either way, because it
    // counts levels to each endpoint without knowing which endpoints have
    // slack.
    reg [31:0] fetch_pc;   // next address to fetch
    reg [31:0] head_pc;    // address of q[0]
    reg        outstanding;

    assign instr       = q[0];
    assign q3          = q[3];
    assign q4          = q[4];
    assign words_avail = (count > 3'd7) ? 3'd7 : count[2:0];
    assign pc_out      = head_pc;

    // See the header: one extension word arrives in the LOW half.
    //
    // NOTE THE DEPENDENCE ON ext_words, and what it means for anyone decoding
    // the offered opcode to LEARN ext_words: taking this signal closes a
    // combinational cycle -- decode -> ext_words -> this mux -> decode. It
    // settles in simulation, because ext_words is a function of the opcode
    // alone, so the cycle is false; but a false cycle is still a cycle to
    // place-and-route, which unrolls it and charges two passes through the
    // decoder to one clock. Measured at 78% of the whole core's worst path.
    // ext_raw exists so that decode can be driven from something the mux does
    // not depend on. tb/uop_decode_equiv_tb.sv checks the property this relies
    // on -- ext_words identical for differing ext -- across all 65,536 opcodes.
    assign ext     = (ext_words == 3'd1) ? {16'h0, q[1]} : {q[1], q[2]};
    assign ext_raw = {q[1], q[2]};

    // A fetch launched before a redirect must have its data discarded, or it
    // lands in the flushed queue as if it were on the new path. An epoch tag
    // handles that regardless of how the ack and the redirect line up: the
    // epoch flips on every redirect, each request remembers the epoch it was
    // issued under, and an ack whose tag no longer matches is dropped.
    //
    // A plain "flush pending" flag is NOT sufficient and was tried first: it
    // has to be set at the redirect and cleared at the ack, which leaves the
    // same-cycle overlap unhandled, and stale data reached the queue. This is
    // the same in-flight-fetch hazard that cost rtl/ a real bug
    // (project_skiptx_branch_target_regwrite_bug.md) -- worth over-solving.
    reg epoch, req_epoch;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)        epoch <= 1'b0;
        else if (redirect) epoch <= ~epoch;
    end

    // FETCHES ARE LONGWORD-ALIGNED, and a branch to an odd-word target discards
    // the leading word rather than asking the bus for an unaligned longword.
    //
    // This was a real bug, and the reason it survived is worth recording. Branch
    // targets are only WORD-aligned on a 68k -- the fill loop in tests/bench1.s
    // branches to 0x0E -- and this unit used to put that address straight on the
    // bus as a 4-byte read. The abstract memory models answer that: they
    // assemble the result byte by byte from the exact address, so a longword read
    // at 0x0E genuinely returns the bytes at 0x0E..0x11 and the queue got
    // word@0x0E and word@0x10, which is the convention this unit expects.
    //
    // NO REAL 68030 BUS CAN DO THAT. A 32-bit port returns the ALIGNED longword
    // containing the address, so the same request yields the bytes at 0x0C..0x0F
    // -- the queue receives word@0x0C first, one word too early, and every
    // instruction after the branch decodes one word out of step. It presented as
    // a wrong answer rather than a hang: the copy loop in tests/bench1.s ran past
    // its bound for over a thousand iterations because the ADDQ that increments
    // its counter had been shifted out of the stream.
    //
    // The fix is the reference's: rtl/m68030_ifu.sv fetches on aligned
    // boundaries and carries a skip_first_r for exactly this case. Here the
    // redirect rounds the target DOWN to a longword boundary and tags the
    // resulting fetch, and a tagged fetch enqueues only its low word -- the one
    // at the target -- so head_pc still names the instruction the branch went to.
    // Every later fetch is aligned by construction, since it advances by 4.
    //
    // The tag travels with the REQUEST, not the redirect, for the same reason
    // req_epoch does: the redirect and the launch are different cycles, and a
    // second redirect can land in between.
    reg skip_pend, req_skip;

    integer i;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            count       <= 4'd0;
            fetch_pc    <= 32'h0;
            head_pc     <= 32'h0;
            outstanding <= 1'b0;
            if_req      <= 1'b0;
            if_addr     <= 32'h0;
            skip_pend   <= 1'b0;
            req_skip    <= 1'b0;
            for (i = 0; i < QD; i = i + 1) q[i] <= 16'h0;
        end else if (redirect) begin
            // Drop everything in flight. A fetch already on the bus still
            // returns its ack, so `outstanding` stays set and its data is
            // discarded below rather than pushed into the flushed queue --
            // the same in-flight-fetch hazard that cost rtl/ a real bug
            // (project_skiptx_branch_target_regwrite_bug.md).
            count    <= 4'd0;
            // Round DOWN to the longword the target lives in; head_pc still
            // names the target itself, so pc_out is unaffected.
            fetch_pc  <= {redirect_pc[31:2], 2'b00};
            head_pc   <= redirect_pc;
            skip_pend <= redirect_pc[1];
            if (if_ack) begin
                outstanding <= 1'b0;   // let an ack landing here retire
                if_req      <= 1'b0;
            end
            // if_req is deliberately NOT dropped here. A fetch already on the
            // bus must be allowed to complete and have its data discarded
            // (flush_pending). Cancelling the request instead leaves the
            // transaction unacknowledged, `outstanding` stuck high, and the
            // fetch unit permanently wedged -- which is exactly what happened:
            // execution stopped dead at the first taken branch.
        end else begin
            // Retire consumed words.
            if (drain != 3'd0) begin
                for (i = 0; i < QD; i = i + 1)
                    q[i] <= (i + drain < QD) ? q[i + drain] : 16'h0;
                count   <= count - {1'b0, drain};
                head_pc <= head_pc + {28'h0, drain, 1'b0};   // 2 bytes per word
            end

            // Accept a returning fetch, unless it was launched before a
            // redirect that has since flushed the queue.
            if (if_ack) begin
                outstanding <= 1'b0;
                if_req      <= 1'b0;
                if (req_epoch == epoch) begin
                    if (req_skip) begin
                        // A tagged fetch: the target was the LOW word of this
                        // longword, so the high word belongs to the instruction
                        // before the branch and is dropped.
                        q[count - {1'b0, drain}] <= if_rdata[15:0];
                        count    <= count - {1'b0, drain} + 4'd1;
                    end else begin
                        q[count - {1'b0, drain}]     <= if_rdata[31:16];
                        q[count - {1'b0, drain} + 1] <= if_rdata[15:0];
                        count    <= count - {1'b0, drain} + 4'd2;
                    end
                    fetch_pc <= fetch_pc + 32'd4;
                end
            end else if (!outstanding && (count <= 4'd5)) begin
                // Room for a longword; keep the queue topped up.
                outstanding <= 1'b1;
                if_req      <= 1'b1;
                if_addr     <= fetch_pc;
                req_epoch   <= epoch;
                // Consume the skip: it applies to this one fetch only.
                req_skip    <= skip_pend;
                skip_pend   <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
