// Split out of rtl/eu_seq.sv (was lines 583-6291 of the original 11,001-line
// file) purely for navigability -- `` `include ``'d back into eu_seq.sv's own
// module body at the exact point this text used to live, so the compiled/
// elaborated module is byte-identical to before. NOT standalone-compilable:
// no `module`/`endmodule` of its own, and deliberately no
// `` `default_nettype `` bracketing of its own -- that directive is not
// file-scoped, and must stay set exactly once, in the parent file
// (rtl/eu_seq.sv itself). Depends on rtl/eu_seq.sv's own port list, local
// parameters, pre-extracted instruction-field assigns, and shared helper
// functions/tasks (eval_cc/calc_step/eu_lane/grp_aop/grp_xop/
// setup_mem_incdec), all of which stay in the parent file, included before
// this file.
//
// Pure combinational decode stage: computes every `dec_*` signal from
// instr_word/ext_data/etc, no state, no side effects. See rtl/eu_seq.sv's
// own "DECODE stage" banner immediately below for where the original text
// began.

    // -----------------------------------------------------------------------
    // DECODE stage — purely combinational
    // All instr_word bit-selects replaced with pre-extracted signals.
    // -----------------------------------------------------------------------
    logic        dec_valid, dec_writes_reg, dec_updates_ccr;
    logic        dec_x_unchanged, dec_use_imm, dec_use_reg_cnt, dec_needs_ext;
    logic        dec_reads_src, dec_reads_dst, dec_reads_c;
    logic [2:0]  dec_unit;
    logic [3:0]  dec_alu_op, dec_shf_op;
    logic [2:0]  dec_md_op;
    logic [3:0]  dec_src_reg;   // rd_a: source operand register
    logic [3:0]  dec_dst_reg;   // rd_b: destination/second-operand register
    logic [3:0]  dec_c_reg;     // rd_c: 3rd simultaneous read (Phase 149, plan.md)
    logic [3:0]  dec_dest_reg;  // register to commit result into
    logic [1:0]  dec_siz;       // 00=long, 01=byte, 10=word
    logic [31:0] dec_imm;
    logic [5:0]  dec_shf_imm_cnt;
    logic [1:0]  dec_bcd_op;
    logic [1:0]  dec_bit_op;
    logic [4:0]  dec_bit_num;       // immediate bit number
    logic        dec_bit_from_reg;
    logic        dec_is_branch;    // BRA/Bcc: redirects PC at decode time
    logic        dec_is_dbcc;      // DBcc: branch decision deferred to EX stage
    logic        dec_reads_ccr;    // stall if pending CCR write in EX or WB
    logic        dec_reads_usp;    // stall if pending USP write (MOVE An,USP) in EX or WB -- Phase 161 Part A Stage A2
    logic [3:0]  dec_branch_cond;  // condition code for Bcc/Scc/DBcc
    logic [31:0] dec_branch_disp;  // branch displacement (relative to PC+2)
    logic        dec_is_swap;      // SWAP Dn: swap halfwords in EX
    logic        dec_sext;         // EXT sign-extend operation
    logic        dec_sext_from_byte; // 1=extend byte, 0=extend word
    // Memory-access decode signals
    logic        dec_is_mem_rd;   // instruction needs a memory read
    logic        dec_is_mem_wr;   // instruction needs a memory write
    logic        dec_is_lea;      // LEA: result is the EA itself (no bus cycle)
    logic        dec_is_movea_w;  // MOVEA.W: sign-extend mem_rdata[15:0] in WB
    logic [31:0] dec_ea_offset;   // EA offset: 0, +d16, or -step (for -(An))
    logic [31:0] dec_an_delta;    // An update: +step (An)+, -step -(An), 0 otherwise
    logic        dec_an_upd_en;   // An register needs updating
    logic [2:0]  dec_an_upd_reg;  // which An to update (the EA register)
    // subroutine / jump instructions
    logic        dec_is_jmp;      // JMP ea
    logic        dec_is_jsr;      // JSR ea (push return PC then jump)
    logic        dec_is_bsr;      // BSR disp (push return PC then relative branch)
    logic        dec_is_rts;      // RTS (pop PC from stack)
    logic        dec_is_rtr;      // RTR (pop CCR+PC from stack; 2 reads)
    logic        dec_is_link;     // LINK An, #d16
    logic        dec_is_unlk;     // UNLK An
    // absolute EA
    logic        dec_abs_ea_en;   // EA is absolute (overrides An+offset for bus cycle)
    logic        dec_abs_jmp_en;  // branch target is absolute (for JMP/JSR abs; separate from EA)
    logic [31:0] dec_abs_ea_val;  // pre-computed absolute address (shared by both flags)
    logic [31:0] dec_return_pc;   // return address pushed by JSR/BSR
    logic [31:0] dec_bsr_target;  // pre-computed BSR target = decode_pc+2+disp
    logic [31:0] dec_jump_offset; // JMP/JSR target offset (0 for (An), d16 for (d16,An))
    // brief indexed EA (d8,An,Xn)
    logic        dec_is_idx;     // brief indexed EA mode active
    logic        dec_xn_wl;     // Xn size: 0=word(sign-ext to 32), 1=longword
    logic [1:0]  dec_xn_scale;  // Xn scale: 00=×1, 01=×2, 10=×4, 11=×8
    // dynamic bit op with indexed EA — Dn (bit count) supplied separately
    logic        dec_is_dyn_bit_idx; // 1 when BTST/BCHG/BCLR/BSET Dn,(d8,An,Xn)
    logic [2:0]  dec_dyn_bit_reg;   // f_dn register selector for the bit count
    logic        dec_dyn_bit_is_an; // 1 when dyn_bit_reg selects an address register
    logic        dec_dyn_bit_swap_a; // 1: dyn_bit swap targets rd_a instead of rd_b
                                      // (MOVE mem-src,(d8,An_dst,Xn): rd_a=src_An during
                                      // the read, swaps to dst_An at read_ack; rd_b stays
                                      // fixed = dst_Xn throughout, no swap needed there)
    // second dyn_bit swap target — for MOVE (d8,An_src,Xn),(d8,An_dst,Xn): both sides
    // indexed, so rd_a AND rd_b both need to swap at read_ack (rd_a: src_An->dst_An
    // via dyn_bit_reg/is_an as usual; rd_b: src_Xn->dst_Xn via this second target).
    logic        dec_dyn_bit_swap_both; // 1: swap BOTH rd_a and rd_b at read_ack
    logic [2:0]  dec_dyn_bit_reg2;      // dst_Xn register selector (2nd swap target)
    logic        dec_dyn_bit_is_an2;    // 1 when dyn_bit_reg2 selects an address register
    // destination's own indexed-EA scale/wl, separate from dec_xn_wl/dec_xn_scale
    // (which the source uses for its own indexed EA when both sides are indexed —
    // e.g. MOVE (d8,An_src,Xn),(d8,An_dst,Xn) — the move_mm_dst_addr_r capture
    // formula picks dst_xn_wl/dst_xn_scale over the shared fields when this is set).
    logic        dec_dst_is_idx;
    logic        dec_dst_xn_wl;
    logic [1:0]  dec_dst_xn_scale;
    logic        dec_is_bit_imm;    // 1 when BTST Dn,#imm — immediate byte as bit_dst
    // MOVEM register save/restore
    logic        dec_is_movem;      // MOVEM instruction
    logic        dec_movem_load;     // 1=mem→reg (load), 0=reg→mem (store)
    logic        dec_movem_predec;   // 1=-(An) predecrement mode (store only)
    logic        dec_movem_postinc;  // 1=(An)+ post-increment mode (load only)
    logic        dec_movem_long;     // 1=longword (f_ss[0]), 0=word
    logic        dec_movem_mask_hi;  // 1=mask in ext_data[31:16] (2-ext-word EA modes)
    // MOVEC / MOVES
    logic        dec_is_movec;      // MOVEC instruction (Rn→Rc direction only; Rc→Rn uses dec_use_imm)
    logic        dec_movec_to_ctrl; // 1=Rn→Rc (write to ctrl reg)
    logic        dec_is_moves;      // MOVES instruction
    logic        dec_moves_load;    // 1=load (ea→Rn, SFC), 0=store (Rn→ea, DFC)
    // TAS
    logic        dec_is_tas;        // TAS.B instruction (test and set byte)
    // Scc
    logic        dec_is_scc_dn;     // Scc Dn (register-direct form only, not Scc <ea>)
    // CHK, CMP2, CHK2
    logic        dec_is_chk;        // CHK <ea>,Dn
    logic        dec_chk_word;      // 1=CHK.W (size word), 0=CHK.L (size long)
    logic        dec_is_cmp2chk2;   // CMP2 or CHK2 two-bound compare
    // MOVEP
    logic        dec_is_movep;      // MOVEP instruction
    logic        dec_movep_load;    // 1=mem→Dn (load), 0=Dn→mem (store)
    logic        dec_movep_long;    // 1=longword (4 bytes), 0=word (2 bytes)
    // MOVE16
    logic        dec_is_move16;     // MOVE16 instruction
    logic [1:0]  dec_move16_form;   // 00=(An)+/(Am)+, 01=(An)+/abs, 10=abs/(An)+, 11=(An)/(An)
    // FPU coprocessor dispatch stub
    logic        dec_is_fpu;        // Group F FPU instruction (cpid=1)
    logic        dec_is_cpsave;     // cpSAVE (Phase 157 Stage 4)
    logic        dec_is_cprestore;  // cpRESTORE (Phase 157 Stage 4)
    // memory-indirect EA ([bd,An],Xn,od)
    logic        dec_is_memind;       // instruction uses memory-indirect EA (full ext, fi_iis != 0)
    logic        dec_memind_is_post;  // 1=post-indexed (IS=1: Xn to outer), 0=pre-indexed
    logic [31:0] dec_memind_od;       // outer displacement
    // ALU-EA genuine indirect EA (plan.md, general ALU-with-EA-source stage):
    // the memind FSM's own outer-read bus size (memind_siz_r in
    // eu_seq_execute.svh) historically just captured dec_siz directly, which
    // is correct for MOVE (dec_siz IS its own read size) and for
    // LEA/PEA/JMP/JSR (dec_siz is always forced longword there, matching
    // their own always-32-bit address/PC handling) but is WRONG for
    // MULU/MULS/DIVU/DIVS, whose dec_siz reflects the 32-bit RESULT written
    // to Dn while the actual memory OPERAND read must stay 16-bit
    // (dec_mem_rd_siz already captures this correctly for their own
    // existing non-indirect indexed case). dec_memind_rd_siz decouples the
    // two: every memind-dispatching family sets it explicitly (MOVE's own
    // arm to dec_siz, the new ALU-EA arms to dec_mem_rd_siz, matching
    // whichever already reflects their own real read size); LEA/PEA/JMP/JSR
    // are untouched and rely on the default below, which already equals
    // what their own dec_siz always is.
    logic [1:0]  dec_memind_rd_siz;

    // MMU instruction decode signals
    logic        dec_is_pflush;
    logic        dec_pflush_all;
    logic [2:0]  dec_pflush_fc;
    logic        dec_is_ptest;
    logic [2:0]  dec_ptest_fc;
    logic        dec_is_pload;       // Phase 150 Stage 5
    logic [2:0]  dec_pload_fc;
    logic        dec_pload_rw;
    logic        dec_is_pmove;
    logic        dec_is_pmove64;     // 64-bit PMOVE (CRP/SRP)
    logic        dec_is_mem_src;     // memory source + register accumulator → register result
    logic [2:0]  dec_pmove_preg;
    logic        dec_pmove_to_mem;   // 1=register→EA (write), 0=EA→register (read)

    // new exception / trace decode signals
    logic        dec_is_jsr_idx;   // JSR (d8,An,Xn) or (d8,PC,Xn) — push via ex_cur_sp, not rd_b
    logic        dec_is_pea_idx;   // PEA (d8,An,Xn) — push EA via ex_cur_sp; rd_b=Xn, rd_a=An
    logic        dec_is_trace;     // trace exception fires after this instruction retires
    logic        dec_is_priv;      // privilege violation (supervisor-only opcode in user mode)
    logic        dec_is_linea;     // Line-A opcode (Group A) → vector 10
    logic        dec_is_linef;     // Line-F non-FPU/MMU/MOVE16 (Group F) → vector 11
    // Forward declaration — needed by dec_is_flow_chg (assigned below BRA/Bcc section)
    logic        dec_branch_taken;

    // OS control / exception instructions
    logic        dec_is_rte;         // RTE (return from exception)
    logic        dec_is_stop;        // STOP #sr
    logic [15:0] dec_stop_sr;        // new SR value from extension word
    logic        dec_is_trap;        // TRAP #n
    logic [3:0]  dec_trap_num;       // trap number (0–15)
    logic        dec_is_trapv;       // TRAPV
    logic        dec_is_illegal;     // ILLEGAL
    logic        dec_is_bkpt;        // BKPT #n (Phase 157 Stage 3)
    logic        dec_is_move_sr_r;   // MOVE SR,Dn  (read SR → register)
    logic        dec_is_move_ccr_r;  // MOVE CCR,Dn (read CCR → register)
    logic        dec_is_move_sr_w;   // MOVE Dn,SR  (write register → full SR)
    logic        dec_is_move_ccr_w;  // MOVE Dn,CCR (write register → CCR only)
    logic        dec_is_move_usp;    // MOVE An,USP (write An → USP)
    logic        dec_sext_src;      // sign-extend ALU source from 16→32 bits (ADDA.W/SUBA.W/CMPA.W)
    logic [1:0]  dec_mem_rd_siz;    // bus-read size override (0=use ex_siz)
    // MULU.L/MULS.L/DIVU.L/DIVS.L
    logic        dec_is_muldivl;   // instruction is a long mul/div
    logic [2:0]  dec_md_dst2;      // Dh (MUL) or Dr (DIV) register number
    logic        dec_md_64bit;     // 1=write second register (Dh/Dr distinct from Dl/Dq)
    // PEA, EXG, RTD, CMPM
    logic        dec_is_pea;       // PEA (push EA to stack at A7-=4)
    logic        dec_is_exg;       // EXG (register exchange)
    logic        dec_exg_dd;       // 1=Dx,Dy (wr2 port); 0=Ax,Ay or Dx,Ay (an_wr)
    logic        dec_is_cmpm;      // CMPM (Ay)+,(Ax)+ — two-phase memory compare

    // memory-destination ALU RMW
    logic        dec_is_mem_rmw;   // read-modify-write: read EA, ALU op, write back

    // ADDX/SUBX -(Ay),-(Ax) memory predecrement form
    logic        dec_is_addx_mem;  // 3-phase predecrement read-read-write FSM

    // MOVE memory→memory (2-phase: read src EA, write to dst EA)
    logic        dec_is_move_mm;
    logic        dec_is_move_mm_idx_dst; // dst is (d8,An,Xi); src is abs.L or PC-rel
    logic        dec_is_move_reg_idx_dst; // MOVE Dn/An→(d8,An,Xi): plain write, source reg on rd_c (Phase 149)
    logic [31:0] dec_dst_ea_offset;
    logic        dec_abs_dst_ea_en;
    logic [31:0] dec_abs_dst_ea_val;
    logic        dec_dst_an_upd_en;
    logic [2:0]  dec_dst_an_upd_reg;
    logic [31:0] dec_dst_an_delta;

    // TRAPcc, CAS EU decode, BCD/bit-op memory forms
    logic        dec_is_cas;          // CAS Dc,Du,(An) — compare-and-swap
    logic [2:0]  dec_cas_du_reg;      // Du register number from ext_data[2:0]
    logic        dec_is_abcd_sbcd_mem; // ABCD/SBCD -(Ay),-(Ax) memory form
    logic        dec_is_abcd_mem;     // 1=ABCD, 0=SBCD (only valid when dec_is_abcd_sbcd_mem)

    // CAS2 EU decode
    logic        dec_is_cas2;         // CAS2 Dc1:Dc2,Du1:Du2,(Rn1):(Rn2)
    logic [2:0]  dec_cas2_du1_reg;    // Du1 register from ext_data[10:8]
    logic [3:0]  dec_cas2_rn2_reg;    // {is_an, reg[2:0]} Rn2 from ext_data[19:16]
    logic [2:0]  dec_cas2_dc2_reg;    // Dc2 register from ext_data[30:28]
    logic [2:0]  dec_cas2_du2_reg;    // Du2 register from ext_data[26:24]

    // bit-field instructions (BFTST/BFEXTU/BFCHG/BFEXTS/BFCLR/BFFFO/BFSET/BFINS)
    logic        dec_is_bf;        // bit-field instruction
    logic [2:0]  dec_bf_op;        // {f_dn[1:0], f_dir}: 000=TST 001=EXTU 010=CHG 011=EXTS 100=CLR 101=FFO 110=SET 111=INS
    logic        dec_bf_reg_ea;    // 1=register EA (Dn), 0=memory EA ((An))
    logic        dec_bf_mutates;   // 1=CHG/CLR/SET/INS (modifies field in place)

    // PACK/UNPK/LINK.L/RESET
    logic        dec_is_pack;      // PACK instruction (register or memory form)
    logic        dec_is_unpk;      // UNPK instruction (register or memory form)
    logic        dec_is_pack_mem;  // 1=memory form -(Ay),-(Ax), 0=register form Dy,Dx
    logic        dec_is_reset;     // RESET instruction (pulse RSTOUT)

    // Control register read mux for MOVEC Rc→Rn (ext_data[11:0] = Rc code)
    logic [31:0] ctrl_reg_rd_val;
    always_comb begin
        case (ext_data[11:0])
            12'h000: ctrl_reg_rd_val = {29'h0, sfc_in};
            12'h001: ctrl_reg_rd_val = {29'h0, dfc_in};
            // Phase 158 Stage 6: manual §6.3.1.3/6.3.1.4/6.3.1.8/6.3.1.9 +
            // §6.3.1 itself (confirmed by direct re-read) -- CD/CED/CI/CEI
            // (bits 11/10/3/2, the self-clearing "pulse" trigger bits) "are
            // always read as a zero", and bits 31-14 + 7-5 are reserved,
            // "currently read as zeros." This masks only the MOVEC-readback
            // path -- cacr_in feeds *only* this mux (confirmed via grep,
            // eu_seq.sv's only other CACR-shaped signal is the separate,
            // deliberately-unmasked `cacr` input biu_cache_if.sv/
            // biu_icache_if.sv read directly for their own CD/CED/CI/CEI
            // clear-trigger detection -- masking that one instead would
            // break the clear mechanism entirely, since it needs to
            // observe the momentary 1 software just wrote).
            12'h002: ctrl_reg_rd_val = {18'h0, cacr_in[13:12], 2'b00, cacr_in[9:8],
                                         3'h0, cacr_in[4], 2'b00, cacr_in[1:0]};
            12'h800: ctrl_reg_rd_val = usp_in;
            12'h801: ctrl_reg_rd_val = vbr_in;
            12'h802: ctrl_reg_rd_val = caar_in;
            12'h803: ctrl_reg_rd_val = msp_in;
            12'h804: ctrl_reg_rd_val = isp_in;
            default: ctrl_reg_rd_val = 32'h0;
        endcase
    end

    always_comb begin
        // ── Decode valid / execution unit ──────────────────────────────────────
        dec_valid        = 1'b0;
        dec_unit         = UNIT_NONE;

        // ── ALU / shifter / mul-div / BCD / bit-op ─────────────────────────────
        dec_alu_op       = ALU_ADD;
        dec_shf_op       = SHF_LSL;
        dec_shf_imm_cnt  = 6'd1;
        dec_md_op        = MUL_UW;
        dec_md_dst2      = 3'b0;
        dec_md_64bit     = 1'b0;
        dec_bcd_op       = BCD_ADD;
        dec_bit_op       = BIT_TST;
        dec_bit_num      = 5'h0;
        dec_bit_from_reg = 1'b0;
        dec_is_bit_imm   = 1'b0;

        // ── Register operands ──────────────────────────────────────────────────
        dec_src_reg      = 4'h0;
        dec_dst_reg      = 4'h0;
        dec_c_reg        = 4'h0;
        dec_dest_reg     = 4'h0;
        dec_reads_src    = 1'b0;
        dec_reads_dst    = 1'b0;
        dec_reads_c      = 1'b0;
        dec_writes_reg   = 1'b0;
        dec_sext_src     = 1'b0;

        // ── Size / CCR / flags ─────────────────────────────────────────────────
        dec_siz          = 2'b00;
        dec_updates_ccr  = 1'b0;
        dec_reads_ccr    = 1'b0;
        dec_reads_usp    = 1'b0;
        dec_x_unchanged  = 1'b0;
        dec_sext         = 1'b0;
        dec_sext_from_byte = 1'b0;
        dec_use_reg_cnt  = 1'b0;

        // ── Immediate / extension word ─────────────────────────────────────────
        dec_imm          = ext_data;
        dec_use_imm      = 1'b0;
        dec_needs_ext    = 1'b0;

        // ── EA / addressing ────────────────────────────────────────────────────
        dec_ea_offset    = 32'h0;
        dec_an_delta     = 32'h0;
        dec_an_upd_en    = 1'b0;
        dec_an_upd_reg   = 3'h0;
        dec_abs_ea_en    = 1'b0;
        dec_abs_ea_val   = 32'h0;
        dec_is_idx       = 1'b0;
        dec_xn_wl        = 1'b0;
        dec_xn_scale     = 2'b00;
        dec_is_dyn_bit_idx = 1'b0;
        dec_dyn_bit_reg  = 3'b0;
        dec_dyn_bit_is_an = 1'b0;
        dec_dyn_bit_swap_a = 1'b0;
        dec_dyn_bit_swap_both = 1'b0;
        dec_dyn_bit_reg2   = 3'b0;
        dec_dyn_bit_is_an2 = 1'b0;
        dec_dst_is_idx     = 1'b0;
        dec_dst_xn_wl      = 1'b0;
        dec_dst_xn_scale   = 2'b00;

        // ── Memory access ──────────────────────────────────────────────────────
        dec_is_mem_rd    = 1'b0;
        dec_is_mem_wr    = 1'b0;
        dec_is_mem_rmw   = 1'b0;
        dec_is_mem_src   = 1'b0;
        dec_mem_rd_siz   = 2'b00;

        // ── Branches / jumps ───────────────────────────────────────────────────
        dec_is_branch    = 1'b0;
        dec_is_dbcc      = 1'b0;
        dec_branch_cond  = 4'h0;
        dec_branch_disp  = 32'h0;
        dec_is_jmp       = 1'b0;
        dec_is_jsr       = 1'b0;
        dec_is_jsr_idx   = 1'b0;
        dec_is_bsr       = 1'b0;
        dec_is_rts       = 1'b0;
        dec_is_rtr       = 1'b0;
        dec_abs_jmp_en   = 1'b0;
        dec_return_pc    = 32'h0;
        dec_bsr_target   = 32'h0;
        dec_jump_offset  = 32'h0;

        // ── Multi-operand / stack ops ──────────────────────────────────────────
        dec_is_swap      = 1'b0;
        dec_is_lea       = 1'b0;
        dec_is_movea_w   = 1'b0;
        dec_is_pea       = 1'b0;
        dec_is_pea_idx   = 1'b0;
        dec_is_link      = 1'b0;
        dec_is_unlk      = 1'b0;
        dec_is_exg       = 1'b0;
        dec_exg_dd       = 1'b0;
        dec_is_cmpm      = 1'b0;
        dec_is_addx_mem  = 1'b0;
        dec_is_muldivl   = 1'b0;

        // ── MOVEM ──────────────────────────────────────────────────────────────
        dec_is_movem      = 1'b0;
        dec_movem_load    = 1'b0;
        dec_movem_predec  = 1'b0;
        dec_movem_postinc = 1'b0;
        dec_movem_long    = 1'b0;
        dec_movem_mask_hi = 1'b0;

        // ── MOVE mem→mem ───────────────────────────────────────────────────────
        dec_is_move_mm        = 1'b0;
        dec_is_move_mm_idx_dst = 1'b0;
        dec_is_move_reg_idx_dst = 1'b0;
        dec_dst_ea_offset = 32'h0;
        dec_abs_dst_ea_en = 1'b0;
        dec_abs_dst_ea_val= 32'h0;
        dec_dst_an_upd_en = 1'b0;
        dec_dst_an_upd_reg= 3'b0;
        dec_dst_an_delta  = 32'h0;

        // ── Bit-field ──────────────────────────────────────────────────────────
        dec_is_bf        = 1'b0;
        dec_bf_op        = 3'b0;
        dec_bf_reg_ea    = 1'b0;
        dec_bf_mutates   = 1'b0;

        // ── PACK / UNPK ────────────────────────────────────────────────────────
        dec_is_pack      = 1'b0;
        dec_is_unpk      = 1'b0;
        dec_is_pack_mem  = 1'b0;

        // ── CAS / CAS2 ─────────────────────────────────────────────────────────
        dec_is_cas       = 1'b0;
        dec_cas_du_reg   = 3'b0;
        dec_is_cas2      = 1'b0;
        dec_cas2_du1_reg = 3'b0;
        dec_cas2_rn2_reg = 4'h0;
        dec_cas2_dc2_reg = 3'b0;
        dec_cas2_du2_reg = 3'b0;

        // ── TAS / CHK / CMP2 / MOVEP / MOVE16 ─────────────────────────────────
        dec_is_tas       = 1'b0;
        dec_is_scc_dn    = 1'b0;
        dec_is_chk       = 1'b0;
        dec_chk_word     = 1'b0;
        dec_is_cmp2chk2  = 1'b0;
        dec_is_movep     = 1'b0;
        dec_movep_load   = 1'b0;
        dec_movep_long   = 1'b0;
        dec_is_move16    = 1'b0;
        dec_move16_form  = 2'b0;

        // ── MOVEC / MOVES / USP / SR / CCR ────────────────────────────────────
        dec_is_movec     = 1'b0;
        dec_movec_to_ctrl = 1'b0;
        dec_is_moves     = 1'b0;
        dec_moves_load   = 1'b0;
        dec_is_move_usp  = 1'b0;
        dec_is_move_sr_r  = 1'b0;
        dec_is_move_ccr_r = 1'b0;
        dec_is_move_sr_w  = 1'b0;
        dec_is_move_ccr_w = 1'b0;

        // ── BCD / ABCD / SBCD ──────────────────────────────────────────────────
        dec_is_abcd_sbcd_mem = 1'b0;
        dec_is_abcd_mem  = 1'b0;

        // ── FPU / memory-indirect ──────────────────────────────────────────────
        dec_is_fpu       = 1'b0;
        dec_is_cpsave    = 1'b0;
        dec_is_cprestore = 1'b0;
        dec_is_memind    = 1'b0;
        dec_memind_is_post = 1'b0;
        dec_memind_od    = 32'h0;
        dec_memind_rd_siz = 2'b00;

        // ── MMU instructions ───────────────────────────────────────────────────
        dec_is_pflush    = 1'b0;
        dec_pflush_all   = 1'b0;
        dec_pflush_fc    = 3'b0;
        dec_is_ptest     = 1'b0;
        dec_ptest_fc     = 3'b0;
        dec_is_pload     = 1'b0;
        dec_pload_fc     = 3'b0;
        dec_pload_rw     = 1'b1;
        dec_is_pmove     = 1'b0;
        dec_is_pmove64   = 1'b0;
        dec_pmove_preg   = 3'b0;
        dec_pmove_to_mem = 1'b0;

        // ── Exceptions / privilege ─────────────────────────────────────────────
        dec_is_priv      = 1'b0;
        dec_is_linea     = 1'b0;
        dec_is_linef     = 1'b0;
        dec_is_illegal   = 1'b0;
        dec_is_bkpt      = 1'b0;
        dec_is_rte       = 1'b0;
        dec_is_stop      = 1'b0;
        dec_stop_sr      = 16'h0;
        dec_is_trap      = 1'b0;
        dec_trap_num     = 4'h0;
        dec_is_trapv     = 1'b0;
        dec_is_reset     = 1'b0;

        if (instr_valid) begin
            case (f_group)

                // ----------------------------------------------------------------
                // Group 0000: immediate ALU ops (ORI/ANDI/SUBI/ADDI/EORI/CMPI)
                //             + immediate bit ops (f_dn=100)
                //             + register bit ops (f_dir=1)
                // ----------------------------------------------------------------
                4'h0: begin
                    if (!f_dir && f_mode == 3'b000) begin
                        // f_dir=0: f_dn is subop selector
                        dec_dst_reg     = {1'b0, f_reg};
                        dec_dest_reg    = {1'b0, f_reg};
                        dec_updates_ccr = 1'b1;
                        dec_reads_dst   = 1'b1;
                        case (f_dn)
                            3'b100: begin
                                // BTST/BCHG/BCLR/BSET #imm,Dn
                                // f_ss encodes op: 00=BTST 01=BCHG 10=BCLR 11=BSET
                                dec_unit         = UNIT_BIT;
                                dec_siz          = 2'b00;  // longword for Dn dest
                                dec_needs_ext    = 1'b1;
                                dec_bit_num      = ext_bit_num;  // from extension word
                                dec_bit_from_reg = 1'b0;
                                dec_x_unchanged  = 1'b1;
                                case (f_ss)
                                    2'b00: begin dec_bit_op=BIT_TST; dec_valid=1'b1; end
                                    2'b01: begin dec_bit_op=BIT_CHG; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    2'b10: begin dec_bit_op=BIT_CLR; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    2'b11: begin dec_bit_op=BIT_SET; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                endcase
                            end
                            default: begin
                                // Immediate ALU ops
                                dec_siz     = f_siz;
                                dec_unit    = UNIT_ALU;
                                dec_use_imm = 1'b1;
                                dec_needs_ext = 1'b1;
                                case (f_dn)
                                    3'b000: begin dec_alu_op=ALU_OR;  dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    3'b001: begin dec_alu_op=ALU_AND; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    3'b010: begin dec_alu_op=ALU_SUB; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    3'b011: begin dec_alu_op=ALU_ADD; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    3'b101: begin dec_alu_op=ALU_EOR; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                    3'b110: begin dec_alu_op=ALU_CMP; dec_x_unchanged=1'b1; dec_valid=1'b1; end
                                    default: ;
                                endcase
                            end
                        endcase
                    end else if (f_dir && f_mode == 3'b000) begin
                        // Register BTST/BCHG/BCLR/BSET Dn,Dn
                        // f_dn = bit-count register, f_ss = op
                        dec_unit         = UNIT_BIT;
                        dec_siz          = 2'b00;
                        dec_src_reg      = {1'b0, f_dn};  // bit count reg → rd_a
                        dec_dst_reg      = {1'b0, f_reg};
                        dec_dest_reg     = {1'b0, f_reg};
                        dec_bit_from_reg = 1'b1;
                        dec_reads_src    = 1'b1;
                        dec_reads_dst    = 1'b1;
                        dec_updates_ccr  = 1'b1;
                        dec_x_unchanged  = 1'b1;
                        case (f_ss)
                            2'b00: begin dec_bit_op=BIT_TST; dec_valid=1'b1; end
                            2'b01: begin dec_bit_op=BIT_CHG; dec_writes_reg=1'b1; dec_valid=1'b1; end
                            2'b10: begin dec_bit_op=BIT_CLR; dec_writes_reg=1'b1; dec_valid=1'b1; end
                            2'b11: begin dec_bit_op=BIT_SET; dec_writes_reg=1'b1; dec_valid=1'b1; end
                        endcase
                    // ── immediate ALU ops to memory EA ──────────────
                    // ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm, <ea>
                    // <ea>: (An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(xxx).W/(xxx).L
                    // Excludes f_ss=11 (CMP2 overlap) and f_dn=100/111 (non-ALU subops).
                    // imm packing: byte/word in ext_data[31:16]; long in ext_data[31:0].
                    //   (d16,An)/(d8,An,Xn)/(xxx).W long: imm=ext_data, d16/brief/abs=q3_word.
                    //   (xxx).L long: imm=ext_data, abs64=ext34_data.
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001))) &&
                                 (f_dn != 3'b100 && f_dn != 3'b111)) begin
                        // Common preamble: shared by all five EA modes
                        dec_siz       = f_siz;
                        dec_unit      = UNIT_ALU;
                        dec_use_imm   = 1'b1;
                        dec_needs_ext = 1'b1;
                        dec_is_mem_rd = 1'b1;
                        // EA-mode-specific setup
                        case (f_mode)
                            3'b010: begin  // (An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                            end
                            3'b011: begin  // (An)+
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(f_siz, f_reg == 3'b111);
                            end
                            3'b100: begin  // -(An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(f_siz, f_reg == 3'b111) + 32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            3'b101: begin  // (d16,An): long→q3, byte/word→ext_data[15:0]
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_imm       = (f_ss == 2'b10) ? ext_data
                                                                 : {16'h0, ext_data[31:16]};
                                dec_ea_offset = (f_ss == 2'b10) ? {{16{q3_word[15]}},  q3_word}
                                                                 : {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b110: begin  // (d8,An,Xn): long→q3_word, byte/word→ext_data[15:0]
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_is_idx    = 1'b1;
                                dec_imm       = (f_ss == 2'b10) ? ext_data
                                                                 : {16'h0, ext_data[31:16]};
                                dec_dst_reg   = (f_ss == 2'b10) ? {q3_word[15],  q3_word[14:12]}
                                                                 : {ext_data[15], ext_data[14:12]};
                                dec_reads_dst  = 1'b1;
                                dec_xn_wl     = (f_ss == 2'b10) ? q3_word[11]    : ext_data[11];
                                dec_xn_scale  = (f_ss == 2'b10) ? q3_word[10:9]  : ext_data[10:9];
                                dec_ea_offset = (f_ss == 2'b10) ? {{24{q3_word[7]}},  q3_word[7:0]}
                                                                 : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            3'b111: begin  // (xxx).W (f_reg=0) or (xxx).L (f_reg=1)
                                dec_abs_ea_en  = 1'b1;
                                dec_imm        = (f_ss == 2'b10) ? ext_data
                                                                 : {16'h0, ext_data[31:16]};
                                dec_abs_ea_val = (f_reg == 3'b000)
                                    ? ((f_ss == 2'b10) ? {{16{q3_word[15]}},  q3_word}
                                                       : {{16{ext_data[15]}}, ext_data[15:0]})
                                    : ((f_ss == 2'b10) ? ext34_data
                                                       : {ext_data[15:0], ext34_data[31:16]});
                            end
                            default: ;
                        endcase
                        // Shared op decode — identical for all five EA modes above
                        case (f_dn)
                            3'b000: begin dec_alu_op=ALU_OR;  dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b001: begin dec_alu_op=ALU_AND; dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b010: begin dec_alu_op=ALU_SUB; dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b011: begin dec_alu_op=ALU_ADD; dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b101: begin dec_alu_op=ALU_EOR; dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b110: begin  // CMPI: compare only, no write-back
                                dec_alu_op      = ALU_CMP;
                                dec_x_unchanged = 1'b1;
                                dec_updates_ccr = 1'b1;
                                dec_valid       = 1'b1;
                            end
                            default: ;
                        endcase
                    // ── CMPI #imm, (d16,PC) ───────────────────────────────────────
                    // Only CMPI uses PC-relative EA (other imm ops use data-alterable EAs).
                    // byte/word: ext_data={imm_word, d16}; long: ext_data={hi_imm,lo_imm}, q3=d16.
                    // EA = address_of_d16_word + sign_ext(d16).
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && f_reg == 3'b010 &&
                                 f_dn == 3'b110) begin
                        dec_siz        = f_siz;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = ALU_CMP;
                        dec_use_imm    = 1'b1;
                        dec_needs_ext  = 1'b1;
                        dec_is_mem_rd  = 1'b1;
                        dec_abs_ea_en  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_valid      = 1'b1;
                        dec_imm        = (f_ss == 2'b10) ? ext_data
                                                          : {16'h0, ext_data[31:16]};
                        // byte/word: d16 at decode_pc+4; long: d16 at decode_pc+6
                        dec_abs_ea_val = (f_ss == 2'b10) ? decode_pc + 32'd6 + {{16{q3_word[15]}}, q3_word}
                                                          : decode_pc + 32'd4 + {{16{ext_data[15]}}, ext_data[15:0]};
                    // ── Register bit ops to memory EA (BCLR/BSET/BCHG/BTST) ──────────────
                    // BTST/BCHG/BCLR/BSET Dn, ea  (f_dir=1)
                    // Simple (An)/(An)+/-(An): rd_a=An, rd_b=Dn; d16/abs: same.
                    // Indexed: rd_a=An (base), rd_b=Xn (index); Dn supplied separately
                    // via ex_dyn_bit_reg override of rd_b_sel when bit op fires.
                    end else if (f_dir &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                        f_reg == 3'b010 || f_reg == 3'b011 ||
                                                        f_reg == 3'b100)))) begin
                        dec_unit         = UNIT_BIT;
                        dec_siz          = 2'b01;
                        dec_bit_from_reg = 1'b1;
                        dec_updates_ccr  = 1'b1;
                        dec_x_unchanged  = 1'b1;
                        dec_is_mem_rd    = 1'b1;
                        case (f_mode)
                            3'b010: begin  // (An): rd_a=An, rd_b=Dn
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_dst_reg   = {1'b0, f_dn};
                                dec_reads_dst = 1'b1;
                            end
                            3'b011: begin  // (An)+
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_dst_reg   = {1'b0, f_dn};
                                dec_reads_dst = 1'b1;
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(2'b01, f_reg == 3'b111);
                            end
                            3'b100: begin  // -(An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_dst_reg   = {1'b0, f_dn};
                                dec_reads_dst = 1'b1;
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(2'b01, f_reg == 3'b111) + 32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            3'b101: begin  // (d16,An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_dst_reg   = {1'b0, f_dn};
                                dec_reads_dst = 1'b1;
                                dec_needs_ext  = 1'b1;
                                dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b110: begin  // (d8,An,Xn) brief, or full (bd,An,Xn): rd_a=An, rd_b=Xn, Dn via override
                                dec_src_reg        = {1'b1, f_reg};
                                dec_reads_src      = 1'b1;
                                dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst      = 1'b1;
                                dec_is_idx         = 1'b1;
                                dec_xn_wl          = ext_data[11];
                                dec_xn_scale       = ext_data[10:9];
                                // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd
                                // extension, same template as Stage 1 -- see TAS's
                                // own comment in the mode=110 unary-op family above
                                // for the full reasoning. dyn_bit_get_Dn's own
                                // register-conflict handling is orthogonal and
                                // already correct unchanged.
                                dec_ea_offset      = fi_is_full ? fi_bd
                                                   : {{24{ext_data[7]}}, ext_data[7:0]};
                                dec_needs_ext      = 1'b1;
                                dec_is_dyn_bit_idx = 1'b1;
                                dec_dyn_bit_reg    = f_dn;
                            end
                            3'b111: begin
                                dec_abs_ea_en  = 1'b1;
                                dec_needs_ext  = 1'b1;
                                case (f_reg)
                                    3'b000: begin  // abs.W
                                        dec_dst_reg    = {1'b0, f_dn};
                                        dec_reads_dst  = 1'b1;
                                        dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b001: begin  // abs.L
                                        dec_dst_reg    = {1'b0, f_dn};
                                        dec_reads_dst  = 1'b1;
                                        dec_abs_ea_val = ext_data;
                                    end
                                    3'b010: begin  // (d16,PC): EA = PC+2 + d16
                                        dec_dst_reg    = {1'b0, f_dn};
                                        dec_reads_dst  = 1'b1;
                                        dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b011: begin  // (d8,PC,Xn): EA = PC+2 + d8 + scaled(Xn)
                                        dec_abs_ea_val    = decode_pc + 32'd2
                                                          + {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                        dec_reads_dst     = 1'b1;
                                        dec_is_idx        = 1'b1;
                                        dec_xn_wl         = ext_data[11];
                                        dec_xn_scale      = ext_data[10:9];
                                        dec_is_dyn_bit_idx = 1'b1;
                                        dec_dyn_bit_reg   = f_dn;
                                    end
                                    3'b100: begin  // #imm — BTST Dn, #byte (clears mem-rd flags)
                                        dec_is_mem_rd   = 1'b0;
                                        dec_abs_ea_en   = 1'b0;
                                        dec_src_reg     = {1'b0, f_dn};
                                        dec_reads_src   = 1'b1;
                                        dec_imm         = {24'h0, ext_data[7:0]};
                                        dec_is_bit_imm  = 1'b1;
                                        dec_needs_ext   = 1'b1;
                                    end
                                    default: ;
                                endcase
                            end
                            default: ;
                        endcase
                        case (f_ss)
                            2'b00: begin dec_bit_op=BIT_TST; dec_valid=1'b1; end
                            // CCR fires via mem_rmw_sr_wr_en (captured at read-ack), not WB —
                            // dec_updates_ccr must stay 0 or WB re-fires one cycle later with
                            // stale mem_rdata and clobbers the correct value (Z ends up wrong).
                            2'b01: begin dec_bit_op=BIT_CHG; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                            2'b10: begin dec_bit_op=BIT_CLR; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                            2'b11: begin dec_bit_op=BIT_SET; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                        endcase
                    // ── BTST/BCHG/BCLR/BSET #n, memory EA ──────────────────
                    // f_dn=100 selects static (immediate) bit number from extension word.
                    // CMP2/CHK2 uses f_dn=000/001/010 (!f_dn[2]) — no overlap with f_dn=100.
                    // Modes (An)/(An)+/-(An): ext_count=1, bit_num from ext_data[2:0]
                    // Modes d16(An)/indexed/abs.W/(d16,PC)/(d8,PC,Xn): ext_count=2, bit_num from ext_data[18:16]
                    // Mode abs.L: ext_count=3, bit_num from ext_data[18:16]
                    end else if (!f_dir && f_dn == 3'b100 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                        f_reg == 3'b010 || f_reg == 3'b011)))) begin
                        dec_unit         = UNIT_BIT;
                        dec_siz          = 2'b01;
                        dec_bit_from_reg = 1'b0;
                        // For simple modes (An)/(An)+/-(An): bit_num in ext_data[2:0] (ext_count=1)
                        // For extended modes: bit_num in ext_data[18:16] (ext_count=2 or 3)
                        dec_bit_num      = (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100) ?
                                           {2'b00, ext_data[2:0]} : {2'b00, ext_data[18:16]};
                        dec_is_mem_rd    = 1'b1;
                        dec_needs_ext    = 1'b1;
                        dec_x_unchanged  = 1'b1;
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                        end
                        case (f_mode)
                            3'b011: begin  // (An)+
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(2'b01, f_reg == 3'b111);
                            end
                            3'b100: begin  // -(An)
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(2'b01, f_reg == 3'b111) + 32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            3'b101: begin  // (d16,An): EA ext in ext_data[15:0]
                                dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b110: begin  // (d8,An,Xn): brief_ext in ext_data[15:0]
                                dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst  = 1'b1;
                                dec_is_idx     = 1'b1;
                                dec_xn_wl      = ext_data[11];
                                dec_xn_scale   = ext_data[10:9];
                                dec_ea_offset  = {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            3'b111: begin
                                case (f_reg)
                                    3'b000: begin  // abs.W
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b001: begin  // abs.L
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = {ext_data[15:0], q3_word};
                                    end
                                    3'b010: begin  // (d16,PC): EA = (PC+4) + d16
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = decode_pc + 32'd4
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b011: begin  // (d8,PC,Xn): EA = (PC+4) + d8 + scaled(Xn)
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = decode_pc + 32'd4
                                                       + {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                        dec_reads_dst  = 1'b1;
                                        dec_is_idx     = 1'b1;
                                        dec_xn_wl      = ext_data[11];
                                        dec_xn_scale   = ext_data[10:9];
                                    end
                                    default: ;
                                endcase
                            end
                            default: ;  // mode 010 (An): no extra EA setup
                        endcase
                        case (f_ss)
                            2'b00: begin dec_bit_op=BIT_TST; dec_valid=1'b1; dec_updates_ccr=1'b1; end
                            // CCR fires via mem_rmw_sr_wr_en (captured at read-ack), not WB —
                            // see comment on the register-src block above.
                            2'b01: begin dec_bit_op=BIT_CHG; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                            2'b10: begin dec_bit_op=BIT_CLR; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                            2'b11: begin dec_bit_op=BIT_SET; dec_valid=1'b1; dec_is_mem_rmw=1'b1; dec_updates_ccr=1'b0; end
                        endcase
                    // ── CAS2 Dc1:Dc2, Du1:Du2, (Rn1):(Rn2) ───────────────
                    // Opcode: 0x0CFC (.W) / 0x0EFC (.L)
                    // ext_data[31:16] (ext1): [30:28]=Dc2, [26:24]=Du2, [19]=Rn2_an, [18:16]=Rn2
                    // ext_data[15:0]  (ext2): [14:12]=Dc1, [10:8]=Du1,  [3]=Rn1_an,  [2:0]=Rn1
                    end else if (!f_dir && f_ss == 2'b11 &&
                                 (f_dn == 3'b110 || f_dn == 3'b111) &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid          = 1'b1;
                        dec_is_cas2        = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_CMP;
                        dec_is_mem_rd      = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_x_unchanged    = 1'b1;
                        dec_src_reg        = {ext_data[3], ext_data[2:0]};    // Rn1 → rd_a (EA)
                        dec_reads_src      = 1'b1;
                        dec_dst_reg        = {1'b0, ext_data[14:12]};         // Dc1 → rd_b (CMP)
                        dec_reads_dst      = 1'b1;
                        dec_cas2_du1_reg   = ext_data[10:8];
                        dec_cas2_rn2_reg   = {ext_data[19], ext_data[18:16]};
                        dec_cas2_dc2_reg   = ext_data[30:28];
                        dec_cas2_du2_reg   = ext_data[26:24];
                        dec_siz            = (f_dn == 3'b110) ? 2'b10 : 2'b00;  // .W or .L
                    // ── CAS Dc,Du,(An) ─────────────────────────────────────
                    end else if (!f_dir && f_ss == 2'b11 &&
                                 (f_dn == 3'b101 || f_dn == 3'b011 || f_dn == 3'b111) &&
                                 f_mode == 3'b010) begin
                        dec_valid       = 1'b1;
                        dec_is_cas      = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};
                        dec_dst_reg     = {1'b0, ext_data[8:6]};
                        dec_cas_du_reg  = ext_data[2:0];
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        case (f_dn)
                            3'b101: dec_siz = 2'b01;
                            3'b011: dec_siz = 2'b10;
                            default: dec_siz = 2'b00;
                        endcase
                    end else if (!f_dir && f_ss == 2'b11 && !f_dn[2] && f_dn != 3'b011 &&
                                 (f_mode == 3'b010 || f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010)))) begin
                        // CMP2/CHK2 <ea>,Rn — 0000 ss00 11 mmm rrr + ext
                        // f_dn: 000=CMP2.B, 001=CMP2.W, 010=CMP2.L  (all have !f_dn[2])
                        // ext[15]=D/A, ext[14:12]=Rn, ext[11]=CHK2(1)/CMP2(0)
                        // (An) and extended EA: (d16,An), (xxx).W, (d16,PC)
                        // For 2-ext-word modes: ext_data[31:16]=cmp2_ext, ext_data[15:0]=disp
                        logic [15:0] cmp2_ext_w;
                        logic        cmp2_two_ext;
                        cmp2_two_ext = (f_mode != 3'b010);
                        cmp2_ext_w   = cmp2_two_ext ? ext_data[31:16] : ext_data[15:0];
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_is_cmp2chk2 = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {cmp2_ext_w[15], cmp2_ext_w[14:12]};  // Rn → rd_b
                        dec_reads_dst   = 1'b1;
                        dec_imm         = {16'h0, cmp2_ext_w};  // ex_imm[11]=CHK2 flag always
                        case (f_dn)
                            3'b000: dec_siz = 2'b01;  // CMP2.B
                            3'b001: dec_siz = 2'b10;  // CMP2.W
                            default: dec_siz = 2'b00; // CMP2.L (f_dn=010)
                        endcase
                        case (f_mode)
                            3'b010: begin  // (An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                            end
                            3'b101: begin  // (d16,An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b111: begin
                                if (f_reg == 3'b000) begin  // (xxx).W
                                    dec_abs_ea_en  = 1'b1;
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                end else begin  // (d16,PC): f_reg=010
                                    dec_abs_ea_en  = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd4
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                            end
                            // (d8,An,Xn) brief, or full (bd,An,Xn) — Phase 120.
                            // Previously unimplemented (no case arm at all, not just
                            // brief-limited like every other family in this rollout).
                            // ext_data[31:16]=cmp2_ext_w (Rn/CHK2-flag, same as every
                            // other 2-ext-word mode above), ext_data[15:0]=the EA
                            // descriptor itself -- fi_is_full/fi_bdsz/fi_iis (module-
                            // level, reading ext_data's low half) apply unchanged, but
                            // fi_bd itself does NOT: it reads a word-bd value from
                            // ext_data[31:16], which for every single-descriptor
                            // family holds the real bd word (via is_memind_full's own
                            // q1/q2 swap) but here holds cmp2_ext_w instead (this
                            // family deliberately isn't in mode110_ea_src, same
                            // reasoning as MOVEM in Phase 119 -- see
                            // is_cmp2chk2_idx_full in m68030_seq.sv). Needs the exact
                            // same q3_word-based extraction MOVEM's own bd uses
                            // instead. Rn is only needed for the bound comparison
                            // AFTER the read completes -- same deferred-register shape
                            // dyn_bit_get_Dn already proved for CHK's own indexed form
                            // (Phase 84/86); overrides the dec_dst_reg=Rn set above
                            // (needed as-is for every other mode) with Xn for the read
                            // phase, swapping back to Rn at the read-ack cycle.
                            3'b110: begin
                                dec_src_reg        = {1'b1, f_reg};                    // An (base) → rd_a
                                dec_reads_src      = 1'b1;
                                dec_dst_reg        = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                                dec_is_idx         = 1'b1;
                                dec_xn_wl          = ext_data[11];
                                dec_xn_scale       = ext_data[10:9];
                                dec_ea_offset      = (fi_is_full && fi_bdsz == 2'b10 && fi_iis == 3'b000)
                                                   ? {{16{q3_word[15]}}, q3_word}
                                                   : {{24{ext_data[7]}}, ext_data[7:0]};
                                dec_is_dyn_bit_idx = 1'b1;
                                dec_dyn_bit_reg    = cmp2_ext_w[14:12];  // Rn → rd_b after swap
                                dec_dyn_bit_is_an  = cmp2_ext_w[15];
                            end
                            default: ;
                        endcase
                    end else if (!f_dir && f_dn == 3'b111 && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        // MOVES: 0000 1110 0ss mmm rrr + extension word
                        // ext[15]=D/A, ext[14:12]=Rn, ext[11]=direction (1=load, 0=store)
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = f_siz;
                        dec_x_unchanged = 1'b1;
                        dec_is_moves    = 1'b1;
                        dec_needs_ext   = 1'b1;
                        if (ext_data[11]) begin
                            // Load: ea → Rn (use SFC as mem_fc)
                            dec_moves_load = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};   // An = EA base → rd_a
                            dec_reads_src  = 1'b1;
                            dec_dest_reg   = {ext_data[15], ext_data[14:12]};  // Rn
                            dec_writes_reg = 1'b1;
                        end else begin
                            // Store: Rn → ea (use DFC as mem_fc)
                            dec_moves_load = 1'b0;
                            dec_is_mem_wr  = 1'b1;
                            dec_src_reg    = {ext_data[15], ext_data[14:12]};  // Rn = data
                            dec_dst_reg    = {1'b1, f_reg};   // An = EA base → rd_b
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                        end
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    end else if (!f_dir && f_dn == 3'b111 && f_mode == 3'b101) begin
                        // MOVES (d16,An) — ext_count=2
                        // ext[31:16]=MOVES desc, ext[15:0]=d16
                        // ext[27]=dir (1=load), ext[31]=D/A, ext[30:28]=Rn
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = f_siz;
                        dec_x_unchanged = 1'b1;
                        dec_is_moves    = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_ea_offset   = {{16{ext_data[15]}}, ext_data[15:0]};
                        if (ext_data[27]) begin
                            dec_moves_load = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};
                            dec_reads_src  = 1'b1;
                            dec_dest_reg   = {ext_data[31], ext_data[30:28]};
                            dec_writes_reg = 1'b1;
                        end else begin
                            dec_moves_load = 1'b0;
                            dec_is_mem_wr  = 1'b1;
                            dec_src_reg    = {ext_data[31], ext_data[30:28]};
                            dec_dst_reg    = {1'b1, f_reg};
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                        end
                    end else if (!f_dir && f_dn == 3'b111 && f_mode == 3'b110 &&
                                 ext_data[27]) begin
                        // MOVES (d8,An,Xn) LOAD only — ext_count=2
                        // ext[31:16]=MOVES desc, ext[15:0]=brief ext word
                        // Store omitted: 3-register conflict (Rn+An+Xn simultaneously)
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = f_siz;
                        dec_x_unchanged = 1'b1;
                        dec_is_moves    = 1'b1;
                        dec_moves_load  = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};                    // An = EA base
                        dec_reads_src   = 1'b1;
                        dec_dst_reg     = {ext_data[15], ext_data[14:12]};  // Xn index
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {ext_data[31], ext_data[30:28]};  // Rn = dest
                        dec_writes_reg  = 1'b1;
                        dec_is_idx      = 1'b1;
                        dec_xn_wl       = ext_data[11];
                        dec_xn_scale    = ext_data[10:9];
                        dec_ea_offset   = {{24{ext_data[7]}}, ext_data[7:0]};
                    end else if (!f_dir && f_dn == 3'b111 && f_mode == 3'b111 &&
                                 f_reg == 3'b000) begin
                        // MOVES (xxx).W — ext_count=2
                        // ext[31:16]=MOVES desc, ext[15:0]=abs.W address
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = f_siz;
                        dec_x_unchanged = 1'b1;
                        dec_is_moves    = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_abs_ea_en   = 1'b1;
                        dec_abs_ea_val  = {{16{ext_data[15]}}, ext_data[15:0]};
                        if (ext_data[27]) begin
                            dec_moves_load = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_dest_reg   = {ext_data[31], ext_data[30:28]};
                            dec_writes_reg = 1'b1;
                        end else begin
                            dec_moves_load = 1'b0;
                            dec_is_mem_wr  = 1'b1;
                            dec_src_reg    = {ext_data[31], ext_data[30:28]};
                            dec_reads_src  = 1'b1;
                        end
                    end else if (f_dir && f_mode == 3'b001) begin
                        // MOVEP: 0000 DDD1 dir siz 001 AAA + d16
                        // f_ss[1]=direction (1=Dn→mem/store, 0=mem→Dn/load)
                        // f_ss[0]=size (1=longword 4 bytes, 0=word 2 bytes)
                        // EA = (d16,An): An=f_reg, d16=ext_data signed
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_NONE;
                        dec_is_movep   = 1'b1;
                        dec_movep_load = !f_ss[1];
                        dec_movep_long = f_ss[0];
                        dec_needs_ext  = 1'b1;
                        dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                        dec_src_reg    = {1'b1, f_reg};   // An → rd_a (EA base)
                        dec_reads_src  = 1'b1;
                        dec_dst_reg    = {1'b0, f_dn};    // Dn → rd_b (store data / load dest)
                        dec_reads_dst  = 1'b1;
                    end else if (!f_dir && f_mode == 3'b111 && f_reg == 3'b100 &&
                                 (f_ss == 2'b00 || f_ss == 2'b01) &&
                                 (f_dn == 3'b000 || f_dn == 3'b001 || f_dn == 3'b101)) begin
                        // ORI/ANDI/EORI #imm to CCR or SR.
                        // SR form is supervisor-only; CCR form is always allowed.
                        if (f_ss == 2'b01 && !sr_live[13]) begin
                            // ANDI/ORI/EORI to SR in user mode → privilege violation
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_reads_ccr = 1'b1;
                            dec_needs_ext = 1'b1;
                            dec_use_imm   = 1'b1;
                            if (f_ss == 2'b00) begin    // CCR
                                dec_is_move_ccr_w = 1'b1;
                                dec_updates_ccr   = 1'b1;
                                case (f_dn)
                                    3'b000: dec_imm = {24'h0, sr_live[7:0] |  ext_data[7:0]};
                                    3'b001: dec_imm = {24'h0, sr_live[7:0] &  ext_data[7:0]};
                                    3'b101: dec_imm = {24'h0, sr_live[7:0] ^  ext_data[7:0]};
                                    default: dec_valid = 1'b0;
                                endcase
                            end else begin              // SR (supervisor only, already checked)
                                dec_is_move_sr_w = 1'b1;
                                dec_updates_ccr  = 1'b1;
                                case (f_dn)
                                    3'b000: dec_imm = {16'h0, sr_live |  ext_data[15:0]};
                                    3'b001: dec_imm = {16'h0, sr_live &  ext_data[15:0]};
                                    3'b101: dec_imm = {16'h0, sr_live ^  ext_data[15:0]};
                                    default: dec_valid = 1'b0;
                                endcase
                            end
                        end
                    end
                end

                // ----------------------------------------------------------------
                // MOVE / MOVEA (groups 1/2/3)
                // Bit layout: [15:12]=size, [11:9]=dst_reg, [8:6]=dst_mode,
                //             [5:3]=src_mode, [2:0]=src_reg
                // f_dn=dst_reg, f_move_dst_mode={f_dir,f_ss}=dst_mode,
                // f_mode=src_mode, f_reg=src_reg
                // ----------------------------------------------------------------
                4'h1, 4'h2, 4'h3: begin
                    dec_siz         = f_move_sz;
                    dec_x_unchanged = 1'b1;

                    if (f_move_dst_mode == 3'b000) begin
                        // ── dst = Dn ──
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;

                        if (f_mode == 3'b000) begin
                            // MOVE.B/W/L Dn,Dn — register direct
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_src_reg   = {1'b0, f_reg};
                            dec_dst_reg   = {1'b0, f_dn};
                            dec_reads_src = 1'b1;
                        end else if (f_mode == 3'b001) begin
                            // MOVE.W/L An,Dn — source is address register
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_src_reg   = {1'b1, f_reg};  // An
                            dec_dst_reg   = {1'b0, f_dn};
                            dec_reads_src = 1'b1;
                        end else if (f_mode[2:1] == 2'b01 ||
                                     f_mode == 3'b100 || f_mode == 3'b101) begin
                            // MOVE.B/W/L (ea),Dn — memory load (modes 010/011/100/101)
                            dec_valid      = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_src_reg    = {1'b1, f_reg};   // An for EA base
                            dec_dst_reg    = {1'b0, f_dn};
                            dec_reads_src  = 1'b1;
                            case (f_mode)
                                3'b010: ;  // (An): offset=0 (default)
                                3'b011: begin  // (An)+
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(f_move_sz, f_reg==3'b111);
                                end
                                3'b100: begin  // -(An)
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_reg==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin  // (d16,An)
                                    dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_needs_ext = 1'b1;
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b111) begin
                            // MOVE.B/W/L (special EA), Dn — abs, PC-relative, or immediate source
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_needs_ext = 1'b1;
                            case (f_reg)
                                3'b100: begin // MOVE #imm, Dn — immediate source
                                    dec_use_imm = 1'b1;
                                end
                                3'b000: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b001: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = ext_data;
                                end
                                3'b010: begin // (d16,PC): EA = PC+2 + sign_ext(d16)
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b011: begin // (d8,PC,Xn): EA = PC+2 + d8 + scaled(Xn)
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst = 1'b1;
                                    dec_is_idx    = 1'b1;
                                    dec_xn_wl     = ext_data[11];
                                    dec_xn_scale  = ext_data[10:9];
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b110) begin
                            dec_needs_ext = 1'b1;
                            dec_src_reg   = {1'b1, f_reg};                    // An (base) → rd_a
                            dec_dst_reg   = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_src = 1'b1;
                            dec_reads_dst = 1'b1;
                            dec_xn_wl     = ext_data[11];
                            dec_xn_scale  = ext_data[10:9];
                            if (!fi_is_full) begin
                                // BRIEF (d8,An,Xn): single extension word
                                dec_valid     = 1'b1;
                                dec_is_mem_rd = 1'b1;
                                dec_unit      = UNIT_MOVE;
                                dec_is_idx    = 1'b1;
                                dec_ea_offset = {{24{ext_data[7]}}, ext_data[7:0]};
                            end else if (fi_iis == 3'b000) begin
                                // FULL, no indirection: (bd,An,Xn*SCALE) — same as brief but with bd
                                dec_valid     = 1'b1;
                                dec_is_mem_rd = 1'b1;
                                dec_unit      = UNIT_MOVE;
                                dec_is_idx    = !fi_is_s;
                                dec_reads_dst = !fi_is_s;
                                dec_ea_offset = fi_bd;
                            end else begin
                                // Memory-indirect full extension word: ([bd,An],Xn,od)
                                // FSM owns all bus cycles and WB (memind_wr_en); suppress
                                // normal mem_rd path and WB to avoid spurious post-FSM read.
                                dec_valid          = 1'b1;
                                dec_is_mem_rd      = 1'b0;
                                dec_writes_reg     = 1'b0;
                                dec_unit           = UNIT_MOVE;
                                dec_is_memind      = 1'b1;
                                // Pre- vs post-indexed selection comes from the I/IS
                                // field's bit 2 (ext_data[2]), not the unrelated IS
                                // (Index Suppress, ext_data[6]) bit fi_is_s -- these
                                // are two independent 68020 EA concepts that happened
                                // to agree for every pre-indexed case tried so far
                                // (both 0), masking this until a dedicated post-indexed
                                // Musashi-cosim test (tests/memind.s) caught the DUT
                                // reading the inner pointer from An+Xn instead of An
                                // alone for a genuine post-indexed access. See plan.md
                                // Phase 107/115.
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                // Xn belongs in the *inner* (pointer-read) address only
                                // when it's present at all (!fi_is_s) AND this is
                                // pre-indexed -- for post-indexed, Xn is added to the
                                // *outer* address instead (memind_post_xn_r, gated on
                                // ex_memind_is_post independently of dec_is_idx), so
                                // including it here too would double-count it.
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                                // dec_siz IS this MOVE's own real read size (unlike
                                // MULU/MULS/DIVU/DIVS below, whose dec_siz reflects
                                // their 32-bit result instead) -- see dec_memind_rd_siz's
                                // own declaration comment for the full reasoning.
                                dec_memind_rd_siz  = dec_siz;
                            end
                        end

                    end else if (f_move_dst_mode == 3'b001) begin
                        // ── dst = An → MOVEA ──
                        dec_dest_reg    = {1'b1, f_dn};
                        dec_writes_reg  = 1'b1;
                        dec_is_movea_w  = (f_group == 4'h3);  // MOVEA.W: sign-extend
                        dec_siz         = 2'b00;              // always longword to An
                        // MOVEA.W memory source must be a word bus read; result normalised
                        // to [15:0] by biu_sizing_fsm so wb_result_final sign-extends correctly.
                        dec_mem_rd_siz  = (f_group == 4'h3) ? 2'b10 : 2'b00;

                        if (f_mode == 3'b000) begin
                            // MOVEA Dn,An
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_src_reg   = {1'b0, f_reg};
                            dec_reads_src = 1'b1;
                            dec_sext           = (f_group == 4'h3);
                            dec_sext_from_byte = 1'b0;
                        end else if (f_mode == 3'b001) begin
                            // MOVEA An,An
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                        end else if (f_mode[2:1] == 2'b01 ||
                                     f_mode == 3'b100 || f_mode == 3'b101) begin
                            // MOVEA (ea),An — memory load
                            dec_valid      = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_src_reg    = {1'b1, f_reg};
                            dec_reads_src  = 1'b1;
                            case (f_mode)
                                3'b010: ;
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(f_move_sz, f_reg==3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_reg==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin
                                    dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_needs_ext = 1'b1;
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b111) begin
                            // MOVEA (special EA), An — abs, PC-relative, or immediate source
                            dec_valid     = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_needs_ext = 1'b1;
                            case (f_reg)
                                3'b100: begin // MOVEA.L #imm32, An — immediate source
                                    dec_use_imm = 1'b1;
                                    // dec_is_movea_w already set above for group 3
                                end
                                3'b000: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b001: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = ext_data;
                                end
                                3'b010: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b011: begin
                                    dec_is_mem_rd = 1'b1;
                                    dec_abs_ea_en = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst = 1'b1;
                                    dec_is_idx    = 1'b1;
                                    dec_xn_wl     = ext_data[11];
                                    dec_xn_scale  = ext_data[10:9];
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b110) begin
                            // MOVEA (d8/bd,An,Xn[,od]), An — brief or full extension word
                            dec_needs_ext  = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};
                            dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_xn_wl      = ext_data[11];
                            dec_xn_scale   = ext_data[10:9];
                            if (!fi_is_full) begin
                                // BRIEF (d8,An,Xn)
                                dec_valid      = 1'b1;
                                dec_is_mem_rd  = 1'b1;
                                dec_unit       = UNIT_MOVE;
                                dec_is_idx     = 1'b1;
                                dec_ea_offset  = {{24{ext_data[7]}}, ext_data[7:0]};
                            end else if (fi_iis == 3'b000) begin
                                // FULL no indirection: (bd,An,Xn*SCALE)
                                dec_valid      = 1'b1;
                                dec_is_mem_rd  = 1'b1;
                                dec_unit       = UNIT_MOVE;
                                dec_is_idx     = !fi_is_s;
                                dec_reads_dst  = !fi_is_s;
                                dec_ea_offset  = fi_bd;
                            end else begin
                                // FULL memory-indirect: ([bd,An],Xn,od)
                                // FSM owns bus cycles and WB; suppress normal mem/WB paths.
                                dec_valid          = 1'b1;
                                dec_is_mem_rd      = 1'b0;
                                dec_writes_reg     = 1'b0;
                                dec_unit           = UNIT_MOVE;
                                dec_is_memind      = 1'b1;
                                // Same fix and reasoning as the other memory-indirect
                                // decode block above (dec_memind_is_post must come from
                                // fi_iis[2], not the unrelated IS bit fi_is_s -- see its
                                // comment for the full writeup).
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                                dec_memind_rd_siz  = dec_siz;  // see dec_memind_rd_siz's own comment
                            end
                        end

                    end else if (f_move_dst_mode[2:1] == 2'b01 ||
                                 f_move_dst_mode == 3'b100 ||
                                 f_move_dst_mode == 3'b101) begin
                        // ── dst = memory (An)/(An)+/-(An)/(d16,An) ──
                        if (f_mode == 3'b000 || f_mode == 3'b001) begin
                            // src = register (Dn or An)
                            dec_valid      = 1'b1;
                            dec_is_mem_wr  = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_src_reg    = (f_mode == 3'b000) ? {1'b0, f_reg}
                                                                 : {1'b1, f_reg};
                            dec_dst_reg    = {1'b1, f_dn};
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_writes_reg = 1'b0;
                            dec_updates_ccr = 1'b1; // Dn and An source both update CCR
                            case (f_move_dst_mode)
                                3'b010: ;
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin
                                    dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_needs_ext = 1'b1;
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b111 && f_reg == 3'b100) begin
                            // MOVE #imm, (An)/(An)+/-(An)/(d16,An) — immediate source
                            dec_valid       = 1'b1;
                            dec_is_mem_wr   = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_use_imm     = 1'b1;
                            dec_dst_reg     = {1'b1, f_dn};
                            dec_reads_dst   = 1'b1;
                            dec_writes_reg  = 1'b0;
                            dec_updates_ccr = 1'b1;
                            dec_needs_ext   = 1'b1;
                            case (f_move_dst_mode)
                                3'b010: ;
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin
                                    // MOVE.L: imm in {q1,q2}=ext_data, d16 in q3_word
                                    // MOVE.B/W: imm in q1=ext_data[31:16], d16 in q2=ext_data[15:0]
                                    dec_imm       = (f_group == 4'h2) ? ext_data
                                                                       : {16'h0, ext_data[31:16]};
                                    dec_ea_offset = (f_group == 4'h2)
                                                    ? {{16{q3_word[15]}}, q3_word}
                                                    : {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b111 && f_reg == 3'b011) begin
                            // MOVE (d8,PC,Xi), (indirect_dst): PC-indexed src, indirect dst.
                            // ext_count=1 for dst modes 2/3/4 (brief in [15:0]);
                            // ext_count=2 for dst mode 5 (brief in [31:16], d16 in [15:0]).
                            // dyn_bit: rd_b starts as src_Xn, switches to dst_An at read_ack.
                            dec_valid          = 1'b1;
                            dec_is_move_mm     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_unit           = UNIT_MOVE;
                            dec_writes_reg     = 1'b0;
                            dec_x_unchanged    = 1'b1;
                            dec_needs_ext      = 1'b1;
                            dec_abs_ea_en      = 1'b1;
                            dec_is_idx         = 1'b1;
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;
                            dec_dyn_bit_is_an  = 1'b1;
                            dec_siz            = f_move_sz;
                            if (f_move_dst_mode == 3'b101) begin
                                // dst = (d16,An_dst): brief in [31:16], d16 in [15:0]
                                dec_dst_reg       = {ext_data[31], ext_data[30:28]};
                                dec_reads_dst     = 1'b1;
                                dec_xn_wl         = ext_data[27];
                                dec_xn_scale      = ext_data[26:25];
                                dec_abs_ea_val    = decode_pc + 32'd2
                                                  + {{24{ext_data[23]}}, ext_data[23:16]};
                                dec_dst_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin
                                // dst = (An_dst)/(An_dst)+/-(An_dst): brief in [15:0]
                                dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst  = 1'b1;
                                dec_xn_wl      = ext_data[11];
                                dec_xn_scale   = ext_data[10:9];
                                dec_abs_ea_val = decode_pc + 32'd2
                                              + {{24{ext_data[7]}}, ext_data[7:0]};
                                case (f_move_dst_mode)
                                    3'b010: ;
                                    3'b011: begin
                                        dec_dst_an_upd_en  = 1'b1;
                                        dec_dst_an_upd_reg = f_dn;
                                        dec_dst_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                    end
                                    3'b100: begin
                                        dec_dst_an_upd_en  = 1'b1;
                                        dec_dst_an_upd_reg = f_dn;
                                        dec_dst_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                        dec_dst_ea_offset  = dec_dst_an_delta;
                                    end
                                    default: ;
                                endcase
                            end
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101 || f_mode == 3'b111) begin
                            // src = memory → MOVE (src),(dst)
                            dec_valid       = 1'b1;
                            dec_is_move_mm  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_writes_reg  = 1'b0;
                            dec_x_unchanged = 1'b1;
                            // src EA setup
                            if (f_mode == 3'b111) begin
                                dec_abs_ea_en  = 1'b1;
                                dec_needs_ext  = 1'b1;
                                case (f_reg)
                                    3'b000: dec_abs_ea_val =
                                        (f_move_dst_mode == 3'b101)
                                        ? {{16{ext_data[31]}}, ext_data[31:16]}
                                        : {{16{ext_data[15]}}, ext_data[15:0]};
                                    3'b001: dec_abs_ea_val = ext_data;
                                    3'b010: dec_abs_ea_val =
                                        (f_move_dst_mode == 3'b101)
                                        ? decode_pc + 32'd2 + {{16{ext_data[31]}}, ext_data[31:16]}
                                        : decode_pc + 32'd2 + {{16{ext_data[15]}}, ext_data[15:0]};
                                    default: ;
                                endcase
                            end else begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                case (f_mode)
                                    3'b010: ;
                                    3'b011: begin
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = calc_step(f_move_sz, f_reg==3'b111);
                                    end
                                    3'b100: begin
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = ~calc_step(f_move_sz, f_reg==3'b111)+32'h1;
                                        dec_ea_offset  = dec_an_delta;
                                    end
                                    3'b101: begin
                                        dec_needs_ext = 1'b1;
                                        dec_ea_offset =
                                            (f_move_dst_mode == 3'b101)
                                            ? {{16{ext_data[31]}}, ext_data[31:16]}
                                            : {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    default: ;
                                endcase
                            end
                            // dst EA setup (always uses rd_b = dst An)
                            dec_dst_reg   = {1'b1, f_dn};
                            dec_reads_dst = 1'b1;
                            case (f_move_dst_mode)
                                3'b010: ;
                                3'b011: begin
                                    dec_dst_an_upd_en  = 1'b1;
                                    dec_dst_an_upd_reg = f_dn;
                                    dec_dst_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                end
                                3'b100: begin
                                    dec_dst_an_upd_en  = 1'b1;
                                    dec_dst_an_upd_reg = f_dn;
                                    dec_dst_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                    dec_dst_ea_offset  = dec_dst_an_delta;
                                end
                                3'b101: begin
                                    dec_needs_ext     = 1'b1;
                                    // abs.L src (f_mode=7, f_reg=1, 2 src ext words): d16 is in q[3]
                                    dec_dst_ea_offset = (f_mode == 3'b111 && f_reg == 3'b001)
                                        ? {{16{q3_word[15]}}, q3_word}
                                        : {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                default: ;
                            endcase
                            // Same-register An conflict: src (An)+ or -(An) on same An as dst.
                            // The 68000/030 applies src An update before computing dst EA.
                            // Add src delta to dec_dst_ea_offset so dst EA uses the updated An.
                            // If dst also updates An, combine deltas into one dst-An write.
                            if ((f_mode == 3'b011 || f_mode == 3'b100) && f_reg == f_dn) begin
                                dec_dst_ea_offset = dec_dst_ea_offset + dec_an_delta;
                                if (dec_dst_an_upd_en) begin
                                    dec_dst_an_delta = dec_dst_an_delta + dec_an_delta;
                                    dec_an_upd_en    = 1'b0;
                                end
                            end
                        end else if (f_mode == 3'b110) begin
                            // MOVE (d8/bd,An_src,Xn),<memory dst>: indexed source (brief or
                            // full-format), memory dst. ext_count depends on dst: 1 for modes
                            // 2/3/4, 2+ for mode 5 (d16) -- see is_move_idx_src_memdst_full in
                            // m68030_seq.sv for the full ext_count derivation (deferred-items
                            // closure follow-up, plan.md).
                            // dyn_bit switches rd_b from src_Xn to dst_An at move_mm_read_ack,
                            // so move_mm_dst_addr_r = An_dst + dec_dst_ea_offset. ✓
                            dec_valid       = 1'b1;
                            dec_is_move_mm  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_writes_reg  = 1'b0;
                            dec_x_unchanged = 1'b1;
                            dec_needs_ext   = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};           // An_src → rd_a
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_is_idx      = 1'b1;
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;  // dst_An → rd_b after dyn_bit
                            dec_dyn_bit_is_an  = 1'b1;
                            if (f_move_dst_mode == 3'b101) begin
                                // dst = (d16,An): m68030_seq.sv deliberately excludes THIS
                                // sub-case from the is_memind_full swap (see its own
                                // eu_ext_data comment for the full reasoning) -- q1 (source's
                                // own descriptor) always stays at its natural, un-swapped
                                // high-half position. ext_data[24] is q1's own is-full bit
                                // (same position as m68030_seq.sv's own peek_fi_full), not
                                // the shared fi_is_full (which assumes q1 already relocated
                                // to the low half -- true for the dst != 101 sub-case below,
                                // not this one). Full-format's own bits[23:16] are NOT a
                                // valid displacement byte (that layout only applies to
                                // brief) -- for null bd (the common full-format case here)
                                // the real displacement is architecturally 0; word/long bd
                                // would need a genuine 3rd/4th extension word this arm
                                // doesn't have (q2 is already spoken for by dst's own d16),
                                // so this deliberately treats every full-format bd size the
                                // same way (displacement 0) rather than mis-read a byte that
                                // isn't a displacement at all for the non-null-bd case --
                                // the same "least-wrong fallback, documented not fixed"
                                // boundary every other family in this rollout uses for a
                                // combination needing more words than it currently has.
                                dec_dst_reg   = {ext_data[31], ext_data[30:28]}; // src_Xn → rd_b
                                dec_xn_wl     = ext_data[27];
                                dec_xn_scale  = ext_data[26:25];
                                dec_ea_offset = ext_data[24]
                                              ? 32'd0                                   // full-format: bd=0 (null-bd correct, word/long a documented fallback)
                                              : {{24{ext_data[23]}}, ext_data[23:16]};  // brief: real d8_src
                                dec_dst_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin
                                // dst = (An)/(An)+/-(An): ext_count=1(+bd words), brief or
                                // full in [15:0] (is_memind_full's own swap already relocates
                                // q1 here -- see eu_seq.sv's own fi_is_full/fi_bd, already the
                                // standard template used throughout the mode=110 EA rollout).
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]}; // src_Xn → rd_b
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                dec_ea_offset = fi_is_full ? fi_bd
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                                case (f_move_dst_mode)
                                    3'b010: ;  // dst EA = An_dst + 0
                                    3'b011: begin  // (An_dst)+
                                        dec_dst_an_upd_en  = 1'b1;
                                        dec_dst_an_upd_reg = f_dn;
                                        dec_dst_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                    end
                                    3'b100: begin  // -(An_dst)
                                        dec_dst_an_upd_en  = 1'b1;
                                        dec_dst_an_upd_reg = f_dn;
                                        dec_dst_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                        dec_dst_ea_offset  = dec_dst_an_delta;
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end else if (f_move_dst_mode == 3'b110) begin
                        // ── dst = (d8,An,Xn) indexed ──
                        if (f_mode == 3'b000 || f_mode == 3'b001) begin
                            // MOVE Dn/An, (d8,An_dst,Xn) brief, or (bd,An_dst,Xn) full
                            // (Phase 149, plan.md): register source, indexed dst -- the one
                            // case in the project confirmed to genuinely need a 3rd
                            // simultaneous register-file read (port3.md): An_dst_base
                            // (rd_a) + Xn (rd_b) are both needed live for the EA the
                            // entire write cycle, and the source register's own value
                            // (rd_c) is needed at the very same moment for the write data
                            // -- unlike every dyn_bit_get_Dn-solvable case elsewhere in
                            // this project, there's no bus-ack event before a plain write
                            // starts to key a deferred register-port swap off. Was RMW
                            // (a "2-port trick": real but unnecessary bus read, purely to
                            // get 2 simultaneous register reads) until Phase 148 added the
                            // rd_c port -- now a genuine single-phase write, same
                            // dec_is_mem_wr/dec_updates_ccr shape as CLR's own indexed
                            // form (Phase 144) reusing the already-Harte-proven CCR path,
                            // except the write data is the live rd_c_data instead of a
                            // constant 0 (see move_result_w's own first branch and
                            // mem_wdata's own ex_is_move_reg_idx_dst case below).
                            // brief_ext in ext_data[15:0] (ext_count=1 -> eu_ext_data={16'h0,q[1]});
                            // full-format bd via the standard fi_is_full/fi_bd template.
                            dec_valid               = 1'b1;
                            dec_is_mem_wr           = 1'b1;
                            dec_unit                = UNIT_MOVE;
                            dec_src_reg             = {1'b1, f_dn};  // dst_An_base → rd_a (indexed EA)
                            dec_reads_src           = 1'b1;
                            dec_dst_reg             = {ext_data[15], ext_data[14:12]};  // dst_Xn → rd_b
                            dec_reads_dst           = 1'b1;
                            dec_c_reg               = {(f_mode == 3'b001), f_reg};  // source reg → rd_c
                            dec_reads_c             = 1'b1;
                            dec_is_idx              = 1'b1;
                            dec_xn_wl               = ext_data[11];
                            dec_xn_scale            = ext_data[10:9];
                            dec_ea_offset           = fi_is_full ? fi_bd
                                                    : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_writes_reg          = 1'b0;
                            dec_updates_ccr         = 1'b1;
                            dec_needs_ext           = 1'b1;
                            dec_siz                 = f_move_sz;
                            dec_is_move_reg_idx_dst = 1'b1;
                        end else if (f_mode == 3'b111 && f_reg == 3'b000) begin
                            // MOVE (xxx).W, (d8,An_dst,Xn) brief, or (bd,An_dst,Xn) full
                            // (Phase 122, Sub-scope A): abs.W src, indexed dst.
                            // ext_data = {q1=(xxx).W, q2=brief/full descriptor}: abs.W in
                            // hi, dst's own descriptor in lo -- same "q1=other data,
                            // q2=EA descriptor" shape as MOVEM/CMP2CHK2, so fi_is_full/
                            // fi_bdsz/fi_iis (already reading ext_data's low half) apply
                            // unchanged, but a full-format bd's own VALUE needs q3_word
                            // (not the shared fi_bd, which reads ext_data[31:16] -- that
                            // slot holds the abs.W value here, not a bd word) -- see
                            // is_move_mm_absw_idxdst_full in m68030_seq.sv.
                            dec_valid               = 1'b1;
                            dec_is_move_mm          = 1'b1;
                            dec_is_move_mm_idx_dst  = 1'b1;
                            dec_is_mem_rd           = 1'b1;
                            dec_unit                = UNIT_MOVE;
                            dec_writes_reg          = 1'b0;
                            dec_needs_ext           = 1'b1;
                            dec_abs_ea_en           = 1'b1;
                            dec_abs_ea_val          = {{16{ext_data[31]}}, ext_data[31:16]};
                            dec_src_reg             = {1'b1, f_dn};   // dst_An_base → rd_a
                            dec_reads_src           = 1'b1;
                            dec_dst_reg             = {ext_data[15], ext_data[14:12]};   // dst_Xn → rd_b
                            dec_reads_dst           = 1'b1;
                            dec_xn_wl               = ext_data[11];
                            dec_xn_scale            = ext_data[10:9];
                            dec_dst_ea_offset       = (fi_is_full && fi_bdsz == 2'b10 && fi_iis == 3'b000)
                                                    ? {{16{q3_word[15]}}, q3_word}
                                                    : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_siz                 = f_move_sz;
                        end else if (f_mode == 3'b111 && f_reg == 3'b010) begin
                            // MOVE (d16,PC), (d8,An_dst,Xn) brief, or (bd,An_dst,Xn) full
                            // (Phase 122, Sub-scope A): PC-relative src, indexed dst.
                            // Same shape as the abs.W-src arm just above -- see its own
                            // comment for the full reasoning.
                            dec_valid               = 1'b1;
                            dec_is_move_mm          = 1'b1;
                            dec_is_move_mm_idx_dst  = 1'b1;
                            dec_is_mem_rd           = 1'b1;
                            dec_unit                = UNIT_MOVE;
                            dec_writes_reg          = 1'b0;
                            dec_needs_ext           = 1'b1;
                            dec_abs_ea_en           = 1'b1;
                            dec_abs_ea_val          = decode_pc + 32'd2
                                                    + {{16{ext_data[31]}}, ext_data[31:16]};
                            dec_src_reg             = {1'b1, f_dn};   // dst_An_base → rd_a
                            dec_reads_src           = 1'b1;
                            dec_dst_reg             = {ext_data[15], ext_data[14:12]};   // dst_Xn → rd_b
                            dec_reads_dst           = 1'b1;
                            dec_xn_wl               = ext_data[11];
                            dec_xn_scale            = ext_data[10:9];
                            dec_dst_ea_offset       = (fi_is_full && fi_bdsz == 2'b10 && fi_iis == 3'b000)
                                                    ? {{16{q3_word[15]}}, q3_word}
                                                    : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_siz                 = f_move_sz;
                        end else if (f_mode == 3'b111 && f_reg == 3'b100) begin
                            // MOVE #imm, (d8,An,Xn): MOVE.L has imm32 in ext_data, descriptor
                            // in q3_word; MOVE.B/W has imm16 in ext_data[31:16], descriptor in
                            // ext_data[15:0]. Full-format bd support added Phase 141 (plan.md):
                            // deliberately NOT the shared fi_bd (that signal's own VALUE
                            // extraction assumes bd's word lives at ext_data[31:16] -- for
                            // BOTH size variants here that slot is occupied by the immediate,
                            // not bd, same reasoning as MOVEM's own bespoke mode110
                            // extraction just above). MOVE.B/W's descriptor sits at
                            // ext_data[15:0] (unswapped, since is_move_mm never joins
                            // mode110_ea_src) -- happens to be the exact bit positions
                            // fi_is_full/fi_bdsz/fi_iis already read, so those three ARE
                            // directly reusable for the *check* (not fi_bd's own value);
                            // bd's own word lives one word later than a single-EA-word
                            // family, at q3_word (word bd) or q3_word+ext34_data[15:0] (long
                            // bd) -- matches m68030_seq.sv's own movem_bd_words-style
                            // additive sizing for this arm. MOVE.L's descriptor is one word
                            // later still, at q3_word itself, so its own full/bdsz/iis bits
                            // come from q3_word directly; word bd's value is at
                            // ext34_data[15:0]=q4, and (Phase 147, plan.md, now that Phase
                            // 145's genuine q5 exists) long bd's own low half is one word
                            // further out still, at q5_word (high half stays at q4).
                            dec_valid      = 1'b1;
                            dec_is_mem_rd  = 1'b1;
                            dec_is_mem_rmw = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_use_imm    = 1'b1;
                            dec_imm        = (f_group == 4'h2) ? ext_data
                                                                : {16'h0, ext_data[31:16]};
                            dec_src_reg    = {1'b1, f_dn};
                            dec_reads_src  = 1'b1;
                            dec_dst_reg    = {(f_group == 4'h2) ? q3_word[15]    : ext_data[15],
                                              (f_group == 4'h2) ? q3_word[14:12] : ext_data[14:12]};
                            dec_reads_dst  = 1'b1;
                            dec_is_idx     = 1'b1;
                            dec_xn_wl      = (f_group == 4'h2) ? q3_word[11]   : ext_data[11];
                            dec_xn_scale   = (f_group == 4'h2) ? q3_word[10:9] : ext_data[10:9];
                            if (f_group == 4'h2) begin
                                dec_ea_offset = (q3_word[8] && q3_word[5:4] == 2'b10 && q3_word[2:0] == 3'b000)
                                              ? {{16{ext34_data[15]}}, ext34_data[15:0]}
                                              : (q3_word[8] && q3_word[5:4] == 2'b11 && q3_word[2:0] == 3'b000)
                                              ? {ext34_data[15:0], q5_word}
                                              : {{24{q3_word[7]}}, q3_word[7:0]};
                            end else begin
                                dec_ea_offset = (fi_is_full && fi_bdsz == 2'b10 && fi_iis == 3'b000)
                                              ? {{16{q3_word[15]}}, q3_word}
                                              : (fi_is_full && fi_bdsz == 2'b11 && fi_iis == 3'b000)
                                              ? {q3_word, ext34_data[15:0]}
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            dec_writes_reg = 1'b0;
                            dec_updates_ccr = 1'b1;
                            dec_needs_ext  = 1'b1;
                            dec_siz        = f_move_sz;
                        end else if (f_mode == 3'b111 && f_reg == 3'b001) begin
                            // MOVE (xxx).L, (d8,An,Xn): abs.L src, indexed dst.
                            // ext_data={abs_hi,abs_lo}, q3_word=brief_ext for dst.
                            // rd_a=dst An (f_dn), rd_b=dst Xi (q3_word[15:12]).
                            // dec_is_idx NOT set (would corrupt abs read addr); instead
                            // ex_is_move_mm_idx_dst flags indexed dst EA at read_ack.
                            // Full-format bd (Phase 142, plan.md): abs.L src's own 2-word
                            // baseline pushes the dst descriptor to q3_word, the exact same
                            // "one word further out" position MOVE.L imm-src (Phase 141)
                            // already needed its own peek for -- word bd's value is at
                            // ext34_data[15:0]=q4, and (Phase 147, plan.md) long bd's own
                            // low half is one word further out still, at q5_word. Unlike the
                            // imm-src arm, this one uses the move_mm FSM (a real src-then-dst
                            // read/write, not the RMW "2-port trick"), so it doesn't share
                            // that arm's own phantom-read quirk.
                            dec_valid              = 1'b1;
                            dec_is_move_mm         = 1'b1;
                            dec_is_move_mm_idx_dst = 1'b1;
                            dec_is_mem_rd          = 1'b1;
                            dec_unit               = UNIT_MOVE;
                            dec_writes_reg         = 1'b0;
                            dec_needs_ext          = 1'b1;
                            dec_abs_ea_en          = 1'b1;
                            dec_abs_ea_val         = ext_data; // abs.L src address
                            dec_src_reg            = {1'b1, f_dn}; // dst An base
                            dec_reads_src          = 1'b1;
                            dec_dst_reg            = {q3_word[15], q3_word[14:12]}; // dst Xi
                            dec_reads_dst          = 1'b1;
                            // Xi scale/wl and d8 for indexed dst EA (no dec_is_idx)
                            dec_xn_wl              = q3_word[11];
                            dec_xn_scale           = q3_word[10:9];
                            dec_dst_ea_offset      = (q3_word[8] && q3_word[5:4] == 2'b10 && q3_word[2:0] == 3'b000)
                                                   ? {{16{ext34_data[15]}}, ext34_data[15:0]}
                                                   : (q3_word[8] && q3_word[5:4] == 2'b11 && q3_word[2:0] == 3'b000)
                                                   ? {ext34_data[15:0], q5_word}
                                                   : {{24{q3_word[7]}}, q3_word[7:0]};
                            dec_siz                = f_move_sz;
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101) begin
                            // MOVE (An)/(An)+/-(An)/(d16,An), (d8,An_dst,Xn): memory
                            // source, indexed dst. No 3rd port needed: rd_a=src_An only
                            // during the read phase (generic ex_ea path — dec_is_idx is
                            // NOT set here, so dst_Xn sitting on rd_b never corrupts the
                            // source address); dyn_bit_swap_a fires at the read ack and
                            // switches rd_a from src_An to dst_An for the
                            // move_mm_dst_addr_r indexed-dst capture. rd_b stays fixed
                            // = dst_Xn throughout, untouched by the swap.
                            dec_valid              = 1'b1;
                            dec_is_move_mm         = 1'b1;
                            dec_is_move_mm_idx_dst = 1'b1;
                            dec_is_mem_rd          = 1'b1;
                            dec_unit               = UNIT_MOVE;
                            dec_writes_reg         = 1'b0;
                            dec_x_unchanged        = 1'b1;
                            dec_src_reg            = {1'b1, f_reg};  // src_An → rd_a (read phase)
                            dec_reads_src          = 1'b1;
                            dec_dst_reg            = {ext_data[15], ext_data[14:12]}; // dst_Xn → rd_b
                            dec_reads_dst          = 1'b1;
                            dec_xn_wl              = ext_data[11];
                            dec_xn_scale           = ext_data[10:9];
                            // Full-format bd support (Phase 143, plan.md). The dst
                            // descriptor always lands at ext_data[15:0] regardless of
                            // which physical q-slot it came from -- m68030_seq.sv's own
                            // ext_count-aware eu_ext_data formula already guarantees
                            // this (same reason dst_reg/xn_wl/xn_scale just above never
                            // needed a mode split). For src modes (An)/(An)+/-(An), the
                            // baseline is 1 word (the descriptor alone, at q1) -- the
                            // exact shape the shared fi_is_full/fi_bd template already
                            // assumes (bd's own word at ext_data[31:16]), so directly
                            // reusable unmodified. For (d16,An)-src, the baseline is 2
                            // words (src's own d16 at q1 + descriptor at q2) -- one word
                            // further than fi_bd assumes (that slot holds src's own d16
                            // here, not bd), so needs a fresh q3_word-based extraction,
                            // same shape MOVEM's own bespoke mode110 arm (Phase 138) and
                            // MOVE.B/W's own imm-src arm (Phase 141) already use for an
                            // analogous "one word further out" need. Deferred-items
                            // closure plan Stage 8 (plan.md): long bd's own low half is
                            // one word further out still, at q4 (ext34_data[15:0]) --
                            // the exact same "high half at the word bd's own slot, low
                            // half one word further" shape fi_bd itself already uses at
                            // its own (different) baseline, just applied here one word
                            // later to match this arm's own 2-word baseline.
                            dec_dst_ea_offset      = (f_mode == 3'b101)
                                                   ? ((ext_data[8] && ext_data[5:4] == 2'b10 && ext_data[2:0] == 3'b000)
                                                      ? {{16{q3_word[15]}}, q3_word}
                                                      : (ext_data[8] && ext_data[5:4] == 2'b11 && ext_data[2:0] == 3'b000)
                                                      ? {q3_word, ext34_data[15:0]}
                                                      : {{24{ext_data[7]}}, ext_data[7:0]})
                                                   : ((fi_is_full && fi_iis == 3'b000)
                                                      ? fi_bd
                                                      : {{24{ext_data[7]}}, ext_data[7:0]});
                            dec_needs_ext          = 1'b1;
                            dec_siz                = f_move_sz;
                            dec_is_dyn_bit_idx     = 1'b1;
                            dec_dyn_bit_reg        = f_dn;   // dst_An → rd_a after swap
                            dec_dyn_bit_is_an      = 1'b1;
                            dec_dyn_bit_swap_a     = 1'b1;   // swap targets rd_a, not rd_b
                            case (f_mode)
                                3'b011: begin  // (An_src)+
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(f_move_sz, f_reg==3'b111);
                                end
                                3'b100: begin  // -(An_src)
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_reg==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin  // (d16,An_src) — comes first in the ext
                                              // stream (source before dest), so the d16
                                              // is in the HIGH half; dst brief stays low.
                                    dec_ea_offset = {{16{ext_data[31]}}, ext_data[31:16]};
                                end
                                default: ;  // (An_src): offset = 0
                            endcase
                            // Same-register An conflict: src (An)+ or -(An) on the same
                            // An as dst_An. The src auto-increment/decrement is applied
                            // (as part of evaluating the source operand) before the
                            // destination EA is computed — add the src delta to the
                            // dst offset so the indexed-dst capture uses the updated An.
                            if ((f_mode == 3'b011 || f_mode == 3'b100) && f_reg == f_dn) begin
                                dec_dst_ea_offset = dec_dst_ea_offset + dec_an_delta;
                            end
                            // Same conflict, but against dst_Xn (the index register)
                            // instead of dst_An (the base): the capture formula
                            // multiplies Xn by the scale, so the compensating delta
                            // must be scaled too (delta*(1<<scale) == delta<<scale).
                            if ((f_mode == 3'b011 || f_mode == 3'b100) &&
                                ext_data[15] && (f_reg == ext_data[14:12])) begin
                                dec_dst_ea_offset = dec_dst_ea_offset
                                                  + (dec_an_delta << ext_data[10:9]);
                            end
                        end else if (f_mode == 3'b110) begin
                            // MOVE (d8,An_src,Xn_src),(d8,An_dst,Xn_dst): BOTH sides
                            // indexed. ext_count=2 (generic is_move_mm classifier in
                            // m68030_seq.sv already handles this — src_ext_w=1 for
                            // f_mode=110, dst_ext_w=1 for dst_mode_s=110, no separate
                            // entry needed): src brief ext word first (high half,
                            // source evaluated before dest), dst brief ext word
                            // second (low half).
                            // rd_a=src_An, rd_b=src_Xn during the read (source's own
                            // indexed EA via the generic ex_ea path). At read_ack,
                            // BOTH swap (dyn_bit_swap_both): rd_a->dst_An (reg/is_an),
                            // rd_b->dst_Xn (reg2/is_an2). The capture formula uses the
                            // separate ex_dst_xn_wl/ex_dst_xn_scale (dec_dst_is_idx=1)
                            // for the destination, since the shared xn fields are
                            // taken by the source here.
                            dec_valid              = 1'b1;
                            dec_is_move_mm         = 1'b1;
                            dec_is_move_mm_idx_dst = 1'b1;
                            dec_is_mem_rd          = 1'b1;
                            dec_unit               = UNIT_MOVE;
                            dec_writes_reg         = 1'b0;
                            dec_x_unchanged        = 1'b1;
                            dec_siz                = f_move_sz;
                            dec_needs_ext          = 1'b1;
                            dec_src_reg            = {1'b1, f_reg};  // src_An → rd_a
                            dec_reads_src          = 1'b1;
                            dec_dst_reg            = {ext_data[31], ext_data[30:28]};  // src_Xn → rd_b
                            dec_reads_dst          = 1'b1;
                            dec_is_idx             = 1'b1;
                            dec_xn_wl              = ext_data[27];
                            dec_xn_scale           = ext_data[26:25];
                            dec_ea_offset          = {{24{ext_data[23]}}, ext_data[23:16]};  // d8_src
                            dec_is_dyn_bit_idx     = 1'b1;
                            dec_dyn_bit_swap_both  = 1'b1;
                            dec_dyn_bit_reg        = f_dn;               // dst_An → rd_a after swap
                            dec_dyn_bit_is_an      = 1'b1;
                            dec_dyn_bit_reg2       = ext_data[14:12];    // dst_Xn → rd_b after swap
                            dec_dyn_bit_is_an2     = ext_data[15];
                            dec_dst_is_idx         = 1'b1;
                            dec_dst_xn_wl          = ext_data[11];
                            dec_dst_xn_scale       = ext_data[10:9];
                            dec_dst_ea_offset      = {{24{ext_data[7]}}, ext_data[7:0]};  // d8_dst
                        end else if (f_mode == 3'b111 && f_reg == 3'b011) begin
                            // MOVE (d8,PC,Xn_src),(d8,An_dst,Xn_dst): PC-relative
                            // indexed src, indexed dst. Source needs no An (PC-
                            // relative) — rd_a can be dst_An from the start (no swap
                            // needed, same as the abs.W/(d16,PC) src cases above);
                            // only rd_b (src_Xn -> dst_Xn) swaps at read_ack, via the
                            // plain single-target dyn_bit_get_Dn mechanism (swap_a/
                            // swap_both both stay 0 — this is a normal rd_b-only swap
                            // like Bucket B/BCHG, not the swap_both case above).
                            dec_valid              = 1'b1;
                            dec_is_move_mm         = 1'b1;
                            dec_is_move_mm_idx_dst = 1'b1;
                            dec_is_mem_rd          = 1'b1;
                            dec_unit               = UNIT_MOVE;
                            dec_writes_reg         = 1'b0;
                            dec_x_unchanged        = 1'b1;
                            dec_siz                = f_move_sz;
                            dec_needs_ext          = 1'b1;
                            dec_abs_ea_en          = 1'b1;
                            dec_abs_ea_val         = decode_pc + 32'd2
                                                    + {{24{ext_data[23]}}, ext_data[23:16]}; // PC+2+d8_src
                            dec_dst_reg            = {ext_data[31], ext_data[30:28]};  // src_Xn → rd_b
                            dec_reads_dst          = 1'b1;
                            dec_is_idx             = 1'b1;
                            dec_xn_wl              = ext_data[27];
                            dec_xn_scale           = ext_data[26:25];
                            dec_src_reg            = {1'b1, f_dn};   // dst_An_base → rd_a (fixed)
                            dec_reads_src          = 1'b1;
                            dec_is_dyn_bit_idx     = 1'b1;
                            dec_dyn_bit_reg        = ext_data[14:12]; // dst_Xn → rd_b after swap
                            dec_dyn_bit_is_an      = ext_data[15];
                            dec_dst_is_idx         = 1'b1;
                            dec_dst_xn_wl          = ext_data[11];
                            dec_dst_xn_scale       = ext_data[10:9];
                            dec_dst_ea_offset      = {{24{ext_data[7]}}, ext_data[7:0]};  // d8_dst
                        end
                        // Other src modes (indirect with pre/post) not yet decoded
                    end else if (f_move_dst_mode == 3'b111) begin
                        // ── dst = absolute address ──
                        if (f_mode == 3'b000 || f_mode == 3'b001) begin
                            // src = Dn or An
                            dec_valid      = 1'b1;
                            dec_is_mem_wr  = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_src_reg    = (f_mode == 3'b000) ? {1'b0, f_reg}
                                                                 : {1'b1, f_reg};
                            dec_reads_src  = 1'b1;
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = (f_dn == 3'b001) ? ext_data
                                           : {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_writes_reg  = 1'b0;
                            dec_updates_ccr = 1'b1; // Dn and An source both update CCR
                            dec_needs_ext   = 1'b1;
                        end else if (f_mode == 3'b111 && f_reg == 3'b100) begin
                            // MOVE #imm, (xxx).W/(xxx).L — immediate source, absolute destination
                            // B/W: ext_data={imm_word, abs.W addr}; for abs.L: ext_data={imm_word, abs.L_hi}, q3=abs.L_lo
                            // L:   ext_data={imm_hi, imm_lo};       for abs.W: q3=abs.W addr; abs.L: ext34=abs.L
                            dec_valid       = 1'b1;
                            dec_is_mem_wr   = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_use_imm     = 1'b1;
                            dec_siz         = f_move_sz;
                            dec_abs_ea_en   = 1'b1;
                            dec_abs_ea_val  = (f_dn == 3'b001)
                                           ? ((f_move_sz == 2'b00) ? ext34_data
                                                                    : {ext_data[15:0], q3_word})
                                           : ((f_move_sz == 2'b00) ? {{16{q3_word[15]}}, q3_word}
                                                                    : {{16{ext_data[15]}}, ext_data[15:0]});
                            dec_imm         = (f_move_sz == 2'b00) ? ext_data
                                           :                          {16'h0, ext_data[31:16]};
                            dec_writes_reg  = 1'b0;
                            dec_updates_ccr = 1'b1;
                            dec_needs_ext   = 1'b1;
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101 || f_mode == 3'b110 || f_mode == 3'b111) begin
                            // src = memory → MOVE (src),(xxx).W/(xxx).L
                            dec_valid          = 1'b1;
                            dec_is_move_mm     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_unit           = UNIT_MOVE;
                            dec_writes_reg     = 1'b0;
                            dec_x_unchanged    = 1'b1;
                            dec_abs_dst_ea_en  = 1'b1;
                            dec_needs_ext      = 1'b1;
                            // dst abs EA. Layout depends on src ext-word count:
                            //  0 src ext (modes 2/3/4):            abs.L dst = {q[1],q[2]}=ext_data;
                            //                                       abs.W dst = q[1]=ext_data[15:0].
                            //  1 src ext (modes 5,6, 7.reg≠1):     abs.L dst = {q[2],q[3]};
                            //                                       abs.W dst = q[2]=ext_data[15:0].
                            //  2 src ext (mode 7.reg=1 = abs.L):   abs.L dst = {q[3],q[4]}=ext34;
                            //                                       abs.W dst = q[3]=q3_word.
                            dec_abs_dst_ea_val =
                                (f_dn == 3'b001 &&
                                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && f_reg != 3'b001)))
                                ? {ext_data[15:0], q3_word}   // 1 src ext + abs.L dst
                                : (f_dn == 3'b001 && f_mode == 3'b111 && f_reg == 3'b001)
                                ? ext34_data                   // abs.L src + abs.L dst: q[3]+q[4]
                                : (f_dn == 3'b001)
                                ? ext_data                     // 0 src ext + abs.L dst: q[1]+q[2]
                                : (f_mode == 3'b111 && f_reg == 3'b001)
                                ? {{16{q3_word[15]}}, q3_word} // abs.L src + abs.W dst: q[3]
                                : {{16{ext_data[15]}}, ext_data[15:0]};  // 0/1 src ext + abs.W dst
                            // src EA setup
                            if (f_mode == 3'b111) begin
                                dec_abs_ea_en = 1'b1;
                                case (f_reg)
                                    // src in hi slot [31:16]; dst words follow after
                                    3'b000: dec_abs_ea_val = {{16{ext_data[31]}}, ext_data[31:16]};
                                    3'b001: dec_abs_ea_val = ext_data; // abs.L src (abs.W dst only)
                                    3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                           + {{16{ext_data[31]}}, ext_data[31:16]};
                                    3'b011: begin
                                        // (d8,PC,Xi): ext_data={brief_ext, abs.W/abs.L_hi}
                                        // EA = PC+2 + Xi*scale + d8 (brief_ext in hi word)
                                        dec_is_idx     = 1'b1;
                                        dec_dst_reg    = {ext_data[31], ext_data[30:28]};
                                        dec_reads_dst  = 1'b1;
                                        dec_xn_wl      = ext_data[27];
                                        dec_xn_scale   = ext_data[26:25];
                                        dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{24{ext_data[23]}}, ext_data[23:16]};
                                        // abs.L dst: real dst EA is {ext_data[15:0], q3_word}
                                        if (f_dn == 3'b001)
                                            dec_abs_dst_ea_val = {ext_data[15:0], q3_word};
                                    end
                                    default: ;
                                endcase
                            end else begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_reads_dst = 1'b0; // abs dst, no An needed in rd_b
                                case (f_mode)
                                    3'b010: ;
                                    3'b011: begin
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = calc_step(f_move_sz, f_reg==3'b111);
                                    end
                                    3'b100: begin
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = ~calc_step(f_move_sz, f_reg==3'b111)+32'h1;
                                        dec_ea_offset  = dec_an_delta;
                                    end
                                    3'b101: begin
                                        // src d16 always in ext_data[31:16] = q[1] (first ext word)
                                        dec_ea_offset = {{16{ext_data[31]}}, ext_data[31:16]};
                                    end
                                    3'b110: begin
                                        // MOVE (d8,An,Xi),(xxx).W/L — indexed src, abs dst
                                        // ext_data[31:16]=brief_ext, ext_data[15:0]=abs.W or abs.L_hi
                                        dec_dst_reg   = {ext_data[31], ext_data[30:28]}; // Xi → rd_b
                                        dec_reads_dst = 1'b1;
                                        dec_is_idx    = 1'b1;
                                        dec_xn_wl     = ext_data[27];
                                        dec_xn_scale  = ext_data[26:25];
                                        dec_ea_offset = {{24{ext_data[23]}}, ext_data[23:16]}; // d8
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 0100: NEG/NEGX/NOT/CLR/TST / SWAP / EXT / NOP
                // ----------------------------------------------------------------
                4'h4: begin
                    if (f_mode == 3'b000) begin
                        if (f_ss != 2'b11 && !f_dir) begin
                            dec_siz         = f_siz;
                            dec_dst_reg     = {1'b0, f_reg};
                            dec_dest_reg    = {1'b0, f_reg};
                            dec_unit        = UNIT_ALU;
                            dec_updates_ccr = 1'b1;
                            dec_reads_dst   = 1'b1;
                            case (f_dn)
                                3'b000: begin dec_alu_op=ALU_NEGX; dec_writes_reg=1'b1; dec_valid=1'b1; end
                                3'b001: begin dec_alu_op=ALU_CLR;  dec_writes_reg=1'b1; dec_reads_dst=1'b0; dec_valid=1'b1; end
                                3'b010: begin dec_alu_op=ALU_NEG;  dec_writes_reg=1'b1; dec_valid=1'b1; end
                                3'b011: begin dec_alu_op=ALU_NOT;  dec_writes_reg=1'b1; dec_valid=1'b1; end
                                3'b100: begin
                                    if (f_ss == 2'b00) begin
                                        // NBCD.B Dn
                                        dec_unit        = UNIT_BCD;
                                        dec_bcd_op      = BCD_NEG;
                                        dec_siz         = 2'b01;
                                        dec_writes_reg  = 1'b1;
                                        dec_valid       = 1'b1;
                                    end else if (f_ss == 2'b01) begin
                                        // SWAP Dn: 0100 1000 01 000 rrr
                                        dec_unit           = UNIT_MOVE;
                                        dec_src_reg        = {1'b0, f_reg};
                                        dec_dst_reg        = {1'b0, f_reg};
                                        dec_dest_reg       = {1'b0, f_reg};
                                        dec_siz            = 2'b00;
                                        dec_reads_src      = 1'b1;
                                        dec_reads_dst      = 1'b1;
                                        dec_writes_reg     = 1'b1;
                                        dec_updates_ccr    = 1'b1;
                                        dec_x_unchanged    = 1'b1;
                                        dec_is_swap        = 1'b1;
                                        dec_valid          = 1'b1;
                                    end else begin
                                        // EXT.W Dn: 0100 1000 10 000 rrr (f_ss=10)
                                        dec_unit           = UNIT_MOVE;
                                        dec_src_reg        = {1'b0, f_reg};
                                        dec_dst_reg        = {1'b0, f_reg};
                                        dec_dest_reg       = {1'b0, f_reg};
                                        dec_siz            = 2'b10;   // word write
                                        dec_reads_src      = 1'b1;
                                        dec_reads_dst      = 1'b1;
                                        dec_writes_reg     = 1'b1;
                                        dec_updates_ccr    = 1'b1;
                                        dec_x_unchanged    = 1'b1;
                                        dec_sext           = 1'b1;
                                        dec_sext_from_byte = 1'b1;
                                        dec_valid          = 1'b1;
                                    end
                                end
                                3'b101: begin dec_alu_op=ALU_TST;  dec_x_unchanged=1'b1; dec_valid=1'b1; end
                                3'b110: begin
                                    // MULU.L/MULS.L (f_ss=00) or DIVU.L/DIVS.L (f_ss=01)
                                    // Opcode Dn (f_reg) = multiplier/divisor; ext Dl/Dq = destination
                                    //
                                    // MUL/DIV timing investigation (plan.md): the signed/unsigned
                                    // flag was read from ext_data[6] -- WRONG. The real 68020
                                    // extension-word format for this instruction family is bit
                                    // 15=0 (reserved), 14:12=Dh/Dr, 11=sign (1=signed), 10=size
                                    // (MUL only, 1=64-bit), 9:3=0 (reserved), 2:0=Dl/Dq -- bit 11
                                    // is the sign flag, not bit 6. Confirmed empirically (not just
                                    // from memory) by assembling real DIVS.L/DIVU.L via vasm and
                                    // comparing the two extension words directly: they differ in
                                    // exactly one bit, 0x0800 (bit 11); bit 6 is 0 in BOTH. Every
                                    // existing hand-crafted test in this project's own testbenches
                                    // set bit 6 (matching this same wrong convention) rather than
                                    // bit 11, so this bug was invisible to every prior test --
                                    // confirmed via direct execution: a real vasm-assembled
                                    // "DIVS.L D1,D2" with a negative dividend computed the
                                    // UNSIGNED result (ext_data[6]=0 for every real encoding of
                                    // this instruction, regardless of the actual S/U mnemonic
                                    // used, so dec_md_op always selected the _UL/_UW... err _UL
                                    // form). Harte has zero coverage of the .L forms (68000-
                                    // captured corpus, .L mul/div is 68020+-only), which is why
                                    // 158+ prior phases never caught this.
                                    dec_needs_ext   = 1'b1;
                                    dec_siz         = 2'b00;
                                    dec_src_reg     = {1'b0, f_reg};          // multiplier/divisor
                                    dec_dst_reg     = {1'b0, ext_data[2:0]};  // Dl/Dq (multiplicand/dividend)
                                    dec_dest_reg    = {1'b0, ext_data[2:0]};  // primary result write
                                    dec_md_dst2     = ext_data[14:12];         // Dh/Dr (secondary write)
                                    dec_reads_src   = 1'b1;
                                    dec_reads_dst   = 1'b1;
                                    dec_writes_reg  = 1'b1;
                                    dec_updates_ccr = 1'b1;
                                    dec_is_muldivl  = 1'b1;
                                    if (f_ss == 2'b00) begin
                                        // MULU.L / MULS.L
                                        dec_valid    = 1'b1;
                                        dec_unit     = UNIT_MUL;
                                        dec_md_op    = ext_data[11] ? MUL_SL : MUL_UL;
                                        dec_md_64bit = ext_data[10];
                                    end else if (f_ss == 2'b01) begin
                                        // DIVU.L / DIVS.L
                                        dec_valid    = 1'b1;
                                        dec_unit     = UNIT_DIV;
                                        dec_md_op    = ext_data[11] ? DIV_SL : DIV_UL;
                                        dec_md_64bit = (ext_data[14:12] != ext_data[2:0]);
                                    end
                                end
                                3'b111: begin
                                    // TRAP #0-7: 0100 1110 0100 0nnn (f_ss=01)
                                    // TRAP #8-15 has f_mode=001 and is handled later.
                                    // Must override the shared prefix (updates_ccr=1, reads_dst=1, unit=ALU).
                                    dec_valid       = 1'b1;
                                    dec_is_trap     = 1'b1;
                                    dec_trap_num    = f_trap_num;
                                    dec_updates_ccr = 1'b0;
                                    dec_reads_dst   = 1'b0;
                                    dec_unit        = UNIT_NONE;
                                end
                                default: ;
                            endcase
                        end else if (f_ss != 2'b11 && f_dir) begin
                            // CHK Dn_ub, Dn_chk: 0100 DDD1 ss 000 rrr
                            // f_dir=1, f_ss=10→CHK.W, f_ss=00→CHK.L
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_NONE;  // N via wb_ccr[3], not wb_move_n
                            dec_is_chk      = 1'b1;
                            dec_chk_word    = (f_ss == 2'b10);
                            dec_siz         = (f_ss == 2'b10) ? 2'b10 : 2'b00;
                            dec_updates_ccr = 1'b1;
                            dec_x_unchanged = 1'b1;
                            dec_src_reg     = {1'b0, f_reg};   // upper bound → rd_a
                            dec_dst_reg     = {1'b0, f_dn};    // value checked → rd_b
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                        end else begin
                            // f_ss==11, f_mode==000: MOVE to/from SR/CCR, EXT, TAS.B Dn
                            if (f_dn == 3'b000 && !f_dir) begin
                                // MOVE SR,Dn: 0100 000 0 11 000 rrr — read SR → Dn[15:0]
                                dec_valid        = 1'b1;
                                dec_unit         = UNIT_MOVE;
                                dec_siz          = 2'b10;   // word write
                                dec_dest_reg     = {1'b0, f_reg};
                                dec_writes_reg   = 1'b1;
                                dec_x_unchanged  = 1'b1;
                                dec_reads_ccr    = 1'b1;    // stall while CCR in-flight
                                dec_use_imm      = 1'b1;
                                dec_imm          = {16'h0, sr_live};
                                dec_is_move_sr_r = 1'b1;
                            end else if (f_dn == 3'b001 && !f_dir) begin
                                // MOVE CCR,Dn: 0100 001 0 11 000 rrr — read CCR → Dn
                                dec_valid         = 1'b1;
                                dec_unit          = UNIT_MOVE;
                                dec_siz           = 2'b10;
                                dec_dest_reg      = {1'b0, f_reg};
                                dec_writes_reg    = 1'b1;
                                dec_x_unchanged   = 1'b1;
                                dec_reads_ccr     = 1'b1;
                                dec_use_imm       = 1'b1;
                                dec_imm           = {24'h0, sr_live[7:0]};
                                dec_is_move_ccr_r = 1'b1;
                            end else if (f_dn == 3'b010 && !f_dir) begin
                                // MOVE Dn,CCR: 0100 010 0 11 000 rrr — write Dn → CCR
                                dec_valid         = 1'b1;
                                dec_unit          = UNIT_MOVE;
                                dec_siz           = 2'b10;
                                dec_src_reg       = {1'b0, f_reg};
                                dec_reads_src     = 1'b1;
                                dec_x_unchanged   = 1'b1;
                                dec_is_move_ccr_w = 1'b1;
                                dec_updates_ccr   = 1'b1;
                            end else if (f_dn == 3'b011 && !f_dir) begin
                                // MOVE Dn,SR: supervisor only
                                if (!sr_live[13]) begin
                                    dec_valid   = 1'b1;
                                    dec_is_priv = 1'b1;
                                end else begin
                                    dec_valid        = 1'b1;
                                    dec_unit         = UNIT_MOVE;
                                    dec_siz          = 2'b10;
                                    dec_src_reg      = {1'b0, f_reg};
                                    dec_reads_src    = 1'b1;
                                    dec_x_unchanged  = 1'b1;
                                    dec_is_move_sr_w = 1'b1;
                                    dec_updates_ccr  = 1'b1;
                                end
                            end else if (f_dn == 3'b100) begin
                                // EXT.L (f_dir=0) / EXTB.L (f_dir=1)
                                dec_unit           = UNIT_MOVE;
                                dec_src_reg        = {1'b0, f_reg};
                                dec_dst_reg        = {1'b0, f_reg};
                                dec_dest_reg       = {1'b0, f_reg};
                                dec_siz            = 2'b00;   // long write
                                dec_reads_src      = 1'b1;
                                dec_reads_dst      = 1'b1;
                                dec_writes_reg     = 1'b1;
                                dec_updates_ccr    = 1'b1;
                                dec_x_unchanged    = 1'b1;
                                dec_sext           = 1'b1;
                                dec_sext_from_byte = f_dir;   // 0=EXT.L(word→long), 1=EXTB.L(byte→long)
                                dec_valid          = 1'b1;
                            end else if (f_dn == 3'b101 && !f_dir) begin
                                // TAS.B Dn: 0100 1010 11 000 rrr
                                // f_mode=000 puts us here; f_dn=101, f_dir=0, f_ss=11
                                dec_valid       = 1'b1;
                                dec_unit        = UNIT_MOVE;
                                dec_siz         = 2'b01;    // byte
                                dec_src_reg     = {1'b0, f_reg};
                                dec_dest_reg    = {1'b0, f_reg};
                                dec_reads_src   = 1'b1;
                                dec_writes_reg  = 1'b1;
                                dec_updates_ccr = 1'b1;
                                dec_x_unchanged = 1'b1;
                                dec_is_tas      = 1'b1;
                            end
                        end
                    // ── NEGX/NEG/NOT/TST to memory ea ─────────────────
                    // (d8,An,Xn) indexed dst only needs An(rd_a)+Xn(rd_b) — these are
                    // unary memory ops with no separate data-register operand, so the
                    // 2-port regfile is sufficient (same pattern as LEA/PEA indexed;
                    // see port3.md §1 Bucket A — this is not the 3-read-port gap).
                    // (d16,PC) is only reachable for TST (f_dn=101) — not alterable,
                    // so illegal as a NEGX/NEG/NOT destination.
                    // CLR (f_dn=001) used to share this block/RMW path too, but real
                    // 68020/030 CLR-to-memory is architecturally a pure write (no
                    // dest read — unlike the 68000) whereas NEGX/NEG/NOT genuinely
                    // need the old value; split out into its own dedicated block
                    // below (Phase 139, plan.md) so non-indexed CLR stops performing
                    // a real, unnecessary bus read (tests/memind13.s's own header
                    // already documented this quirk). Indexed CLR (mode 110) keeps
                    // the RMW path there too — deferred to Phase 144, which shares
                    // the same 2-register-write fix with MOVE SR,(ea).
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                        (f_dn == 3'b101 && f_reg == 3'b010)))) &&
                                 (f_dn == 3'b000 || f_dn == 3'b010 ||
                                  f_dn == 3'b011 || f_dn == 3'b101)) begin
                        dec_siz         = f_siz;
                        dec_unit        = UNIT_ALU;
                        dec_is_mem_rd   = 1'b1;
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};  // An → rd_a (EA base)
                            dec_reads_src = 1'b1;
                        end
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        case (f_mode)
                            3'b101: begin  // (d16,An)
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b110: begin  // (d8,An,Xn) brief, or full (bd,An,Xn)
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst = 1'b1;
                                dec_is_idx    = 1'b1;
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                // Same fi_is_full/fi_bd extension as TAS/NBCD's
                                // own mode=110 cases -- see TAS's comment for the
                                // full reasoning.
                                dec_ea_offset = fi_is_full ? fi_bd
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b111: begin
                                dec_needs_ext = 1'b1;
                                case (f_reg)
                                    3'b000: begin  // abs.W
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b001: begin  // abs.L
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = ext_data;
                                    end
                                    3'b010: begin  // (d16,PC) — TST only
                                        dec_abs_ea_en  = 1'b1;
                                        dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    default: ;
                                endcase
                            end
                            default: ;
                        endcase
                        case (f_dn)
                            3'b000: begin dec_alu_op=ALU_NEGX; dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b010: begin dec_alu_op=ALU_NEG;  dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b011: begin dec_alu_op=ALU_NOT;  dec_valid=1'b1; dec_is_mem_rmw=1'b1; end
                            3'b101: begin  // TST ea — read + CCR, no write
                                dec_alu_op      = ALU_TST;
                                dec_x_unchanged = 1'b1;
                                dec_updates_ccr = 1'b1;
                                dec_valid       = 1'b1;
                            end
                            default: ;
                        endcase
                    // ── CLR to memory ea ──────────────────────────────
                    // Split out of the shared NEGX/NEG/NOT/TST block above (Phase 139,
                    // plan.md): real 68020/030 CLR-to-memory is a pure write (no
                    // read of the old value, a documented improvement over the
                    // 68000). Indexed EA (f_mode==110) was RMW until Phase 144
                    // (plan.md), which decoupled ex_an_base's own mux from
                    // ex_is_mem_wr for the indexed case specifically, letting
                    // this become a genuine single-phase write too -- every mode
                    // routes through dec_is_mem_wr with dec_unit=UNIT_MOVE/
                    // dec_use_imm=1/dec_imm=0 now, deliberately NOT dec_unit=
                    // UNIT_ALU/ALU_CLR, reusing MOVE #imm,mem's own
                    // already-Harte-proven CCR path instead (move_result_w becomes
                    // ex_imm=0, giving exactly CLR's own flags: Z=1, N=V=C=0 --
                    // architecturally identical to "MOVE #0,ea").
                    end else if (!f_dir && f_ss != 2'b11 && f_dn == 3'b001 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)))) begin
                        dec_valid       = 1'b1;
                        dec_siz         = f_siz;
                        dec_unit        = UNIT_MOVE;
                        dec_use_imm     = 1'b1;
                        dec_imm         = 32'h0;
                        dec_updates_ccr = 1'b1;
                        dec_is_mem_wr   = 1'b1;
                        if (f_mode == 3'b110) begin
                            // Indexed EA (Phase 144): An -> rd_a, Xn -> rd_b, same
                            // register layout the old RMW path already used --
                            // write data always comes from dec_imm=0, never
                            // rd_a_data, so no collision with An sitting on rd_a.
                            dec_src_reg    = {1'b1, f_reg};  // An → rd_a
                            dec_reads_src  = 1'b1;
                            dec_dst_reg    = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_dst  = 1'b1;
                            dec_is_idx     = 1'b1;
                            dec_xn_wl      = ext_data[11];
                            dec_xn_scale   = ext_data[10:9];
                            dec_ea_offset  = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext  = 1'b1;
                        end else begin
                            // Non-indexed: unchanged from Phase 139.
                            if (f_mode != 3'b111) begin
                                dec_dst_reg   = {1'b1, f_reg};  // An → rd_b (write path)
                                dec_reads_dst = 1'b1;
                            end
                            setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                            case (f_mode)
                                3'b101: begin  // (d16,An)
                                    dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_needs_ext = 1'b1;
                                end
                                3'b111: begin
                                    dec_needs_ext = 1'b1;
                                    case (f_reg)
                                        3'b000: begin  // abs.W
                                            dec_abs_ea_en  = 1'b1;
                                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                        end
                                        3'b001: begin  // abs.L
                                            dec_abs_ea_en  = 1'b1;
                                            dec_abs_ea_val = ext_data;
                                        end
                                        default: ;
                                    endcase
                                end
                                default: ;
                            endcase
                        end
                    // ── NBCD memory EA ────────────────────────────────
                    end else if (!f_dir && f_ss == 2'b00 && f_dn == 3'b100 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)))) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_BCD;
                        dec_bcd_op      = BCD_NEG;
                        dec_siz         = 2'b01;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_needs_ext   = (f_mode == 3'b101 || f_mode == 3'b110 || f_mode == 3'b111) ? 1'b1 : 1'b0;
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                        end
                        case (f_mode)
                            3'b011: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(2'b01, f_reg == 3'b111);
                            end
                            3'b100: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(2'b01, f_reg == 3'b111) + 32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            3'b101: begin  // (d16,An)
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b110: begin  // (d8,An,Xn) brief, or full (bd,An,Xn)
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst = 1'b1;
                                dec_is_idx    = 1'b1;
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                // Same fi_is_full/fi_bd extension as TAS's own
                                // mode=110 case above -- see its comment for the
                                // full reasoning (full-format non-indirect only;
                                // genuine memory-indirect deferred).
                                dec_ea_offset = fi_is_full ? fi_bd
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            3'b111: begin  // abs.W or abs.L
                                dec_abs_ea_en  = 1'b1;
                                dec_abs_ea_val = (f_reg == 3'b001) ? ext_data :
                                                 {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            default: ;
                        endcase
                    end else if (f_dir && f_ss == 2'b11 && f_mode >= 3'b010) begin
                        // LEA ea,An: 0100 aaa 111 mmm rrr
                        // f_dir=1, f_ss=11 (bits[8:6]=111 when combined as dst_mode)
                        // f_mode = EA mode (control modes only; phase 37: 010 and 101)
                        if (f_mode == 3'b010 || f_mode == 3'b101) begin
                            dec_valid      = 1'b1;
                            dec_is_lea     = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};   // An for EA base → rd_a
                            dec_reads_src  = 1'b1;
                            dec_dest_reg   = {1'b1, f_dn};   // An destination
                            dec_writes_reg = 1'b1;
                            dec_siz        = 2'b00;           // longword An write
                            if (f_mode == 3'b101) begin
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext = 1'b1;
                            end
                        end else if (f_mode == 3'b111) begin
                            // LEA (special EA), An — abs or PC-relative
                            dec_valid      = 1'b1;
                            dec_is_lea     = 1'b1;
                            dec_dest_reg   = {1'b1, f_dn};
                            dec_writes_reg = 1'b1;
                            dec_siz        = 2'b00;
                            dec_abs_ea_en  = 1'b1;
                            dec_needs_ext  = 1'b1;
                            case (f_reg)
                                3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b001: dec_abs_ea_val = ext_data;
                                3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b011: begin
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst = 1'b1;
                                    dec_is_idx    = 1'b1;
                                    dec_xn_wl     = ext_data[11];
                                    dec_xn_scale  = ext_data[10:9];
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b110) begin
                            // LEA (d8,An,Xn) brief, or full (bd,An,Xn) -- An
                            dec_valid      = 1'b1;
                            dec_is_lea     = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};                    // An (base) → rd_a
                            dec_dst_reg    = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_dest_reg   = {1'b1, f_dn};
                            dec_writes_reg = 1'b1;
                            dec_siz        = 2'b00;
                            dec_is_idx     = 1'b1;
                            dec_xn_wl      = ext_data[11];
                            dec_xn_scale   = ext_data[10:9];
                            dec_needs_ext  = 1'b1;
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd extension,
                            // same template as Stage 1/2. 10-item backlog Stage 9a
                            // (plan.md): genuine memory-indirect (fi_iis!=000) --
                            // same shape as MOVE's own memind arm, but LEA never
                            // dereferences its own final EA, so dec_writes_reg is
                            // suppressed here (the memind FSM completes it directly
                            // via memind_addr_wr_en once the inner pointer read
                            // lands -- see eu_seq_execute.svh).
                            if (fi_is_full && fi_iis != 3'b000) begin
                                dec_writes_reg     = 1'b0;
                                dec_is_memind       = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                            end else begin
                                dec_ea_offset  = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                        end
                    end else if (f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        // CHK #imm, Dn: 0100 DDD1 ss 111 100 + ext
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_NONE;
                        dec_is_chk      = 1'b1;
                        dec_chk_word    = (f_ss == 2'b10);
                        dec_siz         = (f_ss == 2'b10) ? 2'b10 : 2'b00;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};    // value checked → rd_b
                        dec_reads_dst   = 1'b1;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                    // ── CHK memory-source upper bound ───────────────
                    end else if (f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                        f_reg == 3'b010 || f_reg == 3'b011)))) begin
                        // CHK (An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(xxx).W/(xxx).L/
                        // (d16,PC)/(d8,PC,Xn), Dn — read upper bound from memory
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_NONE;
                        dec_is_chk      = 1'b1;
                        dec_chk_word    = (f_ss == 2'b10);
                        dec_siz         = (f_ss == 2'b10) ? 2'b10 : 2'b00;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};    // Dn (value to check) → rd_b
                        dec_reads_dst   = 1'b1;
                        dec_is_mem_rd   = 1'b1;            // read upper bound from memory
                        if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100) begin
                            // (An)/(An)+/-(An): EA = An, auto-inc/dec by operand size
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                            setup_mem_incdec(dec_siz, dec_an_upd_en, dec_an_upd_reg,
                                              dec_an_delta, dec_ea_offset);
                        end else if (f_mode == 3'b101) begin
                            // (d16,An): EA = An + d16
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_needs_ext = 1'b1;
                        end else if (f_mode == 3'b110) begin
                            // (d8,An,Xn): EA = An + Xn*scale + d8. Dn (tested value) is
                            // only needed for the comparison AFTER the memory read
                            // completes — same deferred-register pattern already proven
                            // for AND/OR/EOR/SUB/CMP Dn,(d8,An,Xn) (dyn_bit_get_Dn), not
                            // a true 3-simultaneous-operand case. rd_a=An, rd_b=Xn during
                            // the read; rd_b swaps to Dn exactly at the read-ack cycle,
                            // which is also the cycle CHK's own WB capture fires (no
                            // RMW/move_mm write phase to desync from — see port3.md
                            // Bucket D), so no extra capture register is needed. This
                            // override replaces the dec_dst_reg=Dn set above with Xn for
                            // the read phase; dyn_bit swaps it back to Dn at the ack.
                            dec_src_reg        = {1'b1, f_reg};  // An → rd_a
                            dec_reads_src      = 1'b1;
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd extension,
                            // same template as Stage 1/2. dyn_bit_get_Dn's own
                            // register-swap mechanism is orthogonal, unchanged.
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext      = 1'b1;
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;   // Dn (tested value) → rd_b after swap
                            dec_dyn_bit_is_an  = 1'b0;
                        end else if (f_reg == 3'b000) begin
                            // (xxx).W: EA = sign-extend(abs16)
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_needs_ext  = 1'b1;
                        end else if (f_reg == 3'b001) begin
                            // (xxx).L: EA = abs32
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = ext_data;
                            dec_needs_ext  = 1'b1;
                        end else if (f_reg == 3'b010) begin
                            // (d16,PC): EA = decode_pc+2 + d16 — no register operand for
                            // the base, Dn stays fixed on rd_b, no swap needed.
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = decode_pc + 32'd2
                                           + {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_needs_ext  = 1'b1;
                        end else begin
                            // (d8,PC,Xn): EA = decode_pc+2 + Xn*scale + d8. Xn is hardwired
                            // to rd_b by the EX-stage EA datapath (ex_xn_scaled always reads
                            // rd_b_data), which collides with Dn also needing rd_b for the
                            // post-read comparison — same deferred-swap shape as the
                            // (d8,An,Xn) case above, just with dec_abs_ea_en (PC-relative
                            // base) instead of dec_src_reg (An base); dyn_bit_get_Dn doesn't
                            // care which one supplies the base, only that ex_is_dyn_bit_idx
                            // + ex_is_mem_rd are set, so the same swap-at-ack mechanism works
                            // unmodified. rd_a is unused here (no An operand).
                            dec_abs_ea_en      = 1'b1;
                            dec_abs_ea_val     = decode_pc + 32'd2
                                               + {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            dec_needs_ext      = 1'b1;
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;   // Dn (tested value) → rd_b after swap
                            dec_dyn_bit_is_an  = 1'b0;
                        end
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b10) begin
                        // JSR ea: 0100 1110 10 mmm rrr — push PC to -(A7), jump to ea
                        if (f_mode == 3'b010 || f_mode == 3'b101) begin
                            dec_valid      = 1'b1;
                            dec_is_jsr     = 1'b1;
                            dec_is_mem_wr  = 1'b1;
                            dec_src_reg    = {1'b1, f_reg};   // An (jump base) → rd_a
                            dec_dst_reg    = {1'b1, 3'b111};  // A7 (push base) → rd_b
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_siz        = 2'b00;
                            dec_ea_offset  = 32'hFFFF_FFFC;   // A7-4 = push address
                            dec_an_upd_en  = 1'b1;
                            dec_an_upd_reg = 3'b111;
                            dec_an_delta   = 32'hFFFF_FFFC;   // A7-=4
                            dec_return_pc  = decode_pc + (f_mode == 3'b101 ? 32'd4 : 32'd2);
                            if (f_mode == 3'b101) begin
                                dec_jump_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext   = 1'b1;
                            end
                        end else if (f_mode == 3'b111) begin
                            // JSR (special EA) — abs or PC-relative target, push return PC.
                            // (d8,PC,Xn) (f_reg==011, below) needs A7+Xn+PC simultaneously --
                            // resolved via dec_is_jsr_idx routing the push address through
                            // the dedicated ex_cur_sp path (same mechanism as PEA/JSR
                            // (d8,An,Xn)) instead of rd_b, freeing rd_b for Xn.
                            dec_valid      = 1'b1;
                            dec_is_jsr     = 1'b1;
                            dec_is_mem_wr  = 1'b1;
                            dec_dst_reg    = {1'b1, 3'b111};  // A7 → rd_b for push EA
                            dec_reads_dst  = 1'b1;
                            dec_siz        = 2'b00;
                            dec_ea_offset  = 32'hFFFF_FFFC;   // push at A7-4
                            dec_an_upd_en  = 1'b1;
                            dec_an_upd_reg = 3'b111;
                            dec_an_delta   = 32'hFFFF_FFFC;
                            dec_abs_jmp_en = 1'b1;
                            dec_needs_ext  = 1'b1;
                            case (f_reg)
                                3'b000: begin  // abs.W
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_return_pc  = decode_pc + 32'd4;
                                end
                                3'b001: begin  // abs.L
                                    dec_abs_ea_val = ext_data;
                                    dec_return_pc  = decode_pc + 32'd6;
                                end
                                3'b010: begin  // (d16,PC): target = PC+2+d16; return = PC+4
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_return_pc  = decode_pc + 32'd4;
                                end
                                3'b011: begin  // (d8,PC,Xn): base=PC+2+d8, Xn scales
                                    dec_is_jsr_idx  = 1'b1;
                                    dec_abs_ea_val  = decode_pc + 32'd2
                                                    + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg     = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst   = 1'b1;
                                    dec_is_idx      = 1'b1;
                                    dec_xn_wl       = ext_data[11];
                                    dec_xn_scale    = ext_data[10:9];
                                    dec_return_pc   = decode_pc + 32'd4;
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b110) begin
                            // JSR (d8,An,Xn): push PC to -(A7), jump to An+d8+scale(Xn).
                            // rd_a = An (jump base), rd_b = Xn (index).
                            // Push address uses ex_cur_sp (not rd_b) via ex_is_jsr_idx path.
                            dec_valid       = 1'b1;
                            dec_is_jsr      = 1'b1;
                            dec_is_mem_wr   = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};                    // An → rd_a
                            dec_dst_reg     = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_siz         = 2'b00;
                            dec_is_idx      = 1'b1;
                            dec_xn_wl       = ext_data[11];
                            dec_xn_scale    = ext_data[10:9];
                            dec_an_upd_en   = 1'b1;
                            dec_an_upd_reg  = 3'b111;
                            dec_an_delta    = 32'hFFFF_FFFC;
                            dec_needs_ext   = 1'b1;
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd. 10-item
                            // backlog Stage 9b (plan.md): genuine memory-indirect
                            // (fi_iis!=000) -- same outer-write-then-jump shape as
                            // PEA's own memind arm, but the value pushed is the
                            // return PC (already handled generically by the shared
                            // ex_is_jsr||ex_is_bsr mem_wdata case) and the resolved
                            // EA becomes the jump target instead of a pushed value.
                            if (fi_is_full && fi_iis != 3'b000) begin
                                // dec_is_mem_wr must be suppressed here too
                                // (mirroring PEA's own memind arm) -- left
                                // at 1 (its shared-setup default above), it
                                // trips ex_an_base's own "(ex_is_mem_wr &&
                                // !ex_is_idx) ? rd_b_data : rd_a_data" special
                                // case (meant for JSR/PEA's own SIMPLE,
                                // non-indexed push-address forms), which
                                // would substitute Xn for An in the memind
                                // FSM's own inner-address capture -- found
                                // via a direct cosim mismatch (the inner
                                // read landed at An_value's own coincidental
                                // stand-in, Xn+bd, not An+bd) before this
                                // fix.
                                dec_is_mem_wr       = 1'b0;
                                dec_is_memind       = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                            end else begin
                                dec_is_jsr_idx  = 1'b1;
                                dec_jump_offset = fi_is_full ? fi_bd
                                                : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            // 10-item backlog Stage 9b (plan.md): dec_return_pc was
                            // hardcoded decode_pc+4 unconditionally here -- correct
                            // for brief (2 words) but silently WRONG for the
                            // full-format non-indirect case too (found while adding
                            // memind support and confirmed directly against
                            // Musashi's own reference: a genuine, previously-
                            // undiscovered pre-existing bug, not something this
                            // stage introduced -- likely never exercised since full-
                            // format JSR (d8,An,Xn) is a 68020+-only encoding outside
                            // Harte's own 68000-captured corpus). Now sized from the
                            // instruction's own actual word count: opcode+ext(2) +
                            // base displacement (0/1/2 words) + outer displacement
                            // (0/1/2 words, indirect only).
                            dec_return_pc   = decode_pc + 32'd4
                                            + (fi_is_full ? {29'd0, eaf_disp_words(fi_bdsz)} : 32'd0) * 32'd2
                                            + ((fi_is_full && fi_iis != 3'b000)
                                               ? {29'd0, eaf_disp_words(fi_iis[1:0])} : 32'd0) * 32'd2;
                        end
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b11) begin
                        // JMP ea: 0100 1110 11 mmm rrr — PC ← ea (no stack change)
                        if (f_mode == 3'b010 || f_mode == 3'b101) begin
                            dec_valid     = 1'b1;
                            dec_is_jmp    = 1'b1;
                            dec_src_reg   = {1'b1, f_reg};   // An → rd_a
                            dec_reads_src = 1'b1;
                            dec_siz       = 2'b00;
                            if (f_mode == 3'b101) begin
                                dec_jump_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext   = 1'b1;
                            end
                        end else if (f_mode == 3'b111) begin
                            // JMP (special EA) — abs or PC-relative target
                            dec_valid      = 1'b1;
                            dec_is_jmp     = 1'b1;
                            dec_siz        = 2'b00;
                            dec_abs_jmp_en = 1'b1;
                            dec_needs_ext  = 1'b1;
                            case (f_reg)
                                3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b001: dec_abs_ea_val = ext_data;
                                3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b011: begin  // (d8,PC,Xn)
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst = 1'b1;
                                    dec_is_idx    = 1'b1;
                                    dec_xn_wl     = ext_data[11];
                                    dec_xn_scale  = ext_data[10:9];
                                end
                                default: ;
                            endcase
                        end else if (f_mode == 3'b110) begin
                            // JMP (d8,An,Xn) brief, or full (bd,An,Xn) — indexed target
                            dec_valid       = 1'b1;
                            dec_is_jmp      = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};                    // An (base) → rd_a
                            dec_dst_reg     = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_siz         = 2'b00;
                            dec_is_idx      = 1'b1;
                            dec_xn_wl       = ext_data[11];
                            dec_xn_scale    = ext_data[10:9];
                            dec_needs_ext   = 1'b1;
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd. 10-item
                            // backlog Stage 9b (plan.md): genuine memory-indirect
                            // (fi_iis!=000) -- JMP shares LEA's own address-only
                            // memind shape exactly (never dereferences its own final
                            // EA, becomes the new PC directly once the inner pointer
                            // read lands -- see eu_seq_execute.svh's ex_jmp_taken).
                            if (fi_is_full && fi_iis != 3'b000) begin
                                dec_is_memind       = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                            end else begin
                                dec_jump_offset = fi_is_full ? fi_bd
                                                : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                        end
                    // ── MOVE.W EA, SR/CCR (memory src) and MOVE.W SR/CCR, (EA) ──
                    end else if (!f_dir && f_ss == 2'b11 &&
                                 (((f_dn == 3'b011 || f_dn == 3'b010) &&
                                   (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                    f_mode == 3'b101 || f_mode == 3'b110 ||
                                    (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                          f_reg == 3'b010 || f_reg == 3'b011)))) ||
                                  (f_dn == 3'b000 &&
                                   (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                    f_mode == 3'b101 || f_mode == 3'b110 ||
                                    (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)))))) begin
                        if (f_dn == 3'b000) begin
                            // MOVE.W SR, EA — supervisor only
                            if (!sr_live[13]) begin
                                dec_valid   = 1'b1;
                                dec_is_priv = 1'b1;
                            end else begin
                                dec_valid       = 1'b1;
                                dec_unit        = UNIT_MOVE;
                                dec_siz         = 2'b10;
                                dec_use_imm     = 1'b1;
                                dec_imm         = {16'h0, sr_live};
                                dec_reads_ccr   = 1'b1;
                                dec_x_unchanged = 1'b1;
                                case (f_mode)
                                    3'b010: begin  // (An)
                                        dec_is_mem_wr = 1'b1;
                                        dec_dst_reg   = {1'b1, f_reg};
                                        dec_reads_dst = 1'b1;
                                    end
                                    3'b011: begin  // (An)+
                                        dec_is_mem_wr  = 1'b1;
                                        dec_dst_reg    = {1'b1, f_reg};
                                        dec_reads_dst  = 1'b1;
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = 32'd2;
                                    end
                                    3'b100: begin  // -(An)
                                        dec_is_mem_wr  = 1'b1;
                                        dec_dst_reg    = {1'b1, f_reg};
                                        dec_reads_dst  = 1'b1;
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = 32'hFFFF_FFFE;
                                        dec_ea_offset  = 32'hFFFF_FFFE;
                                    end
                                    3'b101: begin  // (d16,An)
                                        dec_is_mem_wr = 1'b1;
                                        dec_dst_reg   = {1'b1, f_reg};
                                        dec_reads_dst = 1'b1;
                                        dec_needs_ext = 1'b1;
                                        dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                    3'b110: begin  // (d8,An,Xn)/(bd,An,Xn): plain write
                                        // (Phase 144, plan.md). Was an RMW "2-port
                                        // trick" (rd_a=An, rd_b=Xn) purely to get 2
                                        // simultaneous register reads, performing a
                                        // real, architecturally-unnecessary bus read
                                        // before the write -- now a genuine
                                        // single-phase write, safe because ex_an_base's
                                        // own mux (eu_seq.sv) now routes An through
                                        // rd_a specifically for indexed writes, and
                                        // this instruction's own write data always
                                        // comes from dec_use_imm/dec_imm (sr_live, set
                                        // above), never from rd_a_data.
                                        dec_is_mem_wr  = 1'b1;
                                        dec_src_reg    = {1'b1, f_reg};
                                        dec_reads_src  = 1'b1;
                                        dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                        dec_reads_dst  = 1'b1;
                                        dec_is_idx     = 1'b1;
                                        dec_xn_wl      = ext_data[11];
                                        dec_xn_scale   = ext_data[10:9];
                                        // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                                        dec_ea_offset  = fi_is_full ? fi_bd
                                                       : {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_needs_ext  = 1'b1;
                                    end
                                    3'b111: begin
                                        dec_needs_ext = 1'b1;
                                        case (f_reg)
                                            3'b000: begin  // (xxx).W
                                                dec_is_mem_wr  = 1'b1;
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                            end
                                            3'b001: begin  // (xxx).L
                                                dec_is_mem_wr  = 1'b1;
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = ext_data;
                                            end
                                            default: ;
                                        endcase
                                    end
                                    default: ;
                                endcase
                            end
                        end else begin
                            // MOVE.W EA, SR (f_dn=011) or MOVE.W EA, CCR (f_dn=010) — memory source
                            if (f_dn == 3'b011 && !sr_live[13]) begin
                                dec_valid   = 1'b1;
                                dec_is_priv = 1'b1;
                            end else begin
                                dec_valid       = 1'b1;
                                dec_unit        = UNIT_MOVE;
                                dec_is_mem_rd   = 1'b1;
                                dec_siz         = 2'b10;
                                dec_reads_ccr   = 1'b1;
                                dec_x_unchanged = 1'b1;
                                if (f_dn == 3'b011) begin
                                    dec_is_move_sr_w = 1'b1;
                                    dec_updates_ccr  = 1'b1;
                                end else begin
                                    dec_is_move_ccr_w = 1'b1;
                                    dec_updates_ccr   = 1'b1;
                                end
                                case (f_mode)
                                    3'b010: begin  // (An)
                                        dec_src_reg   = {1'b1, f_reg};
                                        dec_reads_src = 1'b1;
                                    end
                                    3'b011: begin  // (An)+
                                        dec_src_reg    = {1'b1, f_reg};
                                        dec_reads_src  = 1'b1;
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = 32'd2;
                                    end
                                    3'b100: begin  // -(An)
                                        dec_src_reg    = {1'b1, f_reg};
                                        dec_reads_src  = 1'b1;
                                        dec_an_upd_en  = 1'b1;
                                        dec_an_upd_reg = f_reg;
                                        dec_an_delta   = 32'hFFFF_FFFE;
                                        dec_ea_offset  = 32'hFFFF_FFFE;
                                    end
                                    3'b101: begin  // (d16,An)
                                        dec_src_reg   = {1'b1, f_reg};
                                        dec_reads_src = 1'b1;
                                        dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                        dec_needs_ext = 1'b1;
                                    end
                                    3'b110: begin  // (d8,An,Xn)/(bd,An,Xn)
                                        dec_src_reg    = {1'b1, f_reg};
                                        dec_reads_src  = 1'b1;
                                        dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                        dec_reads_dst  = 1'b1;
                                        dec_is_idx     = 1'b1;
                                        dec_xn_wl      = ext_data[11];
                                        dec_xn_scale   = ext_data[10:9];
                                        // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                                        dec_ea_offset  = fi_is_full ? fi_bd
                                                       : {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_needs_ext  = 1'b1;
                                    end
                                    3'b111: begin
                                        dec_needs_ext = 1'b1;
                                        case (f_reg)
                                            3'b000: begin  // (xxx).W
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                            end
                                            3'b001: begin  // (xxx).L
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = ext_data;
                                            end
                                            3'b010: begin  // (d16,PC)
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = decode_pc + 32'd2
                                                               + {{16{ext_data[15]}}, ext_data[15:0]};
                                            end
                                            3'b011: begin  // (d8,PC,Xn)
                                                dec_abs_ea_en  = 1'b1;
                                                dec_abs_ea_val = decode_pc + 32'd2
                                                               + {{24{ext_data[7]}}, ext_data[7:0]};
                                                dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                                dec_reads_dst  = 1'b1;
                                                dec_is_idx     = 1'b1;
                                                dec_xn_wl      = ext_data[11];
                                                dec_xn_scale   = ext_data[10:9];
                                            end
                                            default: ;
                                        endcase
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end else if (instr_word == 16'h46FC) begin
                        // MOVE.W #imm, SR — supervisor-only; loads new SR from immediate
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid        = 1'b1;
                            dec_unit         = UNIT_MOVE;
                            dec_siz          = 2'b10;
                            dec_needs_ext    = 1'b1;
                            dec_use_imm      = 1'b1;
                            dec_is_move_sr_w = 1'b1;
                            dec_updates_ccr  = 1'b1;
                            dec_x_unchanged  = 1'b1;
                        end
                    end else if (instr_word == 16'h44FC) begin
                        // MOVE.W #imm, CCR — write low byte of immediate to CCR
                        dec_valid         = 1'b1;
                        dec_unit          = UNIT_MOVE;
                        dec_siz           = 2'b01;
                        dec_needs_ext     = 1'b1;
                        dec_use_imm       = 1'b1;
                        dec_is_move_ccr_w = 1'b1;
                        dec_updates_ccr   = 1'b1;
                        dec_x_unchanged   = 1'b1;
                    end else if (instr_word == 16'h4E75) begin
                        // RTS: pop PC from (A7), A7 += 4
                        dec_valid      = 1'b1;
                        dec_is_rts     = 1'b1;
                        dec_is_mem_rd  = 1'b1;
                        dec_src_reg    = {1'b1, 3'b111};  // A7 → rd_a
                        dec_reads_src  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;
                        dec_an_delta   = 32'd4;
                    end else if (instr_word == 16'h4E77) begin
                        // RTR: pop word→CCR from (A7), A7+=2; pop longword→PC, A7+=4
                        dec_valid     = 1'b1;
                        dec_is_rtr    = 1'b1;
                        dec_is_mem_rd = 1'b1;  // phase-1 read from (A7)
                        dec_src_reg   = {1'b1, 3'b111};  // A7 → rd_a
                        dec_reads_src = 1'b1;
                        dec_siz       = 2'b00;  // longword for phase-2 PC read
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b01 && f_mode == 3'b010) begin
                        // LINK.W An, #d16: 0100 1110 0101 0rrr | d16
                        // -(A7) ← An; An ← A7-4; A7 ← (A7-4) + sign_ext(d16)
                        dec_valid      = 1'b1;
                        dec_is_link    = 1'b1;
                        dec_is_mem_wr  = 1'b1;
                        dec_src_reg    = {1'b1, f_reg};   // An (value to push) → rd_a
                        dec_dst_reg    = {1'b1, 3'b111};  // A7 (EA base for push) → rd_b
                        dec_reads_src  = 1'b1;
                        dec_reads_dst  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_ea_offset  = 32'hFFFF_FFFC;   // A7-4 = push address
                        // When An=A7: skip writes_reg (an_upd handles A7 entirely)
                        dec_writes_reg = (f_reg != 3'b111);
                        dec_dest_reg   = {1'b1, f_reg};   // destination = An
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;          // A7 update
                        // A7_new = A7-4 + d16 = A7 + (d16-4); -4 = 32'hFFFF_FFFC
                        dec_an_delta   = {{16{ext_data[15]}}, ext_data[15:0]} + 32'hFFFF_FFFC;
                        dec_needs_ext  = 1'b1;
                    end else if (f_dn == 3'b100 && !f_dir && f_ss == 2'b00 && f_mode == 3'b001) begin
                        // LINK.L An, #d32: 0100 1000 0000 1rrr | d32 (2 extension words)
                        dec_valid      = 1'b1;
                        dec_is_link    = 1'b1;
                        dec_is_mem_wr  = 1'b1;
                        dec_src_reg    = {1'b1, f_reg};   // An (value to push) → rd_a
                        dec_dst_reg    = {1'b1, 3'b111};  // A7 (EA base for push) → rd_b
                        dec_reads_src  = 1'b1;
                        dec_reads_dst  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_ea_offset  = 32'hFFFF_FFFC;   // A7-4 = push address
                        // When An=A7: skip writes_reg (an_upd handles A7 entirely)
                        dec_writes_reg = (f_reg != 3'b111);
                        dec_dest_reg   = {1'b1, f_reg};   // destination = An
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;          // A7 update
                        // A7_new = A7-4 + d32 = A7 + (d32-4)
                        dec_an_delta   = ext_data + 32'hFFFF_FFFC;
                        dec_needs_ext  = 1'b1;
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b01 && f_mode == 3'b011) begin
                        // UNLK An: 0100 1110 0101 1rrr
                        // A7 ← An; An ← M[(An)]; A7 ← An+4
                        dec_valid      = 1'b1;
                        dec_is_unlk    = 1'b1;
                        dec_is_mem_rd  = 1'b1;            // read old An from M[An]
                        dec_src_reg    = {1'b1, f_reg};   // An (frame ptr = new A7) → rd_a
                        dec_reads_src  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_ea_offset  = 32'h0;           // EA = An (no offset)
                        dec_writes_reg = 1'b1;            // An ← mem_rdata in WB
                        dec_dest_reg   = {1'b1, f_reg};   // An destination
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;          // A7 ← An+4
                        dec_an_delta   = 32'd4;
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b01 && f_mode == 3'b100) begin
                        // MOVE An,USP: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_siz         = 2'b00;
                            dec_src_reg     = {1'b1, f_reg};
                            dec_reads_src   = 1'b1;
                            dec_is_move_usp = 1'b1;
                        end
                    end else if (!f_dir && f_dn == 3'b111 && f_ss == 2'b01 && f_mode == 3'b101) begin
                        // MOVE USP,An: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid      = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            dec_siz        = 2'b00;
                            dec_dest_reg   = {1'b1, f_reg};
                            dec_writes_reg = 1'b1;
                            dec_use_imm    = 1'b1;
                            dec_imm        = usp_in;
                            dec_reads_usp  = 1'b1;
                        end
                    end else if (instr_word == 16'h4E74) begin
                        // RTD #d16: 0100 1110 0111 0100 + ext
                        // Like RTS but A7 += 4 + sign_ext(d16) instead of just 4.
                        dec_valid      = 1'b1;
                        dec_is_rts     = 1'b1;   // reuse RTS FSM; PC ← M[A7]
                        dec_is_mem_rd  = 1'b1;
                        dec_src_reg    = {1'b1, 3'b111};   // A7 → rd_a
                        dec_reads_src  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;
                        dec_an_delta   = 32'd4 + {{16{ext_data[15]}}, ext_data[15:0]};
                        dec_needs_ext  = 1'b1;

                    end else if (instr_word[15:4] == 12'h4E4) begin
                        // TRAP #n: 0100 1110 0100 nnnn  (vector 32+n, n=0..15)
                        dec_valid     = 1'b1;
                        dec_is_trap   = 1'b1;
                        dec_trap_num  = f_trap_num;
                    end else if (instr_word == 16'h4E73) begin
                        // RTE: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid     = 1'b1;
                            dec_is_rte    = 1'b1;
                            dec_is_mem_rd = 1'b1;
                            dec_src_reg   = {1'b1, 3'b111};  // A7 → rd_a
                            dec_reads_src = 1'b1;
                            dec_siz       = 2'b00;
                        end
                    end else if (instr_word == 16'h4E72) begin
                        // STOP #sr: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid     = 1'b1;
                            dec_is_stop   = 1'b1;
                            dec_stop_sr   = ext_data[15:0];  // ext word in low bits (seq format)
                            dec_needs_ext = 1'b1;
                        end
                    end else if (instr_word == 16'h4E76) begin
                        // TRAPV: trap if V flag set — check at decode (CCR stall ensures stable)
                        dec_valid     = 1'b1;
                        dec_reads_ccr = 1'b1;
                        if (flag_v)
                            dec_is_trapv = 1'b1;
                    end else if (instr_word == 16'h4E71) begin
                        // NOP: 0100 1110 0111 0001
                        dec_valid = 1'b1;

                    end else if (instr_word == 16'h4E70) begin
                        // RESET: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid    = 1'b1;
                            dec_is_reset = 1'b1;
                        end

                    end else if (instr_word == 16'h4E7A) begin
                        // MOVEC Rc,Rn: read control register → write to general register
                        // Extension word: [15]=D/A, [14:12]=Rn, [11:0]=Rc
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_MOVE;
                        dec_siz        = 2'b00;   // longword
                        dec_writes_reg = 1'b1;
                        dec_dest_reg   = {ext_data[15], ext_data[14:12]};
                        dec_use_imm    = 1'b1;
                        dec_imm        = ctrl_reg_rd_val;
                        dec_needs_ext  = 1'b1;

                    end else if (instr_word == 16'h4E7B) begin
                        // MOVEC Rn,Rc: supervisor only
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid          = 1'b1;
                            dec_unit           = UNIT_MOVE;
                            dec_siz            = 2'b00;
                            dec_is_movec       = 1'b1;
                            dec_movec_to_ctrl  = 1'b1;
                            dec_src_reg        = {ext_data[15], ext_data[14:12]};
                            dec_reads_src      = 1'b1;
                            dec_needs_ext      = 1'b1;
                        end

                    // ----------------------------------------------------------------
                    // TAS.B (An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(xxx).W/(xxx).L — memory indirect RMW
                    // f_dn=101, f_dir=0, f_ss=11, f_mode=010/011/100/101/110/111(000,001).
                    // (d8,An,Xn) only needs An(rd_a)+Xn(rd_b) — TAS is a unary memory op
                    // (test-and-set the byte itself, no separate data-register operand),
                    // so the 2-port regfile is sufficient (see port3.md §1 Bucket A).
                    // TAS.B Dn (f_mode=000) is decoded inside the f_mode==000/f_ss==11 block above.
                    // N=bit7(original), Z=(original_byte==0), V=0, C=0, X unchanged.
                    // ----------------------------------------------------------------
                    end else if (f_dn == 3'b101 && !f_dir && f_ss == 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)))) begin
                        // TAS.B (An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(xxx).W/(xxx).L — memory indirect RMW
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = 2'b01;    // byte
                        dec_is_mem_rd   = 1'b1;
                        dec_updates_ccr = 1'b0;  // CCR fires via tas_sr_wr path
                        dec_x_unchanged = 1'b1;
                        dec_is_tas      = 1'b1;
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};  // An → rd_a
                            dec_reads_src = 1'b1;
                        end
                        case (f_mode)
                            3'b101: begin  // (d16,An)
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b110: begin  // (d8,An,Xn) brief, or full (bd,An,Xn)
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst = 1'b1;
                                dec_is_idx    = 1'b1;
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                // Full-format, non-indirect (fi_iis==000) reuses
                                // MOVE's own "FULL, no indirection" template --
                                // fi_bd instead of the brief 8-bit signed offset,
                                // no FSM changes needed since the bus access
                                // shape (single read via ex_is_mem_rd, TAS's own
                                // tas_run_r doing the write) is unaffected either
                                // way. Genuine memory-indirect (fi_iis!=000) for
                                // TAS/NBCD-class RMW ops needs tas_run_r itself
                                // taught an extra pointer-read phase ahead of its
                                // existing read+write sequence -- deliberately
                                // not attempted this pass (plan.md Phase 116);
                                // fi_bd is used here regardless of fi_iis as the
                                // least-wrong fallback (matches brief's own
                                // pre-existing behavior of not distinguishing
                                // indirection at all).
                                dec_ea_offset = fi_is_full ? fi_bd
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b111: begin  // (xxx).W / (xxx).L
                                dec_abs_ea_en  = 1'b1;
                                dec_needs_ext  = 1'b1;
                                dec_abs_ea_val = (f_reg == 3'b001) ? ext_data
                                                 : {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            default: ;
                        endcase
                        setup_mem_incdec(2'b01, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);

                    // ----------------------------------------------------------------
                    // MOVEM — register list save/restore
                    // Store (reg→mem): f_dn=100, !f_dir, f_ss[1]=1
                    //   EA: -(An) f_mode=100 or (An) f_mode=010
                    // Load (mem→reg): f_dn=110, !f_dir, f_ss[1]=1
                    //   EA: (An)+ f_mode=011 or (An) f_mode=010
                    // Mask always in ext_data[15:0] (1 extension word).
                    // f_ss[0]: 0=word, 1=longword.
                    // ----------------------------------------------------------------
                    end else if (!f_dir && f_dn == 3'b100 && f_ss == 2'b01 &&
                                 f_mode >= 3'b010) begin
                        // PEA ea: 0100 1000 01 mmm rrr — push effective address to -(A7)
                        // A7 -= 4; M[A7] ← EA (the address, not the contents).
                        // Supported EA modes: (An)=010, (d16,An)=101, (xxx).W/.L/(d16,PC)=111
                        dec_is_pea     = 1'b1;
                        dec_is_mem_wr  = 1'b1;
                        dec_dst_reg    = {1'b1, 3'b111};  // A7 → rd_b (push base)
                        dec_reads_dst  = 1'b1;
                        dec_siz        = 2'b00;
                        dec_ea_offset  = 32'hFFFF_FFFC;   // ex_ea = A7-4 (push address)
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;
                        dec_an_delta   = 32'hFFFF_FFFC;   // A7 -= 4
                        if (f_mode == 3'b010) begin
                            // PEA (An): EA = An
                            dec_valid     = 1'b1;
                            dec_src_reg   = {1'b1, f_reg}; // An → rd_a
                            dec_reads_src = 1'b1;
                        end else if (f_mode == 3'b101) begin
                            // PEA (d16,An): EA = An + d16
                            dec_valid       = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};
                            dec_reads_src   = 1'b1;
                            dec_jump_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_needs_ext   = 1'b1;
                        end else if (f_mode == 3'b110) begin
                            // PEA (d8,An,Xn) brief, or full (bd,An,Xn): EA = An + d + Xn*scale,
                            // push to [A7-4]. rd_a=An (base), rd_b=Xn (index); A7 via ex_cur_sp
                            dec_valid       = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};                   // An → rd_a
                            dec_dst_reg     = {ext_data[15], ext_data[14:12]}; // Xn → rd_b
                            dec_reads_src   = 1'b1;
                            dec_is_idx      = 1'b1;
                            dec_xn_wl       = ext_data[11];
                            dec_xn_scale    = ext_data[10:9];
                            dec_needs_ext   = 1'b1;
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd. 10-item
                            // backlog Stage 9a (plan.md): genuine memory-indirect
                            // (fi_iis!=000) -- PEA still needs a real outer bus cycle
                            // (unlike LEA), but it's a WRITE of the resolved EA to the
                            // stack, not a read at the resolved EA -- see the memind
                            // FSM's own memind_is_pea_r handling in eu_seq_execute.svh.
                            // Deliberately NOT setting dec_is_pea_idx here: ex_ea must
                            // resolve to An+bd(+Xn) for the FSM's own inner-address
                            // capture, not ex_cur_sp-4 (dec_is_pea_idx's usual effect);
                            // the A7 predecrement itself still gets the same ex_cur_sp
                            // treatment via ex_an_new's own (ex_is_pea && ex_is_memind)
                            // arm instead.
                            if (fi_is_full && fi_iis != 3'b000) begin
                                dec_is_mem_wr      = 1'b0;
                                dec_is_memind       = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                            end else begin
                                dec_is_pea_idx  = 1'b1;
                                dec_jump_offset = fi_is_full ? fi_bd
                                                : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                        end else if (f_mode == 3'b111) begin
                            // PEA (xxx).W/.L / (d16,PC): EA = absolute value
                            dec_abs_jmp_en = 1'b1;  // carry absolute EA in abs_ea_val path
                            dec_needs_ext  = 1'b1;
                            case (f_reg)
                                3'b000: begin  // (xxx).W: 1 ext word
                                    dec_valid      = 1'b1;
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b001: begin  // (xxx).L: 2 ext words
                                    dec_valid      = 1'b1;
                                    dec_abs_ea_val = ext_data;
                                end
                                3'b010: begin  // (d16,PC): EA = PC+2+d16
                                    dec_valid      = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b011: begin  // (d8,PC,Xn): EA = PC+2+d8+Xn*scale
                                    // rd_a isn't loaded with A7 here (rd_b holds Xn
                                    // instead), so the A7 push-address/update must go
                                    // through ex_cur_sp like the (d8,An,Xn) case does —
                                    // set dec_is_pea_idx so ex_ea/ex_an_new pick that path.
                                    dec_valid      = 1'b1;
                                    dec_is_pea_idx = 1'b1;
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                    dec_reads_dst  = 1'b1;
                                    dec_is_idx     = 1'b1;
                                    dec_xn_wl      = ext_data[11];
                                    dec_xn_scale   = ext_data[10:9];
                                end
                                default: ;
                            endcase
                        end

                    end else if (instr_word == 16'h4AFC) begin
                        // ILLEGAL: 0100 1010 1111 1100 — always traps
                        dec_valid         = 1'b1;
                        dec_is_illegal    = 1'b1;
                    end else if ((instr_word & 16'hFFF8) == 16'h4848) begin
                        // BKPT #n: 0100 1000 0100 1nnn (Phase 157 Stage 3).
                        // Breakpoint number in bits[2:0] (already f_reg).
                        dec_valid         = 1'b1;
                        dec_is_bkpt       = 1'b1;
                    // ── MOVEM extended EA ─────────────────────────────
                    end else if (!f_dir && f_ss[1] &&
                                 (f_dn == 3'b100 || f_dn == 3'b110)) begin
                        // MOVEM common setup
                        dec_is_movem   = 1'b1;
                        dec_movem_load = (f_dn == 3'b110);
                        dec_movem_long = f_ss[0];
                        dec_siz        = 2'b00;
                        dec_needs_ext  = 1'b1;
                        // Standard 1-ext-word modes: -(An), (An), (An)+
                        if ((f_dn == 3'b100 && (f_mode == 3'b100 || f_mode == 3'b010)) ||
                            (f_dn == 3'b110 && (f_mode == 3'b011 || f_mode == 3'b010))) begin
                            dec_valid         = 1'b1;
                            dec_movem_predec  = (f_dn == 3'b100) && (f_mode == 3'b100);
                            dec_movem_postinc = (f_dn == 3'b110) && (f_mode == 3'b011);
                            dec_dst_reg       = {1'b1, f_reg};  // An → rd_b
                            dec_reads_dst     = 1'b1;
                        // (d16,An): 2 ext words — mask=[31:16], d16=[15:0]
                        end else if (f_mode == 3'b101) begin
                            dec_valid         = 1'b1;
                            dec_movem_mask_hi = 1'b1;
                            dec_src_reg       = {1'b1, f_reg};  // An → rd_a for ex_ea
                            dec_reads_src     = 1'b1;
                            dec_ea_offset     = {{16{ext_data[15]}}, ext_data[15:0]};
                        // (d8,An,Xn) brief, or full (bd,An,Xn): 2(+1/+2) ext words —
                        // mask=[31:16], descriptor=[15:0], word bd (full-format)
                        // in q3_word, long bd's low half in ext34_data[15:0]=q4
                        // (mask already occupies the [31:16] slot a single-EA
                        // family's own bd would use, so MOVEM's own bd needs a
                        // third/fourth fetched word instead -- see
                        // is_movem_idx_full/movem_ext_count in m68030_seq.sv,
                        // which already sizes movem_ext_count correctly for
                        // long bd; only this value extraction was missing,
                        // fixed Phase 138 -- see plan.md).
                        // Genuine memory-indirect (fi_iis!=000) is still NOT
                        // decoded correctly here -- same "least-wrong fallback
                        // to brief" boundary every other family in this rollout
                        // draws around memory-indirect; worst case (mask+
                        // descriptor+long-bd+long-od) needs 6 ext words, beyond
                        // what the IFU can drain today (plan.md Phase 138 §8).
                        end else if (f_mode == 3'b110) begin
                            dec_valid         = 1'b1;
                            dec_movem_mask_hi = 1'b1;
                            dec_src_reg       = {1'b1, f_reg};  // An → rd_a for ex_ea
                            dec_reads_src     = 1'b1;
                            dec_dst_reg       = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_dst     = 1'b1;
                            dec_is_idx        = 1'b1;
                            dec_xn_wl         = ext_data[11];
                            dec_xn_scale      = ext_data[10:9];
                            dec_ea_offset     = (fi_is_full && fi_bdsz == 2'b10 && fi_iis == 3'b000)
                                              ? {{16{q3_word[15]}}, q3_word}
                                              : (fi_is_full && fi_bdsz == 2'b11 && fi_iis == 3'b000)
                                              ? {q3_word, ext34_data[15:0]}
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                        end else if (f_mode == 3'b111) begin
                            case (f_reg)
                                3'b000: begin  // (xxx).W: 2 ext words — mask=[31:16], abs16=[15:0]
                                    dec_valid         = 1'b1;
                                    dec_movem_mask_hi = 1'b1;
                                    dec_abs_ea_en     = 1'b1;
                                    dec_abs_ea_val    = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b001: begin  // (xxx).L: 3 ext words — mask=[31:16], abs_h=[15:0], abs_l=q3_word
                                    dec_valid         = 1'b1;
                                    dec_movem_mask_hi = 1'b1;
                                    dec_abs_ea_en     = 1'b1;
                                    dec_abs_ea_val    = {ext_data[15:0], q3_word};
                                end
                                3'b010: begin  // (d16,PC) load: mask=[31:16], d16=[15:0]
                                    if (f_dn == 3'b110) begin
                                        dec_valid         = 1'b1;
                                        dec_movem_mask_hi = 1'b1;
                                        dec_abs_ea_en     = 1'b1;
                                        dec_abs_ea_val    = decode_pc + 32'd4
                                                          + {{16{ext_data[15]}}, ext_data[15:0]};
                                    end
                                end
                                3'b011: begin  // (d8,PC,Xn) load: mask=[31:16], brief=[15:0]
                                    if (f_dn == 3'b110) begin
                                        dec_valid         = 1'b1;
                                        dec_movem_mask_hi = 1'b1;
                                        dec_abs_ea_en     = 1'b1;
                                        dec_abs_ea_val    = decode_pc + 32'd4
                                                          + {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                        dec_reads_dst     = 1'b1;
                                        dec_is_idx        = 1'b1;
                                        dec_xn_wl         = ext_data[11];
                                        dec_xn_scale      = ext_data[10:9];
                                    end
                                end
                                default: ;
                            endcase
                        end
                    // ── MULU.L/MULS.L/DIVU.L/DIVS.L memory-EA forms ──
                    // (open-items backlog Stage 7, plan.md): the
                    // register-direct form above (f_mode==000, f_dn==110,
                    // in the case(f_dn) block) only ever set
                    // dec_is_muldivl for a Dn source -- the <ea>,Dl
                    // memory-source forms were entirely undecoded.  Same
                    // instruction family/signature (f_dn==110, f_ss ∈
                    // {00=MUL,01=DIV}), disjoint from both the
                    // register-direct case (claims f_mode==000 only,
                    // handled above) and MOVEM's own f_dn==110 sibling
                    // (requires f_ss[1]=1, always 0 here) -- confirmed via
                    // a full-file grep for every f_dn==3'b110 site before
                    // writing this, no other decode claims this space.
                    //
                    // The muldivl descriptor word (Dl/Dq/Dh/Dr/sign/size)
                    // is always the FIRST extension word regardless of EA
                    // mode (fixed position right after the opcode, same
                    // as CMP2/CHK2's own "other data" word, Phase
                    // 119/120); the EA's own extension word(s), if any,
                    // follow it. For the register-indirect forms
                    // ((An)/(An)+/-(An)) that need no EA extension word at
                    // all, ext_count stays at 1 and the descriptor lives
                    // in ext_data[15:0] -- identical to the register-direct
                    // form's own extraction. For (d16,An)/abs.W/abs.L/
                    // (d16,PC), ext_count>=2 and m68030_seq.sv's
                    // eu_ext_data formula (unswapped, ext_count>=2 case)
                    // puts q1 (the descriptor) in the HIGH half
                    // ext_data[31:16] and q2 (the EA's own word) in the
                    // LOW half ext_data[15:0] -- same layout MOVEM's own
                    // 2-ext-word forms already use just above.
                    //
                    // Deliberately deferred to a later pass: the indexed
                    // (d8,An,Xn)/(d8,PC,Xn) forms (would need the
                    // dyn_bit_get_Dn 3rd-operand-deferred-register trick
                    // for the Xn-vs-Dl/Dq register-port conflict, same
                    // shape as CHK's own indexed form, Phase 84) and the
                    // #imm form (would need a 2nd 32-bit immediate word on
                    // top of the descriptor, genuinely 3 ext words) — see
                    // plan.md for the full writeup.
                    end else if ((f_dn == 3'b110) && !f_dir &&
                                 (f_ss == 2'b00 || f_ss == 2'b01) &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 ||
                                  f_mode == 3'b100)) begin
                        // (An)/(An)+/-(An) — ext_count=1, descriptor in
                        // ext_data[15:0] (same half the register-direct
                        // form above reads).
                        dec_needs_ext   = 1'b1;
                        dec_siz         = 2'b00;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_dst_reg     = {1'b0, ext_data[2:0]};   // Dl/Dq → rd_b
                        dec_dest_reg    = {1'b0, ext_data[2:0]};
                        dec_md_dst2     = ext_data[14:12];          // Dh/Dr
                        dec_reads_dst   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_is_muldivl  = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};            // An → rd_a
                        dec_reads_src   = 1'b1;
                        setup_mem_incdec(2'b00, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        if (f_ss == 2'b00) begin
                            dec_valid    = 1'b1;
                            dec_unit     = UNIT_MUL;
                            dec_md_op    = ext_data[11] ? MUL_SL : MUL_UL;
                            dec_md_64bit = ext_data[10];
                        end else begin
                            dec_valid    = 1'b1;
                            dec_unit     = UNIT_DIV;
                            dec_md_op    = ext_data[11] ? DIV_SL : DIV_UL;
                            dec_md_64bit = (ext_data[14:12] != ext_data[2:0]);
                        end
                    end else if ((f_dn == 3'b110) && !f_dir &&
                                 (f_ss == 2'b00 || f_ss == 2'b01) &&
                                 (f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                                        f_reg == 3'b001 ||
                                                        f_reg == 3'b010)))) begin
                        // (d16,An)/abs.W/abs.L/(d16,PC) — ext_count>=2,
                        // descriptor in ext_data[31:16] (HIGH half; q2 in
                        // ext_data[15:0], abs.L's own q3 in q3_word).
                        dec_needs_ext   = 1'b1;
                        dec_siz         = 2'b00;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_dst_reg     = {1'b0, ext_data[18:16]};  // Dl/Dq → rd_b
                        dec_dest_reg    = {1'b0, ext_data[18:16]};
                        dec_md_dst2     = ext_data[30:28];           // Dh/Dr
                        dec_reads_dst   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_is_muldivl  = 1'b1;
                        if (f_ss == 2'b00) begin
                            dec_valid    = 1'b1;
                            dec_unit     = UNIT_MUL;
                            dec_md_op    = ext_data[27] ? MUL_SL : MUL_UL;
                            dec_md_64bit = ext_data[26];
                        end else begin
                            dec_valid    = 1'b1;
                            dec_unit     = UNIT_DIV;
                            dec_md_op    = ext_data[27] ? DIV_SL : DIV_UL;
                            dec_md_64bit = (ext_data[30:28] != ext_data[18:16]);
                        end
                        if (f_mode == 3'b101) begin
                            dec_src_reg   = {1'b1, f_reg};          // An → rd_a
                            dec_reads_src = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else if (f_mode == 3'b111 && f_reg == 3'b000) begin
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else if (f_mode == 3'b111 && f_reg == 3'b001) begin
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = {ext_data[15:0], q3_word};
                        end else if (f_mode == 3'b111 && f_reg == 3'b010) begin
                            dec_abs_ea_en  = 1'b1;
                            dec_abs_ea_val = decode_pc + 32'd4
                                           + {{16{ext_data[15]}}, ext_data[15:0]};
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 0101: ADDQ / SUBQ / Scc / DBcc
                // ----------------------------------------------------------------
                4'h5: begin
                    if (f_ss == 2'b11) begin
                        dec_reads_ccr = 1'b1;
                        if (f_mode == 3'b001) begin
                            // DBcc Dn, d16: 0101 cccc 1100 1 rrr | disp16
                            dec_valid          = 1'b1;
                            dec_is_dbcc        = 1'b1;
                            dec_needs_ext      = 1'b1;
                            dec_branch_cond    = f_cond;
                            dec_branch_disp    = {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_dst_reg        = {1'b0, f_reg};
                            dec_dest_reg       = {1'b0, f_reg};
                            dec_reads_dst      = 1'b1;
                            dec_unit           = UNIT_ALU;
                            dec_alu_op         = ALU_SUB;
                            dec_siz            = 2'b10;   // word counter
                            dec_use_imm        = 1'b1;
                            dec_imm            = 32'h1;
                            dec_writes_reg     = 1'b1;
                            dec_x_unchanged    = 1'b1;
                        end else if (f_mode == 3'b000) begin
                            // Scc Dn: byte ← 0xFF if condition true, 0x00 false
                            dec_valid          = 1'b1;
                            dec_unit           = UNIT_MOVE;
                            dec_dest_reg       = {1'b0, f_reg};
                            dec_siz            = 2'b01;
                            dec_writes_reg     = 1'b1;
                            dec_x_unchanged    = 1'b1;
                            dec_use_imm        = 1'b1;
                            dec_imm            = eval_cc(f_cond, flag_n, flag_z, flag_v, flag_c) ? 32'hFF : 32'h00;
                            dec_is_scc_dn      = 1'b1;
                        // ── Scc to memory ea ───────────────────────
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101 || f_mode == 3'b110 ||
                                     (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001))) begin
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_MOVE;
                            dec_siz         = 2'b01;
                            dec_x_unchanged = 1'b1;
                            dec_use_imm     = 1'b1;
                            dec_imm         = eval_cc(f_cond, flag_n, flag_z, flag_v, flag_c) ? 32'hFF : 32'h00;
                            dec_is_mem_rd   = 1'b1;
                            dec_is_mem_rmw  = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};
                            dec_reads_src   = 1'b1;
                            case (f_mode)
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(2'b01, f_reg == 3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(2'b01, f_reg == 3'b111) + 32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin  // (d16,An): 1 ext word
                                    dec_needs_ext  = 1'b1;
                                    dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b110: begin  // (d8,An,Xn)/(bd,An,Xn): 1+ ext word
                                    dec_needs_ext  = 1'b1;
                                    dec_dst_reg    = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                                    dec_reads_dst  = 1'b1;
                                    dec_is_idx     = 1'b1;
                                    dec_xn_wl      = ext_data[11];
                                    dec_xn_scale   = ext_data[10:9];
                                    // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                                    dec_ea_offset  = fi_is_full ? fi_bd
                                                   : {{24{ext_data[7]}}, ext_data[7:0]};
                                end
                                3'b111: begin
                                    dec_needs_ext  = 1'b1;
                                    dec_abs_ea_en  = 1'b1;
                                    if (f_reg == 3'b000)  // (xxx).W: 1 ext word, sign-extended
                                        dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    else                   // (xxx).L: 2 ext words
                                        dec_abs_ea_val = ext_data;
                                end
                                default: ;
                            endcase
                        // ── TRAPcc ─────────────────────────────────────────
                        // f_reg: 100=no operand, 010=word operand (TRAPcc.W), 011=long
                        // operand (TRAPcc.L). f_reg=000/001 belong to Scc's own
                        // abs.W/abs.L addressing modes (handled above), not TRAPcc.
                        end else if (f_mode == 3'b111 &&
                                     (f_reg == 3'b100 || f_reg == 3'b010 || f_reg == 3'b011)) begin
                            dec_valid       = 1'b1;
                            dec_x_unchanged = 1'b1;
                            if (f_reg == 3'b010 || f_reg == 3'b011) dec_needs_ext = 1'b1;
                            if (eval_cc(f_cond, flag_n, flag_z, flag_v, flag_c))
                                dec_is_trapv = 1'b1;
                        end
                    // ── ADDQ/SUBQ to memory ea ─────────────────────
                    end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                 f_mode == 3'b101 || f_mode == 3'b110 ||
                                 (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001))) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = f_dir ? ALU_SUB : ALU_ADD;
                        dec_siz         = f_siz;
                        dec_use_imm     = 1'b1;
                        dec_imm         = f_addq_imm;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                        end
                        case (f_mode)
                            3'b011: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(f_siz, f_reg == 3'b111);
                            end
                            3'b100: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(f_siz, f_reg == 3'b111) + 32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            3'b101: begin
                                dec_needs_ext  = 1'b1;
                                dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            3'b110: begin  // (d8,An,Xn)/(bd,An,Xn)
                                dec_needs_ext  = 1'b1;
                                dec_dst_reg    = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst  = 1'b1;
                                dec_is_idx     = 1'b1;
                                dec_xn_wl      = ext_data[11];
                                dec_xn_scale   = ext_data[10:9];
                                // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                                dec_ea_offset  = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                            3'b111: begin
                                dec_needs_ext  = 1'b1;
                                dec_abs_ea_en  = 1'b1;
                                if (f_reg == 3'b000)
                                    dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                else
                                    dec_abs_ea_val = ext_data;
                            end
                            default: ;
                        endcase
                    end else if (f_mode == 3'b000) begin
                        // ADDQ / SUBQ #imm3, Dn — CCR updated
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = f_dir ? ALU_SUB : ALU_ADD;
                        dec_siz         = f_siz;
                        dec_dst_reg     = {1'b0, f_reg};
                        dec_dest_reg    = {1'b0, f_reg};
                        dec_reads_dst   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_use_imm     = 1'b1;
                        dec_imm         = f_addq_imm;
                    end else if (f_mode == 3'b001) begin
                        // ADDQ / SUBQ #imm3, An — CCR unchanged (address register)
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = f_dir ? ALU_SUB : ALU_ADD;
                        dec_siz         = 2'b00;    // 32-bit An operation
                        dec_dst_reg     = {1'b1, f_reg};
                        dec_dest_reg    = {1'b1, f_reg};
                        dec_reads_dst   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_use_imm     = 1'b1;
                        dec_imm         = f_addq_imm;
                    end
                end

                // ----------------------------------------------------------------
                // Group 0110: BRA / Bcc / BSR (f_cond=0001)
                // ----------------------------------------------------------------
                4'h6: begin
                    if (f_cond == 4'h1) begin
                        // BSR: push return PC to -(A7), then branch
                        dec_valid       = 1'b1;
                        dec_is_bsr      = 1'b1;
                        dec_is_mem_wr   = 1'b1;
                        dec_dst_reg     = {1'b1, 3'b111};  // A7 → rd_b
                        dec_reads_dst   = 1'b1;
                        dec_siz         = 2'b00;
                        dec_ea_offset   = 32'hFFFF_FFFC;   // -4
                        dec_an_upd_en   = 1'b1;
                        dec_an_upd_reg  = 3'b111;
                        dec_an_delta    = 32'hFFFF_FFFC;   // -4
                        if (f_disp8 == 8'h00) begin
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = {{16{ext_data[15]}}, ext_data[15:0]};
                            dec_return_pc   = decode_pc + 32'd4;
                        end else if (f_disp8 == 8'hFF) begin
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = ext_data;
                            dec_return_pc   = decode_pc + 32'd6;
                        end else begin
                            dec_branch_disp = {{24{f_disp8[7]}}, f_disp8};
                            dec_return_pc   = decode_pc + 32'd2;
                        end
                        dec_bsr_target = decode_pc + 32'd2 + dec_branch_disp;
                    end else begin
                        // BRA / Bcc
                        dec_valid          = 1'b1;
                        dec_is_branch      = 1'b1;
                        dec_reads_ccr      = 1'b1;
                        dec_branch_cond    = f_cond;
                        if (f_disp8 == 8'h00) begin
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else if (f_disp8 == 8'hFF) begin
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = ext_data;
                        end else begin
                            dec_branch_disp = {{24{f_disp8[7]}}, f_disp8};
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 0111: MOVEQ #d8, Dn
                // ----------------------------------------------------------------
                4'h7: begin
                    if (!f_dir) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_siz         = 2'b00;   // longword
                        dec_use_imm     = 1'b1;
                        dec_imm         = {{24{f_disp8[7]}}, f_disp8};
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                    end
                end

                // ----------------------------------------------------------------
                // Group 1000: OR / DIVU.W / DIVS.W
                // ----------------------------------------------------------------
                4'h8: begin
                    if (f_mode == 3'b000) begin
                        if (f_ss == 2'b11) begin
                            // DIVU.W (f_dir=0) or DIVS.W (f_dir=1)
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_DIV;
                            dec_src_reg     = {1'b0, f_reg};
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_siz         = 2'b00;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_md_op       = f_dir ? DIV_SW : DIV_UW;
                        end else if (f_dir && f_ss == 2'b00 && f_mode == 3'b000) begin
                            // SBCD: 1000 ddd1 0000 0sss (f_dir=1, f_ss=00=byte, f_mode=000)
                            // dst = f_dn, src = f_reg
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_BCD;
                            dec_bcd_op      = BCD_SUB;
                            dec_siz         = 2'b01;   // byte
                            dec_src_reg     = {1'b0, f_reg};
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                        end else if (f_dir && f_ss == 2'b01) begin
                            // PACK Dy,Dx,#adj: 1000 Dx 1 01 000 Dy | adj16
                            // temp = Dy[15:0] + adj; result = {temp[11:8], temp[3:0]}
                            dec_valid      = 1'b1;
                            dec_is_pack    = 1'b1;
                            dec_src_reg    = {1'b0, f_reg};  // Dy → rd_a
                            dec_dest_reg   = {1'b0, f_dn};   // Dx = destination
                            dec_reads_src  = 1'b1;
                            dec_writes_reg = 1'b1;
                            dec_siz        = 2'b00;   // long read so rd_a_data[15:0] is valid; result zero-extends
                            dec_needs_ext  = 1'b1;    // adj16 in extension word
                        end else if (f_dir && f_ss == 2'b10) begin
                            // UNPK Dy,Dx,#adj: 1000 Dx 1 10 000 Dy | adj16
                            // temp = {0,Dy[7:4],0,Dy[3:0]} + adj; result = temp[15:0]
                            dec_valid      = 1'b1;
                            dec_is_unpk    = 1'b1;
                            dec_src_reg    = {1'b0, f_reg};  // Dy → rd_a
                            dec_dest_reg   = {1'b0, f_dn};   // Dx = destination
                            dec_reads_src  = 1'b1;
                            dec_writes_reg = 1'b1;
                            dec_siz        = 2'b10;   // word result written to Dx
                            dec_needs_ext  = 1'b1;    // adj16 in extension word
                        end else begin
                            // OR.ss Dn,ea (f_dir=1) or ea,Dn (f_dir=0)
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_ALU;
                            dec_alu_op      = ALU_OR;
                            dec_siz         = f_siz;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            if (!f_dir) begin
                                dec_src_reg  = {1'b0, f_reg};
                                dec_dst_reg  = {1'b0, f_dn};
                                dec_dest_reg = {1'b0, f_dn};
                            end else begin
                                dec_src_reg  = {1'b0, f_dn};
                                dec_dst_reg  = {1'b0, f_reg};
                                dec_dest_reg = {1'b0, f_reg};
                            end
                        end
                    // ── OR Dn, (An)/(An)+/-(An)/(d16,An) ─────────────
                    end else if (f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101)) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_OR;
                        dec_siz         = f_siz;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // An → rd_a (EA base)
                        dec_dst_reg     = {1'b0, f_dn};   // Dn → rd_b (ALU src via redirect)
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        if (f_mode == 3'b101) begin
                            dec_needs_ext = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        end
                    // ── SBCD -(Ay),-(Ax): 1000 Ax 1 00 001 Ay
                    end else if (f_dir && f_ss == 2'b00 && f_mode == 3'b001) begin
                        dec_valid            = 1'b1;
                        dec_unit             = UNIT_BCD;
                        dec_bcd_op           = BCD_SUB;
                        dec_siz              = 2'b01;
                        dec_is_abcd_sbcd_mem = 1'b1;
                        dec_is_abcd_mem      = 1'b0;
                        dec_updates_ccr      = 1'b1;
                        dec_src_reg          = {1'b1, f_reg};
                        dec_dst_reg          = {1'b1, f_dn};
                        dec_reads_src        = 1'b1;
                        dec_reads_dst        = 1'b1;
                    // ── PACK/UNPK -(Ay),-(Ax),#adj — memory form ───────────
                    end else if (f_dir && (f_ss == 2'b01 || f_ss == 2'b10) && f_mode == 3'b001) begin
                        // PACK: 1000 Ax 1 01 001 Ay | adj16  →  predec Ay by 2 (word), predec Ax by 1 (byte)
                        // UNPK: 1000 Ax 1 10 001 Ay | adj16  →  predec Ay by 1 (byte), predec Ax by 2 (word)
                        dec_valid       = 1'b1;
                        dec_is_pack     = (f_ss == 2'b01);
                        dec_is_unpk     = (f_ss == 2'b10);
                        dec_is_pack_mem = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // Ay → rd_a
                        dec_dst_reg     = {1'b1, f_dn};   // Ax → rd_b
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_needs_ext   = 1'b1;           // adj16 in extension word
                    // ── OR Dn, (d8,An,Xn) — indexed memory destination ──
                    end else if (f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_OR;
                        dec_siz            = f_siz;
                        dec_is_mem_rd      = 1'b1;
                        dec_is_mem_rmw     = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                    // ── OR Dn, (xxx).W/(xxx).L — absolute memory destination ──
                    end else if (f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)) begin
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = ALU_OR;
                        dec_siz        = f_siz;
                        dec_is_mem_rd  = 1'b1;
                        dec_is_mem_rmw = 1'b1;
                        dec_needs_ext  = 1'b1;
                        dec_dst_reg    = {1'b0, f_dn};
                        dec_reads_dst  = 1'b1;
                        dec_abs_ea_en  = 1'b1;
                        if (f_reg == 3'b000)
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                        else
                            dec_abs_ea_val = ext_data;
                    // ── OR (An)/(An)+/-(An), Dn — memory source → register dest ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_OR;
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── OR (d8,An,Xn), Dn — indexed memory source ──────
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_OR;
                        dec_siz            = f_siz;
                        dec_writes_reg     = 1'b1;
                        dec_updates_ccr    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): same shape as
                        // DIVU/DIVS's own memind arm -- see its comment for the full
                        // reasoning. dec_siz IS this OR's own real read size (unlike
                        // MULU/MULS/DIVU/DIVS), so dec_memind_rd_siz mirrors dec_siz.
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── OR #imm, Dn — immediate source (group 8 encoding) ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_OR;
                        dec_siz         = f_siz;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_dest_reg    = {1'b0, f_dn};
                    // ── DIVU/DIVS (An)/(An)+/-(An), Dn — memory source ──
                    // Same gap as MULS/MULU: the OR-memory-source blocks above
                    // explicitly exclude f_ss==11 (DIV's own signature, since
                    // DIV doesn't use f_ss for operand size — always 16-bit),
                    // so these EA modes were never decoded for DIV at all.
                    end else if (f_ss == 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_DIV;
                        dec_siz         = 2'b00;
                        dec_mem_rd_siz  = 2'b10;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        dec_md_op       = f_dir ? DIV_SW : DIV_UW;
                        setup_mem_incdec(2'b10, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── DIVU/DIVS (d8,An,Xn), Dn — indexed memory source ──
                    end else if (f_ss == 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_DIV;
                        dec_siz            = 2'b00;
                        dec_mem_rd_siz     = 2'b10;
                        dec_writes_reg     = 1'b1;
                        dec_updates_ccr    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        dec_md_op          = f_dir ? DIV_SW : DIV_UW;
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): fi_iis!=0 dispatches
                        // through the shared memind FSM instead -- dec_is_mem_rd is
                        // suppressed (matching MOVE's own memind arm) since the FSM
                        // owns the bus cycles directly; dec_writes_reg/dec_is_mem_src
                        // stay set (UNLIKE MOVE/LEA) so the genuine ALU(mem,Dn) result
                        // still commits through the ordinary WB path once
                        // dyn_bit_get_Dn's own new memind-outer-completion term swaps
                        // rd_b to Dn (see eu_seq_execute.svh) -- memind's own raw-value
                        // wr_en path (memind_wr_en) is gated off whenever
                        // ex_writes_reg is already true, so the two mechanisms can't
                        // collide. dec_memind_rd_siz mirrors dec_mem_rd_siz (word),
                        // NOT dec_siz (longword, the 32-bit quotient's own result
                        // size) -- see dec_memind_rd_siz's own declaration comment.
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_mem_rd_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── DIVU/DIVS #imm, Dn — immediate source ───────────
                    end else if (f_ss == 2'b11 && f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_DIV;
                        dec_siz         = 2'b00;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_md_op       = f_dir ? DIV_SW : DIV_UW;
                    // ── OR/DIVU/DIVS (ea),Dn — memory source ────────────
                    end else if ((f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                                        f_reg == 3'b001 ||
                                                        f_reg == 3'b010 ||
                                                        f_reg == 3'b011)))) begin
                        if (f_ss == 2'b11) begin
                            // DIVU.W (f_dir=0) or DIVS.W (f_dir=1) from memory EA
                            dec_valid       = 1'b1;
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_DIV;
                            dec_siz         = 2'b00;   // 32-bit result write; MUL/DIV uses src[15:0]
                            dec_mem_rd_siz  = 2'b10;   // but the bus read itself must stay word-sized
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_reads_dst   = 1'b1;
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_md_op       = f_dir ? DIV_SW : DIV_UW;
                        end else if (!f_dir) begin
                            // OR (ea),Dn
                            dec_valid       = 1'b1;
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_ALU;
                            dec_alu_op      = ALU_OR;
                            dec_siz         = f_siz;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_reads_dst   = 1'b1;
                            dec_dest_reg    = {1'b0, f_dn};
                        end
                        if (dec_valid) begin
                            dec_needs_ext = 1'b1;
                            if (f_mode == 3'b101) begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin
                                dec_abs_ea_en = 1'b1;
                                case (f_reg)
                                    3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    3'b001: dec_abs_ea_val = ext_data;
                                    3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                           + {{16{ext_data[15]}}, ext_data[15:0]};
                                    3'b011: begin  // (d8,PC,Xn)
                                        dec_abs_ea_val    = decode_pc + 32'd2
                                                          + {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                        dec_is_idx        = 1'b1;
                                        dec_xn_wl         = ext_data[11];
                                        dec_xn_scale      = ext_data[10:9];
                                        dec_is_dyn_bit_idx = 1'b1;
                                        dec_dyn_bit_reg   = f_dn;
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 1001/1101: SUB/ADD / SUBA/ADDA
                // ----------------------------------------------------------------
                4'h9, 4'hd: begin
                    if (f_mode == 3'b000 && f_ss != 2'b11) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        if (!f_dir) begin
                            // SUB Dm,Dn: Dn ← Dn − Dm
                            dec_src_reg  = {1'b0, f_reg};
                            dec_dst_reg  = {1'b0, f_dn};
                            dec_dest_reg = {1'b0, f_dn};
                        end else begin
                            // SUBX Dy,Dx: Dx ← Dx − Dy − X (register form)
                            dec_alu_op   = grp_xop(f_group);
                            dec_src_reg  = {1'b0, f_reg};  // Dy
                            dec_dst_reg  = {1'b0, f_dn};   // Dx
                            dec_dest_reg = {1'b0, f_dn};
                        end
                    // ── SUBX -(Ay),-(Ax) ───────────────────────────────
                    end else if (f_dir && f_ss != 2'b11 && f_mode == 3'b001) begin
                        dec_valid       = 1'b1;
                        dec_is_addx_mem = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_xop(f_group);
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // Ay → rd_a
                        dec_dst_reg     = {1'b1, f_dn};   // Ax → rd_b
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                    // ── SUB An,Dn — address register source ───────────────────────
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b001) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // An → rd_a
                        dec_dst_reg     = {1'b0, f_dn};   // Dn → rd_b
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                    // ── SUB Dn, (An)/(An)+/-(An)/(d16,An) ─────────────
                    end else if (f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101)) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        if (f_mode == 3'b101) begin
                            dec_needs_ext  = 1'b1;
                            dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        end
                    // ── SUB Dn, (d8,An,Xn) — indexed memory destination ──
                    end else if (f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = grp_aop(f_group);
                        dec_siz            = f_siz;
                        dec_is_mem_rd      = 1'b1;
                        dec_is_mem_rmw     = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                    // ── SUB Dn, (xxx).W/(xxx).L — absolute memory destination ──
                    end else if (f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)) begin
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = grp_aop(f_group);
                        dec_siz        = f_siz;
                        dec_is_mem_rd  = 1'b1;
                        dec_is_mem_rmw = 1'b1;
                        dec_needs_ext  = 1'b1;
                        dec_dst_reg    = {1'b0, f_dn};
                        dec_reads_dst  = 1'b1;
                        dec_abs_ea_en  = 1'b1;
                        if (f_reg == 3'b000)
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                        else
                            dec_abs_ea_val = ext_data;
                    // ── SUB (An)/(An)+/-(An), Dn — memory source → register dest ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── SUB (d8,An,Xn),Dn — indexed memory source ──────
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = grp_aop(f_group);
                        dec_siz            = f_siz;
                        dec_writes_reg     = 1'b1;
                        dec_updates_ccr    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): same shape as
                        // OR's own memind arm above -- see its comment for the full
                        // reasoning. Covers both SUB and ADD via grp_aop(f_group).
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── SUB (ea),Dn — memory source → register dest ────
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                                        f_reg == 3'b001 ||
                                                        f_reg == 3'b010 ||
                                                        f_reg == 3'b011)))) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_needs_ext   = 1'b1;
                        if (f_mode == 3'b101) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            dec_abs_ea_en = 1'b1;
                            case (f_reg)
                                3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b001: dec_abs_ea_val = ext_data;
                                3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b011: begin  // (d8,PC,Xn): EA = PC+2+d8 + scaled(Xn)
                                    dec_abs_ea_val    = decode_pc + 32'd2
                                                      + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                    dec_is_idx        = 1'b1;
                                    dec_xn_wl         = ext_data[11];
                                    dec_xn_scale      = ext_data[10:9];
                                    dec_is_dyn_bit_idx = 1'b1;
                                    dec_dyn_bit_reg   = f_dn;
                                end
                                default: ;
                            endcase
                        end
                    // ── ADD/SUB #imm, Dn — immediate source, register destination ──
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = grp_aop(f_group);
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                    end else if (f_ss == 2'b11) begin
                        // SUBA/ADDA .W (f_dir=0) / .L (f_dir=1): An ← An ± src; CCR unchanged
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = grp_aop(f_group);
                        dec_siz        = 2'b00;
                        dec_dst_reg    = {1'b1, f_dn};
                        dec_dest_reg   = {1'b1, f_dn};
                        dec_reads_dst  = 1'b1;
                        dec_writes_reg = 1'b1;
                        if (f_mode == 3'b000) begin
                            dec_reads_src = 1'b1;
                            dec_src_reg   = {1'b0, f_reg};
                            dec_sext_src  = !f_dir;
                        end else if (f_mode == 3'b001) begin
                            dec_reads_src = 1'b1;
                            dec_src_reg   = {1'b1, f_reg};
                            dec_sext_src  = !f_dir;
                        end else if (f_mode == 3'b111 && f_reg == 3'b100) begin
                            dec_use_imm   = 1'b1;
                            dec_needs_ext = 1'b1;
                            dec_imm       = f_dir ? ext_data[31:0]
                                                  : {{16{ext_data[15]}}, ext_data[15:0]};
                        // ── ADDA/SUBA (d8,An,Xn), An_dst — indexed memory source ──
                        end else if (f_mode == 3'b110) begin
                            dec_is_mem_src     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_sext_src       = !f_dir;
                            dec_mem_rd_siz     = f_dir ? 2'b00 : 2'b10;
                            dec_needs_ext      = 1'b1;
                            dec_src_reg        = {1'b1, f_reg};
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                            dec_reads_src      = 1'b1;
                            dec_reads_dst      = 1'b1;
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;  // An_dst (addr reg) read after mem_ack
                            dec_dyn_bit_is_an  = 1'b1;
                            // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                            // same template as Stage 1 -- see TAS's own comment in the
                            // mode=110 unary-op family for the full reasoning. General
                            // ALU-EA genuine indirect stage (plan.md): same shape as
                            // CMPA's own memind arm -- see its comment.
                            if (fi_is_full && fi_iis != 3'b000) begin
                                dec_is_mem_rd      = 1'b0;
                                dec_is_memind      = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                                dec_memind_rd_siz  = dec_mem_rd_siz;
                            end else begin
                                dec_ea_offset      = fi_is_full ? fi_bd
                                                   : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                        // ── ADDA/SUBA (d8,PC,Xn): PC-indexed memory source ──
                        end else if (f_mode == 3'b111 && f_reg == 3'b011) begin
                            dec_is_mem_src     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_sext_src       = !f_dir;
                            dec_mem_rd_siz     = f_dir ? 2'b00 : 2'b10;
                            dec_needs_ext      = 1'b1;
                            dec_abs_ea_en      = 1'b1;
                            dec_abs_ea_val     = decode_pc + 32'd2 + {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                            dec_reads_dst      = 1'b1;
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;
                            dec_dyn_bit_is_an  = 1'b1;
                        // ── SUBA/ADDA .W/L from memory EA ─────────────
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101 ||
                                     (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                           f_reg == 3'b010))) begin
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_sext_src    = !f_dir;
                            dec_mem_rd_siz  = f_dir ? 2'b00 : 2'b10;
                            if (f_mode != 3'b111) begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                            end
                            case (f_mode)
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(f_dir ? 2'b00 : 2'b10, f_reg == 3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(f_dir ? 2'b00 : 2'b10, f_reg == 3'b111) + 32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin
                                    dec_needs_ext  = 1'b1;
                                    dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b111: begin
                                    dec_needs_ext  = 1'b1;
                                    dec_abs_ea_en  = 1'b1;
                                    case (f_reg)
                                        3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                        3'b001: dec_abs_ea_val = ext_data;
                                        3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                               + {{16{ext_data[15]}}, ext_data[15:0]};
                                        default: ;
                                    endcase
                                end
                                default: ;
                            endcase
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 1011: CMP (f_dir=0) / EOR (f_dir=1) / CMPA (f_ss=11)
                // ----------------------------------------------------------------
                4'hb: begin
                    if (f_mode == 3'b000 && f_ss != 2'b11) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        if (!f_dir) begin
                            dec_alu_op      = ALU_CMP;
                            dec_x_unchanged = 1'b1;
                            dec_src_reg     = {1'b0, f_reg};
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_dest_reg    = {1'b0, f_dn};
                        end else begin
                            dec_alu_op      = ALU_EOR;
                            dec_writes_reg  = 1'b1;
                            dec_src_reg     = {1'b0, f_dn};
                            dec_dst_reg     = {1'b0, f_reg};
                            dec_dest_reg    = {1'b0, f_reg};
                        end
                    end else if (f_dir && f_mode == 3'b001 && f_ss != 2'b11) begin
                        // CMPM (Ay)+,(Ax)+: 1011 Ax 1 ss 001 Ay  (f_ss≠11; f_ss=11 is CMPA.l An)
                        // Phase 1: mem_read at Ay (rd_a), capture Ay_val.
                        // Phase 2: mem_read at Ax (latched), compute CMP; both An postincremented.
                        dec_valid       = 1'b1;
                        dec_is_cmpm     = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // Ay → rd_a (phase 1 read base)
                        dec_dst_reg     = {1'b1, f_dn};   // Ax → rd_b (latched for phase 2)
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_an_delta    = calc_step(f_siz, f_dn == 3'b111);

                    // ── CMP An,Dn — address register source ───────────────────────
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b001) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};  // An → rd_a
                        dec_dst_reg     = {1'b0, f_dn};   // Dn → rd_b
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};

                    // ── EOR Dn, (An)/(An)+/-(An)/(d16,An) ────────────
                    end else if (f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101)) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_EOR;
                        dec_siz         = f_siz;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        // CCR fires via mem_rmw_sr_wr_en, not WB (dec_updates_ccr stays 0)
                        if (f_mode == 3'b101) begin
                            dec_needs_ext = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        end
                    // ── EOR Dn, (d8,An,Xn) — indexed memory destination ──
                    end else if (f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_EOR;
                        dec_siz            = f_siz;
                        dec_is_mem_rd      = 1'b1;
                        dec_is_mem_rmw     = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                    // ── EOR Dn, (xxx).W/(xxx).L — absolute memory destination ──
                    end else if (f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)) begin
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = ALU_EOR;
                        dec_siz        = f_siz;
                        dec_is_mem_rd  = 1'b1;
                        dec_is_mem_rmw = 1'b1;
                        dec_needs_ext  = 1'b1;
                        dec_dst_reg    = {1'b0, f_dn};
                        dec_reads_dst  = 1'b1;
                        dec_abs_ea_en  = 1'b1;
                        if (f_reg == 3'b000)
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                        else
                            dec_abs_ea_val = ext_data;
                    // ── CMP (An)/(An)+/-(An), Dn — memory source, flags only ───────
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── CMP (d8,An,Xn), Dn — indexed memory source, flags only ──
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_CMP;
                        dec_siz            = f_siz;
                        dec_updates_ccr    = 1'b1;
                        dec_x_unchanged    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): same shape as
                        // OR's own memind arm above -- see its comment. CMP writes no
                        // register at all (flags only) -- memind_wr_en's own raw-write
                        // path is gated off for any ex_is_mem_src consumer (already
                        // set above) regardless, so this needs no extra care beyond
                        // the shared template.
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── CMP #imm, Dn — immediate source (group B encoding) ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = f_siz;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_dest_reg    = {1'b0, f_dn};
                    // ── CMP (ea),Dn — memory source, flags only ──────────
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                                        f_reg == 3'b001 ||
                                                        f_reg == 3'b010 ||
                                                        f_reg == 3'b011)))) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = f_siz;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_needs_ext   = 1'b1;
                        if (f_mode == 3'b101) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            dec_abs_ea_en = 1'b1;
                            case (f_reg)
                                3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b001: dec_abs_ea_val = ext_data;
                                3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                       + {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b011: begin  // (d8,PC,Xn)
                                    dec_abs_ea_val    = decode_pc + 32'd2
                                                      + {{24{ext_data[7]}}, ext_data[7:0]};
                                    dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                    dec_is_idx        = 1'b1;
                                    dec_xn_wl         = ext_data[11];
                                    dec_xn_scale      = ext_data[10:9];
                                    dec_is_dyn_bit_idx = 1'b1;
                                    dec_dyn_bit_reg   = f_dn;
                                end
                                default: ;
                            endcase
                        end
                    end else if (f_ss == 2'b11) begin
                        // CMPA.W (f_dir=0) / CMPA.L (f_dir=1): CCR from (An − sign_ext(src))
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_CMP;
                        dec_siz         = 2'b00;           // 32-bit compare
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b1, f_dn};    // An (compared from) → rd_b
                        dec_reads_dst   = 1'b1;
                        if (f_mode == 3'b000) begin
                            dec_reads_src = 1'b1;
                            dec_src_reg   = {1'b0, f_reg}; // Dn → rd_a
                            dec_sext_src  = !f_dir;        // sign-extend for .W
                        end else if (f_mode == 3'b001) begin
                            dec_reads_src = 1'b1;
                            dec_src_reg   = {1'b1, f_reg}; // An → rd_a
                            dec_sext_src  = !f_dir;
                        end else if (f_mode == 3'b111 && f_reg == 3'b100) begin
                            dec_use_imm   = 1'b1;
                            dec_needs_ext = 1'b1;
                            dec_imm       = f_dir ? ext_data[31:0]
                                                  : {{16{ext_data[15]}}, ext_data[15:0]};
                        // ── CMPA (d8,An,Xn), An — indexed memory source ─
                        end else if (f_mode == 3'b110) begin
                            dec_is_mem_src     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_sext_src       = !f_dir;
                            dec_mem_rd_siz     = f_dir ? 2'b00 : 2'b10;
                            dec_needs_ext      = 1'b1;
                            dec_src_reg        = {1'b1, f_reg};
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                            dec_reads_src      = 1'b1;
                            dec_reads_dst      = 1'b1;
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;  // An (addr reg) read after mem_ack
                            dec_dyn_bit_is_an  = 1'b1;
                            // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                            // same template as Stage 1 -- see TAS's own comment in the
                            // mode=110 unary-op family for the full reasoning. General
                            // ALU-EA genuine indirect stage (plan.md): same shape as
                            // OR's own memind arm -- see its comment. dec_memind_rd_siz
                            // mirrors dec_mem_rd_siz (explicitly f_dir-selected word/
                            // long above), not dec_siz (unset/unused for CMPA -- An
                            // compares always use the operand's own real size here).
                            if (fi_is_full && fi_iis != 3'b000) begin
                                dec_is_mem_rd      = 1'b0;
                                dec_is_memind      = 1'b1;
                                dec_memind_is_post = fi_iis[2];
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s && !fi_iis[2];
                                dec_ea_offset      = fi_bd;
                                dec_memind_rd_siz  = dec_mem_rd_siz;
                            end else begin
                                dec_ea_offset      = fi_is_full ? fi_bd
                                                   : {{24{ext_data[7]}}, ext_data[7:0]};
                            end
                        // ── CMPA (d8,PC,Xn): PC-indexed memory source ──
                        end else if (f_mode == 3'b111 && f_reg == 3'b011) begin
                            dec_is_mem_src     = 1'b1;
                            dec_is_mem_rd      = 1'b1;
                            dec_sext_src       = !f_dir;
                            dec_mem_rd_siz     = f_dir ? 2'b00 : 2'b10;
                            dec_needs_ext      = 1'b1;
                            dec_abs_ea_en      = 1'b1;
                            dec_abs_ea_val     = decode_pc + 32'd2 + {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                            dec_reads_dst      = 1'b1;
                            dec_is_idx         = 1'b1;
                            dec_xn_wl          = ext_data[11];
                            dec_xn_scale       = ext_data[10:9];
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;
                            dec_dyn_bit_is_an  = 1'b1;
                        // ── CMPA.W/L from memory EA ───────────────────
                        end else if (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                     f_mode == 3'b101 ||
                                     (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                                                           f_reg == 3'b010))) begin
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_sext_src    = !f_dir;
                            dec_mem_rd_siz  = f_dir ? 2'b00 : 2'b10;
                            if (f_mode != 3'b111) begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                            end
                            case (f_mode)
                                3'b011: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = calc_step(f_dir ? 2'b00 : 2'b10, f_reg == 3'b111);
                                end
                                3'b100: begin
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_reg;
                                    dec_an_delta   = ~calc_step(f_dir ? 2'b00 : 2'b10, f_reg == 3'b111) + 32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin
                                    dec_needs_ext  = 1'b1;
                                    dec_ea_offset  = {{16{ext_data[15]}}, ext_data[15:0]};
                                end
                                3'b111: begin
                                    dec_needs_ext  = 1'b1;
                                    dec_abs_ea_en  = 1'b1;
                                    case (f_reg)
                                        3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                        3'b001: dec_abs_ea_val = ext_data;
                                        3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                               + {{16{ext_data[15]}}, ext_data[15:0]};
                                        default: ;
                                    endcase
                                end
                                default: ;
                            endcase
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Group 1100: AND / MULU.W / MULS.W
                // ----------------------------------------------------------------
                4'hc: begin
                    if (f_mode == 3'b000) begin
                        if (f_ss == 2'b11) begin
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_MUL;
                            dec_src_reg     = {1'b0, f_reg};
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_siz         = 2'b00;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_md_op       = f_dir ? MUL_SW : MUL_UW;
                        end else if (f_dir && f_ss == 2'b00 && f_mode == 3'b000) begin
                            // ABCD: 1100 ddd1 0000 0sss (f_dir=1, f_ss=00=byte, f_mode=000)
                            // dst = f_dn, src = f_reg
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_BCD;
                            dec_bcd_op      = BCD_ADD;
                            dec_siz         = 2'b01;   // byte
                            dec_src_reg     = {1'b0, f_reg};
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                        end else if (f_dir && f_ss == 2'b01) begin
                            // EXG Dx,Dy: 1100 Dx 1 0100 0 Dy (f_dir=1,f_ss=01,f_mode=000)
                            // AND with f_dir=1,f_mode=000 is not a valid 68030 opcode.
                            dec_valid      = 1'b1;
                            dec_is_exg     = 1'b1;
                            dec_exg_dd     = 1'b1;
                            dec_siz        = 2'b00;
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_writes_reg = 1'b1;
                            dec_src_reg    = {1'b0, f_dn};   // Dx → rd_a
                            dec_dst_reg    = {1'b0, f_reg};  // Dy → rd_b
                            dec_dest_reg   = {1'b0, f_dn};   // write Dy→Dx via normal WB
                            dec_md_dst2    = f_reg;           // Dy receives Dx via wr2
                        end else begin
                            // AND Dn (f_dir=0) — f_dir=1 with f_mode=000 is covered above
                            dec_valid       = 1'b1;
                            dec_unit        = UNIT_ALU;
                            dec_alu_op      = ALU_AND;
                            dec_siz         = f_siz;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            if (!f_dir) begin
                                dec_src_reg  = {1'b0, f_reg};
                                dec_dst_reg  = {1'b0, f_dn};
                                dec_dest_reg = {1'b0, f_dn};
                            end else begin
                                dec_src_reg  = {1'b0, f_dn};
                                dec_dst_reg  = {1'b0, f_reg};
                                dec_dest_reg = {1'b0, f_reg};
                            end
                        end
                    // ── ABCD -(Ay),-(Ax): 1100 Ax 1 00 001 Ay
                    end else if (f_dir && f_ss == 2'b00 && f_mode == 3'b001) begin
                        dec_valid            = 1'b1;
                        dec_unit             = UNIT_BCD;
                        dec_bcd_op           = BCD_ADD;
                        dec_siz              = 2'b01;
                        dec_is_abcd_sbcd_mem = 1'b1;
                        dec_is_abcd_mem      = 1'b1;
                        dec_updates_ccr      = 1'b1;
                        dec_src_reg          = {1'b1, f_reg};
                        dec_dst_reg          = {1'b1, f_dn};
                        dec_reads_src        = 1'b1;
                        dec_reads_dst        = 1'b1;
                    // ── AND Dn, (An)/(An)+/-(An)/(d16,An) ────────────
                    end else if (f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101)) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_AND;
                        dec_siz         = f_siz;
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_src   = 1'b1;
                        dec_reads_dst   = 1'b1;
                        // CCR fires via mem_rmw_sr_wr_en, not WB (dec_updates_ccr stays 0)
                        if (f_mode == 3'b101) begin
                            dec_needs_ext = 1'b1;
                            dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin
                            setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                        end
                    end else if (f_dir &&
                                 ((f_ss == 2'b01 && f_mode == 3'b000) ||   // EXG Dx,Dy (handled above)
                                  (f_ss == 2'b01 && f_mode == 3'b001) ||   // EXG Ax,Ay
                                  (f_ss == 2'b10 && f_mode == 3'b001))) begin  // EXG Dx,Ay
                        // EXG: 1100 xxx 1 0100 0 yyy (Dx,Dy), 0100 1 yyy (Ax,Ay), 1000 1 yyy (Dx,Ay)
                        dec_valid      = 1'b1;
                        dec_is_exg     = 1'b1;
                        dec_siz        = 2'b00;
                        dec_reads_src  = 1'b1;
                        dec_reads_dst  = 1'b1;
                        dec_writes_reg = 1'b1;
                        if (f_ss == 2'b01 && f_mode == 3'b000) begin
                            // EXG Dx,Dy: f_ss=01, f_mode=000
                            dec_exg_dd   = 1'b1;
                            dec_src_reg  = {1'b0, f_dn};   // Dx → rd_a
                            dec_dst_reg  = {1'b0, f_reg};  // Dy → rd_b
                            dec_dest_reg = {1'b0, f_dn};   // write Dy→Dx via normal WB
                            dec_md_dst2  = f_reg;           // Dy receives Dx via wr2
                        end else if (f_ss == 2'b01 && f_mode == 3'b001) begin
                            // EXG Ax,Ay: f_ss=01, f_mode=001
                            dec_src_reg    = {1'b1, f_dn};  // Ax → rd_a
                            dec_dst_reg    = {1'b1, f_reg}; // Ay → rd_b
                            dec_dest_reg   = {1'b1, f_dn};  // write Ay→Ax via normal WB
                            dec_an_upd_en  = 1'b1;
                            dec_an_upd_reg = f_reg;          // Ay receives Ax via an_wr (delta=0)
                            dec_an_delta   = 32'h0;
                        end else begin
                            // EXG Dx,Ay: f_ss=10, f_mode=001
                            dec_src_reg    = {1'b0, f_dn};  // Dx → rd_a
                            dec_dst_reg    = {1'b1, f_reg}; // Ay → rd_b
                            dec_dest_reg   = {1'b0, f_dn};  // write Ay→Dx via normal WB
                            dec_an_upd_en  = 1'b1;
                            dec_an_upd_reg = f_reg;          // Ay receives Dx via an_wr (delta=0)
                            dec_an_delta   = 32'h0;
                        end
                    // ── AND Dn, (d8,An,Xn) — indexed memory destination ──
                    end else if (f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_AND;
                        dec_siz            = f_siz;
                        dec_is_mem_rd      = 1'b1;
                        dec_is_mem_rmw     = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                    // ── AND Dn, (xxx).W/(xxx).L — absolute memory destination ──
                    end else if (f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)) begin
                        dec_valid      = 1'b1;
                        dec_unit       = UNIT_ALU;
                        dec_alu_op     = ALU_AND;
                        dec_siz        = f_siz;
                        dec_is_mem_rd  = 1'b1;
                        dec_is_mem_rmw = 1'b1;
                        dec_needs_ext  = 1'b1;
                        dec_dst_reg    = {1'b0, f_dn};
                        dec_reads_dst  = 1'b1;
                        dec_abs_ea_en  = 1'b1;
                        if (f_reg == 3'b000)
                            dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                        else
                            dec_abs_ea_val = ext_data;
                    // ── AND (An)/(An)+/-(An), Dn — memory source → register dest ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_AND;
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── AND (d8,An,Xn), Dn — indexed memory source ──────
                    end else if (!f_dir && f_ss != 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_ALU;
                        dec_alu_op         = ALU_AND;
                        dec_siz            = f_siz;
                        dec_writes_reg     = 1'b1;
                        dec_updates_ccr    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): same shape as
                        // OR's own memind arm above -- see its comment for the full
                        // reasoning.
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── AND #imm, Dn — immediate source (group C encoding) ──
                    end else if (!f_dir && f_ss != 2'b11 &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_AND;
                        dec_siz         = f_siz;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_dest_reg    = {1'b0, f_dn};
                    // ── MULU/MULS (An)/(An)+/-(An), Dn — memory source ──
                    // The AND-memory-source blocks above explicitly exclude
                    // f_ss==11 (MUL's own signature bits, since MUL doesn't
                    // use f_ss for operand size — the operand is always a
                    // 16-bit word), so these three EA-mode groups were never
                    // decoded for MUL at all before this block existed.
                    end else if (f_ss == 2'b11 &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) begin
                        dec_valid       = 1'b1;
                        dec_is_mem_src  = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_unit        = UNIT_MUL;
                        dec_siz         = 2'b00;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_reads_dst   = 1'b1;
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_src_reg     = {1'b1, f_reg};
                        dec_reads_src   = 1'b1;
                        dec_md_op       = f_dir ? MUL_SW : MUL_UW;
                        // dec_siz=00 (longword) is for the 32-bit result write; the
                        // memory READ itself must stay word-sized regardless — override
                        // via dec_mem_rd_siz (sentinel 00 = "no override, use dec_siz").
                        dec_mem_rd_siz  = 2'b10;
                        setup_mem_incdec(2'b10, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);
                    // ── MULU/MULS (d8,An,Xn), Dn — indexed memory source ──
                    end else if (f_ss == 2'b11 && f_mode == 3'b110) begin
                        dec_valid          = 1'b1;
                        dec_is_mem_src     = 1'b1;
                        dec_is_mem_rd      = 1'b1;
                        dec_unit           = UNIT_MUL;
                        dec_siz            = 2'b00;
                        dec_writes_reg     = 1'b1;
                        dec_updates_ccr    = 1'b1;
                        dec_needs_ext      = 1'b1;
                        dec_src_reg        = {1'b1, f_reg};
                        dec_dst_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_reads_dst      = 1'b1;
                        dec_dest_reg       = {1'b0, f_dn};
                        dec_is_idx         = 1'b1;
                        dec_xn_wl          = ext_data[11];
                        dec_xn_scale       = ext_data[10:9];
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        dec_md_op          = f_dir ? MUL_SW : MUL_UW;
                        dec_mem_rd_siz     = 2'b10;  // word read despite longword result
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning. General
                        // ALU-EA genuine indirect stage (plan.md): same shape as
                        // DIVU/DIVS's own memind arm above -- see its comment for the
                        // full reasoning (dec_is_mem_rd suppressed, dec_writes_reg/
                        // dec_is_mem_src stay set, dec_memind_rd_siz mirrors
                        // dec_mem_rd_siz not dec_siz).
                        if (fi_is_full && fi_iis != 3'b000) begin
                            dec_is_mem_rd      = 1'b0;
                            dec_is_memind      = 1'b1;
                            dec_memind_is_post = fi_iis[2];
                            dec_memind_od      = fi_od;
                            dec_is_idx         = !fi_is_s && !fi_iis[2];
                            dec_ea_offset      = fi_bd;
                            dec_memind_rd_siz  = dec_mem_rd_siz;
                        end else begin
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                        end
                    // ── MULU/MULS #imm, Dn — immediate source ───────────
                    end else if (f_ss == 2'b11 && f_mode == 3'b111 && f_reg == 3'b100) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MUL;
                        dec_siz         = 2'b00;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_dst   = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};
                        dec_dest_reg    = {1'b0, f_dn};
                        dec_md_op       = f_dir ? MUL_SW : MUL_UW;
                    // ── AND/MULU/MULS (ea),Dn — memory source ───────────
                    end else if ((f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                                        f_reg == 3'b001 ||
                                                        f_reg == 3'b010 ||
                                                        f_reg == 3'b011)))) begin
                        if (f_ss == 2'b11) begin
                            // MULU.W (f_dir=0) or MULS.W (f_dir=1) from memory EA
                            dec_valid       = 1'b1;
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_MUL;
                            dec_siz         = 2'b00;   // 32-bit result write; MUL/DIV uses src[15:0]
                            dec_mem_rd_siz  = 2'b10;   // but the bus read itself must stay word-sized
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_reads_dst   = 1'b1;
                            dec_dest_reg    = {1'b0, f_dn};
                            dec_md_op       = f_dir ? MUL_SW : MUL_UW;
                        end else if (!f_dir) begin
                            // AND (ea),Dn
                            dec_valid       = 1'b1;
                            dec_is_mem_src  = 1'b1;
                            dec_is_mem_rd   = 1'b1;
                            dec_unit        = UNIT_ALU;
                            dec_alu_op      = ALU_AND;
                            dec_siz         = f_siz;
                            dec_writes_reg  = 1'b1;
                            dec_updates_ccr = 1'b1;
                            dec_dst_reg     = {1'b0, f_dn};
                            dec_reads_dst   = 1'b1;
                            dec_dest_reg    = {1'b0, f_dn};
                        end
                        if (dec_valid) begin
                            dec_needs_ext = 1'b1;
                            if (f_mode == 3'b101) begin
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin
                                dec_abs_ea_en = 1'b1;
                                case (f_reg)
                                    3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                    3'b001: dec_abs_ea_val = ext_data;
                                    3'b010: dec_abs_ea_val = decode_pc + 32'd2
                                                           + {{16{ext_data[15]}}, ext_data[15:0]};
                                    3'b011: begin  // (d8,PC,Xn)
                                        dec_abs_ea_val    = decode_pc + 32'd2
                                                          + {{24{ext_data[7]}}, ext_data[7:0]};
                                        dec_dst_reg       = {ext_data[15], ext_data[14:12]};
                                        dec_is_idx        = 1'b1;
                                        dec_xn_wl         = ext_data[11];
                                        dec_xn_scale      = ext_data[10:9];
                                        dec_is_dyn_bit_idx = 1'b1;
                                        dec_dyn_bit_reg   = f_dn;
                                    end
                                    default: ;
                                endcase
                            end
                        end
                    end
                end
                // ----------------------------------------------------------------
                // Group 1110: shifts
                // Format: 1110 ccc d ss i tt rrr
                //   f_dn=ccc, f_dir=d(1=left), f_ss=ss, f_shf_i=i, f_shf_tt=tt, f_reg=dest
                // shf_op = {tt[1], tt[0]^tt[1], ~d}
                // ----------------------------------------------------------------
                4'he: begin
                    if (f_ss != 2'b11) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_SHF;
                        dec_src_reg     = {1'b0, f_reg};   // operand register
                        dec_dst_reg     = {1'b0, f_dn};    // count register (if i=1)
                        dec_dest_reg    = {1'b0, f_reg};   // result → same register
                        dec_siz         = f_siz;
                        dec_writes_reg  = 1'b1;
                        dec_updates_ccr = 1'b1;
                        dec_reads_src   = 1'b1;
                        dec_shf_op      = {1'b0, f_shf_tt[1], f_shf_tt[0]^f_shf_tt[1], ~f_dir};
                        if (!f_shf_i) begin
                            // Immediate count: ccc=000 → 8
                            dec_shf_imm_cnt = (f_dn == 3'b000) ? 6'd8 : {3'b0, f_dn};
                        end else begin
                            dec_use_reg_cnt = 1'b1;
                            dec_reads_dst   = 1'b1;
                        end
                    // ── bit-field instructions (f_ss=11, f_dn[2]=1) ──────
                    // BFTST=1000 BFEXTU=1001 BFCHG=1010  BFEXTS=1011
                    // BFCLR=1100 BFFFO=1101  BFSET=1110  BFINS=1111 (bits 11:8 of opcode;
                    // confirmed against vasm's own assembly -- Phase 161 Part A Stage A5
                    // found this ordering was previously wrong, see eu_bitfield.sv)
                    // Dn (000) and (An) (010) — 1 ext word (bf_spec in [15:0])
                    // (d16,An)(101) and (xxx).W(111/000) — 2 ext words:
                    //   bf_spec in ext_data[31:16], displacement in ext_data[15:0].
                    //   PC-relative (111/010) read-only EA (no BFCLR/BFSET/BFINS).
                    end else if (f_dn[2] &&
                                 (f_mode == 3'b000 || f_mode == 3'b010 ||
                                  f_mode == 3'b101 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010)))) begin
                        // Determine whether bf_spec is in ext_data[15:0] (1-word) or [31:16] (2-word)
                        // 1-ext-word: Dn (000) and (An) (010); 2-ext-word: all others
                        logic [15:0] bf_spec_w;
                        logic        bf_two_ext;
                        bf_two_ext = (f_mode != 3'b000) && (f_mode != 3'b010);
                        bf_spec_w  = bf_two_ext ? ext_data[31:16] : ext_data[15:0];
                        dec_valid     = 1'b1;
                        dec_needs_ext = 1'b1;
                        dec_is_bf     = 1'b1;
                        dec_siz       = 2'b00;
                        dec_bf_op     = {f_dn[1:0], f_dir};
                        // Phase 161 Part A Stage A5: real bf_op mapping is
                        // 000=TST 001=EXTU 010=CHG 011=EXTS 100=CLR 101=FFO
                        // 110=SET 111=INS (confirmed against vasm's own
                        // assembly of "bfchg" -- NOT the sequential
                        // TST/EXTU/EXTS/FFO/CLR/(gap)/SET/INS ordering this
                        // decode used to assume). Mutating (modifies the
                        // field, writes back): CHG/CLR/SET/INS.
                        dec_bf_mutates = (dec_bf_op == 3'b010) || (dec_bf_op == 3'b100) ||
                                         (dec_bf_op == 3'b110) || (dec_bf_op == 3'b111);
                        dec_bf_reg_ea  = (f_mode == 3'b000);
                        // For 2-ext-word modes, put bf_spec in dec_imm[15:0] so ex_imm matches
                        if (bf_two_ext) dec_imm = {16'h0, bf_spec_w};
                        // Source EA: Dn (000), An (010), or An (101); abs/PC for 111
                        if (f_mode == 3'b000) begin
                            dec_src_reg  = {1'b0, f_reg};
                        end else if (f_mode == 3'b010 || f_mode == 3'b101) begin
                            dec_src_reg  = {1'b1, f_reg};  // An → rd_a
                            if (f_mode == 3'b101)
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else begin  // f_mode == 3'b111
                            if (f_reg == 3'b000) begin  // (xxx).W
                                dec_abs_ea_en  = 1'b1;
                                dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin  // (d16,PC)
                                dec_abs_ea_en  = 1'b1;
                                dec_abs_ea_val = decode_pc + 32'd4
                                               + {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                        end
                        dec_reads_src = (f_mode != 3'b111) || (f_reg == 3'b000);
                        // For BFINS: source Dn from bf_spec[14:12]
                        if ({f_dn[1:0], f_dir} == 3'b111 && f_mode != 3'b111) begin
                            dec_dst_reg   = {1'b0, bf_spec_w[14:12]};
                            dec_reads_dst = 1'b1;
                        end
                        if (f_mode == 3'b000) begin
                            // Register EA: WB path handles result and CCR
                            case ({f_dn[1:0], f_dir})
                                3'b000: dec_updates_ccr = 1'b1;  // BFTST
                                3'b001, 3'b011, 3'b101: begin  // BFEXTU/BFEXTS/BFFFO: write to a DIFFERENT Dn
                                    dec_writes_reg  = 1'b1;
                                    dec_dest_reg    = {1'b0, bf_spec_w[14:12]};
                                    dec_updates_ccr = 1'b1;
                                end
                                default: begin  // BFCHG/BFCLR/BFSET/BFINS: write back to the SAME Dn
                                    dec_writes_reg  = 1'b1;
                                    dec_dest_reg    = {1'b0, f_reg};
                                    dec_updates_ccr = 1'b1;
                                end
                            endcase
                        end else begin
                            // Memory EA: FSM fires result Dn write and CCR directly
                            dec_dest_reg    = {1'b0, bf_spec_w[14:12]};
                            dec_writes_reg  = 1'b0;
                            dec_updates_ccr = 1'b0;
                        end
                    // ── shift/rotate ea (f_ss=11, f_dn[2]=0, memory forms) ──
                    // Encoding: 1110 tt d 11 0ss mmm rrr  (f_dn={tt,0,ss?} — use f_shf_tt)
                    // f_ss=11 + f_dn[2]=0: single-bit shift of memory word.
                    // (d8,An,Xn) only needs An(rd_a)+Xn(rd_b) — memory shifts are always
                    // 1-bit, unary on the word itself, no data-register operand (see
                    // port3.md §1 Bucket A — not the 3-read-port gap).
                    end else if (!f_dn[2] &&
                                 (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
                                  f_mode == 3'b101 || f_mode == 3'b110 ||
                                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)))) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_SHF;
                        dec_siz         = 2'b10;   // word (memory shifts are always word)
                        dec_is_mem_rd   = 1'b1;
                        dec_is_mem_rmw  = 1'b1;
                        // CCR fires via mem_rmw_sr_wr_en (not WB), to avoid stale mem_rdata
                        dec_updates_ccr = 1'b0;
                        dec_shf_imm_cnt = 6'd1;    // always 1-bit memory shift
                        if (f_mode != 3'b111) begin
                            dec_src_reg   = {1'b1, f_reg};
                            dec_reads_src = 1'b1;
                        end
                        // shf_op: {0, f_dn[1], f_dn[0]^f_dn[1], ~f_dir} — same as register form
                        dec_shf_op      = {1'b0, f_dn[1], f_dn[0]^f_dn[1], ~f_dir};
                        case (f_mode)
                            3'b011: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = 32'd2;
                            end
                            3'b100: begin
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = 32'hFFFFFFFE;  // -2
                                dec_ea_offset  = 32'hFFFFFFFE;
                            end
                            3'b101: begin  // (d16,An)
                                dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b110: begin  // (d8,An,Xn) brief, or full (bd,An,Xn)
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]};
                                dec_reads_dst = 1'b1;
                                dec_is_idx    = 1'b1;
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                // Same fi_is_full/fi_bd extension as TAS/NBCD/
                                // NEGX-etc's own mode=110 cases -- see TAS's
                                // comment for the full reasoning.
                                dec_ea_offset = fi_is_full ? fi_bd
                                              : {{24{ext_data[7]}}, ext_data[7:0]};
                                dec_needs_ext = 1'b1;
                            end
                            3'b111: begin  // (xxx).W / (xxx).L
                                dec_abs_ea_en  = 1'b1;
                                dec_needs_ext  = 1'b1;
                                dec_abs_ea_val = (f_reg == 3'b001) ? ext_data
                                                 : {{16{ext_data[15]}}, ext_data[15:0]};
                            end
                            default: ;
                        endcase
                    end
                end

                // ----------------------------------------------------------------
                // Group 1010: Line-A emulator trap → vector 10
                // ----------------------------------------------------------------
                4'ha: begin
                    dec_valid    = 1'b1;
                    dec_is_linea = 1'b1;
                end

                // ----------------------------------------------------------------
                // Group 1111: MOVE16 and FPU coprocessor (cpid=1)
                // cpid=1 (f_dn=001) is shared; disambiguate by f_mode and ppp.
                // MOVE16 uses ppp=000 with EA mode 0-3 (!f_mode[2]).
                // FPU uses cpid=1 with EA mode 4-7 (f_mode[2]=1) OR ppp != 000.
                // ----------------------------------------------------------------
                4'hf: begin
                    if (f_dn == 3'b001 && !f_dir && f_ss == 2'b00 && !f_mode[2]) begin
                        // MOVE16: ppp=000, EA modes 0-3 (modes 4-7 would be FPU)
                        dec_valid     = 1'b1;
                        dec_is_move16 = 1'b1;
                        dec_unit      = UNIT_NONE;
                        dec_needs_ext = 1'b1;
                        dec_src_reg   = {1'b1, f_reg};   // Ax → rd_a (src An or dst An)
                        dec_reads_src = 1'b1;
                        case (f_mode)
                            3'b001: begin  // (An)+,(Am)+
                                dec_move16_form = 2'b00;
                                dec_dst_reg     = {1'b1, ext_data[14:12]};
                                dec_reads_dst   = 1'b1;
                            end
                            3'b010: begin  // (An)+,(xxx).L
                                dec_move16_form = 2'b01;
                            end
                            3'b011: begin  // (xxx).L,(An)+
                                dec_move16_form = 2'b10;
                            end
                            3'b000: begin  // (An),(An)  — no postincrement
                                dec_move16_form = 2'b11;
                                dec_dst_reg     = {1'b1, ext_data[14:12]};
                                dec_reads_dst   = 1'b1;
                            end
                            default: ;
                        endcase
                    end else if (f_dn == 3'b001 && {f_dir, f_ss} == 3'b100) begin
                        // cpSAVE: cpid=1, TYPE=100 (manual Figure 10-15). Privileged.
                        // EA field is bits[5:0] (f_mode/f_reg, same positions as any
                        // ordinary EA). Open-items backlog Stage 14 (plan.md): the
                        // real format-word-driven multi-longword transfer protocol
                        // (Section 10.2.3) was first implemented for (An) only
                        // (f_mode==010); deferred-items closure plan Stage 6
                        // (plan.md) extends it to -(An) (f_mode==100) -- the ONLY
                        // other valid cpSAVE addressing mode. Confirmed directly
                        // against MC68030UM.pdf Section 10.2.3.3.1: "The control
                        // alterable and predecrement addressing modes are valid
                        // for the cpSAVE instruction" -- (An)+ is genuinely
                        // architecturally INVALID for cpSAVE (not just deferred),
                        // so it correctly stays on the original one-CIR-read stub
                        // below, same as every other EA mode. Both (An)-in-rd_a
                        // and -(An)'s own decrement reuse the standard
                        // setup_mem_incdec(2'b00,...) template unmodified: the
                        // manual's own protocol (Figure 10-16, M3) evaluates the
                        // EA and stores the FORMAT WORD there BEFORE the variable
                        // transfer length is even known, so the auto-decrement
                        // step is a fixed 4 bytes (the format word's own size),
                        // identical to any other longword predecrement -- the
                        // cpsr_* FSM's own transfer-loop math (ex_ea + length,
                        // descending) is completely unaffected either way.
                        // Displacement/indexed/absolute/PC-relative stay stubbed,
                        // documented explicitly as still out of scope (same
                        // boundary the FPU coprocessor stub has carried since
                        // Phase 55).
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid     = 1'b1;
                            dec_is_cpsave = 1'b1;
                            dec_unit      = UNIT_NONE;
                            dec_needs_ext = (f_mode == 3'b101 || f_mode == 3'b110 ||
                                             f_mode == 3'b111);
                            if (f_mode == 3'b010 || f_mode == 3'b100) begin  // (An), -(An)
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                setup_mem_incdec(2'b00, dec_an_upd_en, dec_an_upd_reg,
                                                  dec_an_delta, dec_ea_offset);
                            end
                        end
                    end else if (f_dn == 3'b001 && {f_dir, f_ss} == 3'b101) begin
                        // cpRESTORE: cpid=1, TYPE=101 (manual Figure 10-17). Same
                        // privilege check as cpSAVE above; deferred-items closure
                        // plan Stage 6 extends the real protocol to (An)+
                        // (f_mode==011) -- confirmed against Section 10.2.3.4.1:
                        // "All memory addressing modes except the predecrement
                        // addressing mode are valid" for cpRESTORE, the exact
                        // mirror image of cpSAVE's own restriction -- -(An) is
                        // genuinely INVALID for cpRESTORE (not just deferred) and
                        // correctly stays on the stub below. Same fixed-4-byte
                        // setup_mem_incdec template as cpSAVE (the format word is
                        // read from the EA first, THEN An postincrements by its
                        // own fixed size, before the variable-length transfer
                        // loop -- which is unaffected -- even begins).
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid        = 1'b1;
                            dec_is_cprestore = 1'b1;
                            dec_unit         = UNIT_NONE;
                            dec_needs_ext    = (f_mode == 3'b101 || f_mode == 3'b110 ||
                                                f_mode == 3'b111);
                            if (f_mode == 3'b010 || f_mode == 3'b011) begin  // (An), (An)+
                                dec_src_reg   = {1'b1, f_reg};
                                dec_reads_src = 1'b1;
                                setup_mem_incdec(2'b00, dec_an_upd_en, dec_an_upd_reg,
                                                  dec_an_delta, dec_ea_offset);
                            end
                        end
                    end else if (f_dn == 3'b001) begin
                        // FPU coprocessor: cpid=1, any ppp or EA mode 4-7.
                        // Issues one CPI CPU Space bus cycle; full protocol in later phases.
                        dec_valid     = 1'b1;
                        dec_is_fpu    = 1'b1;
                        dec_unit      = UNIT_NONE;
                        dec_needs_ext = 1'b1;   // FPU opcode always has extension word (CIR)
                    end else if (f_dn == 3'b000) begin
                        // MMU cpid=0: PFLUSH / PTEST / PMOVE
                        // Second word ext_data[15:13] selects operation.
                        dec_needs_ext = 1'b1;
                        case (mmu_op_type)
                            3'b001: begin
                                // PFLUSH / PFLUSHA
                                dec_valid      = 1'b1;
                                dec_unit       = UNIT_NONE;
                                dec_is_pflush  = 1'b1;
                                dec_pflush_all = (mmu_sub_mode == 3'b010);
                                dec_pflush_fc  = (mmu_fc_mode == 2'b10)
                                                 ? mmu_fc_val : sfc_in;
                                if (!dec_pflush_all && f_mode == 3'b010) begin
                                    dec_src_reg   = {1'b1, f_reg};
                                    dec_reads_src = 1'b1;
                                end
                            end
                            3'b011: begin
                                // PLOAD (Phase 150 Stage 5, plan.md): explicitly
                                // loads an ATC entry for a given VA/FC, performing
                                // a real (non-PTEST) walk so U/M write-back and
                                // ATC installation happen exactly like an ordinary
                                // access would.
                                //
                                // NOTE on encoding: real Motorola silicon actually
                                // overlaps PLOAD's bit pattern with PFLUSH's own
                                // ext_data[15:13]==001 prefix (confirmed both by
                                // reverse-deriving it from Musashi's m68kdasm.c
                                // d68851_p000() disassembler AND by direct
                                // collision: an early attempt at that literal
                                // encoding matched this file's own already-
                                // established PFLUSHA encoding, 16'h2000, exactly
                                // -- breaking real PFLUSHA). Since mmu_op_type is
                                // already this file's own CLEAN, non-overlapping
                                // 3-bit reinterpretation of Motorola's genuinely
                                // context-dependent bit scheme (not a literal
                                // silicon encoding for PFLUSH/PTEST/PMOVE either),
                                // PLOAD is assigned the same way: an otherwise-
                                // unused mmu_op_type value (011; only 001/010/100
                                // are used by PFLUSH/PMOVE/PTEST), guaranteeing no
                                // collision with any existing MMU instruction.
                                // Harte has zero coverage of this 68020+-only
                                // instruction and Musashi doesn't functionally
                                // implement it either, so there is no external
                                // oracle to verify a literal encoding against in
                                // the first place -- internal self-consistency
                                // with this file's own established convention is
                                // the achievable, honest bar here. VA is taken
                                // from an An-indirect EA (same restriction as
                                // PTEST/PFLUSH); FC-selector reuses PTEST's own
                                // mmu_pt_fc_mode/mmu_pt_fc_val fields; bit 9
                                // (otherwise unused for this op_type) selects the
                                // R/W access-type direction real PLOAD specifies.
                                if (f_mode == 3'b010) begin
                                    dec_valid     = 1'b1;
                                    dec_unit      = UNIT_NONE;
                                    dec_is_pload  = 1'b1;
                                    dec_pload_rw  = ext_data[9];
                                    dec_pload_fc  = (mmu_pt_fc_mode == 2'b10)
                                                     ? {1'b0, mmu_pt_fc_val} : sfc_in;
                                    dec_src_reg   = {1'b1, f_reg};
                                    dec_reads_src = 1'b1;
                                end
                            end
                            3'b100: begin
                                // PTEST: VA from An-indirect EA
                                if (f_mode == 3'b010) begin
                                    dec_valid      = 1'b1;
                                    dec_unit       = UNIT_NONE;
                                    dec_is_ptest   = 1'b1;
                                    dec_ptest_fc   = (mmu_pt_fc_mode == 2'b10)
                                                     ? {1'b0, mmu_pt_fc_val} : sfc_in;
                                    dec_src_reg    = {1'b1, f_reg};
                                    dec_reads_src  = 1'b1;
                                end
                            end
                            3'b010: begin
                                // PMOVE 32-bit registers (TC/TT0/TT1/MMUSR)
                                // 64-bit CRP/SRP (mmu_sub_mode=100/110)
                                if (f_mode == 3'b010 &&
                                    (mmu_sub_mode == 3'b100 || mmu_sub_mode == 3'b110)) begin
                                    // PMOVE CRP/SRP: 2x 32-bit bus cycles, hi word first
                                    dec_valid         = 1'b1;
                                    dec_unit          = UNIT_NONE;
                                    dec_is_pmove64    = 1'b1;
                                    dec_pmove_preg    = mmu_sub_mode;
                                    dec_pmove_to_mem  = mmu_dr;
                                    dec_siz           = 2'b00;
                                    if (mmu_dr) begin
                                        dec_dst_reg   = {1'b1, f_reg};
                                        dec_reads_dst = 1'b1;
                                        dec_is_mem_wr = 1'b1;
                                    end else begin
                                        dec_src_reg   = {1'b1, f_reg};
                                        dec_reads_src = 1'b1;
                                        dec_is_mem_rd = 1'b1;
                                    end
                                end else if (f_mode == 3'b010 &&
                                    mmu_sub_mode != 3'b100 && mmu_sub_mode != 3'b110) begin
                                    dec_valid         = 1'b1;
                                    dec_unit          = UNIT_NONE;
                                    dec_is_pmove      = 1'b1;
                                    dec_pmove_preg    = mmu_sub_mode;
                                    dec_pmove_to_mem  = mmu_dr;
                                    dec_siz           = 2'b00;    // longword
                                    if (mmu_dr) begin
                                        // dr=1: register→EA (write to memory)
                                        dec_dst_reg   = {1'b1, f_reg};
                                        dec_reads_dst = 1'b1;
                                        dec_is_mem_wr = 1'b1;
                                    end else begin
                                        // dr=0: EA→register (read from memory)
                                        dec_src_reg   = {1'b1, f_reg};
                                        dec_reads_src = 1'b1;
                                        dec_is_mem_rd = 1'b1;
                                    end
                                end
                            end
                            default: ;
                        endcase
                    end else begin
                        // Non-FPU, non-MMU, non-MOVE16 Group-F encoding → Line-F (vector 11)
                        dec_valid    = 1'b1;
                        dec_is_linef = 1'b1;
                    end
                end

                default: ;

            endcase
        end
    end

    // trace — computed after always_comb to avoid local-var issues.
    // T1 (SR[15]): every instruction; T0 (SR[14]): flow-change only.
    // Suppressed when instruction itself raises a higher-priority exception (priv/linea/linef),
    // but priority encoder in m68030_exc handles any remaining co-fires.
    logic dec_is_flow_chg;
    assign dec_is_flow_chg = dec_is_jmp || dec_is_jsr || dec_is_jsr_idx ||
                              dec_is_bsr || dec_is_rts || dec_is_rtr || dec_is_rte ||
                              dec_is_trap || dec_is_trapv || dec_is_dbcc ||
                              (dec_is_branch && dec_branch_taken);
    assign dec_is_trace = dec_valid && !dec_is_priv && !dec_is_linea && !dec_is_linef &&
                          (sr_live[15] || (sr_live[14] && dec_is_flow_chg));

