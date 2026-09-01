`timescale 1ns/1ps
`default_nettype none

// MC68030 Instruction Fetch Unit
//
// 6-word × 16-bit prefetch queue.  The BIU always returns a 32-bit
// longword per fetch; the IFU splits it into two 16-bit words and pushes
// them to the queue tail.  The EU/sequencer drains up to 6 words per
// cycle (opcode + up to 5 extension words, Phase 145, plan.md — q[5] was
// already correctly filled by the existing logic below, just never
// exposed as its own output/drain case until this phase).
// 6 words supports MOVE.L #imm32, abs.L (5 total words: opcode+2+2), and
// (Phase 145) genuine memory-indirect EA with long bd + long od together
// (6 total words: opcode+descriptor+bd_hi+bd_lo+od_hi+od_lo), the last
// combination this physical 6-word queue can support without growing it
// further (MOVEM's own genuine-memory-indirect worst case needs a 7th
// word and remains out of scope — see plan.md Phase 145's own writeup).
//
// ext_data format: {q[1], q[2]} — first extension word in bits[31:16],
// second extension word in bits[15:0].  This is the hardware-accurate
// layout (MSW first, matching 68030 big-endian memory).
// eu_seq currently uses ext_data[31:0] as a full 32-bit immediate
// (zero-extended by testbench convention); integrated through m68030_top.
// the two conventions.
//
// BIU request protocol: ifu_req = fetch_pend_r.  Assert ifu_req and hold
// ifu_addr stable; deassert ifu_req one cycle after ifu_ack (fetch_pend_r
// cleared at ack posedge, so ifu_req goes low the same cycle as ack if no
// immediate re-fetch, else stays high with the new address).
//
// PC alignment: if pc_wr_data[1]=1 (word-aligned but not long-aligned),
// skip_first_r causes the IFU to discard rdata[31:16] (the word at
// fetch_addr, which is one word before the actual PC) on the first fill.

