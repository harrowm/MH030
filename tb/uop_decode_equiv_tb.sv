`default_nettype none
`timescale 1ns/1ps
`include "mh030p_uop.svh"

// =============================================================================
// Equivalence sweep: mh030p_decode (rtlp/) vs eu_seq (rtl/), all 65,536 opcodes.
//
// The new decoder is checked against the OLD one rather than against the
// manual, because the old one is what passes 702,142 Harte vectors. That
// makes it the authority on every encoding corner this project already got
// right the hard way.
//
// Only opcodes the new decoder actually CLAIMS (valid && uclass != UC_UNIMPL)
// are compared, so this stays meaningful as coverage grows: adding a family
// to the decoder automatically brings it under test. The reverse direction --
// opcodes the old decoder accepts but the new one does not yet -- is reported
// as a coverage number, not a failure, since partial coverage is the whole
// point of a staged rollout.
//
// Reuses tb/ext_count_overlap_tb.sv's exhaustive-sweep technique (Phases
// 221-224), which is how the last real decode bug in this project was found.
// =============================================================================

module uop_decode_equiv_tb;

    logic clk_4x = 1'b0;
    logic rst_n  = 1'b0;
    always #5 clk_4x = ~clk_4x;

    // ── New decoder (combinational) ─────────────────────────────────────────
    logic [15:0] instr;
    logic [31:0] ext;
    uop_t        uop;

    logic [15:0] q3w;
    // ext_raw is driven independently of ext so the two properties below can be
    // separated: the DISPLACEMENT fields depend on `ext`'s normalised layout,
    // while ext_words must depend only on instr/ext_raw/q3.
    logic [31:0] ext_rawv;
    mh030p_decode u_new (
        .instr  (instr),
        .ext    (ext),
        .ext_raw(ext_rawv),
        .q3     (q3w),
        .uop    (uop)
    );

    // ── Old decoder, driven through eu_seq's decode inputs ──────────────────
    // eu_seq is instantiated purely so its combinational decode section can be
    // observed hierarchically; nothing is clocked through it here.
    logic [15:0] o_instr;
    logic [31:0] o_ext;
    assign o_instr = instr;
    assign o_ext   = ext;

    // ── Extension-word count, against the reference sequencer ───────────────
    // Eight separate extension-word miscounts were found one at a time by the
    // Harte corpus, each costing its own debugging cycle: MOVE USP, TRAPF, bit
    // fields, MOVEC/MOVES, CAS, CMP2/CHK2, the group-0 byte/word immediates and
    // the register-count shifts. They share one root cause -- the count was
    // derived from ea_mode_w and ea_is_imm, which are computed from instr[5:0]
    // unconditionally and are therefore meaningless for any instruction whose
    // low bits are not an EA field.
    //
    // m68030_seq.sv already computes the authoritative count for every opcode,
    // so comparing against it turns eight discoveries into one exhaustive check.
    m68030_seq u_seq (
        .instr_word(instr), .ifu_ext_data(ext), .ifu_q3_word(q3w),
        .ifu_ext34_data(32'h0), .ifu_q5_word(16'h0), .ifu_q6_word(16'h0),
        .instr_valid(1'b1), .ifu_ext1_valid(1'b1), .ifu_ext_valid(1'b1),
        .ifu_ext4_valid(1'b1), .ifu_ext5_valid(1'b1), .ifu_ext6_valid(1'b1),
        .ifu_ext7_valid(1'b1),
        .drain(), .eu_instr_word(), .eu_ext_data(), .eu_q3_word(),
        .eu_ext34_data(), .eu_q5_word(), .eu_q6_word(),
        .eu_instr_valid(), .eu_ext_valid(),
        .eu_instr_ack(1'b0), .eu_busy(1'b0)
    );
    wire [2:0] old_ext_words = u_seq.ext_count;

    // Hierarchical references into eu_seq's decode signals. Same technique
    // tb/cache_tb.sv and tb/mmu_xlate_tb.sv already use for burst_beat_probe.
    `define OLD u_old
    wire       old_valid   = `OLD.dec_valid;
    wire [2:0] old_unit    = `OLD.dec_unit;
    wire [3:0] old_alu_op  = `OLD.dec_alu_op;
    wire [2:0] old_md_op   = `OLD.dec_md_op;
    wire [1:0] old_bit_op  = `OLD.dec_bit_op;
    // EA fields. Comparing these is what catches a wrong extension-word
    // half being read -- a whole bug class the sweep was previously blind to.
    wire        old_xn_wl    = `OLD.dec_xn_wl;
    wire [1:0]  old_xn_scale = `OLD.dec_xn_scale;
    wire [31:0] old_ea_off   = `OLD.dec_ea_offset;
    wire [1:0] old_siz     = `OLD.dec_siz;
    wire [3:0] old_src_reg = `OLD.dec_src_reg;
    // dec_dest_reg ("register to commit result into"), NOT dec_dst_reg
    // ("rd_b: destination/second-operand register", i.e. a READ port
    // selector). uop.dst_reg is a writeback destination, so it maps to
    // dec_dest_reg. Comparing against dec_dst_reg produced a wall of false
    // MOVEA failures -- the exact read-vs-write field-role confusion
    // feedback_read_write_field_roles_swapped.md documents.
    wire [3:0] old_dst_reg = `OLD.dec_dest_reg;
    wire       old_wr_reg  = `OLD.dec_writes_reg;
    wire       old_upd_ccr = `OLD.dec_updates_ccr;
    wire       old_use_imm = `OLD.dec_use_imm;
    wire [31:0] old_imm    = `OLD.dec_imm;

    // eu_seq needs its full port list; everything not feeding decode is tied
    // off. Only the combinational decode outputs above are read.
    eu_seq u_old (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr_word(o_instr), .instr_valid(1'b1),
        .ext_data(o_ext), .ext_valid(1'b1),
        .q3_word(q3w), .ext34_data(32'h0), .q5_word(16'h0), .q6_word(16'h0),
        .rd_a_sel(), .rd_a_siz(), .rd_a_data(32'h0),
        .rd_b_sel(), .rd_b_siz(), .rd_b_data(32'h0),
        .rd_c_sel(), .rd_c_siz(), .rd_c_data(32'h0),
        .rd_prev_a_sel(), .rd_prev_a_siz(), .rd_prev_a_data(32'h0),
        .rd_prev_b_sel(), .rd_prev_b_siz(), .rd_prev_b_data(32'h0),
        .rd_prev_c_sel(), .rd_prev_c_siz(), .rd_prev_c_data(32'h0),
        .wr_en(), .wr_sel(), .wr_siz(), .wr_data(),
        .sr_wr_en(), .sr_wr_data(), .sr_ccr_only(), .sr_out(16'h2700),
        .alu_src(), .alu_dst(), .alu_op(), .alu_siz(), .alu_x_in(), .alu_z_in(),
        .alu_result(32'h0), .alu_n(1'b0), .alu_z(1'b0), .alu_v(1'b0),
        .alu_c(1'b0), .alu_x(1'b0),
        .shf_operand(), .shf_count(), .shf_op(), .shf_siz(), .shf_x_in(),
        .shf_result(32'h0), .shf_n(1'b0), .shf_z(1'b0), .shf_v(1'b0),
        .shf_c(1'b0), .shf_x(1'b0),
        .md_src(), .md_dst(), .md_op(),
        .md_result_lo(32'h0), .md_result_hi(32'h0),
        .md_n(1'b0), .md_z(1'b0), .md_v(1'b0), .md_c(1'b0),
        .md_div_by_zero(1'b0), .md_div_start(), .md_div_busy(1'b0),
        .bcd_src(), .bcd_dst(), .bcd_op(), .bcd_x_in(), .bcd_z_in(),
        .bcd_result(8'h0), .bcd_c(1'b0), .bcd_z(1'b0), .bcd_v(1'b0),
        .bit_dst(), .bit_num(), .bit_op(), .bit_result(32'h0), .bit_z(1'b0),
        .instr_ack(), .seq_busy(), .div_trap(), .chk_trap(), .mmu_config_trap(),
        .eu_need_ext(),
        .int_pending(1'b0), .eu_int_ready(), .exc_active(1'b0),
        .decode_pc(32'h0), .ex_decode_pc_out(), .branch_taken(), .branch_target(),
        .mem_req(), .mem_new_dispatch(), .mem_rw(), .mem_siz(), .mem_fc(),
        .mem_addr(), .mem_wdata(), .mem_rdata(32'h0), .mem_ack(1'b0),
        .mem_berr(1'b0), .mem_rmw(), .mem_rmw_lookup(),
        .eu_is_cas(), .eu_cas_hold(),
        .eu_coproc_req(), .eu_coproc_rw(), .eu_coproc_siz(), .eu_coproc_fc(),
        .eu_coproc_addr(), .eu_coproc_wdata(), .eu_coproc_rdata(32'h0),
        .eu_coproc_ack(1'b0), .eu_coproc_berr(1'b0),
        .eu_bkpt_req(), .eu_bkpt_rw(), .eu_bkpt_siz(), .eu_bkpt_fc(),
        .eu_bkpt_addr(), .eu_bkpt_wdata(), .eu_bkpt_rdata(32'h0),
        .eu_bkpt_ack(1'b0), .eu_bkpt_berr(1'b0), .eu_bkpt_illegal_req(),
        .eu_bkpt_subst_active(), .eu_bkpt_subst_word(),
        .an_wr_en(), .an_wr_sel(), .an_wr_data(),
        .wr2_en()
    );

    // ── Sweep ───────────────────────────────────────────────────────────────
    integer claimed, agreed, mismatches, old_only;
    integer ext_alt_bad;
    integer ew_fast_bad;
    integer ffv;
    integer ff_checked = 0;
    integer ff_bad = 0;
    integer ff_grp [0:15];
    logic [15:0] ffw;
    logic [2:0] ew_ref;
    integer gap_by_group [0:15];
    integer gap_sample_n  [0:15];
    reg [15:0] gap_sample [0:15][0:3];
    integer k;
    integer g;
    integer i;
    reg [31:0] first_bad;

    // Classes whose EA is a plain data operand, so dec_ea_offset really is
    // the displacement rather than one of its other uses.
    wire ea_operand_class = (uop.uclass == UC_ALU)   || (uop.uclass == UC_MOVE)
                         || (uop.uclass == UC_ADDQ)  || (uop.uclass == UC_SHIFT)
                         || (uop.uclass == UC_BITOP);

    task automatic report(input [15:0] op, input string what,
                          input [31:0] got, input [31:0] exp);
        // +allmismatch lifts the cap, which is what makes a whole-family
        // pattern visible instead of the first twenty opcodes of one family.
        if ((mismatches < 20) || $test$plusargs("allmismatch"))
            $display("MISMATCH op=%04h %-12s new=%08h old=%08h", op, what, got, exp);
        mismatches = mismatches + 1;
        if (first_bad == 32'hFFFF_FFFF) first_bad = {16'h0, op};
    endtask

    // Probe: dump the reference decoder's view of specific opcodes. Far
    // faster than guessing one convention per rebuild.
    task automatic probe(input [15:0] op, input string name);
        begin
            instr = op; #1;
            $display("PROBE %-10s op=%04h valid=%b unit=%0d alu=%0d siz=%0d wr=%b ccr=%b dest=%0d", name, op, old_valid, old_unit, old_alu_op, old_siz, old_wr_reg, old_upd_ccr, old_dst_reg);
        end
    endtask

    initial begin
        $display("=== uop decode equivalence sweep (all 65536 opcodes) ===");
        claimed = 0; agreed = 0; mismatches = 0; old_only = 0;
        for (g = 0; g < 16; g = g + 1) begin
            gap_by_group[g] = 0;
            gap_sample_n[g] = 0;
        end
        first_bad = 32'hFFFF_FFFF;
        // Deliberately asymmetric between halves so that reading the WRONG
        // half of the extension word cannot accidentally compare equal.
        //
        // Bit 8 of the FIRST word must be 0, selecting the BRIEF format for an
        // indexed EA. The old value 0xA5A5_3C7F had it set, which made every
        // indexed effective address a FULL-FORMAT one -- and this decoder
        // deliberately implements only the brief format, so the extension-word
        // check would have reported ~4,500 opcodes of that known gap and drowned
        // every real miscount. 0xA4A5 differs only in that bit and is still
        // asymmetric against the low half.
        for (ffv = 0; ffv < 16; ffv = ffv + 1) ff_grp[ffv] = 0;
        ext = 32'hA4A5_3C7F;
        ext_rawv = 32'hA4A5_3C7F;
        q3w = 16'h5A91;
        rst_n = 1'b0;
        repeat (2) @(posedge clk_4x);
        rst_n = 1'b1;
        @(posedge clk_4x);

        if ($test$plusargs("probe")) begin
            probe(16'h42E8, "MOVE CCR,(d16,A0)");   // was the rtl/ ext_count gap
            probe(16'h42F9, "MOVE CCR,(xxx).L");
            probe(16'h42C0, "MOVE CCR,D0");
            probe(16'h51C0, "SF D0");
            probe(16'h50C0, "ST D0");
            probe(16'h6000, "BRA");
            probe(16'h6100, "BSR");
            probe(16'h6600, "BNE");
            probe(16'h51C8, "DBF D0");
            probe(16'hC141, "EXG D0,D1");
            probe(16'hC101, "ABCD D1,D0");
            probe(16'hD101, "ADDX D1,D0");
            probe(16'h1080, "MOVE.B D0,(A0)");
            probe(16'h10A2, "MOVE.B -(A2),(A0)");
            probe(16'h1010, "MOVE.B (A0),D0");
            probe(16'h2010, "MOVE.L (A0),D0");
            probe(16'h2080, "MOVE.L D0,(A0)");
            probe(16'h4250, "CLR.W (A0)");
            probe(16'h0650, "ADDI.W #x,(A0)");
            probe(16'h4450, "NEG.W (A0)");
            probe(16'h4650, "NOT.W (A0)");
            probe(16'h4A50, "TST.W (A0)");
            probe(16'h4AD0, "TAS (A0)");
            probe(16'h5250, "ADDQ.W #1,(A0)");
            probe(16'h5350, "SUBQ.W #1,(A0)");
            probe(16'hE2D0, "ASR.W (A0)");
            probe(16'hE3D0, "ASL.W (A0)");
            probe(16'h41D0, "LEA (A0),A0");
            probe(16'h4850, "PEA (A0)");
            probe(16'h4ED0, "JMP (A0)");
            probe(16'h4E90, "JSR (A0)");
            probe(16'h4E71, "NOP");
            probe(16'h4E75, "RTS");
            probe(16'h4E77, "RTR");
            probe(16'h4E73, "RTE");
            probe(16'h4E40, "TRAP #0");
            probe(16'h4E50, "LINK A0,#x");
            probe(16'h4E58, "UNLK A0");
            probe(16'h48D0, "MOVEM.L r,(A0)");
            probe(16'h4CD0, "MOVEM.L (A0),r");
            probe(16'h4800, "NBCD D0");
            probe(16'h4E47, "TRAP #7");
            probe(16'h4E48, "TRAP #8");
            probe(16'h4E4F, "TRAP #15");
            probe(16'h4E69, "MOVE USP,A1");
            probe(16'hD0C0, "ADDA.W D0,A0");
            probe(16'hD1C0, "ADDA.L D0,A0");
            probe(16'h90C0, "SUBA.W D0,A0");
            probe(16'hB0C0, "CMPA.W D0,A0");
            probe(16'hD190, "ADD.L D0,(A0)");
            probe(16'h8190, "OR.L D0,(A0)");
            probe(16'hB188, "CMPM.L (A0)+,(A0)+");
            probe(16'h50D0, "ST (A0)");
            probe(16'h40D0, "MOVE SR,(A0)");
            probe(16'h44D0, "MOVE (A0),CCR");
            probe(16'h4190, "CHK.W (A0),D0");
            probe(16'h4E7A, "MOVEC c,Rn");
            probe(16'hA000, "A-line trap");
            probe(16'hAFFF, "A-line trap hi");
            probe(16'hE8C0, "BFTST D0{..}");
            probe(16'hEFC0, "BFINS D0{..}");
            probe(16'h11C0, "MOVE.B D0,(xxx).W");
            probe(16'h13FC, "MOVE.B #x,(xxx).L");
            probe(16'h103C, "MOVE.B #x,D0");
            probe(16'h50FC, "TRAPcc");
            probe(16'h0108, "MOVEP.W d(Ay),Dx");
            probe(16'h4840, "SWAP D0 (recheck)");
            probe(16'hE8D0, "BFTST (A0)");
            probe(16'hE8E8, "BFTST d16(A0)");
            probe(16'hE8F0, "BFTST idx(A0)");
            probe(16'hE8F8, "BFTST abs.W");
            probe(16'hE8F9, "BFTST abs.L");
            probe(16'hE8FA, "BFTST d16(PC)");
            probe(16'h1008, "MOVE.B A0,D0?");
            probe(16'h203D, "MOVE.L m7r5,D0?");
            probe(16'h4100, "CHK.L D0,D0");
            probe(16'h5008, "ADDQ.B #8,A0?");
            probe(16'h9008, "SUBX.B -(A0)");
            probe(16'h80D0, "DIVU.W (A0),D0");
            probe(16'hE008, "ASR.B #8,D0?");
            probe(16'hF000, "F-line");
            probe(16'h003C, "ORI #x,CCR");
            probe(16'h00C0, "grp0 ss11 m0");
            probe(16'h1180, "MOVE.B D0,A0dst?");
            probe(16'h4140, "grp4 opmode101?");
            probe(16'h8140, "OR.W D0,D0 dir1?");
            probe(16'hC180, "grpC sel10000?");
            probe(16'h00D0, "CMP2.B (A0),Rn");
            probe(16'h0ED0, "CAS.B (A0)");
            probe(16'h0E10, "MOVES.B (A0)");
            probe(16'h08D0, "BSET #n,(A0)");
            $finish;
        end

        // ── ext_words must not depend on the NORMALISED ext ─────────────────
        // mh030p_top relies on this: the peek decoder that tells the fetch unit
        // how many words to drain is fed ext_raw rather than the fetch unit's
        // own ext, because ext is muxed BY ext_words and taking it there closes
        // a combinational cycle (a false one, but place-and-route unrolls it
        // regardless, and it cost 78% of the core's worst path).
        //
        // The property was originally stated as "ext_words is a function of the
        // OPCODE alone", which was true while only the brief format was counted.
        // It is not true any more and must not be: a full-format extension word
        // carries extra displacement words, and they have to be counted or the
        // instruction stream derails. The real requirement -- the one the
        // loop-break actually needs -- is the narrower one checked here:
        // ext_words must not depend on the NORMALISED `ext`. So this varies
        // `ext` while holding instr, ext_raw and q3 fixed.
        ext_alt_bad = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            instr = i[15:0];
            ext = 32'hA4A5_3C7F; #1;
            ew_ref = uop.ext_words;
            ext = 32'h5B5A_C380; #1;
            if (uop.ext_words !== ew_ref) begin
                if (ext_alt_bad < 10)
                    $display("EXTWORDS-DEPENDS-ON-NORMALISED-EXT op=%04h %0d vs %0d",
                             instr, ew_ref, uop.ext_words);
                ext_alt_bad = ext_alt_bad + 1;
            end
        end
        ext = 32'hA4A5_3C7F; #1;
        $display("  ext_words independent of normalised ext: %s (%0d differ)",
                 (ext_alt_bad == 0) ? "yes" : "NO", ext_alt_bad);

        // ── Shallow ext_words_fast vs the real (brief-format) ext_words ─────
        // Oracle is u_new's OWN uop.ext_words, not the reference (see
        // plan.md's "Full-format addendum profiled" session: the reference's
        // own full-format counting is known wrong, so it cannot validate a
        // replacement). Run with ext held at the fixed BRIEF-format pattern
        // already set above (bit 8 of the first word clear), so the real
        // ext_words' full-format addendum is always 0 and the two values are
        // directly comparable -- ext_words_fast does not model full format at
        // all yet (Stage 1, part 2, not started this session). Checked for
        // EVERY opcode, not just claimed ones: the real decoder computes
        // ext_words even for UC_UNIMPL so the fetch unit can drain correctly,
        // and ext_words_fast must match that, not just the claimed subset.
        ew_fast_bad = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            instr = i[15:0];
            #1;
            if (u_new.ext_words_fast_o !== uop.ext_words) begin
                if (ew_fast_bad < 20)
                    $display("EXTWORDS-FAST-MISMATCH op=%04h fast=%0d real=%0d",
                             instr, u_new.ext_words_fast_o, uop.ext_words);
                ew_fast_bad = ew_fast_bad + 1;
            end
        end
        $display("  ext_words_fast (brief-format) vs real: %s (%0d differ)",
                 (ew_fast_bad == 0) ? "yes" : "NO", ew_fast_bad);

        for (i = 0; i < 65536; i = i + 1) begin
            instr = i[15:0];
            #1;   // settle both combinational decoders

            if (uop.valid && (uop.uclass != UC_UNIMPL)
                          && (uop.uclass != UC_INVALID)) begin
                claimed = claimed + 1;

                // The old decoder must also consider this a real instruction.
                if (!old_valid) begin
                    report(instr, "old-invalid", 32'h1, 32'h0);
                end else begin
                    // TRAP's size is excluded deliberately. The reference
                    // decoder handles TRAP #0-7 and TRAP #8-15 in two
                    // different branches (its own comment at
                    // eu_seq_decode.svh says so), so #0-7 inherit f_siz=word
                    // from a shared prefix while #8-15 report long. With
                    // unit=NONE there is no sized operand either way, so the
                    // difference is an artifact of which branch matched, not
                    // semantics -- dec_is_trap/dec_trap_num are correct in
                    // both. The new decoder uses one consistent size rather
                    // than reproducing the artifact.
                    if ((uop.uclass != UC_TRAP) && (uop.siz !== old_siz))
                        report(instr, "siz", {30'h0, uop.siz}, {30'h0, old_siz});
                    else if (uop.unit !== old_unit)
                        report(instr, "unit", {29'h0, uop.unit}, {29'h0, old_unit});
                    else if ((uop.unit == UU_ALU) && (uop.alu_op !== old_alu_op))
                        report(instr, "alu_op", {28'h0, uop.alu_op},
                                                {28'h0, old_alu_op});
                    // uop.alu_op doubles as the md_op / bit_op field for
                    // those units, so check it there too rather than leaving
                    // those families compared on size and flags alone.
                    else if (((uop.unit == UU_MUL) || (uop.unit == UU_DIV))
                             && (uop.alu_op[2:0] !== old_md_op))
                        report(instr, "md_op", {29'h0, uop.alu_op[2:0]},
                                               {29'h0, old_md_op});
                    else if ((uop.unit == UU_BIT)
                             && (uop.alu_op[1:0] !== old_bit_op))
                        report(instr, "bit_op", {30'h0, uop.alu_op[1:0]},
                                                {30'h0, old_bit_op});
                    else if (uop.writes_reg !== old_wr_reg)
                        report(instr, "writes_reg", {31'h0, uop.writes_reg},
                                                    {31'h0, old_wr_reg});
                    else if (uop.updates_ccr !== old_upd_ccr)
                        report(instr, "updates_ccr", {31'h0, uop.updates_ccr},
                                                     {31'h0, old_upd_ccr});
                    else if (uop.writes_reg && (uop.dst_reg !== old_dst_reg))
                        report(instr, "dst_reg", {28'h0, uop.dst_reg},
                                                 {28'h0, old_dst_reg});
                    // How many extension words this opcode consumes. Getting
                    // this wrong does not produce a wrong ANSWER, it derails the
                    // instruction stream -- the following word is executed as an
                    // instruction, or a real instruction is swallowed as an
                    // operand. Eight of these were found one at a time before
                    // the check existed.
                    // Two families are excluded, because the REFERENCE is the
                    // limited party rather than this decoder:
                    //   * the F-line (MMU and coprocessor). Neither side models
                    //     its operand words in any detail -- both classify it and
                    //     stop -- so agreement would be coincidence.
                    //   * bit fields with a full effective address. CLAUDE.md
                    //     records that rtl/'s own bit-field EA support lacks
                    //     indexed, abs.L and PC-relative, so its count for those
                    //     reflects that gap. A specification word plus a
                    //     displacement is two words, and that is what this
                    //     decoder reports.
                    else if ((uop.ext_words !== old_ext_words)
                             && (instr[15:12] != 4'hF)
                             && !((uop.uclass == UC_BITFIELD)
                                  && (uop.ea_mode != UEA_NONE))
                    // The MOVE CCR,<ea> exclusion that used to sit here is GONE,
                    // because the inconsistency it tolerated is fixed. It read:
                    // eu_seq_decode.svh reports valid=1 for 0x42E8
                    // (MOVE CCR,(d16,A0)) while m68030_seq.sv's ext_count returned
                    // 0 -- a two-word instruction counted as one. m68030_seq.sv now
                    // has an is_move_sr_ccr_memdst arm, all 18 such opcodes agree,
                    // and this check covers them like any other.
                                  )
                        report(instr, "ext_words", {29'h0, uop.ext_words},
                                                   {29'h0, old_ext_words});
                    // EA displacement / index fields. dec_ea_offset is a
                    // heavily REUSED field in the reference: it carries the
                    // (An)+/-(An) delta for auto-increment modes and the
                    // stack predecrement (-4) for PEA, among others. So this
                    // is checked only for classes where the EA is genuinely a
                    // data operand and the field genuinely holds a
                    // displacement, and only when the decoder says the
                    // position is unambiguous (ea_disp_valid).
                    else if (ea_operand_class && uop.ea_disp_valid
                             && (uop.ea_mode == UEA_AN_D16)
                             && (uop.ea_disp !== old_ea_off))
                        report(instr, "ea_disp16", uop.ea_disp, old_ea_off);
                    else if (ea_operand_class && uop.ea_disp_valid
                             && (uop.ea_mode == UEA_AN_IDX)
                             && (uop.ea_disp !== old_ea_off))
                        report(instr, "ea_disp8", uop.ea_disp, old_ea_off);
                    else if (ea_operand_class && uop.ea_disp_valid
                             && (uop.ea_mode == UEA_AN_IDX)
                             && (uop.ea_idx_long !== old_xn_wl))
                        report(instr, "xn_wl", {31'h0, uop.ea_idx_long},
                                               {31'h0, old_xn_wl});
                    else if (ea_operand_class && uop.ea_disp_valid
                             && (uop.ea_mode == UEA_AN_IDX)
                             && (uop.ea_idx_scale !== old_xn_scale))
                        report(instr, "xn_scale", {30'h0, uop.ea_idx_scale},
                                                  {30'h0, old_xn_scale});
                    else
                        agreed = agreed + 1;
                end
            end else if (old_valid) begin
                old_only = old_only + 1;
                gap_by_group[i[15:12]] = gap_by_group[i[15:12]] + 1;
                // Keep the first few unclaimed opcodes per group so the next
                // family to implement can be identified without guessing.
                if (gap_sample_n[i[15:12]] < 4) begin
                    gap_sample[i[15:12]][gap_sample_n[i[15:12]]] = i[15:0];
                    gap_sample_n[i[15:12]] = gap_sample_n[i[15:12]] + 1;
                end
            end
        end

        // ── FULL-FORMAT extension-word count ────────────────────────────────
        // The pass above runs with bit 8 CLEAR, i.e. brief format everywhere,
        // which is deliberate (see the note at the drive) but it means the
        // full-format count was never checked at all -- and it was wrong, in the
        // way that derails the instruction stream rather than giving a wrong
        // answer. This pass drives a genuine full-format word and compares the
        // count against the reference sequencer, which does implement it.
        //
        // The words are driven SYMMETRICALLY -- both halves of ext and ext_raw
        // and q3 all the same -- so that whichever position either side reads as
        // "the EA's extension word", it sees the same value. That removes
        // positional ambiguity from the comparison, which is about the COUNT.
        // Widened from 3 shapes to 8. The original three covered +0/+2/+4 words,
        // which exercises the bd and od sizes but never an ASYMMETRIC pair (bd
        // one size, od another) and never the base/index-suppress bits. A
        // shallow re-implementation of this count has to get all of those right,
        // so they are swept before the logic is touched rather than after.
        //
        // BUT NOTE WHICH ORACLE THIS PASS USES, because it is the wrong one for
        // that job. It compares against the REFERENCE sequencer, and the
        // reference is known wrong here -- which is why this pass is
        // reporting-only (m68030_seq.sv's ext_count miscounts MOVE with an
        // indexed EA at both ends in full format; this pass is what found it).
        // Widening from 3 shapes to 8 took the disagreement count to 18,115,
        // which says more about the reference than about this decoder.
        //
        // So a shallow ext_words decoder must be checked against THIS decoder's
        // own ext_words, not against the reference: mh030p_decode is what passes
        // Harte and the cosims, so it is the trustworthy oracle for a
        // like-for-like replacement. These shapes are what that comparison
        // should sweep.
        for (ffv = 0; ffv < 8; ffv = ffv + 1) begin
            case (ffv)
                // bit 8 full format; bit 7 BS; bit 6 IS;
                // bits [5:4] bd size (01 null, 10 word, 11 long);
                // bits [2:0] I/IS (000 = no memory indirect).
                0: ffw = 16'h3110;   // null bd, no memory indirect -> +0 words
                1: ffw = 16'h3122;   // word bd, word od            -> +2 words
                2: ffw = 16'h3133;   // long bd, long od            -> +4 words
                3: ffw = 16'h3121;   // word bd, null od            -> +1 word
                4: ffw = 16'h3130;   // long bd, no indirect        -> +2 words
                5: ffw = 16'h3123;   // word bd, LONG od (asymmetric) -> +3
                6: ffw = 16'h31A2;   // BS set,  word bd, word od   -> +2 words
                default: ffw = 16'h3162;  // IS set, word bd, word od -> +2 words
            endcase
            ext = {ffw, ffw}; ext_rawv = {ffw, ffw}; q3w = ffw;
            for (i = 0; i < 65536; i = i + 1) begin
                instr = i[15:0]; #1;
                if (uop.valid && (uop.uclass != UC_UNIMPL)
                              && (uop.uclass != UC_INVALID) && old_valid) begin
                    ff_checked = ff_checked + 1;
                    if (uop.ext_words !== old_ext_words) begin
                        if (ff_bad < 12)
                            $display("FF-EXTWORDS op=%04h ffw=%04h new=%0d old=%0d",
                                     instr, ffw, uop.ext_words, old_ext_words);
                        ff_bad = ff_bad + 1;
                        ff_grp[i[15:12]] = ff_grp[i[15:12]] + 1;
                    end
                end
            end
        end
        ext = 32'hA4A5_3C7F; ext_rawv = 32'hA4A5_3C7F; q3w = 16'h5A91; #1;
        $display("  full-format ext_words: %0d checked, %0d disagreement(s)",
                 ff_checked, ff_bad);
        $write("    disagreements by opcode group:");
        for (ffv = 0; ffv < 16; ffv = ffv + 1)
            if (ff_grp[ffv] != 0) $write("  %1h:%0d", ffv[3:0], ff_grp[ffv]);
        $display("");
        // REPORTING ONLY, deliberately. The reference is NOT trustworthy here:
        // for MOVE with an indexed EA at BOTH ends it counts 2 words in brief
        // format but only 1 once the source word is full format, even for a
        // null-bd/no-memory-indirect word that needs exactly as many words as
        // brief -- so it drops the DESTINATION's extension word and would drain
        // one word short. Confirmed directly:
        //     op 0x11b0 brief   new=2 old=2   (agree)
        //     op 0x11b0 ff 3110 new=2 old=1   (reference loses the dst word)
        //     op 0x2e34 ff 3110 new=1 old=1   (indexed source only: agree)
        // That is a genuine bug in frozen rtl/, of the stream-derailment class
        // this project has hit repeatedly. Fixing it there needs its own full
        // gate including the 124-suite sweep, so it is recorded rather than
        // silently matched -- and until it is resolved this check cannot be a
        // hard gate in either direction. See plan.md.

        $display("");
        $display("claimed by new decoder : %0d", claimed);
        $display("  agreed with old      : %0d", agreed);
        $display("  mismatches           : %0d", mismatches);
        $display("old-only (not yet done): %0d  <- coverage gap, not a failure",
                 old_only);
        $write("  remaining by opcode group:");
        for (g = 0; g < 16; g = g + 1)
            if (gap_by_group[g] != 0) $write("  %0h:%0d", g, gap_by_group[g]);
        $display("");
        if ($test$plusargs("gaps"))
            for (g = 0; g < 16; g = g + 1)
                if (gap_by_group[g] != 0) begin
                    $write("    group %0h first unclaimed:", g);
                    for (k = 0; k < gap_sample_n[g]; k = k + 1)
                        $write(" %04h", gap_sample[g][k]);
                    $display("");
                end
        $display("");
        if (ext_alt_bad != 0) begin
            $display("=== %0d opcode(s) derive ext_words from the NORMALISED ext ===",
                     ext_alt_bad);
            $fatal(1);
        end
        if (mismatches == 0) begin
            $display("=== 0 failure(s) ===");
            $display("ALL TESTS PASSED");
        end else begin
            $display("=== %0d failure(s), first at opcode %04h ===",
                     mismatches, first_bad[15:0]);
        end
        $finish;
    end

endmodule

`default_nettype wire