module m68030_ifu (
    input  logic        clk_4x,
    input  logic        rst_n,

    // PC override (branch, exception, boot — from IFU perspective)
    input  logic        pc_wr_en,
    input  logic [31:0] pc_wr_data,

    // Drain: 16-bit words consumed by EU/sequencer this cycle
    //   0 = nothing  1 = opcode only  2 = opcode + 1 ext  3 = opcode + 2 ext
    //   4 = opcode + 3 ext  5 = opcode + 4 ext  6 = opcode + 5 ext (Phase 145)
    input  logic [2:0]  drain,

    // Instruction stream outputs (combinational, valid the cycle after fill)
    output logic [15:0] instr_word,   // q[0] — opcode
    output logic [31:0] ext_data,     // {q[1], q[2]} — two extension words
    output logic [15:0] q3_word,      // q[3] — third extension word
    output logic [31:0] ext34_data,   // {q[3], q[4]} — words 3+4
    output logic [15:0] q5_word,      // q[5] — fifth extension word (Phase 145)
    output logic        instr_valid,  // q_cnt >= 1
    // Plan.md (bus-pipelining-overlap): a genuine "1 extension word is
    // ready" gate, distinct from ext_valid's own q_cnt>=3 -- fills always
    // arrive 2 words at a time, so an instruction needing only 1
    // extension word (the majority of memory-EA/short-immediate forms)
    // was previously forced through the same q_cnt>=3 gate 2-ext-word
    // instructions genuinely need, waiting an entire unneeded extra
    // fetch for a word it never uses. See m68030_seq.sv's own eu_ext_
    // valid mux for the consumer.
    output logic        ext1_valid,   // q_cnt >= 2
    output logic        ext_valid,    // q_cnt >= 3
    output logic        ext4_valid,   // q_cnt >= 4
    output logic        ext5_valid,   // q_cnt >= 5
    output logic        ext6_valid,   // q_cnt >= 6 (Phase 145)
    output logic [31:0] decode_pc,    // PC of instr_word

    // BIU longword-read interface
    output logic [31:0] ifu_addr,     // longword-aligned fetch address
    output logic        ifu_req,      // request held until ifu_ack
    input  logic [31:0] ifu_rdata,    // [31:16]=word@addr, [15:0]=word@addr+2
    input  logic        ifu_ack,      // data valid this cycle
    input  logic        ifu_berr,     // bus error this cycle

    // Supervisor mode → function code selection
    input  logic        supervisor,
    output logic [2:0]  fc_out,       // 110=SV prog, 010=user prog

    // Fault outputs
    output logic        bus_err,
    output logic [31:0] bus_err_addr,
    output logic        addr_err,     // decode_pc[0]: odd address error

    // open-items backlog Stage 13 (plan.md): live BKPT opcode
    // substitution. When active, instr_word presents bkpt_subst_word
    // instead of q[0] for exactly one decode cycle -- the underlying
    // q[] array and drain/ext_count mechanism are entirely untouched,
    // since BKPT is always exactly 1 word with no extension words of
    // its own; the substituted instruction's own extension words (if
    // any) are simply whatever q[1]/q[2]/... already hold, unaffected
    // by this mux.
    input  logic         bkpt_subst_active,
    input  logic [15:0]  bkpt_subst_word
);

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    logic [15:0] q    [0:5];      // prefetch queue: q[0] = head (next opcode)
    logic [2:0]  q_cnt;           // valid word count: 0–6
    logic [31:0] fetch_addr_r;    // next longword address to request
    logic [31:0] decode_pc_r;     // PC of q[0]
    logic        fetch_pend_r;    // outstanding BIU fetch (ifu_req held high)
    logic        skip_first_r;    // discard rdata[31:16] on next fill
    logic        initialized_r;   // set on first pc_wr_en; gate auto-fetch
    logic        bus_err_r;
    logic [31:0] bus_err_addr_r;
    logic [15:0] held_word_r;      // Phase 147: overflow stash (see below)
    logic        held_valid_r;

    // -----------------------------------------------------------------------
    // Combinational outputs
    // -----------------------------------------------------------------------
    // open-items backlog Stage 13 (plan.md): live BKPT opcode substitution.
    assign instr_word   = bkpt_subst_active ? bkpt_subst_word : q[0];
    assign ext_data     = {q[1], q[2]};
    assign q3_word      = q[3];
    assign ext34_data   = {q[3], q[4]};
    assign q5_word      = q[5];
    assign instr_valid  = (q_cnt >= 3'd1);
    assign ext1_valid   = (q_cnt >= 3'd2);
    assign ext_valid    = (q_cnt >= 3'd3);
    assign ext4_valid   = (q_cnt >= 3'd4);
    assign ext5_valid   = (q_cnt >= 3'd5);
    assign ext6_valid   = (q_cnt >= 3'd6);
    assign decode_pc    = decode_pc_r;
    assign ifu_addr     = fetch_addr_r;
    assign ifu_req      = fetch_pend_r;
    assign fc_out       = supervisor ? 3'b110 : 3'b010;
    // Deferred-items closure plan Stage 3 (plan.md): MC68030UM p.6-19
    // distinguishes "faults immediately (data) or pending-on-use
    // (instruction)" -- confirmed, via a dedicated tb/ifu_tb.sv test
    // (IFU-12) plus a direct trace against tb/cache_tb.sv's own I-5, that
    // this RTL does NOT implement the instruction-fetch deferral: bus_err
    // dispatches the instant the underlying speculative prefetch fails,
    // even while decode is still several words behind and would never
    // have reached that address (e.g. a branch not yet taken). A first
    // attempt gated this output on `decode_pc_r >= bus_err_addr_r`
    // (correct for pure linear-readahead speculation, and this DOES pass
    // that case -- see IFU-12's own tb/ifu_tb.sv coverage) but caused a
    // real regression in tb/cache_tb.sv's own I-5: when the faulted word
    // is itself needed as the CURRENT (not-yet-dispatched) instruction's
    // own extension word, decode_pc_r never advances to reach it at all
    // -- it sits pinned at the START of that instruction indefinitely,
    // since dispatch (and therefore decode_pc_r's own advance) requires
    // exactly the missing data to ever happen. A correct general fix
    // needs cross-module visibility into whether decode is genuinely
    // stalled needing more prefetch data than is currently queued (e.g.
    // eu_seq.sv's own need_ext), not available locally in this file today
    // -- threading that signal back into the IFU is a real, substantial
    // change to the queue/decode interface, out of scope for this
    // investigation stage. Reverted to the original unconditional
    // dispatch (confirmed correct for the "decode already needs this
    // word" case, which is the common one) rather than ship a fix that's
    // only correct for pure speculative readahead. See tb/ifu_tb.sv's own
    // IFU-12 for a permanent regression-detector of the confirmed-but-
    // unfixed gap, matching this project's own established "assert
    // today's actual behavior so make test stays green while the gap
    // stays visible" precedent (Phase 106).
    assign bus_err      = bus_err_r;
    assign bus_err_addr = bus_err_addr_r;
    assign addr_err     = decode_pc_r[0];

    // -----------------------------------------------------------------------
    // Combinational drain helpers (all via assign — Icarus always_comb safe)
    // -----------------------------------------------------------------------

    // Cap drain to available words so we never underflow q_cnt
    logic [2:0] dn;
    assign dn = (drain > q_cnt) ? q_cnt : drain;

    // Queue shifted left by dn (drain from head); tail zeroed
    logic [15:0] qd [0:5];
    always_comb begin
        case (dn)
            3'd1: begin qd[0]=q[1]; qd[1]=q[2]; qd[2]=q[3]; qd[3]=q[4]; qd[4]=q[5]; qd[5]=16'h0; end
            3'd2: begin qd[0]=q[2]; qd[1]=q[3]; qd[2]=q[4]; qd[3]=q[5]; qd[4]=16'h0; qd[5]=16'h0; end
            3'd3: begin qd[0]=q[3]; qd[1]=q[4]; qd[2]=q[5]; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            3'd4: begin qd[0]=q[4]; qd[1]=q[5]; qd[2]=16'h0; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            3'd5: begin qd[0]=q[5]; qd[1]=16'h0; qd[2]=16'h0; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            // Phase 145: draining all 6 words (opcode+5 ext) empties the
            // queue entirely -- only reachable when q_cnt==6 (ext6_valid),
            // the physical maximum this queue can ever hold, so there is
            // no q[6] to shift in; every slot simply goes to 0/don't-care
            // (q_cnt_d becomes 0, so nothing downstream reads qd[] as valid).
            3'd6: begin qd[0]=16'h0; qd[1]=16'h0; qd[2]=16'h0; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            default: begin qd[0]=q[0]; qd[1]=q[1]; qd[2]=q[2]; qd[3]=q[3]; qd[4]=q[4]; qd[5]=q[5]; end
        endcase
    end

    // q_cnt after drain (before fill)
    logic [2:0] q_cnt_d;
    assign q_cnt_d = q_cnt - {1'b0, dn};

    // Words added by this ack (0 if no ack; 1 if skip_first; 2 normally)
    logic [2:0] fill_cnt;
    assign fill_cnt = (ifu_ack && fetch_pend_r && !bus_err_r && !ifu_berr)
                      ? (skip_first_r ? 3'd1 : 3'd2)
                      : 3'd0;

    // q_cnt after drain + fill
    logic [2:0] q_cnt_df;
    assign q_cnt_df = q_cnt_d + fill_cnt;

    // Position in qd where fill starts = q_cnt_d (0–4 when ack fires,
    // because we only issue a fetch when q_cnt_d ≤ 4, and q_cnt_d ≤ q_cnt ≤ 4)
    logic [2:0] fill_at;
    assign fill_at = q_cnt_d[2:0];

    // -----------------------------------------------------------------------
    // Sequential queue update
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin : queue_seq

        if (!rst_n) begin
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0;
            q[3] <= 16'h0; q[4] <= 16'h0; q[5] <= 16'h0;
            q_cnt          <= 3'd0;
            fetch_addr_r   <= 32'h0;
            decode_pc_r    <= 32'h0;
            fetch_pend_r   <= 1'b0;
            skip_first_r   <= 1'b0;
            initialized_r  <= 1'b0;
            bus_err_r      <= 1'b0;
            bus_err_addr_r <= 32'h0;
            held_word_r    <= 16'h0;
            held_valid_r   <= 1'b0;

        end else if (pc_wr_en) begin
            // Flush queue and restart from new PC.
            // fetch_pend_r cleared to 0 so any in-flight fetch is abandoned;
            // ifu_ack guarded by fetch_pend_r, so stale data is ignored.
            // The drain-only branch on the next cycle will set fetch_pend_r=1.
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0;
            q[3] <= 16'h0; q[4] <= 16'h0; q[5] <= 16'h0;
            q_cnt          <= 3'd0;
            decode_pc_r    <= pc_wr_data;
            fetch_addr_r   <= {pc_wr_data[31:2], 2'b00};  // longword-align
            skip_first_r   <= pc_wr_data[1];               // 1: PC = long_base + 2
            fetch_pend_r   <= 1'b0;
            initialized_r  <= 1'b1;
            bus_err_r      <= 1'b0;
            bus_err_addr_r <= 32'h0;
            held_word_r    <= 16'h0;
            held_valid_r   <= 1'b0;

        end else begin
            // Always advance decode_pc for consumed words (2 bytes each)
            decode_pc_r <= decode_pc_r + {29'h0, dn, 1'b0};

            if (ifu_berr && fetch_pend_r && !bus_err_r) begin
                // Bus error: latch fault address, stop fetching
                bus_err_r      <= 1'b1;
                bus_err_addr_r <= fetch_addr_r;
                fetch_pend_r   <= 1'b0;
                q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                q_cnt <= q_cnt_d;

            end else if (ifu_ack && fetch_pend_r && !bus_err_r) begin
                // Fill: write new word(s) into qd at position fill_at
                fetch_addr_r <= fetch_addr_r + 32'd4;
                skip_first_r <= 1'b0;
                // Clear fetch_pend_r; drain-only branch re-asserts next cycle
                // with the updated fetch_addr_r, avoiding address-race with the BIU.
                fetch_pend_r <= 1'b0;

                // Phase 147 (plan.md): fill_at==5 overflow. A fetch always
                // returns 2 words, but only 1 physical slot (q[5]) remains
                // free when q_cnt_d==5 -- this is now reachable because the
                // fetch trigger below was widened from <=4 to <=5 to fix a
                // parity-lock bug (see that comment). Keep the first word
                // at q[5]; stash the second in held_word_r for the next
                // free slot (injected with zero bus cost in the drain-only
                // branch below) instead of losing it.
                if (fill_at == 3'd5) begin
                    q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                    q[3] <= qd[3]; q[4] <= qd[4];
                    q[5] <= ifu_rdata[31:16];
                    held_word_r  <= ifu_rdata[15:0];
                    held_valid_r <= 1'b1;
                    q_cnt        <= 3'd6;
                end else begin
                q_cnt        <= q_cnt_df;

                // Write queue: cases on {skip_first_r, fill_at[2:0]}
                // skip_first=0: rdata[31:16] at fill_at, rdata[15:0] at fill_at+1
                // skip_first=1: rdata[15:0]  at fill_at only (first word discarded)
                case ({skip_first_r, fill_at})
                    4'b0_000: begin
                        q[0] <= ifu_rdata[31:16]; q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_001: begin
                        q[0] <= qd[0]; q[1] <= ifu_rdata[31:16];
                        q[2] <= ifu_rdata[15:0];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_010: begin
                        q[0] <= qd[0]; q[1] <= qd[1];
                        q[2] <= ifu_rdata[31:16]; q[3] <= ifu_rdata[15:0];
                        q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_011: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                        q[3] <= ifu_rdata[31:16]; q[4] <= ifu_rdata[15:0];
                        q[5] <= qd[5];
                    end
                    4'b0_100: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                        q[4] <= ifu_rdata[31:16]; q[5] <= ifu_rdata[15:0];
                    end
                    4'b1_000: begin
                        q[0] <= ifu_rdata[15:0];
                        q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_001: begin
                        q[0] <= qd[0]; q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_010: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= ifu_rdata[15:0];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_011: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= ifu_rdata[15:0];
                        q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_100: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                        q[4] <= ifu_rdata[15:0]; q[5] <= qd[5];
                    end
                    default: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                endcase
                end

            end else begin
                // Phase 147 (plan.md): parity-lock fix. A fetch always
                // delivers 2 words, so once a fresh instruction stream's
                // queue parity goes odd (via the one-time skip_first
                // catch-up below), every later fill preserves that parity
                // (1->3->5->7...) -- q_cnt could only ever land on 5, never
                // 6, and the old trigger ("<=4") never re-armed from 5,
                // permanently stalling any instruction needing q[5] valid
                // (ext_count==5, unreachable before Phase 145/147). Fixed
                // by widening the trigger to <=5 (below) and handling the
                // resulting 1-slot-only overflow via held_word_r/
                // held_valid_r (stash the fetch's 2nd word, no bus cost to
                // place it once a slot frees up -- see the fill_at==5 case
                // above and the injection just below).
                if (held_valid_r && (q_cnt_d < 3'd6)) begin
                    // Inject the stashed word into the first free slot
                    // instead of a plain shift-only drain -- zero bus cost.
                    case (q_cnt_d)
                        3'd0: begin q[0]<=held_word_r; q[1]<=qd[1]; q[2]<=qd[2]; q[3]<=qd[3]; q[4]<=qd[4]; q[5]<=qd[5]; end
                        3'd1: begin q[0]<=qd[0]; q[1]<=held_word_r; q[2]<=qd[2]; q[3]<=qd[3]; q[4]<=qd[4]; q[5]<=qd[5]; end
                        3'd2: begin q[0]<=qd[0]; q[1]<=qd[1]; q[2]<=held_word_r; q[3]<=qd[3]; q[4]<=qd[4]; q[5]<=qd[5]; end
                        3'd3: begin q[0]<=qd[0]; q[1]<=qd[1]; q[2]<=qd[2]; q[3]<=held_word_r; q[4]<=qd[4]; q[5]<=qd[5]; end
                        3'd4: begin q[0]<=qd[0]; q[1]<=qd[1]; q[2]<=qd[2]; q[3]<=qd[3]; q[4]<=held_word_r; q[5]<=qd[5]; end
                        default: begin q[0]<=qd[0]; q[1]<=qd[1]; q[2]<=qd[2]; q[3]<=qd[3]; q[4]<=qd[4]; q[5]<=held_word_r; end
                    endcase
                    q_cnt        <= q_cnt_d + 3'd1;
                    held_valid_r <= 1'b0;
                end else begin
                    // Drain only: just shift the queue
                    q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                    q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    q_cnt <= q_cnt_d;
                end

                // Issue a new fetch if queue has room (<= 5 words after
                // drain, widened from <=4 -- see comment above) and we
                // aren't already holding a stashed word (avoid a second
                // overflow before the first held word has been placed).
                // Guard !ifu_ack: biu_cycle_gen holds ifu_ack high for all 4
                // ticks of S7.  Without this guard the drain-only path re-arms
                // fetch_pend_r on tick 1 of S7, causing a spurious second fill
                // (at tick 2) with stale captured_rdata and advancing
                // fetch_addr_r past the next real fetch address.
                if (!fetch_pend_r && !bus_err_r && initialized_r &&
                    (q_cnt_d <= 3'd5) && !ifu_ack && !held_valid_r) begin
                    fetch_pend_r <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
