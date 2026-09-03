// Split out of rtl/eu_seq.sv (was lines 6292-10998 of the original
// 11,001-line file) purely for navigability -- see rtl/eu_seq_decode.svh's
// own header for the full rationale (same mechanism, same file-scoping
// caveats: not standalone-compilable, no `` `default_nettype `` of its own).
//
// "Execute" here covers everything after decode: stall/hazard logic, the
// EX-stage latch, the WB-stage latch, and every per-instruction-family FSM
// (RTR, TAS, mem_rmw, ADDX-mem, MOVEP, MOVE16, FPU, BKPT, CPSR, MMU/
// PFLUSH/PTEST/PLOAD, memind, CAS/CAS2, BF, PACK/UNPK, BCD, STOP, ...) --
// not just the ALU. See the "WB stage signal declarations" banner
// immediately below for where the original text began.

    // -----------------------------------------------------------------------
    // WB stage signal declarations — placed before stall assigns to avoid
    // Icarus forward-reference elaboration errors.
    // -----------------------------------------------------------------------
    logic        wb_valid, wb_writes_reg, wb_updates_ccr, wb_x_unchanged, wb_is_move;
    logic [3:0]  wb_dest_reg;
    logic [1:0]  wb_siz;
    logic [31:0] wb_result;
    logic [4:0]  wb_ccr;       // {X, N, Z, V, C}
    logic        wb_move_n;    // corrected N flag for MOVE (sized MSB)
    logic        wb_an_upd_en;
    logic [2:0]  wb_an_upd_reg;
    logic [31:0] wb_an_upd_new;
    logic        wb_is_mem_rd;
    logic        wb_is_mem_rmw;
    logic        wb_is_movea_w;
    // MOVEC Rn→Rc write-back
    logic        wb_is_movec_wr;
    logic [11:0] wb_movec_rc;
    // SR/CCR/USP write flags
    logic        wb_is_move_sr_w;   // MOVE Dn,SR  → full SR write in WB
    logic        wb_is_move_ccr_w;  // MOVE Dn,CCR → CCR-only write in WB
    logic        wb_is_move_usp;    // MOVE An,USP → USP write in WB
    // 64-bit mul/div high result write
    logic        wb_is_muldivl;     // MULU.L/MULS.L/DIVU.L/DIVS.L in WB
    logic [2:0]  wb_md_dst2;        // Dh (MUL) or Dr (DIV) register number
    logic        wb_md_64bit;       // 1=write second register (Dh/Dr ≠ Dl/Dq)
    logic [31:0] wb_md_hi;          // latched result_hi from EX stage
    // EXG secondary write
    logic        wb_is_exg;         // EXG in WB stage
    logic        wb_exg_dd;         // 1=Dx,Dy form (wr2 needed)

    // -----------------------------------------------------------------------
    // Stall / hazard logic — checks both EX and WB for RAW conflicts.
    // 2 stall cycles cover EX→WB→regfile-commit latency.
    // ex_mem_stall: EX holds a memory op waiting for BIU ack.
    // -----------------------------------------------------------------------
    logic        ex_valid, ex_writes_reg, ex_updates_ccr;
    logic [3:0]  ex_dest_reg;
    logic        ex_is_mem_rd, ex_is_mem_wr, ex_is_lea, ex_is_movea_w;
    // Declared early for hazard_ex forward-ref (Icarus requires declaration before use)
    logic        ex_an_upd_en;
    logic [2:0]  ex_an_upd_reg;
    // declared here (before stall assigns) for Icarus forward-ref safety
    logic        ex_is_jmp, ex_is_jsr, ex_is_bsr, ex_is_rts, ex_is_rtr;
    // LINK / UNLK
    logic        ex_is_link;
    // absolute EA
    logic        ex_abs_ea_en;
    logic        ex_abs_jmp_en;
    logic [31:0] ex_abs_ea_val;
    // brief indexed EA
    logic        ex_is_idx;
    logic        ex_xn_wl;
    logic [1:0]  ex_xn_scale;
    logic        ex_is_dyn_bit_idx; // dynamic bit op with indexed EA
    logic [2:0]  ex_dyn_bit_reg;    // Dn register for bit count
    logic        ex_dyn_bit_is_an;  // 1 when dyn_bit_reg selects address register
    logic        ex_dyn_bit_swap_a; // 1: dyn_bit swap targets rd_a instead of rd_b
    logic        ex_dyn_bit_swap_both; // 1: swap BOTH rd_a and rd_b at read_ack
    logic [2:0]  ex_dyn_bit_reg2;      // dst_Xn register selector (2nd swap target)
    logic        ex_dyn_bit_is_an2;    // 1 when dyn_bit_reg2 selects an address register
    logic        ex_dst_is_idx;
    logic        ex_dst_xn_wl;
    logic [1:0]  ex_dst_xn_scale;
    logic [31:0] dyn_bit_ea_r;      // latched EA for RMW write-back addr fix
    // MOVEM
    logic        ex_is_movem;
    logic        ex_movem_load;
    logic        ex_movem_predec;
    logic        ex_movem_postinc;
    logic        ex_movem_long;
    // MOVEC / MOVES
    logic        ex_is_movec_wr;   // MOVEC Rn→Rc in EX
    logic [11:0] ex_movec_rc;      // Rc code latched from extension word
    logic        ex_is_moves;      // MOVES in EX
    logic        ex_moves_load;    // 1=load (SFC), 0=store (DFC)
    // TAS
    logic        ex_is_tas;        // TAS in EX stage
    // cpSAVE/cpRESTORE (deferred-items closure plan Stage 6, plan.md): gates
    // WB's own generic an_upd path off, mirroring ex_is_mem_rmw's own
    // existing "handled by a dedicated wr_en instead" exclusion below.
    logic        ex_is_cpsr;       // cpSAVE or cpRESTORE in EX stage
    // CHK, CMP2/CHK2
    logic        ex_is_chk;        // CHK in EX stage
    logic        ex_chk_word;      // 1=CHK.W, 0=CHK.L
    logic        ex_is_cmp2chk2;   // CMP2 or CHK2 in EX stage
    logic        ex_is_movep;      // MOVEP in EX stage
    logic        ex_is_fpu;        // FPU instruction in EX stage (Group F, cpid=1)
    // memory-indirect EA state in EX
    logic        ex_is_memind;
    logic        ex_memind_is_post;
    logic [31:0] ex_memind_od;
    // MMU instruction EX stage signals
    logic        ex_is_pflush;
    logic        ex_pflush_all;
    logic [2:0]  ex_pflush_fc;
    logic        ex_is_ptest;
    logic [2:0]  ex_ptest_fc;
    logic        ex_is_pload;      // Phase 150 Stage 5
    logic [2:0]  ex_pload_fc;
    logic        ex_pload_rw;
    logic        ex_is_pmove;
    logic        ex_is_pmove64;   // 64-bit PMOVE (CRP/SRP)
    logic        ex_is_mem_src;   // memory source + register accumulator → register result
    logic [2:0]  ex_pmove_preg;
    logic        ex_pmove_to_mem;
    logic        ex_movep_load;    // 1=load, 0=store
    logic        ex_movep_long;    // 1=longword, 0=word
    logic        ex_is_move16;     // MOVE16 in EX stage
    logic [1:0]  ex_move16_form;
    // OS control / exception instructions
    logic        ex_is_rte;
    logic        ex_is_stop;
    logic [15:0] ex_stop_sr;
    logic        ex_is_trap;
    logic [3:0]  ex_trap_num;
    logic        ex_is_trapv;
    logic        ex_is_illegal;
    // new exception outputs
    logic        ex_is_jsr_idx;   // JSR (d8,An,Xn) or (d8,PC,Xn) in EX
    logic        ex_is_pea_idx;   // PEA (d8,An,Xn) in EX — push EA via ex_cur_sp
    logic        ex_is_trace;     // trace exception for this instruction
    logic        ex_is_priv;      // privilege violation
    logic        ex_is_linea;     // Line-A opcode
    logic        ex_is_linef;     // Line-F non-FPU opcode
    logic        ex_is_move_sr_w;
    logic        ex_is_move_ccr_w;
    logic        ex_is_move_usp;
    logic        ex_sext_src;          // sign-extend ALU source 16→32 (ADDA.W/SUBA.W/CMPA.W)
    logic [1:0]  ex_mem_rd_siz;        // latched bus-read size override
    // 64-bit mul/div long in EX
    logic        ex_is_muldivl;       // MULU.L/MULS.L/DIVU.L/DIVS.L in EX
    logic [2:0]  ex_md_dst2;          // Dh (MUL) or Dr (DIV) register number
    logic        ex_md_64bit;         // 1=write second register
    // PEA, EXG, CMPM
    logic        ex_is_pea;           // PEA in EX stage
    logic        ex_is_exg;           // EXG in EX stage
    logic        ex_exg_dd;           // 1=Dx,Dy form
    logic        ex_is_cmpm;          // CMPM in EX stage
    // Memory RMW
    logic        ex_is_mem_rmw;       // memory read-modify-write in EX stage
    // ADDX/SUBX memory predecrement
    logic        ex_is_addx_mem;      // ADDX/SUBX -(Ay),-(Ax) in EX stage
    // MOVE memory→memory
    logic        ex_is_move_mm;
    logic        ex_is_move_mm_idx_dst;
    logic        ex_is_move_reg_idx_dst; // MOVE Dn/An→(d8,An,Xi): plain write, source reg on rd_c (Phase 149)
    logic [31:0] ex_dst_ea_offset;
    logic        ex_abs_dst_ea_en;
    logic [31:0] ex_abs_dst_ea_val;
    logic        ex_dst_an_upd_en;
    logic [2:0]  ex_dst_an_upd_reg;
    logic [31:0] ex_dst_an_delta;

    // bit-field instructions in EX stage
    logic        ex_is_bf;
    logic [2:0]  ex_bf_op;
    logic        ex_bf_reg_ea;
    logic        ex_bf_mutates;

    // PACK/UNPK/RESET
    logic        ex_is_pack;
    logic        ex_is_unpk;
    logic        ex_is_pack_mem;
    logic        ex_is_reset;

    // TAS (An) RMW state — declared early for ex_mem_stall
    logic        tas_run_r;          // TAS write phase active
    logic        tas_after_write_r;  // 1-cycle cooldown after write ack; prevents re-trigger
    logic [7:0]  tas_wdata_r;        // byte to write (original | 0x80)
    logic [4:0]  tas_ccr_r;          // CCR {X,N,Z,V,C} captured from read value
    logic        tas_read_ack;       // hold stall on read-ack cycle before write starts
    logic        tas_sr_wr_en;       // combinational: fire CCR update when write ack

    // RTR two-phase read state (module-level registers; declared here for stall)
    logic        rtr_phase_r;
    logic [7:0]  rtr_ccr_r;
    logic [31:0] rtr_a7_next_r;
    // RTR completion outputs (declared here so an_wr/sr_wr assigns can use them)
    logic        rtr_sr_wr_en;
    logic [15:0] rtr_sr_wr_data;
    logic        rtr_an_wr_en;
    logic [31:0] rtr_an_wr_data;

    // RTE two-phase read state (mirrors RTR; declared early for stall/an_wr assigns)
    logic        rte_phase_r;
    logic [15:0] rte_sr_r;
    logic [31:0] rte_a7_next_r;
    logic  [7:0] rte_fmt_skip_r;  // extra bytes beyond base 8 determined by frame format
    logic        rte_sr_wr_en;    // combinational: fire full-SR write when phase-2 acks
    logic        rte_an_wr_en;    // combinational: update A7 when phase-2 acks

    // STOP state (CPU halted until interrupt)
    logic        stop_r;          // 1 = CPU stopped, waiting for interrupt
    logic        stop_sr_wr_en;   // combinational: fire SR write on first cycle STOP is in EX

    // CMPM two-phase compare state (declared early for stall assign)
    logic        cmpm_phase_r;    // 1=in phase 2 (reading Ax)
    logic [31:0] cmpm_src_r;      // Ay_val from phase 1 read
    logic [31:0] cmpm_ax_addr_r;  // Ax address for phase 2 read
    logic [31:0] cmpm_step_r;     // Ax postincrement step
    logic [2:0]  cmpm_ax_reg_r;   // Ax register number latched for an_wr
    logic        cmpm_stall;
    // Ay step: uses Ay register (ex_src_reg) for A7 special case; Ax uses ex_an_delta.
    logic [31:0] cmpm_ay_step;
    assign cmpm_stall = ex_valid && ex_is_cmpm && !(cmpm_phase_r && mem_ack);

    // ADDX/SUBX -(Ay),-(Ax) 3-phase predecrement FSM (declared early for ex_mem_stall)
    logic        addx_mem_run_r;    // FSM is active (phases 0-2 in progress)
    logic [1:0]  addx_mem_phase_r;  // 0=read Ay, 1=read Ax, 2=write result
    logic [31:0] addx_src_r;        // M[Ay-step] captured at phase 0 ack
    logic [31:0] addx_dst_r;        // M[Ax-step] captured at phase 1 ack
    logic [31:0] addx_ay_addr_r;    // Ay-step (predecremented Ay address)
    logic [31:0] addx_ax_addr_r;    // Ax-step (predecremented Ax address)
    logic [2:0]  addx_ay_reg_r;     // Ay register number
    logic [2:0]  addx_ax_reg_r;     // Ax register number
    logic [1:0]  addx_siz_r;        // transfer size
    logic        addx_mem_stall;
    // (mem_berr || exc_active) spelled out rather than referencing the
    // later-declared `mem_abort` wire — this assign is textually earlier in
    // the file than mem_abort's own declaration, and both mem_berr/
    // exc_active are module ports, available everywhere regardless of
    // declaration order. See "mem_abort" comment near ex_mem_stall's own
    // assign for why exc_active must be included, not just mem_berr.
    assign addx_mem_stall = ex_valid && ex_is_addx_mem && !(mem_berr || exc_active) &&
                            !(addx_mem_run_r && addx_mem_phase_r == 2'd2 && mem_ack);

    // bit-field memory FSM (declared early for ex_mem_stall)
    logic        bf_mem_run_r;       // FSM active
    logic        bf_mem_phase_r;     // 0=read, 1=write
    logic [31:0] bf_mem_data_r;      // captured memory longword
    logic [31:0] bf_mem_addr_r;      // EA address
    logic [2:0]  bf_mem_op_r;        // bf_op captured
    logic [4:0]  bf_mem_offset_r;    // offset captured
    logic [4:0]  bf_mem_width_r;     // width captured
    logic [2:0]  bf_mem_dn_r;        // result Dn (EXTU/EXTS/FFO) captured
    logic [31:0] bf_mem_src_r;       // BFINS source Dn captured
    logic        bf_mem_mutates_r;   // 1=CLR/SET/INS (needs write phase)

    // bf_mem_stall: active while FSM is running and not yet done
    // (mem_berr || exc_active) spelled out — see addx_mem_stall's own
    // comment above for why (forward-reference / must include exc_active).
    logic bf_mem_stall;
    assign bf_mem_stall = ex_valid && ex_is_bf && !ex_bf_reg_ea && !(mem_berr || exc_active) &&
                          !(bf_mem_run_r && mem_ack &&
                            (!bf_mem_phase_r && !bf_mem_mutates_r ||   // read done, non-mut
                              bf_mem_phase_r));                          // write done

    // PACK/UNPK memory FSM state registers (declared early for stall)
    logic        pack_mem_run_r;
    logic        pack_mem_phase_r;     // 0=read Ay, 1=write result to Ax
    logic        pack_mem_is_unpk_r;   // 1=UNPK, 0=PACK
    logic [31:0] pack_mem_src_r;       // captured read data
    logic [31:0] pack_mem_ay_addr_r;   // predecremented Ay address (read address)
    logic [31:0] pack_mem_ax_addr_r;   // predecremented Ax address (write address)
    logic [2:0]  pack_mem_ay_reg_r;    // Ay register number (for An update)
    logic [2:0]  pack_mem_ax_reg_r;    // Ax register number (for An update)
    logic [15:0] pack_mem_adj_r;       // adj immediate captured from ext word
    // Stall: active while FSM is running and not done (write ack ends it)
    logic pack_mem_stall;
    assign pack_mem_stall = ex_valid && (ex_is_pack || ex_is_unpk) && ex_is_pack_mem &&
                            !(mem_berr || exc_active) &&
                            !(pack_mem_run_r && pack_mem_phase_r && mem_ack);

    // RESET counter (declared early for stall / eu_reset_req)
    logic        reset_run_r;
    logic [10:0] reset_cnt_r;   // counts down from 2047 (512 ext cycles × 4 = 2048 internal ticks)
    assign eu_reset_req = reset_run_r;

    // ex_is_cas / ex_is_abcd_sbcd_mem — declared early (assigned at EX latch below)
    logic        ex_is_cas;
    logic [2:0]  ex_cas_du_reg;
    logic        ex_is_abcd_sbcd_mem;
    logic        ex_is_abcd_mem;

    // ex_is_cas2 and CAS2 extra fields — declared early for stall
    logic        ex_is_cas2;
    logic [2:0]  ex_cas2_du1_reg;
    logic [3:0]  ex_cas2_rn2_reg;
    logic [2:0]  ex_cas2_dc2_reg;
    logic [2:0]  ex_cas2_du2_reg;

    // CAS2 FSM registers (declared early for ex_mem_stall)
    logic        cas2_rd2_r;        // issuing read of M[Rn2]
    logic        cas2_get_du1_r;    // fetching Du1 from regfile (match path)
    logic        cas2_wr1_r;        // writing Du1 to M[Rn1]
    logic        cas2_get_du2_r;    // fetching Du2 from regfile
    logic        cas2_wr2_r;        // writing Du2 to M[Rn2]
    logic        cas2_dc1_wr_r;     // writing Dc1 ← rdata1 (mismatch path)
    logic        cas2_dc2_wr_r;     // writing Dc2 ← rdata2 (mismatch path), CCR fires
    logic        cas2_after_r;      // 1-cycle cooldown
    logic        cas2_active_r;     // overall FSM active flag
    logic        ex_cas2_done_r;    // blocks re-entry until EX advances
    logic [31:0] cas2_ea1_r;
    logic [31:0] cas2_ea2_r;
    logic [1:0]  cas2_siz_r;
    logic [31:0] cas2_rdata1_r;
    logic [31:0] cas2_rdata2_r;
    logic        cas2_z1_r;
    logic [31:0] cas2_du1_val_r;
    logic [31:0] cas2_du2_val_r;
    logic [2:0]  cas2_dc1_reg_r;
    logic [2:0]  cas2_dc2_reg_r;
    logic [4:0]  cas2_ccr_r;

    // CAS2 rd1 ack: initial read of M[Rn1] done via normal EX path
    logic        cas2_rd1_ack;
    assign cas2_rd1_ack = ex_valid && ex_is_cas2 && ex_is_mem_rd && mem_ack
                          && !cas2_active_r && !ex_cas2_done_r;

    // Sized comparison for CAS2 second comparison (during cas2_rd2_r ack)
    // rd_b_data = Dc2 (via rd_b override), mem_rdata = M[Rn2]
    logic cas2_rd2_z_w;
    assign cas2_rd2_z_w = (cas2_siz_r == 2'b10) ? (mem_rdata[15:0] == rd_b_data[15:0]) :
                          (cas2_siz_r == 2'b01) ? (mem_rdata[7:0]  == rd_b_data[7:0])  :
                                                   (mem_rdata        == rd_b_data);

    // general memory RMW state (declared early for ex_mem_stall)
    logic        mem_rmw_run_r;    // write phase of RMW active
    logic        mem_rmw_after_r;  // 1-cycle cooldown after write ack
    logic [31:0] mem_rmw_wdata_r;  // ALU/unit result captured at read ack
    logic [4:0]  mem_rmw_ccr_r;   // {X,N,Z,V,C} captured at read ack
    logic [31:0] mem_rmw_addr_r;   // EA captured at read ack (for write phase)
    logic        mem_rmw_read_ack;   // combinatorial: read phase just acked
    logic        mem_rmw_sr_wr_en;   // combinatorial: fire CCR on write ack
    logic        mem_rmw_an_wr_en;   // combinatorial: fire An update on write ack
    logic        cpsr_an_wr_en;      // cpSAVE -(An)/cpRESTORE (An)+ (Stage 6):
                                      // fire An's own fixed 4-byte auto-adjust
                                      // once, at cpsr_start_r (mirrors real
                                      // silicon's own EA-evaluation micro-step,
                                      // which happens before the transfer even
                                      // begins -- ex_an_upd_en/ex_an_delta are
                                      // already valid+stable by then and stay
                                      // so for the whole multi-cycle FSM, so
                                      // firing here vs. later makes no value
                                      // difference, just needs to fire exactly
                                      // once since ex_mem_stall blocks the
                                      // generic WB an_upd path throughout).
    logic        mem_rmw_ccr_en_r;   // registered: this RMW op updates CCR
    // Read ack: all referenced signals declared before this block.
    assign mem_rmw_read_ack = ex_valid && ex_is_mem_rmw && ex_is_mem_rd && mem_ack
                              && !mem_rmw_run_r && !mem_rmw_after_r && !ex_is_cas;
    // CCR fires from the captured mem_rmw_ccr_en_r flag (set at read ack).
    // ex_updates_ccr is NOT used here because dec_updates_ccr=0 for most RMW ops.
    assign mem_rmw_sr_wr_en = mem_rmw_run_r && mem_ack && mem_rmw_ccr_en_r;

    // MOVE memory→memory FSM — declared early for ex_mem_stall
    logic        move_mm_run_r;         // write phase active
    logic        move_mm_after_r;       // 1-cycle cooldown after write ack
    logic [31:0] move_mm_data_r;        // captured read data
    logic [31:0] move_mm_dst_addr_r;    // dst EA captured at read ack
    logic [1:0]  move_mm_siz_r;
    logic [4:0]  move_mm_ccr_r;         // {X,N,Z,0,0} captured at read ack
    logic        move_mm_dst_an_upd_r;  // dst An needs update at write ack
    logic [2:0]  move_mm_dst_an_reg_r;
    logic [31:0] move_mm_dst_an_new_r;
    logic        move_mm_read_ack;
    logic        move_mm_sr_wr_en;
    logic        move_mm_dst_an_wr_en;
    assign move_mm_read_ack    = ex_valid && ex_is_move_mm && ex_is_mem_rd && mem_ack
                                 && !move_mm_run_r && !move_mm_after_r;
    assign move_mm_sr_wr_en    = move_mm_run_r && mem_ack;
    assign move_mm_dst_an_wr_en = move_mm_run_r && mem_ack && move_mm_dst_an_upd_r;

    // CAS compare-and-swap FSM — declared early for ex_mem_stall
    logic        cas_get_du_r;
    logic        cas_write_r;
    logic        cas_after_r;
    logic        cas_z_r;
    logic [4:0]  cas_ccr_r;
    logic [31:0] cas_ea_r;
    logic [1:0]  cas_siz_r;
    logic [31:0] cas_rdata_r;
    logic [31:0] cas_du_val_r;
    logic [3:0]  cas_dc_reg_r;
    logic        cas_dc_wr_en;
    logic        cas_sr_wr_en;
    logic        cas_read_ack;
    logic        cas_active_r;    // 1 from first read-ack until FSM fully done
    logic        ex_cas_mem_done_r; // 1 after read acks until EX advances; blocks re-entry
    assign cas_dc_wr_en = cas_get_du_r && !cas_z_r;
    assign cas_sr_wr_en = (cas_get_du_r && !cas_z_r) || (cas_write_r && mem_ack);
    assign cas_read_ack = ex_valid && ex_is_cas && ex_is_mem_rd && mem_ack
                          && !cas_get_du_r && !cas_active_r && !ex_cas_mem_done_r;

    // ABCD/SBCD -(Ay),-(Ax) memory FSM — declared early for ex_mem_stall
    logic        bcds_run_r;
    logic [1:0]  bcds_phase_r;
    logic        bcds_is_abcd_r;
    logic [7:0]  bcds_src_r;
    logic [7:0]  bcds_dst_r;
    logic [31:0] bcds_ay_addr_r;
    logic [31:0] bcds_ax_addr_r;
    logic [2:0]  bcds_ay_reg_r;
    logic [2:0]  bcds_ax_reg_r;
    logic        bcds_stall;
    logic        bcds_sr_wr_en;
    logic        bcds_ay_wr_en, bcds_ax_wr_en;
    // Byte-sized -(An) on A7 steps by 2, not 1, to stay word-aligned.
    // (assigned further down, after ex_src_reg/ex_dst_reg are declared)
    logic [31:0] bcds_ay_step, bcds_ax_step;
    assign bcds_stall   = ex_valid && ex_is_abcd_sbcd_mem && !(mem_berr || exc_active) &&
                          !(bcds_run_r && bcds_phase_r == 2'd2 && mem_ack);
    assign bcds_sr_wr_en = ex_valid && ex_is_abcd_sbcd_mem &&
                           bcds_run_r && bcds_phase_r == 2'd2 && mem_ack;
    assign bcds_ay_wr_en = ex_valid && ex_is_abcd_sbcd_mem &&
                           bcds_run_r && bcds_phase_r == 2'd0 && mem_ack;
    assign bcds_ax_wr_en = ex_valid && ex_is_abcd_sbcd_mem &&
                           bcds_run_r && bcds_phase_r == 2'd1 && mem_ack;

    // MOVEM FSM state registers
    logic        movem_start_r;    // 1-cycle stall while waiting for An to appear in rd_b
    logic        movem_run_r;      // MOVEM bus sequence active
    logic        movem_load_r;     // 1=mem→reg load, 0=reg→mem store
    logic        movem_predec_r;   // -(An) predecrement mode
    logic        movem_postinc_r;  // (An)+ post-increment mode
    logic        movem_long_r;     // 1=longword, 0=word
    logic        movem_mask_hi_r;  // 1=extended EA mode; mask from ext[31:16], addr from ex_ea
    logic [15:0] movem_mask_r;     // remaining register mask (set bits = pending registers)
    logic [31:0] movem_addr_r;     // current bus address
    logic [2:0]  movem_an_r;       // base An register number for final An update

    // MOVEM combinatorial signals
    logic [3:0]  movem_bit_idx;    // lowest set bit of movem_mask_r (= current register)
    logic [15:0] movem_next_mask;  // movem_mask_r with current bit cleared
    logic [3:0]  movem_reg_sel;    // regfile index for current register (0-7=D0-D7, 8-15=A0-A7)
    logic [31:0] movem_step;       // address increment per register (4 or 2)
    logic        movem_last;       // this is the final register in the list
    logic [31:0] movem_an_final;   // final An value to write on completion

    // Priority encoder: lowest set bit in movem_mask_r (iterates MSB→LSB so last wins = LSB)
    always_comb begin
        movem_bit_idx = 4'd0;
        for (int mi = 15; mi >= 0; mi--)
            if (movem_mask_r[mi]) movem_bit_idx = 4'(unsigned'(mi));
    end

    // For predecrement: bit i → register (15-i); for others: bit i → register i
    // This correctly maps the reversed predec mask encoding to regfile selects.
    assign movem_reg_sel  = movem_predec_r ? (4'd15 - movem_bit_idx) : movem_bit_idx;
    assign movem_step     = movem_long_r ? 32'd4 : 32'd2;
    assign movem_next_mask = movem_mask_r & (movem_mask_r - 16'd1); // clear lowest set bit
    assign movem_last     = movem_run_r && mem_ack && (movem_next_mask == 16'h0);
    // Final An value: predec stays at current address; postinc = current + step
    assign movem_an_final = movem_predec_r  ? movem_addr_r
                                            : (movem_addr_r + movem_step);

    // MOVEP byte-interleaved FSM state — declared early for ex_mem_stall
    logic        movep_start_r;       // cycle 1: capture Dn/addr (ex_ea valid, rd_b_data valid)
    logic        movep_pre_r;         // cycle 2: movep_wr_byte_r stable; assert movep_run_r next
    logic        movep_run_r;         // bus sequence active
    logic        movep_load_r;        // 1=mem→Dn (load), 0=Dn→mem (store)
    logic        movep_long_r;        // 1=longword (4 bytes), 0=word (2 bytes)
    logic [1:0]  movep_byte_r;        // current byte index (0=first)
    logic [31:0] movep_addr_r;        // current byte address
    logic [2:0]  movep_dn_r;          // Dn number for writeback
    logic [31:0] movep_dn_val_r;      // captured Dn value for stores
    logic [31:0] movep_acc_r;         // accumulated load data
    logic        movep_last;          // final byte this cycle
    logic [7:0]  movep_wr_byte_r;     // pre-registered byte to send (avoids comb ordering issue)
    logic [31:0] movep_rd_acc_w;      // accumulator updated with current byte
    logic        movep_wr_en;         // register writeback for loads
    logic [31:0] movep_wr_data;
    logic [3:0]  movep_wr_sel;

    assign movep_last = movep_run_r && mem_ack &&
                        ((movep_long_r && movep_byte_r == 2'd3) ||
                         (!movep_long_r && movep_byte_r == 2'd1));

    always_comb begin
        movep_rd_acc_w = movep_acc_r;
        if (movep_run_r && mem_ack && movep_load_r) begin
            case ({movep_long_r, movep_byte_r})
                3'b000: movep_rd_acc_w = {movep_acc_r[31:16], mem_rdata[7:0], movep_acc_r[7:0]};
                3'b001: movep_rd_acc_w = {movep_acc_r[31:8],  mem_rdata[7:0]};
                3'b100: movep_rd_acc_w = {mem_rdata[7:0],     movep_acc_r[23:0]};
                3'b101: movep_rd_acc_w = {movep_acc_r[31:24], mem_rdata[7:0], movep_acc_r[15:0]};
                3'b110: movep_rd_acc_w = {movep_acc_r[31:16], mem_rdata[7:0], movep_acc_r[7:0]};
                3'b111: movep_rd_acc_w = {movep_acc_r[31:8],  mem_rdata[7:0]};
                default: movep_rd_acc_w = movep_acc_r;
            endcase
        end
    end

    assign movep_wr_en   = movep_last && movep_load_r;
    assign movep_wr_data = movep_rd_acc_w;
    assign movep_wr_sel  = {1'b0, movep_dn_r};

    // MOVE16 16-byte block move FSM — declared early for ex_mem_stall
    logic        move16_start_r;
    logic        move16_run_r;
    logic        move16_phase_r;       // 0=read from src, 1=write to dst
    logic [1:0]  move16_beat_r;
    logic [31:0] move16_src_r;         // current read address
    logic [31:0] move16_dst_r;         // current write address
    logic [31:0] move16_src_base_r;    // captured src base for postinc calc
    logic [31:0] move16_dst_base_r;    // captured dst base for postinc calc
    logic [31:0] move16_data_r [0:3];  // read data buffer
    logic [1:0]  move16_form_r;
    logic        move16_src_postinc_r;
    logic        move16_dst_postinc_r;
    logic [2:0]  move16_src_an_r;
    logic [2:0]  move16_dst_an_r;
    logic        move16_an2_wr_r;      // deferred dst An postinc write

    logic        move16_last;
    logic [31:0] move16_wdata_w;
    assign move16_last = move16_run_r && move16_phase_r && (move16_beat_r == 2'd3) && mem_ack;

    // FPU dispatch FSM state — declared early for ex_mem_stall
    logic        fpu_start_r;      // one-cycle setup after instr_ack
    logic        fpu_run_r;        // eu_coproc_req active, waiting for ack
    logic [2:0]  fpu_prim_r;       // captured ppp = {f_dir, f_ss} for address generation

    // BKPT breakpoint-acknowledge FSM (Phase 157 Stage 3) — declared early for ex_mem_stall
    logic        bkpt_start_r;     // one-cycle setup after instr_ack
    logic        bkpt_run_r;       // eu_bkpt_req active, waiting for ack/berr
    logic [2:0]  bkpt_num_r;       // captured breakpoint number (f_reg)
    logic [15:0] bkpt_replacement_r; // captured replacement opcode word (DSACK'd outcome)
    // open-items backlog Stage 13 (plan.md): live opcode substitution.
    // bkpt_wait_replacement_r bridges the 1-cycle gap between
    // bkpt_replacement_r's own registered write (the same edge
    // bkpt_run_r clears) and it actually being readable; bkpt_subst_active_r
    // is then 1 for exactly the one decode cycle the IFU should present
    // bkpt_replacement_r instead of its own q[0] as instr_word.
    logic        bkpt_wait_replacement_r;
    logic        bkpt_subst_active_r;

    // cpSAVE/cpRESTORE dispatch FSM (Phase 157 Stage 4) — declared early for ex_mem_stall
    logic        cpsr_start_r;     // one-cycle setup after instr_ack
    logic        cpsr_run_r;       // eu_coproc_req active, waiting for ack (shared w/ FPU) --
                                    // cpSAVE only: reading the Save CIR, retrying in place
                                    // while the returned format is NOT_READY. cpRESTORE's
                                    // own first real step is cpsr_mem_fmt_r (its own format
                                    // word comes from MEMORY first, not a CIR read).
    logic        cpsr_is_restore_r; // 0=cpSAVE (Save CIR), 1=cpRESTORE (Restore CIR)
    logic [15:0] cpsr_fmt_r;       // captured format word (format code in [15:8], length in [7:0])
    // open-items backlog Stage 14 (plan.md): real format-word-driven transfer
    // protocol (Section 10.2.3); deferred-items closure plan Stage 6
    // (plan.md) widened this from (An)-only to also cover each instruction's
    // own one remaining architecturally-valid mode (-(An) for cpSAVE,
    // (An)+ for cpRESTORE) -- see the decode block's own comment
    // (dec_is_cpsave/dec_is_cprestore) for the full scope boundary.
    // cpsr_real_r gates the whole extended FSM below; every other EA mode
    // keeps falling through to the original Phase 157 Stage 4 stub (one CIR
    // read, then complete) via the unchanged cpsr_run_r->done path.
    logic        cpsr_real_r;       // captured at dispatch: (An) always, plus
                                     // -(An) for cpSAVE / (An)+ for cpRESTORE
    logic        cpsr_mem_fmt_r;    // cpSAVE: write format longword to EA;
                                     // cpRESTORE: read format longword from EA
    logic        cpsr_cir_wr_r;     // cpRESTORE only: write format word to Restore CIR
    logic        cpsr_cir_echo_r;   // cpRESTORE only: re-read Restore CIR (echo/confirm)
    logic        cpsr_abort_r;      // write $0001 abort mask to Control CIR, then format error
    logic        cpsr_xfer_cir_r;   // transfer loop: Operand CIR access (rd for save, wr for restore)
    logic        cpsr_xfer_mem_r;   // transfer loop: memory access (wr for save, rd for restore)
    logic [7:0]  cpsr_len_r;        // byte length from format word (multiple of 4)
    logic [7:0]  cpsr_xfer_cnt_r;   // bytes transferred so far in the loop
    logic [31:0] cpsr_xfer_addr_r;  // current transfer address (descending for save,
                                     // ascending for restore)
    logic [31:0] cpsr_xfer_val_r;   // value in flight between CIR and memory
    // Deferred-items closure plan Stage 6 (plan.md): ex_ea is NOT a frozen
    // snapshot -- it's recomputed live every cycle from rd_a_data (An's own
    // CURRENT register value), unlike e.g. mem_rmw's own tas_addr-style
    // registers. cpsr_an_wr_en (below) commits -(An)/(An)+'s own register
    // update as early as cpsr_start_r, well before ex_ea's own last real
    // use (the format-word bus access, and cpsr_xfer_addr_r's own
    // computation) -- so ex_ea itself would silently go stale (reflecting
    // the ALREADY-updated An) by the time those later phases read it.
    // cpsr_ea_r captures the correct, pre-update ex_ea once, at the same
    // cpsr_start_r transition the register commit itself fires on (see
    // cpsr_an_wr_en's own comment) -- every later cpsr_* use of the
    // instruction's own effective address reads this instead of ex_ea
    // directly.
    logic [31:0] cpsr_ea_r;
    // one-shot format-error trigger (same shape as chk_trap_raw/chk_trap_fired_r,
    // Phase 202 -- prevents ex_will_except's own OR-list from re-firing every
    // tick cpsr_abort_r's own multi-cycle CIR write is in flight). cpsr_abort_r
    // and eu_coproc_ack (the only two inputs cpsr_fmt_err_raw's own assign
    // needs, written further down near the main FSM) are both already
    // early-available (a plain logic reg and a port respectively), so unlike
    // chk_trap_raw this signal never actually needs the split -- declared
    // here anyway, mirroring the established convention for consistency.
    logic        cpsr_fmt_err_raw, cpsr_fmt_err_fired_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                cpsr_fmt_err_fired_r <= 1'b0;
        else if (!ex_valid)        cpsr_fmt_err_fired_r <= 1'b0;
        else if (cpsr_fmt_err_raw) cpsr_fmt_err_fired_r <= 1'b1;
    end
    // Gated one-shot pulse, mirroring chk_trap's own shape exactly.
    wire cpsr_fmt_err_w = cpsr_fmt_err_raw && !cpsr_fmt_err_fired_r;

    // MMU instruction FSM state — declared early for ex_mem_stall
    logic        pflush_start_r, pflush_req_r;
    logic        pflush_all_r;
    logic [2:0]  pflush_fc_r;
    logic [31:0] pflush_va_r;
    logic        ptest_start_r, ptest_run_r;
    logic [31:0] ptest_va_r;
    logic [2:0]  ptest_fc_r;
    logic        pload_start_r, pload_run_r;   // Phase 150 Stage 5
    logic [31:0] pload_va_r;
    logic [2:0]  pload_fc_r;
    logic        pload_rw_r;
    // MMU control registers (internal to EU)
    logic [31:0] tc_r   = 32'h0;
    logic [31:0] tt0_r  = 32'h0;
    logic [31:0] tt1_r  = 32'h0;
    logic [15:0] mmusr_r = 16'h0;

    // memory-indirect EA FSM state — declared early for ex_mem_stall
    logic        memind_start_r;       // 1 cycle: An/Xn available in rd_a/rd_b
    logic        memind_inner_r;       // inner longword read in progress
    logic        memind_outer_r;       // outer instruction-sized read in progress
    logic [31:0] memind_inner_addr_r;  // inner bus address
    logic [31:0] memind_ptr_r;         // pointer value from inner read
    logic [31:0] memind_od_r;          // outer displacement
    logic [31:0] memind_post_xn_r;     // scaled Xn for post-indexed outer EA
    logic        memind_is_rd_r;       // memory-indirect outer access is always a read
    logic [1:0]  memind_siz_r;         // transfer size for outer read
    logic [3:0]  memind_dest_r;        // destination register for outer read WB
    // 10-item backlog Stage 9a (plan.md): LEA ([bd,An],Xn,od),Am never
    // dereferences its own final EA (LEA/PEA never access memory at the
    // address they compute, per real 68030 semantics) -- unlike MOVE's own
    // memind arm, which needs a full outer bus cycle to load a VALUE from
    // the resolved address. Set for LEA's own memind dispatch only; skips
    // memind_outer_r entirely and completes with a direct register write
    // the same cycle the inner (pointer) read's own ack arrives, using
    // mem_rdata (the just-arrived pointer) + memind_post_xn_r + memind_od_r
    // as the write value -- see memind_addr_wr_en below.
    logic        memind_addr_only_r;
    // 10-item backlog Stage 9a (plan.md): PEA ([bd,An],Xn,od) -- unlike
    // LEA, PEA DOES need a real outer bus cycle (it pushes the resolved EA
    // to the stack), but that cycle is a WRITE at the stack address, not a
    // READ at the resolved address like MOVE's own case. memind_outer_r is
    // reused for this (still a real bus cycle, just repurposed), gated by
    // this flag for the mem_addr/mem_wdata/mem_rw selection. memind_is_rd_r
    // is set to 0 (write) for this case at dispatch time.
    logic        memind_is_pea_r;
    // A7-4 (the push address) captured at dispatch time, same cycle as
    // memind_inner_addr_r -- ex_cur_sp itself isn't safe to re-read later
    // in the sequence (the predecrement's own an_wr_en, wired independently
    // via dec_an_upd_en, can retire before the outer write phase runs).
    logic [31:0] memind_pea_wr_addr_r;
    // 10-item backlog Stage 9b (plan.md): JSR ([bd,An],Xn,od) -- same
    // outer-write shape as PEA (reuses memind_pea_wr_addr_r, the push
    // address is identical: ex_cur_sp-4), but the VALUE pushed is the
    // return PC, not the resolved EA -- the resolved EA becomes the jump
    // target instead, once the outer write itself completes.
    logic        memind_is_jsr_r;
    always_comb begin
        case (move16_beat_r)
            2'd0: move16_wdata_w = move16_data_r[0];
            2'd1: move16_wdata_w = move16_data_r[1];
            2'd2: move16_wdata_w = move16_data_r[2];
            2'd3: move16_wdata_w = move16_data_r[3];
        endcase
    end

    // CMP2/CHK2 two-read FSM state — declared early for ex_mem_stall
    logic        cmp2_run_r;        // second read in progress
    logic        cmp2_after_r;      // 1-cycle cooldown after second read ack
    logic [31:0] cmp2_lb_r;         // lower bound captured from first read
    logic [31:0] cmp2_addr2_r;      // address for second read (EA + size_step)
    logic        cmp2_is_chk2_r;    // 1=CHK2 (trap on range fail), 0=CMP2
    logic        cmp2_is_an_r;      // 1=Rn is An (always 32-bit compare)
    logic [1:0]  cmp2_siz_r;        // instruction size for sign extension
    logic        cmp2_first_ack;    // first read just acked — hold stall while FSM starts
    logic        cmp2_sr_wr_en;     // fire CCR update when second read acks

    // CMP2/CHK2 sign-extended comparison values (combinational from FSM state + mem_rdata)
    // rd_b_data (not a registered cmp2_rn_r) feeds Rn directly: cmp2_sr_wr_en
    // fires the exact same cycle dyn_bit_get_Dn's swap delivers Rn onto
    // rd_b (Phase 120 -- see dyn_bit_get_Dn's own comment above), and a
    // non-blocking-assignment register capture on that same cycle would
    // read the *previous* cycle's stale value (classic same-edge
    // read-before-write) -- consuming rd_b_data live sidesteps that
    // entirely, since it's already valid combinationally this cycle.
    logic [31:0] cmp2_lb_sext_w, cmp2_ub_sext_w, cmp2_rn_sext_w;
    logic        cmp2_c_w, cmp2_z_w;
    always_comb begin
        case (cmp2_siz_r)
            2'b01: begin  // byte
                cmp2_lb_sext_w = {{24{cmp2_lb_r[7]}},  cmp2_lb_r[7:0]};
                cmp2_ub_sext_w = {{24{mem_rdata[7]}},   mem_rdata[7:0]};
                cmp2_rn_sext_w = cmp2_is_an_r ? rd_b_data : {{24{rd_b_data[7]}},  rd_b_data[7:0]};
            end
            2'b10: begin  // word
                cmp2_lb_sext_w = {{16{cmp2_lb_r[15]}}, cmp2_lb_r[15:0]};
                cmp2_ub_sext_w = {{16{mem_rdata[15]}},  mem_rdata[15:0]};
                cmp2_rn_sext_w = cmp2_is_an_r ? rd_b_data : {{16{rd_b_data[15]}}, rd_b_data[15:0]};
            end
            default: begin  // long
                cmp2_lb_sext_w = cmp2_lb_r;
                cmp2_ub_sext_w = mem_rdata;
                cmp2_rn_sext_w = rd_b_data;
            end
        endcase
        cmp2_c_w = ($signed(cmp2_rn_sext_w) < $signed(cmp2_lb_sext_w)) ||
                   ($signed(cmp2_rn_sext_w) > $signed(cmp2_ub_sext_w));
        cmp2_z_w = (cmp2_rn_sext_w == cmp2_lb_sext_w) || (cmp2_rn_sext_w == cmp2_ub_sext_w);
    end

    // pmove64_run_r/skip declared early for ex_mem_stall (FSM body is below)
    logic pmove64_run_r;
    logic pmove64_skip_r;  // burns the stale ack from the old address at phase-1 start

    logic rtr_stall, rte_stall, ex_mem_stall;
    // (mem_berr || exc_active) spelled out — see addx_mem_stall's own
    // comment further down for why (forward-reference / must include
    // exc_active, not just mem_berr).
    assign rtr_stall    = ex_is_rtr && !(mem_berr || exc_active) && !(rtr_phase_r && mem_ack);
    assign rte_stall    = ex_is_rte && !(mem_berr || exc_active) && !(rte_phase_r && mem_ack) && !eu_fmt_err_req;

    // open-items backlog Stage 13 (plan.md), Bug 2 fix: JSR/BSR/RTS/RTR/RTE
    // all occupy EX for one or more cycles WAITING on their own push/pop
    // mem_ack before the redirect/flush actually lands. During that
    // window, decode has *already* moved on (dec_valid/instr_word reflect
    // q[0] combinationally, independent of whether the older EX-stage
    // instruction has committed) -- so decode can be looking at the
    // STALE, pre-redirect "fall-through" instruction slot, which is about
    // to be discarded once the pending redirect resolves. Every OTHER
    // instruction type is naturally immune to this (their own dispatch
    // trigger requires instr_ack, which requires !stall, so they never
    // commit until AFTER stall_base clears). BKPT's own early trigger
    // (see the ex_mem_stall term below) is the first mechanism in this
    // project to react to dec_valid alone, specifically because instr_ack
    // can never fire for a raw BKPT opcode -- which also makes it the
    // first mechanism exposed to this stale-slot race. Confirmed via
    // direct trace (Bug 2 investigation): a genuine JSR (A0) Harte test
    // hung because BKPT's own early trigger fired on the fall-through
    // word immediately after JSR's own opcode (a word gen_harte_hex.py
    // deliberately patches into memory to match the reference CPU's own
    // real prefetch-queue content for that test -- not stale batch-mode
    // memory carryover; this can happen in ANY run, single-process or
    // batched, whenever the IFU's own linear readahead reaches it before
    // an older control-transfer's own redirect lands).
    //
    // First attempt excluded only "still waiting for mem_ack" (via an
    // explicit !mem_ack-style check per instruction) and left the exact
    // ack/redirect cycle itself unguarded -- still hung, because
    // m68030_ifu.sv's own q_cnt<=0 flush (on pc_wr_en, itself driven
    // combinationally from branch_taken/ex_jsr_taken etc. this same
    // cycle) only takes effect on the FOLLOWING clock edge: on the exact
    // cycle mem_ack arrives and the redirect fires, decode is STILL
    // looking at the old, pre-flush q[0] one more time. Confirmed via
    // trace: the hang reproduced with ex_valid=1/ex_is_jsr=1/mem_ack=1
    // (JSR's OWN redirect firing) on the exact same cycle BKPT's early
    // trigger fired too.
    //
    // Fixed via branch_taken (a port, so no forward-reference concern --
    // covers Bcc/JMP/DBcc, all of which resolve unconditionally the same
    // cycle they'd otherwise race this exact way, as well as the redirect
    // cycle itself for JSR/BSR/RTS/RTR/RTE) OR'd with a plain "one of
    // JSR/BSR/RTS/RTR/RTE is anywhere in EX" check (covers their own
    // multi-cycle wait BEFORE mem_ack arrives, in addition to the
    // redirect cycle branch_taken already covers). Both terms clear on
    // the exact same clock edge m68030_ifu.sv's own q_cnt<=0 takes
    // effect (ex_valid/ex_is_X latch from dec_valid, which by then
    // already reflects the flushed/empty queue), so there's no residual
    // gap between "guard lifts" and "IFU catches up".
    logic ex_redirect_pending;
    assign ex_redirect_pending = branch_taken ||
        (ex_valid && (ex_is_jsr || ex_is_bsr || ex_is_rts || ex_is_rtr || ex_is_rte));
    // cmpm_stall declared above (near CMPM state registers)
    // tas_read_ack: hold pipeline stall on the cycle the TAS read ack fires (before
    // tas_run_r becomes 1) so EX doesn't release prematurely. Gated by !tas_after_write_r
    // to prevent re-triggering after the write phase completes.
    assign tas_read_ack = ex_valid && ex_is_tas && ex_is_mem_rd && mem_ack
                          && !tas_run_r && !tas_after_write_r;
    // cmp2_first_ack: holds stall when first read of CMP2/CHK2 acks, before cmp2_run_r=1
    assign cmp2_first_ack = ex_valid && ex_is_cmp2chk2 && ex_is_mem_rd && mem_ack
                            && !cmp2_run_r && !cmp2_after_r;
    // cmp2_sr_wr_en: combinational CCR update from CMP2/CHK2 second read
    assign cmp2_sr_wr_en  = cmp2_run_r && mem_ack;
    // During cmp2_after_r and tas_after_write_r cooldowns, suppress bus req and mem-wait
    // stall so EX can advance cleanly without a spurious bus cycle.
    //
    // mem_abort: the real abort trigger for every in-flight memory-op FSM
    // below (generic read/write, TAS, MOVEM, CAS2, ...) — not just mem_berr
    // on its own. mem_ack/mem_berr are both forced to 0 for the EU the
    // instant exc_active fires (m68030_top's arbiter mux masks biu_eu_req
    // out entirely once exc_active=1), so a fault detected via a different
    // path (e.g. the IFU, which has its own independent, already-working
    // berr recognition) can win the race and set exc_active *before* the
    // EU's own mem_berr pulse for its in-flight access ever arrives —
    // confirmed empirically via trace: exc_active could be seen asserted
    // for many cycles with mem_berr never once true in that entire window,
    // permanently starving an mem_berr-only abort condition. exc_active
    // itself is the correct, independent "give up now" signal regardless
    // of which path detected the fault.
    wire mem_abort = mem_berr || exc_active;
    assign ex_mem_stall = tas_run_r || tas_read_ack || movem_start_r || movem_run_r ||
                          movep_start_r || movep_pre_r || movep_run_r ||
                          move16_start_r || move16_run_r ||
                          fpu_start_r || fpu_run_r ||
                          bkpt_start_r || bkpt_run_r || bkpt_wait_replacement_r ||
                          // open-items backlog Stage 13 (plan.md): a raw,
                          // just-recognized BKPT opcode must stall the
                          // SAME cycle it's first decoded -- otherwise
                          // instr_ack fires immediately (bkpt_start_r
                          // isn't set until the NEXT edge), letting the
                          // IFU drain past BKPT's own slot before the
                          // substitution FSM even starts, corrupting the
                          // instruction stream once the real replacement
                          // finally arrives (confirmed via direct trace,
                          // not guessed at -- decode_pc had already
                          // advanced past BKPT's own address while
                          // bkpt_run_r was still 1).
                          //
                          // Bug 2 fix (see ex_redirect_pending's own
                          // declaration/comment near ex_jsr_taken etc.):
                          // also require !ex_redirect_pending -- while an
                          // older JSR/BSR/RTS/RTR/RTE is still waiting on
                          // its own mem_ack, the "current" decode slot can
                          // be a stale fall-through word about to be
                          // flushed by that instruction's own pending
                          // redirect; don't let a spurious BKPT-shaped
                          // match on that stale word stall/dispatch here.
                          (dec_valid && dec_is_bkpt && !bkpt_start_r && !bkpt_run_r &&
                           !bkpt_wait_replacement_r && !bkpt_subst_active_r &&
                           !ex_redirect_pending) ||
                          cpsr_start_r || cpsr_run_r ||
                          cpsr_mem_fmt_r || cpsr_cir_wr_r || cpsr_cir_echo_r ||
                          cpsr_abort_r || cpsr_xfer_cir_r || cpsr_xfer_mem_r ||
                          memind_start_r || memind_inner_r || memind_outer_r ||
                          pflush_start_r || pflush_req_r ||
                          ptest_start_r  || ptest_run_r  ||
                          pload_start_r  || pload_run_r  ||
                          cmp2_run_r || cmp2_first_ack ||
                          mem_rmw_run_r || mem_rmw_read_ack ||
                          move_mm_run_r || move_mm_read_ack ||
                          addx_mem_stall || bf_mem_stall || pack_mem_stall ||
                          cas_read_ack || cas_active_r || cas_write_r || cas_after_r || bcds_stall ||
                          cas2_rd1_ack || cas2_active_r ||
                          pmove64_run_r ||
                          (!tas_after_write_r && !cmp2_run_r && !cmp2_after_r &&
                           !memind_start_r && !memind_inner_r && !memind_outer_r &&
                           !mem_rmw_run_r && !mem_rmw_after_r && !pmove64_run_r &&
                           !move_mm_run_r && !move_mm_after_r &&
                           !cas_get_du_r && !cas_write_r && !cas_after_r && !ex_cas_mem_done_r &&
                           !cas2_rd2_r && !cas2_get_du1_r && !cas2_wr1_r &&
                           !cas2_get_du2_r && !cas2_wr2_r && !cas2_dc1_wr_r && !cas2_dc2_wr_r &&
                           !cas2_after_r && !ex_cas2_done_r &&
                           (ex_is_mem_rd || ex_is_mem_wr) && !mem_ack && !mem_abort) ||
                          rtr_stall || rte_stall || cmpm_stall || stop_r || reset_run_r;

    // ex_berr_abort_wb: true the cycle *after* a fault collapses ex_mem_stall
    // back to 0 (registered, since ex_mem_stall's own drop and this check
    // happen one cycle apart). Without this, the WB latch below would treat
    // a berr-aborted memory op exactly like a successful one on the very
    // next cycle (its "else" branch unconditionally captures ex_valid/
    // ex_writes_reg the instant ex_mem_stall drops, with no way to tell a
    // clean completion from an abort) — committing a phantom register write
    // with garbage/stale data for an instruction that never actually
    // completed. One shared guard for every ex_mem_stall-driven FSM
    // (generic read/write, TAS, MOVEM, CAS2, ...) rather than duplicating
    // WB-suppression logic in each one individually.
    logic ex_mem_stall_r, mem_abort_r, ex_berr_abort_wb;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_stall_r <= 1'b0;
            mem_abort_r    <= 1'b0;
        end else begin
            ex_mem_stall_r <= ex_mem_stall;
            mem_abort_r    <= mem_abort;
        end
    end
    assign ex_berr_abort_wb = ex_mem_stall_r && mem_abort_r;

    // ex_internal_stall: artificial extra hold cycles for register-only
    // instructions whose real 68030 microcode genuinely takes longer than
    // this pipeline's own 1-cycle combinational EX (Phase 162, plan.md).
    // Confirmed empirically (Stage D0) that the gap for these instructions
    // is flat per instruction class, not scaling with a runtime shift
    // count or bit-field width/scan depth -- so this is a fixed-N-ticks
    // lookup keyed on decode-time classification, not a value-dependent
    // microsequencer. Reuses ex_mem_stall's own proven freeze semantics
    // (EX latches held unchanged, WB bubbled) rather than inventing a new
    // pipeline-control shape -- see the ex_mem_stall/ex_berr_abort_wb
    // block just above for the pattern this mirrors.
    //
    // dec_internal_stall_ticks_fixed / ex_internal_stall_ticks_resolved are
    // both in real clk_4x ticks (4 ticks = 1 external/"manual" clock,
    // matching every other timing figure in this project).
    //
    // Stage D2 (plan.md): first real whitelist entries -- shift/rotate
    // register forms. N derived from scripts/timing_tables.py's own
    // SHIFT_ROTATE NCC values, minus this project's own already-measured
    // 3-clock (12-tick) baseline for a 1-word register-direct instruction
    // (confirmed uniform across this whole family: Stage D0's own LSL/
    // BFFFO spot-checks plus a direct ROL.L Dx,Dy check before this stage,
    // all measuring the identical baseline regardless of shift count or
    // scan depth/width).
    //
    // Two computation paths, because the manual's own row for a given op
    // sometimes depends on the register-supplied COUNT (the "%"=count<=
    // operand-size vs "+"=count>size split for LSL/LSR/ASR), and that
    // count isn't known until the register file read resolves -- the same
    // timing shf_count itself already has (rd_b_data-derived, valid once
    // ex_valid=1, not at decode time). ASL/ROL/ROR have no such split (a
    // single flat NCC value in the manual regardless of count) and so can
    // be decided purely combinationally at decode time; ROXL/ROXR's own
    // single "ROXd Dn" row applies identically whether the count comes
    // from an immediate or a register (no separate rows exist), so it's
    // also decode-time-only via dec_shf_imm_cnt/dec_use_reg_cnt requiring
    // no distinction at all.
    // "+1clk recal" (this file-wide): every constant below was originally
    // calibrated as manual_NCC_ticks - empirically_measured_baseline, which
    // exactly cancels this RTL's own genuine, unfixable +1 clock dispatch
    // floor (traced and confirmed real -- see plan.md's own writeup: an
    // isolated instruction has no predecessor bus activity to overlap its
    // own opcode fetch with, and MC68030UM.pdf Section 11.3.3 explicitly
    // states its own "two clock periods per bus cycle" NCC model assumes
    // overlap with a PREVIOUS instruction, never available in isolation).
    // Un-padded instructions like plain register-direct ADD show this
    // floor honestly as a measured +1 gap; every stall-padded instruction
    // here was silently absorbing the identical floor into its own
    // calibration instead, reporting a misleadingly-exact 0. Recalibrated
    // uniformly (+4 ticks = +1 clock on every constant) so every
    // instruction in this whitelist now reports the same honest +1 gap as
    // an unpadded one -- a reporting-consistency change only, not a
    // hardware-accuracy fix (the +1 floor itself remains, matching every
    // other instruction in the corpus).
    // Widened from [7:0] to [15:0] (MUL/DIV timing investigation, plan.md):
    // DIVS.L's own gap (manual NCC=90, this RTL's eu_mul_div.sv computing
    // it purely combinationally in ~3 clocks) needs a 352-tick stall,
    // exceeding the old 8-bit field's own 255-tick ceiling -- every prior
    // entry (largest: BFFFO at 72 ticks) fit comfortably under that limit,
    // so this was never hit until now.
    logic [15:0] dec_internal_stall_ticks_fixed;
    always_comb begin
        dec_internal_stall_ticks_fixed = 16'd0;
        // dec_unit==UNIT_SHF also covers the memory-EA (single-bit) shift
        // form (dec_is_mem_rmw=1, e.g. "ASL.W (An)") -- that form's own
        // manual row is fea/cea-based (bus-cycle-driven, already exact via
        // Stage A1/A4), not the register-direct NCC row this stall
        // whitelist targets, so it must stay excluded here.
        if (dec_valid && dec_unit == UNIT_SHF && !dec_is_mem_rmw) begin
            case (dec_shf_op)
                SHF_ASL: dec_internal_stall_ticks_fixed =
                    dec_use_reg_cnt ? 8'd24 : 8'd8; // +1clk recal: reg:NCC=8+1clk=6clk=24t; imm:NCC=4+1clk=2clk=8t
                SHF_ASR: if (!dec_use_reg_cnt) dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: imm:NCC=4+1clk=2clk=8t (reg form via resolve, below)
                SHF_LSL, SHF_LSR: if (!dec_use_reg_cnt) dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: imm:NCC=4+1clk=2clk=8t (reg form via resolve)
                SHF_ROL, SHF_ROR: dec_internal_stall_ticks_fixed =
                    dec_use_reg_cnt ? 8'd24 : 8'd16; // +1clk recal: reg:NCC=8+1clk=6clk=24t; imm:NCC=6+1clk=4clk=16t
                SHF_ROXL, SHF_ROXR: dec_internal_stall_ticks_fixed = 8'd40; // +1clk recal: NCC=12+1clk=10clk=40t (imm or reg, one row)
                default: ;
            endcase
        end
        // Stage D4 (plan.md): a handful of other simple register-direct
        // instructions with small (1-3 clock), flat, decode-time-only
        // gaps -- EXG/MOVE CCR,Dn/MOVE SR,Dn/SWAP, all confirmed to share
        // the same 3-clock (12-tick) baseline as every other 1-word
        // register-direct instruction (Stage D0's own established
        // pattern), each needing just N=(manual-3)*4 ticks.
        if (dec_valid) begin
            if (dec_is_exg)          dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: EXG NCC=4+1clk=8t
            else if (dec_is_move_ccr_r) dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: MOVE CCR,Dn NCC=4+1clk=8t
            else if (dec_is_move_sr_r)  dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: MOVE SR,Dn NCC=4+1clk=8t
            else if (dec_is_swap)    dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: SWAP Dn NCC=4+1clk=8t
        end
        // Stage D5 (plan.md): the remaining small (-1/-3) register-only
        // negative-gap entries left after D2-D4 -- ABCD/SBCD Dn,Dn, EXT,
        // Scc Dn, TAS Dn all share the same 1-word/3-clock baseline as
        // D4's own flat entries above (each needs just +1 clock = 4
        // ticks); NBCD Dn and dynamic BCHG/BCLR/BSET Dn,Dn both need +3
        // clocks = 12 ticks instead (their own manual NCC=6, vs these
        // others' NCC=4). Each condition below is deliberately built from
        // the one signal (or signal combination) that's already proven,
        // by direct code inspection, to exclude that op's own MEMORY-
        // destination sibling -- e.g. dec_is_abcd_sbcd_mem/dec_is_mem_rd
        // are exactly the flags those memory forms set and the
        // register-direct forms never do (mirrors Stage D4's own
        // !dec_is_mem_rmw lesson: a shared dec_unit/dec_bcd_op/dec_bit_op
        // value alone is never enough on its own).
        if (dec_valid && dec_unit == UNIT_BCD && !dec_is_abcd_sbcd_mem) begin
            case (dec_bcd_op)
                BCD_ADD: dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: ABCD Dn,Dn NCC=4+1clk=8t
                BCD_SUB: dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: SBCD Dn,Dn NCC=4+1clk=8t
                BCD_NEG: if (!dec_is_mem_rd) dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: NBCD Dn NCC=6+1clk=4clk=16t
                default: ;
            endcase
        end
        if (dec_valid && dec_sext)     dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: EXT.W/EXT.L/EXTB.L NCC=4+1clk=8t
        if (dec_valid && dec_is_scc_dn) dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: Scc Dn NCC=4+1clk=8t
        if (dec_valid && dec_is_tas && !dec_is_mem_rd)
            dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: TAS Dn NCC=4+1clk=8t
        if (dec_valid && dec_unit == UNIT_BIT && dec_bit_from_reg &&
            !dec_is_mem_rd && dec_writes_reg)
            dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: dynamic BCHG/BCLR/BSET Dn,Dn NCC=6+1clk=4clk=16t
        // Cycle-accuracy-closing plan.md, item 1: register-only "too fast"
        // regressions found via a fresh clock survey after Phase 163 Stage
        // 1's own ext_valid fix (documented there as "left for a possible
        // future extension of Part D's own work," never revisited until
        // now). All 5 confirmed via the survey's own "clean" (target's
        // destination IS the watched register, no marker-cost inflation)
        // subset -- a genuinely isolated, apples-to-apples measurement.
        //
        // BCHG/BCLR/BSET #(data),Dn (static bit-number, register dest):
        // scripts/timing_tables.py's own BIT_MANIP table gives all three an
        // identical NCC=6, matching the dynamic-register form's own already-
        // whitelisted uniform treatment just above -- `dec_writes_reg`
        // naturally excludes BTST (which doesn't write) the same way the
        // dynamic form's own entry does; BTST #(data),Dn has no clean-list
        // data point yet and is deliberately left untouched.
        if (dec_valid && dec_unit == UNIT_BIT && !dec_bit_from_reg &&
            !dec_is_mem_rd && dec_writes_reg)
            dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: BCHG/BCLR/BSET #(data),Dn NCC=6+1clk=4clk=16t
        // MOVEC Cr,Rn (read direction) -- decoded via a fixed opcode match
        // (16'h4E7A, mirrors the decode block's own comment: "Rc→Rn uses
        // dec_use_imm", so no dedicated dec_is_X flag exists for this
        // direction the way dec_is_movec/dec_movec_to_ctrl covers the write
        // direction) -- same re-derive-the-raw-opcode-check precedent as
        // every fixed-encoding entry elsewhere in this project.
        if (dec_valid && instr_word == 16'h4E7A)
            dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: MOVEC Cr,Rn NCC=6+1clk=4clk=16t
        // PACK/UNPK Dy,Dx,#(data) -- register form only (dec_is_pack_mem=0
        // is the memory -(Ay),-(Ax) form, already excluded); BCD_EXT table
        // gives PACK NCC=6, UNPK NCC=8, matching this project's own
        // separately-measured -3/-5 clean-list gaps exactly.
        if (dec_valid && dec_is_pack && !dec_is_pack_mem)
            dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: PACK Dy,Dx,#(data) NCC=6+1clk=4clk=16t
        if (dec_valid && dec_is_unpk && !dec_is_pack_mem)
            dec_internal_stall_ticks_fixed = 8'd24; // +1clk recal: UNPK Dy,Dx,#(data) NCC=8+1clk=6clk=24t
        // MOVE.B/W #(data),Dn -- re-derives the exact decode condition from
        // the MOVE/MOVEA block above (f_group∈{1,3} byte/word, dst=Dn,
        // f_mode=111/f_reg=100 immediate source) using only module-level
        // continuous-assign fields, same precedent as MOVEC's own raw-
        // opcode check. f_move_sz!=00 alone already implies f_group∈{1,3}
        // (its own definition maps every other group to 2'b00/long) so no
        // separate f_group check is needed, but f_move_dst_mode/f_mode/
        // f_reg are still required to avoid colliding with an unrelated
        // opcode that happens to share these same bit positions outside
        // groups 1/2/3. The long form (MOVE.L #(data),Dn, f_move_sz==00)
        // has no clean-list data point (a1_fea_imml is a POSITIVE +2 gap,
        // a different, not-yet-investigated mechanism -- item 2) and is
        // deliberately excluded here.
        if (dec_valid && f_move_sz != 2'b00 && f_move_dst_mode == 3'b000 &&
            f_mode == 3'b111 && f_reg == 3'b100)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: MOVE.B/W #(data),Dn NCC=4+1clk=2clk=8t
        // Cycle-accuracy-closing plan.md, item 3: 7 more register-only
        // "too fast" gaps, all newly surfaced by item 3's own marker-free
        // watch_kind=1/2 redesign (previously hidden -- with a trailing
        // marker instruction folded into the measured total, several of
        // these coincidentally landed on a POSITIVE gap that looked
        // already-fine, or simply had no clean data point at all). All
        // confirmed against the identical 3-clock/12-tick 1-word
        // register-direct baseline this whole whitelist already uses.
        if (dec_valid && dec_is_move_ccr_w)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: MOVE Dn,CCR NCC=4+1clk=2clk=8t
        // MOVE USP,An (read direction) -- dec_reads_usp is unique to this
        // one decode site (the write direction, MOVE An,USP, uses the
        // separate dec_is_move_usp flag instead).
        if (dec_valid && dec_reads_usp)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: MOVE USP,An NCC=4+1clk=2clk=8t
        // MOVE An,USP (write direction) -- timing-gaps-largest-first
        // plan, Stage 6. Same NCC=4 as the read direction above, mirrors
        // its own precedent exactly; dec_is_move_usp is set only for this
        // one instruction shape (no taken/not-taken split to worry about).
        if (dec_valid && dec_is_move_usp)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: MOVE An,USP NCC=4+1clk=2clk=8t
        // TRAPV, not-trapping path only (V=0 -> falls through, no
        // exception) -- timing-gaps-largest-first plan, Stage 6. Uses a
        // raw opcode match (mirrors MOVEC's own precedent above) rather
        // than dec_is_trapv, which this decode block deliberately only
        // sets for the TRAP-TAKEN case (see its own "trap if V flag set"
        // decode comment) -- gating on !flag_v here is the exact mirror-
        // image, guaranteeing this can never fire for the taken path
        // (a real exception dispatch, an entirely different and already
        // correctly-measured cost) or for TRAPcc (a different opcode
        // pattern, unaffected by this instr_word-specific match).
        if (dec_valid && instr_word == 16'h4E76 && !flag_v)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: TRAPV (no trap) NCC=4+1clk=2clk=8t
        // ADDA.W/SUBA.W/CMPA.W, register-direct source (Dn or An) --
        // dec_sext_src is set only for f_mode==000/001 (register-direct
        // source, sign-extended 16->32) among all three ops' own shared
        // decode block, per that block's own comment ("SUBA/ADDA .W
        // (f_dir=0)... CCR unchanged") -- naturally excludes the .L forms
        // (already accurate, dec_sext_src=!f_dir=0 there) and the memory-
        // EA/immediate-source forms (untested, different natural timing,
        // not touched here). All three ops confirmed to need the
        // identical correction, matching this whole family's own uniform
        // NCC=4 row.
        if (dec_valid && dec_sext_src)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: ADDA.W/SUBA.W/CMPA.W Rn,An NCC=4+1clk=2clk=8t
        // BTST #(data),Dn / BTST Dn,Dn -- dec_writes_reg=0 (BTST never
        // writes back) is what distinguishes this from the already-
        // whitelisted BCHG/BCLR/BSET entries above, which share the same
        // dec_unit==UNIT_BIT / dec_bit_from_reg split but always write.
        if (dec_valid && dec_unit == UNIT_BIT && dec_bit_op == BIT_TST && !dec_is_mem_rd)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: BTST #(data)/Dn,Dn NCC=4+1clk=2clk=8t
        // BFTST Dn -- the one bit-field register-form op (3'b000) the
        // Stage D3 whitelist above deliberately left out, per its own
        // "3'b000 = BFTST: see marker-overcounting note above" comment;
        // item 3's own watch_kind=2 redesign finally gives it a clean
        // data point instead of a marker-inflated one.
        if (dec_valid && dec_is_bf && dec_bf_reg_ea && dec_bf_op == 3'b000)
            dec_internal_stall_ticks_fixed = 8'd24; // +1clk recal: BFTST Dn NCC=8+1clk=6clk=24t
        // CHK Dn,Dn (no exception): re-enabled (Cycle-accuracy-closing
        // plan.md, Stage 2) now that `chk_trap` (below) is edge-triggered
        // via `chk_trap_fired_r` -- see that signal's own comment for the
        // full history. A first attempt at this same whitelist entry
        // (Phase 166) found `chk_trap`'s own pure-combinational condition
        // re-firing on every tick of the artificial stall (`chk_trap_cnt`
        // incremented 11x instead of 1x); with the one-shot latch in
        // place this is now safe. !dec_use_imm excludes the separate CHK
        // #(data),Dn form (untested, different baseline); !dec_is_mem_rd
        // excludes CHK's own memory-source forms.
        if (dec_valid && dec_is_chk && !dec_use_imm && !dec_is_mem_rd)
            dec_internal_stall_ticks_fixed = 8'd24; // +1clk recal: CHK Dn,Dn NCC=8+1clk=6clk=24t
        // LEA (An),An -- f_mode==3'b010 is LEA's own plain register-
        // indirect form specifically (the ONE-word, no-extension-word
        // shape matching this whole whitelist's shared baseline); LEA's
        // other EA modes (d16,An / indexed / abs / PC-relative) all need
        // an extension word and so have a structurally different natural
        // baseline already, not touched here.
        if (dec_valid && dec_is_lea && f_mode == 3'b010)
            dec_internal_stall_ticks_fixed = 8'd8; // +1clk recal: LEA (An),An NCC=4+1clk=2clk=8t
        // MUL/DIV timing investigation (plan.md): DIVS.L/DIVU.L/MULS.L/
        // MULU.L Dr,Dq (32x32/32<-64/32, register-direct source only).
        // eu_mul_div.sv is explicitly documented "purely combinational" --
        // it computes the full multiply/divide in this pipeline's own
        // single-cycle EX stage (plain HDL */÷ operators), while real
        // 68030 microcode runs a genuinely serial (non-restoring) divide/
        // multiply algorithm taking dozens of real clocks -- by far the
        // largest gap of this whole whitelist mechanism's history (DIVS.L
        // alone needs an 88-clock stall, exceeding every prior entry's
        // own headroom combined, which is why dec_internal_stall_ticks_
        // fixed/internal_stall_cnt_r were both widened from 8 to 16 bits
        // to hold it -- see those signals' own declaration comments).
        // Measured baseline (empirically, via a new dedicated timing test
        // -- no test for this whole family existed before): 3 clocks,
        // matching the same uniform ext_count==1 register-direct baseline
        // every other 2-word instruction in this whitelist shares.
        // dec_is_muldivl used to be set ONLY for the register-direct
        // (f_mode==000) source form; the memory-EA source forms
        // (MULS.L/DIVS.L/etc with a non-register source) were flagged
        // here as "not decoded/implemented in this RTL at all." Open-
        // items backlog Stage 7 (plan.md) implemented them -- and they
        // ALSO set dec_is_muldivl (needed for the WB-stage Dh:Dl/Dr:Dq
        // dual-register-write mechanism a few hundred lines down, which
        // applies identically regardless of where the source operand
        // came from). Explicitly excluding !dec_is_mem_src here: this
        // register-direct-only stall calibration (measured against a
        // purely-combinational 3-clock natural baseline with zero real
        // bus activity) does not apply to the memory-EA forms, which
        // already have real, natural bus-read timing baked in from the
        // EA fetch itself -- applying it anyway caused a genuine
        // correctness bug (found via cosim, tests/memind25.s), not just
        // a timing one: holding ex_valid/dec_is_mem_src active for the
        // full ~168-352 tick stall re-issued the memory read every
        // cycle for the whole stall duration instead of once. A
        // correctly-calibrated memory-EA stall (manual's own NCC row is
        // the SAME 44/90/78 as the register-direct row, needing FIEA
        // time from the specific EA mode added on top per the `**`
        // table-footnote convention -- scripts/timing_tables.py's own
        // ALU dict) is deliberately deferred as documented follow-up,
        // matching the plan's own framing of this as secondary to
        // correctness.
        if (dec_valid && dec_is_muldivl && !dec_is_mem_src) begin
            if (dec_unit == UNIT_MUL)
                dec_internal_stall_ticks_fixed = 16'd168; // +1clk recal: MULS.L/MULU.L Dn,Dn NCC=44+1clk=45clk=168t
            else if (dec_unit == UNIT_DIV) begin
                if (dec_md_op == DIV_SL)
                    dec_internal_stall_ticks_fixed = 16'd352; // +1clk recal: DIVS.L Dn,Dn NCC=90+1clk=91clk=352t
                else
                    dec_internal_stall_ticks_fixed = 16'd304; // +1clk recal: DIVU.L Dn,Dn NCC=78+1clk=79clk=304t
            end
        end
        // ANDI/ORI/EORI #imm,SR or CCR (manual NCC=14, own natural
        // baseline measures 13 -- gap=-1) were investigated but are
        // DELIBERATELY NOT whitelisted here. A +4-tick entry gated on
        // dec_reads_ccr+dec_use_imm+dec_needs_ext+(dec_is_move_sr_w||
        // dec_is_move_ccr_w) was tried and confirmed, via direct signal
        // tracing, to genuinely delay this instruction's own WB commit
        // by exactly 4 ticks as designed -- but the total measured clock
        // count for the test (ANDI-to-SR followed by a dependent MOVE.L
        // #imm,Dn) did not change at all. This op's own unusually large
        // 13-clock unstalled baseline (vs. the uniform 8-clock baseline
        // every other 2-word register-direct instruction in this project
        // shares -- see Stage D3's own bit-field entries above) already
        // points at a genuinely different, separate mechanism -- almost
        // certainly the IFU prefetch-queue refill/flush this project's
        // own history (Phase 96/98) already associates with SR/CCR
        // writes -- and the 4 extra EX-stage ticks were fully absorbed
        // into slack that mechanism already has, never reaching the
        // measured total. Fixing this for real would need the extra
        // time inserted at the IFU/decode stage instead of EX/WB, a
        // materially different and riskier change than every other
        // entry in this whitelist; left undone per this plan's own
        // explicit "not safely fixable" allowance rather than guessed
        // at further.
        // Stage D3 (plan.md): bit-field register (Dn) forms. All confirmed
        // flat regardless of offset/width/scan-depth (Stage D0's own
        // BFFFO spot-check) and fully decode-time computable -- offset/
        // width come from the already-fetched extension word, not a live
        // register read, unlike shift/rotate's own register-count case
        // above.
        //
        // Phase 163 Stage 1 (plan.md) recalibration: these are 2-word
        // (ext_count==1) register-direct instructions, so Stage 1's own
        // ext1_valid dispatch fix (m68030_seq.sv) sped up their shared
        // unstalled baseline too -- from 8 clocks (32 ticks, Stage D3's
        // own original figure) down to a uniform 3 clocks (12 ticks),
        // identical to the 1-word register-direct baseline, confirmed by
        // direct re-measurement of all 7 forms after Stage 1 landed (each
        // needed exactly 5 more clocks / 20 more ticks than before to
        // stay exact -- a uniform shift, not a per-op adjustment). BFTST
        // itself needs its own marker instruction to observe completion
        // (it writes no register, only CCR) and that marker's own cost
        // isn't isolated by the pin-level MEASURED_INSTR_ONLY correction
        // (Stage 0) either -- both are the same class of gap this
        // project's timing-survey infrastructure already knows how to
        // fix, just not yet extended to cover it; flagged as a follow-up,
        // not chased down as part of this stage.
        if (dec_valid && dec_is_bf && dec_bf_reg_ea) begin
            case (dec_bf_op)
                3'b010:  dec_internal_stall_ticks_fixed = 8'd48; // +1clk recal: BFCHG NCC=14+1clk=12clk=48t
                3'b100:  dec_internal_stall_ticks_fixed = 8'd48; // +1clk recal: BFCLR NCC=14+1clk=12clk=48t
                3'b110:  dec_internal_stall_ticks_fixed = 8'd48; // +1clk recal: BFSET NCC=14+1clk=12clk=48t
                3'b011:  dec_internal_stall_ticks_fixed = 8'd32; // +1clk recal: BFEXTS NCC=10+1clk=8clk=32t
                3'b001:  dec_internal_stall_ticks_fixed = 8'd32; // +1clk recal: BFEXTU NCC=10+1clk=8clk=32t
                3'b111:  dec_internal_stall_ticks_fixed = 8'd40; // +1clk recal: BFINS NCC=12+1clk=10clk=40t
                3'b101:  dec_internal_stall_ticks_fixed = 8'd72; // +1clk recal: BFFFO NCC=20+1clk=18clk=72t
                default: ; // 3'b000 = BFTST: see marker-overcounting note above
            endcase
        end
        // DBcc (cc=True): the "no branch, no decrement" path only --
        // reliable-baseline follow-up plan, Stage 1. Traced directly
        // (temporary $display on instr_ack/ex_is_dbcc/wb_valid) and
        // confirmed this RTL dispatches DBcc through the exact same
        // 1-word... no, 2-word/ext_count==1, 3-clock/12-tick baseline as
        // every other register-direct instruction in this whitelist,
        // computing the condition-true/no-op outcome combinationally in
        // one EX cycle -- real 68030 microcode needs more serial time
        // (NCC=8) even for this "do nothing" path. Deliberately gated on
        // eval_cc(dec_branch_cond,...) evaluating TRUE at decode time
        // (the same flag_n/z/v/c signals and eval_cc() function already
        // used combinationally elsewhere in this decode block, e.g. Scc's
        // own dec_imm computation above) so this can NEVER fire for
        // either cc=false path (count-not-expired/branch-taken, whose own
        // real branch redirect costs measure close to NCC=8 already via
        // natural bus timing -- MISMATCH is a separate, already-KNOWN
        // readahead artifact, not this stall's concern; or count-expired,
        // which already matches the manual exactly with zero stall and
        // must not be disturbed).
        if (dec_valid && dec_is_dbcc &&
            eval_cc(dec_branch_cond, flag_n, flag_z, flag_v, flag_c))
            dec_internal_stall_ticks_fixed = 8'd24; // +1clk recal: DBcc(cc=True) NCC=8+1clk=6clk=24t
        // Bcc not-taken (condition evaluates FALSE -> fall through, no
        // branch) -- timing-gaps-largest-first plan, Stage 3. Same
        // "internal microcode ceiling" shape as DBcc(cc=True) above,
        // gated the mirror-image way: dec_branch_taken's own existing
        // formula (elsewhere in this file) already defines "taken" as
        // eval_cc(...)==true, so "not taken" is exactly !eval_cc(...) --
        // this can never fire for BRA (f_cond=0000, eval_cc always true)
        // or for the taken path (a separate, already-KNOWN speculative-
        // readahead gap, untouched by this entry). f_disp8 distinguishes
        // which extension-word shape was used, mirroring this same
        // group's own branch-decode block above (f_disp8==8'h00 -> word
        // displacement follows; otherwise a literal byte displacement is
        // embedded in the opcode itself) -- found via a real test bug
        // investigation: a6_bcc_b_not_taken's own original "exact match"
        // was measuring vasm's own LEA(An),An NOP-substitute for a
        // degenerate zero-distance branch, not a real Bcc.B opcode at
        // all (fixed in tests/timing/a6_bcc_b_not_taken.s); once fixed,
        // BOTH byte and word not-taken forms share the identical
        // 3-clock/12-tick baseline this whole whitelist already uses.
        // f_disp8==8'hFF (long-form, 68020+) has no test coverage and is
        // deliberately left unhandled rather than guessed at.
        if (dec_valid && dec_is_branch &&
            !eval_cc(dec_branch_cond, flag_n, flag_z, flag_v, flag_c)) begin
            if (f_disp8 != 8'h00 && f_disp8 != 8'hFF)
                dec_internal_stall_ticks_fixed = 8'd8;  // +1clk recal: Bcc.B not-taken NCC=4+1clk=2clk=8t
            else if (f_disp8 == 8'h00)
                dec_internal_stall_ticks_fixed = 8'd16; // +1clk recal: Bcc.W not-taken NCC=6+1clk=4clk=16t
        end
    end

    // LSL/LSR/ASR register-count forms: arm a one-cycle "resolving" flag
    // at dispatch (instr_ack) -- it ALSO freezes the pipeline exactly like
    // ex_internal_stall itself (folded into the same stall_base/EX-freeze/
    // WB-bubble sites below), so nothing can advance during the one-cycle
    // resolution window. The following cycle, ex_shf_op/ex_siz/shf_count
    // are all valid (same timing shf_count already has) and the real tick
    // count loads directly, based on the manual's own count<=size / >size
    // bucket split.
    logic dec_needs_stall_resolve;
    assign dec_needs_stall_resolve = dec_valid && dec_unit == UNIT_SHF && dec_use_reg_cnt &&
                                      (dec_shf_op == SHF_LSL || dec_shf_op == SHF_LSR ||
                                       dec_shf_op == SHF_ASR);

    // internal_stall_cnt_r/internal_stall_resolving_r are declared (and
    // ex_internal_stall computed from them) here so stall_base -- assigned
    // just below -- can reference ex_internal_stall without a forward
    // reference; the always_ff that actually DRIVES these two regs is
    // deferred to just after ex_siz/ex_shf_op's own declarations further
    // down in this file (Icarus requires those declared before the
    // resolving-cycle logic that reads them), search for "Phase 162 Stage
    // D2 (continued)".
    // Widened to [15:0] alongside dec_internal_stall_ticks_fixed (see that
    // signal's own declaration comment -- MUL/DIV timing investigation).
    logic [15:0] internal_stall_cnt_r;
    logic       internal_stall_resolving_r;
    logic       ex_internal_stall;
    assign ex_internal_stall = (internal_stall_cnt_r != 16'd0) || internal_stall_resolving_r;

    logic hazard_ex, hazard_wb, hazard_ccr, hazard_usp, need_ext, stall;
    assign hazard_ex  = ex_valid && ex_writes_reg && (
                            (dec_reads_src && ex_dest_reg == dec_src_reg) ||
                            (dec_reads_dst && ex_dest_reg == dec_dst_reg) ||
                            (dec_reads_c   && ex_dest_reg == dec_c_reg)) ||
                        (ex_valid && ex_is_muldivl && ex_md_64bit && (
                            (dec_reads_src && {1'b0, ex_md_dst2} == dec_src_reg) ||
                            (dec_reads_dst && {1'b0, ex_md_dst2} == dec_dst_reg) ||
                            (dec_reads_c   && {1'b0, ex_md_dst2} == dec_c_reg))) ||
                        // An-update hazard: non-RMW instruction updates An via an_upd_en; wb fires
                        // one cycle after stall clears so the next instruction must wait one cycle
                        (ex_valid && ex_an_upd_en && !ex_is_mem_rmw && (
                            (dec_reads_src && dec_src_reg == {1'b1, ex_an_upd_reg}) ||
                            (dec_reads_dst && dec_dst_reg == {1'b1, ex_an_upd_reg}) ||
                            (dec_reads_c   && dec_c_reg   == {1'b1, ex_an_upd_reg})));
    assign hazard_wb  = wb_valid && wb_writes_reg && (
                            (dec_reads_src && wb_dest_reg == dec_src_reg) ||
                            (dec_reads_dst && wb_dest_reg == dec_dst_reg) ||
                            (dec_reads_c   && wb_dest_reg == dec_c_reg)) ||
                        (wb_valid && wb_is_muldivl && wb_md_64bit && (
                            (dec_reads_src && {1'b0, wb_md_dst2} == dec_src_reg) ||
                            (dec_reads_dst && {1'b0, wb_md_dst2} == dec_dst_reg) ||
                            (dec_reads_c   && {1'b0, wb_md_dst2} == dec_c_reg)));
    assign hazard_ccr = dec_reads_ccr && (
                            (ex_valid && ex_updates_ccr) ||
                            (wb_valid && wb_updates_ccr));
    // hazard_usp: MOVE USP,An reads usp_in live at decode; usp_r (eu_regfile.sv)
    // is a plain registered write with no forwarding, so a back-to-back
    // MOVE An,USP ; MOVE USP,An pair can otherwise read the pre-write value --
    // found via Phase 161 Part A Stage A2's own timing sweep (MC68030UM.pdf
    // 11-39), the first time this exact instruction pair was ever exercised
    // in this project's history (absent from the Harte corpus, which has no
    // USP coverage at all). Same two-stage EX/WB protection shape as
    // hazard_ccr above.
    assign hazard_usp = dec_reads_usp && (
                            (ex_valid && ex_is_move_usp) ||
                            (wb_valid && wb_is_move_usp));
    assign need_ext   = dec_needs_ext && !ext_valid;
    // ex_mem_stall freezes the entire pipeline regardless of dec_valid.
    // STOP stall: one-cycle bubble after STOP fires in EX so the following
    // instruction never enters EX before stop_r is set.  Using the dec_valid
    // path (not ex_mem_stall) ensures EX is cleared, not frozen.
    logic stop_first_cycle;
    assign stop_first_cycle = ex_valid && ex_is_stop && !stop_r;
    // stop_wb_hazard: STOP's own SR write (stop_sr_wr_en, below) fires
    // directly from EX the instant STOP is decoded -- unlike an ordinary
    // instruction's own CCR update, which commits one stage later, from
    // WB. hazard_ccr (above) protects a decode that *reads* CCR from a
    // still-in-flight EX/WB update, but STOP doesn't read CCR, it
    // unconditionally *overwrites* the whole SR -- so nothing previously
    // stopped it from entering EX on the exact same cycle a preceding
    // instruction's own delayed WB commit (e.g. a memory-source ALU op,
    // whose WB only fires once its own mem_ack finally arrives) is also
    // trying to land. When that collision happens, sr_wr_data's own
    // priority mux picks stop_sr_wr_en's branch over the ordinary
    // CCR-commit branch, silently discarding the real instruction's own
    // CCR result before it's ever visible in sr_r -- found via Phase 127's
    // own cache plan Step 6 (an I-cache hit on STOP's own opcode fetch can
    // close a timing gap the old, always-uncached fetch path guaranteed
    // never closed), confirmed via direct wb_valid/wb_updates_ccr/
    // stop_sr_wr_en/sr_r tracing, not guessed at.
    //
    // Checks both EX and WB stage, mirroring hazard_ccr's own two-stage
    // shape: a wb-only check has no effect on a memory-source instruction
    // whose own WB is delayed by mem_ack -- by the time wb_valid&&
    // wb_updates_ccr finally goes true, STOP has *already* left decode
    // (dec_is_stop already false), since it was free to advance the whole
    // time that instruction sat waiting in EX with ex_updates_ccr already
    // visible (a static per-opcode property, held for its whole EX
    // residency). Checking ex_valid&&ex_updates_ccr too catches this one
    // cycle earlier, while STOP is still in decode.
    //
    // Both terms use the SAME "insert a bubble into EX" stall_base
    // treatment as every other hazard_* term below, not ex_mem_stall's own
    // "keep EX completely unchanged" one -- a first attempt tried the
    // latter for the ex_valid&&ex_updates_ccr case specifically, reasoning
    // the preceding instruction was "still using" EX and shouldn't be
    // bubbled out from under it. That reasoning doesn't hold: the WB latch
    // (elsewhere in this file) is a *separate* always_ff, sampling
    // ex_valid/ex_updates_ccr's own pre-edge value on the very same clock
    // edge regardless of what the EX latch does to its own registers that
    // same edge -- inserting a bubble into EX does NOT retroactively
    // erase what the WB latch already captured from EX going INTO this
    // edge. Confirmed by the failure mode: "keep unchanged" instead
    // created a genuine deadlock (ex_updates_ccr's own condition can only
    // ever clear via the normal EX-advances path, which "keep unchanged"
    // permanently blocks) -- test #4 (ADD.b memory-source) hung forever,
    // never retiring at all.
    //
    // sr_wr_en (used below instead of a bare wb_updates_ccr check) covers
    // a dozen OTHER instruction families that ALSO write SR directly from
    // EX, not through the ordinary wb_valid/wb_updates_ccr path
    // (mem_rmw_sr_wr_en, tas_sr_wr_en, cmp2_sr_wr_en, bcds_sr_wr_en,
    // cas_sr_wr_en, cas2_sr_wr_en, move_mm_sr_wr_en, addx_mem_sr_wr_en,
    // bf_mem_sr_wr_en, memind_ccr_wr_en, rte_sr_wr_en, rtr_sr_wr_en) --
    // reusing sr_wr_en itself, the same aggregate this whole hazard is
    // about, is simpler and complete by construction than enumerating each
    // one; its own stop_sr_wr_en term is guaranteed false here since
    // dec_is_stop and ex_is_stop can never both be true the same cycle.
    // Gated on !need_ext: STOP is itself a 2-word instruction (opcode +
    // its own #imm operand), consumed via the SAME dec_needs_ext/ext_valid
    // extension-word mechanism every multi-word opcode uses. A first
    // version of this hazard had no such guard and holding STOP in decode
    // for the extra cycle this hazard adds -- BEFORE STOP's own extension
    // word had actually been fetched -- desynced that mechanism: STOP's
    // own opcode word got treated as already consumed while STOP itself
    // never actually reached EX, so decode silently moved on to STOP's
    // own immediate operand (0x2700) and misdecoded IT as a fresh
    // instruction (0x2700 = "MOVE.L (A0),-(A3)" under ordinary 68k
    // decode) -- corrupting an unrelated address register by exactly -4
    // (the predecrement side effect) on every MOVEtoSR/RTE test
    // immediately followed by STOP. Confirmed via direct dec_is_stop/
    // dec_an_upd_en/decode_pc tracing showing dec_is_stop flip from 1 to
    // 0 at the *same* decode_pc between consecutive cycles once the extra
    // stall cycle was in play. need_ext (already computed above) is
    // exactly "this decode still needs an extension word it doesn't have
    // yet" -- excluding that window lets the pre-existing need_ext stall
    // (already part of stall_base's own bucket) finish fetching STOP's
    // own operand normally, with stop_wb_hazard only taking over once
    // STOP has that operand in hand and is genuinely ready to enter EX.
    // ex_valid-side check must cover ALL THREE of sr_wr_en's own WB-delayed
    // terms (wb_updates_ccr / wb_is_move_sr_w / wb_is_move_ccr_w), not just
    // wb_updates_ccr's own EX-stage precursor (ex_updates_ccr) -- a first
    // version of this fix only checked ex_updates_ccr, which is the ordinary
    // ALU-CCR-commit flag. That missed MOVE Dn,SR/MOVE Dn,CCR immediately
    // followed by STOP: MOVEtoSR's own SR write commits via wb_is_move_sr_w,
    // a completely different WB flag ex_updates_ccr never reflects, so a
    // MOVEtoSR sitting in EX with STOP right behind it in decode was
    // invisible to this hazard -- STOP was free to advance into EX the very
    // cycle MOVEtoSR's own WB (wb_is_move_sr_w) landed, recreating the exact
    // same sr_wr_data priority-mux collision this hazard exists to prevent.
    // Found via Step 6's full 4-config Harte sweep: every failure was a
    // register-direct "MOVE Dn,SR" test (the shortest-EX-residency form,
    // exactly the one most likely to still be in EX when STOP reaches
    // decode) showing the same -4 A3 corruption signature as the original
    // desync bug, on tests standalone-reproducible outside any batching
    // context -- a real, independent gap, not a batching artifact.
    logic stop_wb_hazard;
    assign stop_wb_hazard = dec_is_stop && !need_ext && (
                                sr_wr_en ||
                                (ex_valid && (ex_updates_ccr || ex_is_move_sr_w || ex_is_move_ccr_w)));
    // Forward-declare EX-stage branch-taken signals (assigned later in file).
    // Icarus/iverilog requires declarations before use in concurrent assigns.
    logic [15:0] ex_alu_result_w;
    logic ex_dbcc_taken;
    logic ex_jmp_taken, ex_jsr_taken, ex_bsr_taken, ex_rts_taken, ex_rtr_taken, ex_rte_taken;
    // EX-branch stall: when any EX-stage branch fires (BSR/JSR/RTS/RTR/RTE/JMP/DBcc),
    // the IFU has been flushed at this posedge. Hold stall for 1 cycle so the
    // sequential instruction currently in DEC cannot enter EX — the IFU flush
    // will clear dec_valid on the next cycle, giving EX a clean bubble.
    // (ex_jmp_taken/ex_jsr_taken/etc. are assigned below; forward refs are fine
    // in concurrent assigns.)
    // ex_exc_dispatch_hazard: blocks new decode->EX dispatch (plain
    // dec_valid-style "insert bubble" semantics -- see below for why no
    // freeze is needed) for as long as an internal exception is either
    // about to be seen by m68030_exc for the first time, OR is still being
    // dispatched by it (exc_active). Found via Step 6's cache plan:
    // eu_priv_req/eu_trap_req/eu_illegal_req/etc are all bare "ex_valid &&
    // ex_is_X" combinational pulses with NOTHING gating dec_valid's own
    // advance behind them -- decode was completely free to keep dispatching
    // (and committing register side effects for) whatever instruction
    // stream happens to sit at the NEXT sequential address, for the ENTIRE
    // multi-cycle EXC_PUSH/FETCH/LOAD dispatch sequence, since pc_wr_en
    // (the actual IFU/decode flush, m68030_exc's new_pc_wr) doesn't fire
    // until state_r reaches EXC_LOAD -- exc_active merely steals bus
    // arbitration (m68030_top's biu_eu_req mux) in the meantime, which only
    // blocks memory-*data*-dependent side effects, not e.g. an EA
    // predecrement (dec_an_upd_en), which commits as part of ordinary
    // dispatch regardless of whether the accompanying bus access ever
    // completes. Root-caused via a MOVE Dn,SR (clearing S) immediately
    // followed by the Harte runway's own STOP: STOP correctly takes a
    // Privilege Violation (dec_is_priv, from the same-cycle SR-forwarding
    // path, architecturally correct -- real 68030 sees the new SR
    // immediately) -- but decode then continued straight through STOP's
    // own leftover operand byte (0x2700), misdecoding it as
    // "MOVE.L (A0),-(A3)" and committing that instruction's own -(A3)
    // predecrement, a real, previously latent gap in ALL internal-exception
    // dispatch (not the STOP/CCR hazard above, and not caused by it), only
    // exposed now because I-cache timing shifted exactly when this specific
    // race window opens.
    //
    // A first version gated this on "ex_will_except && !exc_active" alone,
    // reasoning that stall could safely drop the instant exc_active first
    // turns on. Traced and disproved: exc_active means only "state_r has
    // LEFT EXC_IDLE" (asserted across the whole EXC_PUSH/FETCH/LOAD
    // sequence) -- it does NOT mean the flush has landed. Dropping the
    // hazard there freed decode one full dispatch sequence too early,
    // reproducing the exact corruption one cycle later than before. The
    // fix folds exc_active itself into the SAME OR term rather than gating
    // on its absence, holding stall for the ENTIRE window through to the
    // EXC_LOAD cycle new_pc_wr actually fires on (exc_active's last cycle
    // asserted).
    //
    // No "keep EX frozen" (ex_mem_stall-style) treatment is needed despite
    // that being the first instinct (a stop_wb_hazard-shaped concern about
    // losing eu_priv_req after one bubbled cycle): m68030_exc's own
    // EXC_IDLE case samples exc_pending/priv_req combinationally and
    // transitions off EXC_IDLE on the very same edge it was ever visible --
    // a single-cycle pulse is already sufficient, so bubbling ex_is_priv
    // away immediately afterward loses nothing the FSM needed. What
    // actually matters -- blocking new dispatch -- is unconditionally
    // covered by the exc_active term for the rest of the window regardless
    // of what EX itself holds, so plain bubble semantics (this term lives
    // in stall_base's usual OR, not ex_mem_stall's own frozen branch) are
    // both sufficient and simpler, with no deadlock risk to reason about.
    //
    // Every one of eu_seq.sv's own "_req" exception triggers shares the
    // identical unprotected shape, so this aggregates all of them rather
    // than special-casing priv alone. Excluded: eu_reset_req (RESET
    // pulses RSTOUT directly, no exc_active-mediated frame dispatch to
    // race against) and eu_trace_req -- investigated directly (deferred-
    // items closure plan Stage 11, plan.md; see tb/mmu_xlate_tb.sv's own
    // "Phase 7" test) via a hierarchical trace: the same 1-cycle dispatch
    // race Phase 108 fixed for interrupts DOES occur here too (instr_ack
    // fires for the next instruction the exact cycle eu_trace_req
    // asserts, one cycle before exc_active catches up) -- but it never
    // corrupts anything, because exc_active is already in `stall` below,
    // and the very next cycle's pre-existing, exception-agnostic
    // "stall -> insert bubble" EX-latch branch (else if (stall)
    // ex_valid<=1'b0, several hundred lines below) squashes the raced-in
    // instruction before wb_valid<=ex_valid can ever commit it. No
    // bespoke term needed -- eu_trace_req doesn't have a different hazard
    // shape from priv/trap/illegal/etc.; it's the identical shape,
    // already covered by exc_active alone.
    // BKPT's BERR outcome (Phase 157 Stage 3) is decided later than decode
    // time -- only once eu_bkpt_berr arrives, mid-FSM -- same shape as
    // chk_trap/div_trap immediately below, not the plain ex_is_illegal
    // decode-time case. Per the manual (Section 7.4.2): a BERR'd
    // breakpoint-acknowledge cycle takes an illegal instruction exception.
    wire bkpt_trap_w = bkpt_run_r && eu_bkpt_berr;
    assign eu_bkpt_illegal_req = bkpt_trap_w;
    // open-items backlog Stage 13 (plan.md): live opcode substitution.
    assign eu_bkpt_subst_active = bkpt_subst_active_r;
    assign eu_bkpt_subst_word   = bkpt_replacement_r;

    logic ex_will_except;
    assign ex_will_except = ex_valid && (ex_is_trap || ex_is_trapv || ex_is_illegal ||
                                          ex_is_priv || ex_is_linea || ex_is_linef) ||
                             chk_trap || div_trap || eu_fmt_err_req || bkpt_trap_w;

    // Phase 150 Stage 1 (plan.md): mem_berr-driven dispatch race, the same
    // hazard class as ex_will_except's own gap above but for a BUS ERROR
    // rather than an internal exception. mem_berr (asserted the one cycle
    // an EU-initiated access's abort is detected) immediately clears
    // ex_mem_stall for the faulting instruction -- freeing decode to
    // dispatch whatever instruction is already sitting decoded downstream
    // on the VERY NEXT cycle -- but m68030_exc's own exc_active takes one
    // further cycle to recognize bus_err_req (via the sticky-to-pulse
    // eu_bus_err_r edge-detector in m68030_top.sv), leaving a genuine
    // 1-cycle window where neither ex_will_except-style pre-signaling nor
    // exc_active yet blocks new dispatch. Found via a Stage 1 investigation
    // probe (a deliberate MMU translation fault on a MOVE.L's own data
    // read): the instruction immediately after the faulting one -- already
    // decoded and waiting -- launched into EX and fully committed (visible
    // in its own destination register) one cycle before exc_active ever
    // turned on. Same shape as Phase 108's int_ready/int_pending fix and
    // Phase 134's own ex_exc_dispatch_hazard fix, just for the mem_berr
    // trigger specifically: latch mem_berr into a sticky flag that holds
    // the hazard from the fault-detection cycle through to the cycle
    // exc_active itself takes over (its own first cycle asserted), exactly
    // filling the gap. mem_berr (not the wider mem_abort, which already
    // includes exc_active) is the correct trigger -- it is already the
    // canonical "a bus error was just detected on any EU-initiated access"
    // pulse shared by every ex_mem_stall-shaped `_mem_stall`/`_stall`
    // formula above (ordinary reads/writes and all ~19 FSM sources the
    // BERR-abort rollout, Phases 108-109, already covers), so this
    // automatically applies to all of them, not just ordinary MOVE.
    // mem_berr itself (combinational) must be included directly, not just
    // latched a cycle later: mem_berr's own same-cycle assertion is what
    // makes ex_mem_stall/stall_base drop to 0 in the first place (every
    // `_mem_stall` formula's own `!(mem_berr || exc_active)` term), so a
    // registered-only latch (updating one cycle later) is one cycle too
    // late to prevent that exact same-cycle dispatch window -- confirmed
    // by re-tracing after a first attempt that used only the registered
    // form: stall_base read 0 at t=6665 (mem_berr's own first cycle) and
    // MOVEQ still dispatched then, one full cycle before pending_mem_berr_r
    // (which only updates starting the NEXT clock edge) could possibly
    // help. pending_mem_berr_r still covers the cycle(s) after that, until
    // exc_active itself takes over.
    logic pending_mem_berr_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)             pending_mem_berr_r <= 1'b0;
        else if (mem_berr)      pending_mem_berr_r <= 1'b1;
        else if (exc_active)    pending_mem_berr_r <= 1'b0;
    end

    logic ex_exc_dispatch_hazard;
    assign ex_exc_dispatch_hazard = ex_will_except || exc_active || mem_berr || pending_mem_berr_r;
    logic stall_base;
    assign stall_base = ex_mem_stall
                      || ex_internal_stall
                      || ex_exc_dispatch_hazard
                      || (ex_jmp_taken | ex_jsr_taken | ex_bsr_taken
                         | ex_rts_taken | ex_rtr_taken | ex_rte_taken | ex_dbcc_taken)
                      || (dec_valid && (hazard_ex || hazard_wb || hazard_ccr || hazard_usp || need_ext || stop_first_cycle || stop_wb_hazard));
    // int_defer: a pending interrupt sees a clean instruction boundary this
    // cycle (dec_valid would otherwise dispatch with no other stall source).
    // Real 68030 silicon only samples IPL between instructions; freezing
    // dispatch for exactly this window (rather than letting the ready
    // instruction launch and then trying to sample decode_pc on the same
    // edge) avoids a race where the exception controller's saved return PC
    // could point at an instruction that has already started executing.
    // Held for as long as int_pending stays asserted — spans the whole
    // EXC_PUSH/FETCH/LOAD sequence, since nothing else changes dec_valid
    // until the IFU flush on pc_wr_en naturally clears it.
    logic int_defer;
    assign int_defer  = dec_valid && !stall_base && int_pending;
    assign stall      = stall_base || int_defer;
    assign eu_int_ready = int_defer;
    assign seq_busy  = stall;
    assign instr_ack = dec_valid && !stall;

    // -----------------------------------------------------------------------
    // EX stage latch
    // -----------------------------------------------------------------------
    // ex_is_cas / ex_is_abcd_sbcd_mem / ex_cas_du_reg / ex_is_abcd_mem declared early above
    logic [2:0]  ex_unit;
    logic [3:0]  ex_alu_op, ex_shf_op;
    logic [2:0]  ex_md_op;
    logic [1:0]  ex_bcd_op;
    logic [1:0]  ex_bit_op;
    logic [4:0]  ex_bit_num;
    logic        ex_bit_from_reg;
    logic        ex_is_bit_imm;
    logic [3:0]  ex_src_reg, ex_dst_reg, ex_c_reg;  // ex_c_reg: Phase 149, plan.md
    assign bcds_ay_step = (ex_src_reg[2:0] == 3'b111) ? 32'd2 : 32'd1;
    assign bcds_ax_step = (ex_dst_reg[2:0] == 3'b111) ? 32'd2 : 32'd1;
    logic [1:0]  ex_siz;
    logic [31:0] ex_imm;
    logic        ex_use_imm, ex_use_reg_cnt;
    logic        ex_x_unchanged;
    logic [5:0]  ex_shf_imm_cnt;
    logic        ex_is_swap, ex_sext, ex_sext_from_byte;
    logic        ex_is_dbcc;
    logic [3:0]  ex_dbcc_cond;
    logic [31:0] ex_dbcc_disp;
    logic [31:0] ex_decode_pc;
    assign ex_decode_pc_out = ex_decode_pc;
    // Memory-access EX signals
    logic [31:0] ex_ea_offset;   // displacement for EA (0 or d16 or -step)
    logic [31:0] ex_an_delta;    // An update amount (Ax step for CMPM; Ay step computed separately)
    // CMPM Ay postincrement step — uses Ay register (ex_src_reg) for A7 special case.
    always_comb begin
        case (ex_siz)
            2'b00:   cmpm_ay_step = 32'd4;
            2'b10:   cmpm_ay_step = 32'd2;
            default: cmpm_ay_step = (ex_src_reg[2:0] == 3'b111) ? 32'd2 : 32'd1;
        endcase
    end
    // subroutine / jump EX signals
    logic [31:0] ex_return_pc;   // return address for JSR/BSR push
    logic [31:0] ex_bsr_target;  // pre-computed BSR branch target
    logic [31:0] ex_jump_offset; // JMP/JSR target offset (0 or d16)

    // Phase 162 Stage D2 (continued): the resolving-cycle half of the
    // artificial-internal-stall mechanism declared up near ex_mem_stall/
    // ex_berr_abort_wb -- deferred to here because it needs ex_siz/
    // ex_shf_op (just declared above), which Icarus requires to be
    // declared before any expression referencing them, unlike the many
    // other far-later-declared signals ex_mem_stall's own OR-list gets
    // away forward-referencing (those were deliberately relocated earlier
    // in the file for exactly this reason; moving ex_siz/ex_shf_op
    // themselves felt like the wrong tradeoff given how many other things
    // in this file already depend on their current declaration point).
    logic [5:0] ex_shf_width_bits;
    assign ex_shf_width_bits = (ex_siz == 2'b01) ? 6'd8 : (ex_siz == 2'b10) ? 6'd16 : 6'd32;

    logic [7:0] ex_internal_stall_ticks_resolved;
    always_comb begin
        ex_internal_stall_ticks_resolved = 8'd0;
        case (ex_shf_op)
            SHF_LSL, SHF_LSR: ex_internal_stall_ticks_resolved =
                (shf_count <= ex_shf_width_bits) ? 8'd12 : 8'd20; // %NCC=6->3clk=12t, +NCC=8->5clk=20t
            SHF_ASR: ex_internal_stall_ticks_resolved =
                (shf_count <= ex_shf_width_bits) ? 8'd12 : 8'd28; // %NCC=6->3clk=12t, +NCC=10->7clk=28t
            default: ;
        endcase
    end

    // Loaded the exact cycle a whitelisted instruction dispatches into EX
    // (instr_ack, the same "this instruction is entering EX right now"
    // condition every other one-shot EX-entry latch in this file keys
    // off); decrements every cycle thereafter until it reaches 0, at which
    // point ex_internal_stall drops and the ordinary (non-stalled) EX/WB
    // path takes over on its own, needing no further changes here.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            internal_stall_cnt_r      <= 16'd0;
            internal_stall_resolving_r <= 1'b0;
        end else if (internal_stall_resolving_r) begin
            // Resolution cycle: ex_shf_op/ex_siz/shf_count are now valid.
            internal_stall_cnt_r       <= {8'd0, ex_internal_stall_ticks_resolved};
            internal_stall_resolving_r <= 1'b0;
        end else if (internal_stall_cnt_r != 16'd0) begin
            internal_stall_cnt_r <= internal_stall_cnt_r - 16'd1;
        end else if (instr_ack && (dec_internal_stall_ticks_fixed != 16'd0)) begin
            internal_stall_cnt_r <= dec_internal_stall_ticks_fixed;
        end else if (instr_ack && dec_needs_stall_resolve) begin
            internal_stall_resolving_r <= 1'b1;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid          <= 1'b0;
            ex_unit           <= UNIT_NONE;
            ex_writes_reg     <= 1'b0;
            ex_updates_ccr    <= 1'b0;
            ex_is_swap        <= 1'b0;
            ex_sext           <= 1'b0;
            ex_sext_from_byte <= 1'b0;
            ex_is_dbcc        <= 1'b0;
            ex_dbcc_cond      <= 4'h0;
            ex_dbcc_disp      <= 32'h0;
            ex_decode_pc      <= 32'h0;
            ex_is_mem_rd      <= 1'b0;
            ex_is_mem_wr      <= 1'b0;
            ex_is_lea         <= 1'b0;
            ex_is_movea_w     <= 1'b0;
            ex_ea_offset      <= 32'h0;
            ex_an_delta       <= 32'h0;
            ex_an_upd_en      <= 1'b0;
            ex_an_upd_reg     <= 3'h0;
            ex_is_jmp         <= 1'b0;
            ex_is_jsr         <= 1'b0;
            ex_is_bsr         <= 1'b0;
            ex_is_rts         <= 1'b0;
            ex_is_rtr         <= 1'b0;
            ex_is_link        <= 1'b0;
            ex_abs_ea_en      <= 1'b0;
            ex_abs_jmp_en     <= 1'b0;
            ex_abs_ea_val     <= 32'h0;
            ex_is_idx             <= 1'b0;
            ex_xn_wl              <= 1'b0;
            ex_xn_scale           <= 2'b00;
            ex_is_dyn_bit_idx     <= 1'b0;
            ex_dyn_bit_reg        <= 3'b0;
            ex_dyn_bit_is_an      <= 1'b0;
            ex_dyn_bit_swap_a     <= 1'b0;
            ex_dyn_bit_swap_both  <= 1'b0;
            ex_dyn_bit_reg2       <= 3'b0;
            ex_dyn_bit_is_an2     <= 1'b0;
            ex_dst_is_idx         <= 1'b0;
            ex_dst_xn_wl          <= 1'b0;
            ex_dst_xn_scale       <= 2'b00;
            ex_is_bit_imm         <= 1'b0;
            ex_return_pc          <= 32'h0;
            ex_bsr_target         <= 32'h0;
            ex_jump_offset        <= 32'h0;
            ex_is_movem           <= 1'b0;
            ex_movem_load         <= 1'b0;
            ex_movem_predec   <= 1'b0;
            ex_movem_postinc  <= 1'b0;
            ex_movem_long     <= 1'b0;
            ex_is_tas         <= 1'b0;
            ex_is_cpsr        <= 1'b0;
            ex_is_chk         <= 1'b0;
            ex_chk_word       <= 1'b0;
            ex_is_cmp2chk2    <= 1'b0;
            ex_is_movep       <= 1'b0;
            ex_movep_load     <= 1'b0;
            ex_movep_long     <= 1'b0;
            ex_is_move16      <= 1'b0;
            ex_move16_form    <= 2'b0;
            ex_is_fpu         <= 1'b0;
            ex_is_memind      <= 1'b0;
            ex_memind_is_post <= 1'b0;
            ex_memind_od      <= 32'h0;
            ex_is_pflush      <= 1'b0;
            ex_pflush_all     <= 1'b0;
            ex_pflush_fc      <= 3'b0;
            ex_is_ptest       <= 1'b0;
            ex_ptest_fc       <= 3'b0;
            ex_is_pload       <= 1'b0;
            ex_pload_fc       <= 3'b0;
            ex_pload_rw       <= 1'b1;
            ex_is_pmove       <= 1'b0;
            ex_is_pmove64     <= 1'b0;
            ex_pmove_preg     <= 3'b0;
            ex_pmove_to_mem   <= 1'b0;
            ex_is_mem_src     <= 1'b0;
            ex_mem_rd_siz     <= 2'b00;
            ex_is_rte         <= 1'b0;
            ex_is_stop        <= 1'b0;
            ex_stop_sr        <= 16'h0;
            ex_is_trap        <= 1'b0;
            ex_trap_num       <= 4'h0;
            ex_is_trapv       <= 1'b0;
            ex_is_illegal     <= 1'b0;
            ex_is_jsr_idx     <= 1'b0;
            ex_is_pea_idx     <= 1'b0;
            ex_is_trace       <= 1'b0;
            ex_is_priv        <= 1'b0;
            ex_is_linea       <= 1'b0;
            ex_is_linef       <= 1'b0;
            ex_is_move_sr_w   <= 1'b0;
            ex_is_move_ccr_w  <= 1'b0;
            ex_is_move_usp    <= 1'b0;
            ex_sext_src       <= 1'b0;
            ex_is_muldivl     <= 1'b0;
            ex_md_dst2        <= 3'b0;
            ex_md_64bit       <= 1'b0;
            ex_is_pea         <= 1'b0;
            ex_is_exg         <= 1'b0;
            ex_exg_dd         <= 1'b0;
            ex_is_cmpm        <= 1'b0;
            ex_is_mem_rmw     <= 1'b0;
            ex_is_addx_mem    <= 1'b0;
            ex_is_move_mm         <= 1'b0;
            ex_is_move_mm_idx_dst <= 1'b0;
            ex_is_move_reg_idx_dst <= 1'b0;
            ex_dst_ea_offset  <= 32'h0;
            ex_abs_dst_ea_en  <= 1'b0;
            ex_abs_dst_ea_val <= 32'h0;
            ex_dst_an_upd_en  <= 1'b0;
            ex_dst_an_upd_reg <= 3'b0;
            ex_dst_an_delta   <= 32'h0;
            ex_is_bf          <= 1'b0;
            ex_bf_op          <= 3'b0;
            ex_bf_reg_ea      <= 1'b0;
            ex_bf_mutates     <= 1'b0;
            ex_is_pack        <= 1'b0;
            ex_is_unpk        <= 1'b0;
            ex_is_pack_mem    <= 1'b0;
            ex_is_reset       <= 1'b0;
            ex_is_cas         <= 1'b0;
            ex_cas_du_reg     <= 3'b0;
            ex_is_abcd_sbcd_mem <= 1'b0;
            ex_is_abcd_mem    <= 1'b0;
            ex_is_cas2        <= 1'b0;
            ex_cas2_du1_reg   <= 3'b0;
            ex_cas2_rn2_reg   <= 4'h0;
            ex_cas2_dc2_reg   <= 3'b0;
            ex_cas2_du2_reg   <= 3'b0;
        end else if (ex_mem_stall || ex_internal_stall) begin
            // EX holds waiting for BIU ack, or for an artificial internal
            // stall (Phase 162) to expire — keep all EX latch signals unchanged.
            // (SystemVerilog: un-driven signals retain their current value.)
        end else if (stall) begin
            // DECODE holds; insert bubble into EX.
            ex_valid          <= 1'b0;
            ex_writes_reg     <= 1'b0;
            ex_updates_ccr    <= 1'b0;
            ex_is_swap        <= 1'b0;
            ex_sext           <= 1'b0;
            ex_sext_from_byte <= 1'b0;
            ex_is_dbcc        <= 1'b0;
            ex_is_mem_rd      <= 1'b0;
            ex_is_mem_wr      <= 1'b0;
            ex_is_lea         <= 1'b0;
            ex_is_movea_w     <= 1'b0;
            ex_an_upd_en      <= 1'b0;
            ex_is_jmp         <= 1'b0;
            ex_is_jsr         <= 1'b0;
            ex_is_bsr         <= 1'b0;
            ex_is_rts         <= 1'b0;
            ex_is_rtr         <= 1'b0;
            ex_is_link        <= 1'b0;
            ex_abs_ea_en          <= 1'b0;
            ex_abs_jmp_en         <= 1'b0;
            ex_is_idx             <= 1'b0;
            ex_is_dyn_bit_idx     <= 1'b0;
            ex_dyn_bit_reg        <= 3'b0;
            ex_dyn_bit_is_an      <= 1'b0;
            ex_dyn_bit_swap_a     <= 1'b0;
            ex_dyn_bit_swap_both  <= 1'b0;
            ex_dyn_bit_reg2       <= 3'b0;
            ex_dyn_bit_is_an2     <= 1'b0;
            ex_dst_is_idx         <= 1'b0;
            ex_dst_xn_wl          <= 1'b0;
            ex_dst_xn_scale       <= 2'b00;
            ex_is_bit_imm         <= 1'b0;
            ex_is_movem           <= 1'b0;
            ex_movem_load     <= 1'b0;
            ex_movem_predec   <= 1'b0;
            ex_movem_postinc  <= 1'b0;
            ex_movem_long     <= 1'b0;
            ex_is_tas         <= 1'b0;
            ex_is_cpsr        <= 1'b0;
            ex_is_chk         <= 1'b0;
            ex_chk_word       <= 1'b0;
            ex_is_cmp2chk2    <= 1'b0;
            ex_is_movep       <= 1'b0;
            ex_movep_load     <= 1'b0;
            ex_movep_long     <= 1'b0;
            ex_is_move16      <= 1'b0;
            ex_move16_form    <= 2'b0;
            ex_is_fpu         <= 1'b0;
            ex_is_memind      <= 1'b0;
            ex_memind_is_post <= 1'b0;
            ex_memind_od      <= 32'h0;
            ex_is_movec_wr    <= 1'b0;
            ex_movec_rc       <= 12'h0;
            ex_is_moves       <= 1'b0;
            ex_moves_load     <= 1'b0;
            ex_is_pflush      <= 1'b0;
            ex_pflush_all     <= 1'b0;
            ex_pflush_fc      <= 3'b0;
            ex_is_ptest       <= 1'b0;
            ex_ptest_fc       <= 3'b0;
            ex_is_pload       <= 1'b0;
            ex_pload_fc       <= 3'b0;
            ex_pload_rw       <= 1'b1;
            ex_is_pmove       <= 1'b0;
            ex_is_pmove64     <= 1'b0;
            ex_pmove_preg     <= 3'b0;
            ex_pmove_to_mem   <= 1'b0;
            ex_is_mem_src     <= 1'b0;
            ex_mem_rd_siz     <= 2'b00;
            ex_is_rte         <= 1'b0;
            ex_is_stop        <= 1'b0;
            ex_is_trap        <= 1'b0;
            ex_is_trapv       <= 1'b0;
            ex_is_illegal     <= 1'b0;
            ex_is_jsr_idx     <= 1'b0;
            ex_is_pea_idx     <= 1'b0;
            ex_is_trace       <= 1'b0;
            ex_is_priv        <= 1'b0;
            ex_is_linea       <= 1'b0;
            ex_is_linef       <= 1'b0;
            ex_is_move_sr_w   <= 1'b0;
            ex_is_move_ccr_w  <= 1'b0;
            ex_is_move_usp    <= 1'b0;
            ex_sext_src       <= 1'b0;
            ex_is_muldivl     <= 1'b0;
            ex_md_dst2        <= 3'b0;
            ex_md_64bit       <= 1'b0;
            ex_is_pea         <= 1'b0;
            ex_is_exg         <= 1'b0;
            ex_exg_dd         <= 1'b0;
            ex_is_cmpm        <= 1'b0;
            ex_is_mem_rmw     <= 1'b0;
            ex_is_addx_mem    <= 1'b0;
            ex_is_move_mm         <= 1'b0;
            ex_is_move_mm_idx_dst <= 1'b0;
            ex_is_move_reg_idx_dst <= 1'b0;
            ex_dst_ea_offset  <= 32'h0;
            ex_abs_dst_ea_en  <= 1'b0;
            ex_abs_dst_ea_val <= 32'h0;
            ex_dst_an_upd_en  <= 1'b0;
            ex_dst_an_upd_reg <= 3'b0;
            ex_dst_an_delta   <= 32'h0;
            ex_is_bf          <= 1'b0;
            ex_bf_op          <= 3'b0;
            ex_bf_reg_ea      <= 1'b0;
            ex_bf_mutates     <= 1'b0;
            ex_is_pack        <= 1'b0;
            ex_is_unpk        <= 1'b0;
            ex_is_pack_mem    <= 1'b0;
            ex_is_reset       <= 1'b0;
            ex_is_cas         <= 1'b0;
            ex_cas_du_reg     <= 3'b0;
            ex_is_abcd_sbcd_mem <= 1'b0;
            ex_is_abcd_mem    <= 1'b0;
            ex_is_cas2        <= 1'b0;
            ex_cas2_du1_reg   <= 3'b0;
            ex_cas2_rn2_reg   <= 4'h0;
            ex_cas2_dc2_reg   <= 3'b0;
            ex_cas2_du2_reg   <= 3'b0;
        end else begin
            ex_valid          <= dec_valid;
            ex_unit           <= dec_unit;
            ex_alu_op         <= dec_alu_op;
            ex_shf_op         <= dec_shf_op;
            ex_md_op          <= dec_md_op;
            ex_bcd_op         <= dec_bcd_op;
            ex_bit_op         <= dec_bit_op;
            ex_bit_num        <= dec_bit_num;
            ex_bit_from_reg   <= dec_bit_from_reg;
            ex_src_reg        <= dec_src_reg;
            ex_dst_reg        <= dec_dst_reg;
            ex_c_reg          <= dec_c_reg;
            ex_dest_reg       <= dec_dest_reg;
            ex_siz            <= dec_siz;
            ex_imm            <= dec_imm;
            ex_use_imm        <= dec_use_imm;
            ex_use_reg_cnt    <= dec_use_reg_cnt;
            ex_writes_reg     <= dec_writes_reg;
            ex_updates_ccr    <= dec_updates_ccr;
            ex_x_unchanged    <= dec_x_unchanged;
            ex_shf_imm_cnt    <= dec_shf_imm_cnt;
            ex_is_swap        <= dec_is_swap;
            ex_sext           <= dec_sext;
            ex_sext_from_byte <= dec_sext_from_byte;
            ex_is_dbcc        <= dec_is_dbcc;
            ex_dbcc_cond      <= dec_branch_cond;
            ex_dbcc_disp      <= dec_branch_disp;
            ex_decode_pc      <= decode_pc;
            ex_is_mem_rd      <= dec_is_mem_rd;
            ex_is_mem_wr      <= dec_is_mem_wr;
            ex_is_lea         <= dec_is_lea;
            ex_is_movea_w     <= dec_is_movea_w;
            ex_ea_offset      <= dec_ea_offset;
            ex_an_delta       <= dec_an_delta;
            ex_an_upd_en      <= dec_an_upd_en;
            ex_an_upd_reg     <= dec_an_upd_reg;
            ex_is_jmp         <= dec_is_jmp;
            ex_is_jsr         <= dec_is_jsr;
            ex_is_bsr         <= dec_is_bsr;
            ex_is_rts         <= dec_is_rts;
            ex_is_rtr         <= dec_is_rtr;
            ex_is_link        <= dec_is_link;
            ex_abs_ea_en      <= dec_abs_ea_en;
            ex_abs_jmp_en     <= dec_abs_jmp_en;
            ex_abs_ea_val     <= dec_abs_ea_val;
            ex_is_idx         <= dec_is_idx;
            ex_xn_wl          <= dec_xn_wl;
            ex_xn_scale       <= dec_xn_scale;
            ex_is_dyn_bit_idx <= dec_is_dyn_bit_idx;
            ex_dyn_bit_reg    <= dec_dyn_bit_reg;
            ex_dyn_bit_is_an  <= dec_dyn_bit_is_an;
            ex_dyn_bit_swap_a <= dec_dyn_bit_swap_a;
            ex_dyn_bit_swap_both <= dec_dyn_bit_swap_both;
            ex_dyn_bit_reg2       <= dec_dyn_bit_reg2;
            ex_dyn_bit_is_an2     <= dec_dyn_bit_is_an2;
            ex_dst_is_idx         <= dec_dst_is_idx;
            ex_dst_xn_wl          <= dec_dst_xn_wl;
            ex_dst_xn_scale       <= dec_dst_xn_scale;
            ex_is_bit_imm     <= dec_is_bit_imm;
            ex_return_pc      <= dec_return_pc;
            ex_bsr_target     <= dec_bsr_target;
            ex_jump_offset    <= dec_jump_offset;
            ex_is_movem       <= dec_is_movem;
            ex_movem_load     <= dec_movem_load;
            ex_movem_predec   <= dec_movem_predec;
            ex_movem_postinc  <= dec_movem_postinc;
            ex_movem_long     <= dec_movem_long;
            ex_is_movec_wr    <= dec_is_movec && dec_movec_to_ctrl;
            ex_movec_rc       <= ext_data[11:0];
            ex_is_moves       <= dec_is_moves;
            ex_moves_load     <= dec_moves_load;
            ex_is_tas         <= dec_is_tas;
            ex_is_cpsr        <= dec_is_cpsave || dec_is_cprestore;
            ex_is_chk         <= dec_is_chk;
            ex_chk_word       <= dec_chk_word;
            ex_is_cmp2chk2    <= dec_is_cmp2chk2;
            ex_is_movep       <= dec_is_movep;
            ex_movep_load     <= dec_movep_load;
            ex_movep_long     <= dec_movep_long;
            ex_is_move16      <= dec_is_move16;
            ex_move16_form    <= dec_move16_form;
            ex_is_fpu         <= dec_is_fpu;
            ex_is_memind      <= dec_is_memind;
            ex_memind_is_post <= dec_memind_is_post;
            ex_memind_od      <= dec_memind_od;
            ex_is_pflush      <= dec_is_pflush;
            ex_pflush_all     <= dec_pflush_all;
            ex_pflush_fc      <= dec_pflush_fc;
            ex_is_ptest       <= dec_is_ptest;
            ex_ptest_fc       <= dec_ptest_fc;
            ex_is_pload       <= dec_is_pload;
            ex_pload_fc       <= dec_pload_fc;
            ex_pload_rw       <= dec_pload_rw;
            ex_is_pmove       <= dec_is_pmove;
            ex_is_pmove64     <= dec_is_pmove64;
            ex_pmove_preg     <= dec_pmove_preg;
            ex_pmove_to_mem   <= dec_pmove_to_mem;
            ex_is_mem_src     <= dec_is_mem_src;
            ex_mem_rd_siz     <= dec_mem_rd_siz;
            ex_is_rte         <= dec_is_rte;
            ex_is_stop        <= dec_is_stop;
            ex_stop_sr        <= dec_stop_sr;
            ex_is_trap        <= dec_is_trap;
            ex_trap_num       <= dec_trap_num;
            ex_is_trapv       <= dec_is_trapv;
            ex_is_illegal     <= dec_is_illegal;
            ex_is_jsr_idx     <= dec_is_jsr_idx;
            ex_is_pea_idx     <= dec_is_pea_idx;
            ex_is_trace       <= dec_is_trace;
            ex_is_priv        <= dec_is_priv;
            ex_is_linea       <= dec_is_linea;
            ex_is_linef       <= dec_is_linef;
            ex_is_move_sr_w   <= dec_is_move_sr_w;
            ex_is_move_ccr_w  <= dec_is_move_ccr_w;
            ex_is_move_usp    <= dec_is_move_usp;
            ex_sext_src       <= dec_sext_src;
            ex_is_muldivl     <= dec_is_muldivl;
            ex_md_dst2        <= dec_md_dst2;
            ex_md_64bit       <= dec_md_64bit;
            ex_is_pea         <= dec_is_pea;
            ex_is_exg         <= dec_is_exg;
            ex_exg_dd         <= dec_exg_dd;
            ex_is_cmpm        <= dec_is_cmpm;
            ex_is_mem_rmw     <= dec_is_mem_rmw;
            ex_is_addx_mem    <= dec_is_addx_mem;
            ex_is_move_mm         <= dec_is_move_mm;
            ex_is_move_mm_idx_dst  <= dec_is_move_mm_idx_dst;
            ex_is_move_reg_idx_dst <= dec_is_move_reg_idx_dst;
            ex_dst_ea_offset  <= dec_dst_ea_offset;
            ex_abs_dst_ea_en  <= dec_abs_dst_ea_en;
            ex_abs_dst_ea_val <= dec_abs_dst_ea_val;
            ex_dst_an_upd_en  <= dec_dst_an_upd_en;
            ex_dst_an_upd_reg <= dec_dst_an_upd_reg;
            ex_dst_an_delta   <= dec_dst_an_delta;
            ex_is_bf          <= dec_is_bf;
            ex_bf_op          <= dec_bf_op;
            ex_bf_reg_ea      <= dec_bf_reg_ea;
            ex_bf_mutates     <= dec_bf_mutates;
            ex_is_pack        <= dec_is_pack;
            ex_is_unpk        <= dec_is_unpk;
            ex_is_pack_mem    <= dec_is_pack_mem;
            ex_is_reset       <= dec_is_reset;
            ex_is_cas         <= dec_is_cas;
            ex_cas_du_reg     <= dec_cas_du_reg;
            ex_is_abcd_sbcd_mem <= dec_is_abcd_sbcd_mem;
            ex_is_abcd_mem    <= dec_is_abcd_mem;
            ex_is_cas2        <= dec_is_cas2;
            ex_cas2_du1_reg   <= dec_cas2_du1_reg;
            ex_cas2_rn2_reg   <= dec_cas2_rn2_reg;
            ex_cas2_dc2_reg   <= dec_cas2_dc2_reg;
            ex_cas2_du2_reg   <= dec_cas2_du2_reg;
        end
    end
    // ex_an_upd_en declared above inside the EX latch always_ff block:
    assign mem_rmw_an_wr_en = mem_rmw_run_r && mem_ack && ex_valid && ex_an_upd_en;
    assign cpsr_an_wr_en    = cpsr_start_r && ex_an_upd_en;

    // Scc to memory is UNIT_MOVE and does NOT affect CCR.
    // All other memory RMW ops (ALU/SHF/BIT) do affect CCR.
    logic ex_mem_rmw_ccr;
    // ex_is_move_reg_idx_dst removed (Phase 149, plan.md): no longer RMW-shaped,
    // uses the ordinary WB-commit dec_updates_ccr path like CLR's own indexed form.
    assign ex_mem_rmw_ccr = ex_is_mem_rmw && (ex_unit != UNIT_MOVE);

    // -----------------------------------------------------------------------
    // Drive functional unit inputs from EX stage + register file
    // For memory ops: rd_a/rd_b must provide full 32-bit values (An for EA
    // base, Dn for write data). Override siz to longword so no sign-extension.
    // -----------------------------------------------------------------------
    // during MOVEM store, override rd_a_sel to read the current register to store.
    // during CAS2 rd2 phase, override to Rn2 for address; get_du phases use rd_b.
    // for indexed dynamic bit ops, override rd_b to Dn when bit op fires.
    // For BSET/BCLR/BCHG (RMW): override at mem_rmw_read_ack; for BTST: at mem_ack.
    // MOVE mem-src,(d8,An_dst,Xn) (dec_dyn_bit_swap_a=1) overrides rd_a instead: rd_a
    // holds src_An during the read (for the generic source EA), then swaps to dst_An
    // at read_ack for the move_mm_dst_addr_r indexed-dst capture; rd_b stays fixed
    // = dst_Xn the whole time (untouched by this override) since it was never needed
    // for the source (dec_is_idx is not set for these source EA modes).
    // MOVE (d8,An_src,Xn),(d8,An_dst,Xn) (dec_dyn_bit_swap_both=1): both sides are
    // indexed, so rd_a AND rd_b both swap at read_ack — rd_a: src_An->dst_An (reg/
    // is_an, same as swap_a), rd_b: src_Xn->dst_Xn (reg2/is_an2, the 2nd target).
    // CMP2/CHK2 (Phase 120): needs Xn (not yet swapped) at the FIRST read's
    // own ack — that's exactly when cmp2_addr2_r derives the second read's
    // address from ex_ea, which lives combinationally off rd_b_data — so
    // swapping rd_b to Rn on that same cycle corrupts the captured address.
    // Unlike every other dyn_bit_get_Dn consumer, CMP2/CHK2's own Rn isn't
    // needed until the final comparison, which happens only after the
    // *second* read completes — so excluding the first-read ack here and
    // consuming rd_b_data live at the second-read ack instead (see
    // cmp2_rn_sext_w's own comment) resolves the conflict with zero effect
    // on every other instruction family already using this mechanism (CHK,
    // ALU-mem-src, dynamic bit-ops, MOVE mem-to-mem indexed-dst) since none
    // of them have a second read at all.
    logic dyn_bit_get_Dn;
    assign dyn_bit_get_Dn = ex_is_dyn_bit_idx && ex_is_mem_rd &&
                            (ex_is_mem_rmw ? mem_rmw_read_ack
                                           : (mem_ack && !mem_rmw_run_r && !mem_rmw_after_r
                                              && !move_mm_run_r && !move_mm_after_r
                                              && !(ex_is_cmp2chk2 && !cmp2_run_r && !cmp2_after_r)));
    assign rd_a_sel = (movem_run_r && !movem_load_r) ? movem_reg_sel :
                      cas2_rd2_r                      ? ex_cas2_rn2_reg :
                      (dyn_bit_get_Dn && (ex_dyn_bit_swap_a || ex_dyn_bit_swap_both)) ? {ex_dyn_bit_is_an, ex_dyn_bit_reg} :
                                                        ex_src_reg;
    assign rd_a_siz = (movem_run_r || ex_is_mem_rd || ex_is_mem_wr || ex_is_lea || ex_is_abcd_sbcd_mem || ex_is_addx_mem) ? 2'b00 : ex_siz;
    assign rd_b_sel = cas_get_du_r     ? {1'b0, ex_cas_du_reg}  :
                      cas2_rd2_r       ? {1'b0, ex_cas2_dc2_reg} :  // Dc2 for inline compare
                      cas2_get_du1_r   ? {1'b0, ex_cas2_du1_reg} :
                      cas2_get_du2_r   ? {1'b0, ex_cas2_du2_reg} :
                      // Use explicit flag: An for ADDA/SUBA/CMPA indexed, Dn for bit ops
                      (dyn_bit_get_Dn && ex_dyn_bit_swap_both) ? {ex_dyn_bit_is_an2, ex_dyn_bit_reg2} :
                      (dyn_bit_get_Dn && !ex_dyn_bit_swap_a) ? {ex_dyn_bit_is_an, ex_dyn_bit_reg} :
                                         ex_dst_reg;
    // for indexed EA and CMP2/CHK2, rd_b carries Xn/Rn — full longword needed
    // memind post-indexed also needs full longword Xn in rd_b (for outer EA scaling)
    // CMPM rd_b carries Ax address base — must be full 32-bit regardless of siz
    assign rd_b_siz = (ex_is_mem_wr || ex_is_idx || ex_is_cmp2chk2 || ex_is_memind || ex_is_cmpm || ex_is_mem_rmw || ex_is_addx_mem || ex_is_bf || ex_is_move_mm || ex_is_cas || ex_is_abcd_sbcd_mem || ex_is_cas2) ? 2'b00 : ex_siz;

    // Read port C: MOVE Dn/An,(d8,An,Xn)'s own source register (Phase 149,
    // plan.md) -- the sole consumer today. Always full longword (like rd_a's
    // own ex_is_mem_wr case): eu_lane() sizes the write from d[7:0]/d[15:0].
    assign rd_c_sel = ex_is_move_reg_idx_dst ? ex_c_reg : 4'd0;
    assign rd_c_siz = 2'b00;

    // EA computation: An base from rd_a (loads/LEA) or rd_b (stores) --
    // EXCEPT an indexed write (Phase 144, plan.md), which needs An on rd_a
    // and Xn on rd_b simultaneously (ex_xn_val below is unconditionally
    // rd_b_data, so a plain write's own default "An on rd_b" rule would
    // collide with Xn for exactly this case). This is what let MOVE SR,(ea)
    // and CLR's own indexed form become genuine single-phase plain writes
    // instead of borrowing the RMW read-phase's own register layout purely
    // to get 2 simultaneous ports -- their write DATA never depends on
    // rd_a_data (always dec_use_imm), so routing An through rd_a here
    // doesn't collide with anything. Every non-indexed plain write
    // (MOVE Dn/imm/SR,ea non-indexed forms, CLR non-indexed, Phases 121/
    // 139/141-143) is completely unaffected -- ex_is_idx is 0 for all of
    // them, so this reduces to the original formula unchanged.
    logic [31:0] ex_an_base;
    assign ex_an_base = (ex_is_mem_wr && !ex_is_idx) ? rd_b_data : rd_a_data;

    // brief indexed — scaled index register value added to EA and jump target
    logic [31:0] ex_xn_val;
    logic [31:0] ex_xn_scaled;
    assign ex_xn_val    = ex_xn_wl ? rd_b_data : {{16{rd_b_data[15]}}, rd_b_data[15:0]};
    assign ex_xn_scaled = ex_is_idx ? (ex_xn_val << ex_xn_scale) : 32'h0;

    // post-indexed memind Xn*SCALE (valid during memind_start_r when EX holds)
    logic [31:0] memind_xn_sc_w;
    assign memind_xn_sc_w = ex_xn_val << ex_xn_scale;  // always computed; selected by FSM
    // Outer EA: pointer + post-indexed Xn (pre-indexed already in pointer) + od
    logic [31:0] memind_outer_addr_w;
    assign memind_outer_addr_w = memind_ptr_r + memind_post_xn_r + memind_od_r;

    // current active stack pointer (mirrors regfile's A7 selection by SR[13:12])
    logic [31:0] ex_cur_sp;
    assign ex_cur_sp = sr_live[13] ? (sr_live[12] ? msp_in : isp_in) : usp_in;

    logic [31:0] ex_ea;       // effective address for bus cycle or LEA result
    // ex_xn_scaled always added — zero when !ex_is_idx; handles (d8,PC,Xn)
    // where ex_abs_ea_val = PC+2+d8 and ex_xn_scaled carries the scaled index.
    // JSR/PEA (d8,An,Xn) — push address is SP-4; rd_b carries Xn (not A7).
    assign ex_ea = (ex_is_jsr_idx || ex_is_pea_idx) ? (ex_cur_sp - 32'd4)
                 : ex_abs_ea_en  ? (ex_abs_ea_val + ex_xn_scaled)
                 :                 (ex_an_base + ex_ea_offset + ex_xn_scaled);

    logic [31:0] ex_an_new;   // updated An value for (An)+ / -(An)
    // for JSR/PEA indexed, A7 update uses ex_cur_sp (rd_b holds Xn, not A7).
    // 10-item backlog Stage 9a/9b (plan.md): PEA/JSR's own memind case is
    // NOT marked ex_is_pea_idx/ex_is_jsr_idx (rd_a holds An, needed as
    // ex_ea's own base for the memind FSM's inner-address capture -- those
    // flags would instead force ex_ea to ex_cur_sp-4, wrong for that
    // purpose), but both still need the SAME ex_cur_sp-relative A7 update
    // every other PEA/JSR form gets, so they're added here independently.
    assign ex_an_new = (ex_is_jsr_idx || ex_is_pea_idx ||
                        ((ex_is_pea || ex_is_jsr) && ex_is_memind))
                      ? (ex_cur_sp + ex_an_delta)
                      : (ex_an_base + ex_an_delta);

    // jump target = An_jump + offset (rd_a is the An base for JMP/JSR)
    // absolute EA overrides; ex_xn_scaled adds index for (d8,PC,Xn)
    logic [31:0] ex_jmp_target;
    assign ex_jmp_target = ex_abs_jmp_en ? (ex_abs_ea_val + ex_xn_scaled)
                                         : (rd_a_data + ex_jump_offset + ex_xn_scaled);

    // RTR two-phase read state machine (placed here: ex_ea is in scope above)
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rtr_phase_r   <= 1'b0;
            rtr_ccr_r     <= 8'h0;
            rtr_a7_next_r <= 32'h0;
        end else if (ex_valid && ex_is_rtr && !rtr_phase_r && mem_ack) begin
            rtr_phase_r   <= 1'b1;
            rtr_ccr_r     <= mem_rdata[7:0];  // CCR from word read at (A7)
            rtr_a7_next_r <= ex_ea + 32'd2;   // A7+2: CCR pop is word-sized, not longword
        end else if (ex_valid && ex_is_rtr && rtr_phase_r && mem_ack) begin
            rtr_phase_r   <= 1'b0;
        end else if (ex_valid && ex_is_rtr && rtr_phase_r && mem_abort) begin
            // A fault on the second (PC) read aborts RTR — must explicitly
            // reset here or this stays stuck for the next RTR instruction.
            // The first (CCR) read's own fault needs no reset: rtr_phase_r
            // is still 0 at that point, its correct idle value.
            rtr_phase_r   <= 1'b0;
        end
    end

    // CMPM two-phase compare FSM
    // Phase 1: read (Ay)+ → capture Ay_val and Ax address, fire Ay an_wr
    // Phase 2: read (Ax)+ → alu computes CMP result, fire Ax an_wr
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cmpm_phase_r   <= 1'b0;
            cmpm_src_r     <= 32'h0;
            cmpm_ax_addr_r <= 32'h0;
            cmpm_step_r    <= 32'h0;
            cmpm_ax_reg_r  <= 3'b0;
        end else if (ex_valid && ex_is_cmpm && !cmpm_phase_r && mem_ack) begin
            cmpm_phase_r   <= 1'b1;
            cmpm_src_r     <= mem_rdata;          // Ay_val from phase 1
            // When Ax==Ay, capture post-increment address (Ay step, not Ax step).
            cmpm_ax_addr_r <= (ex_src_reg == ex_dst_reg) ? rd_b_data + cmpm_ay_step : rd_b_data;
            cmpm_step_r    <= ex_an_delta;         // postincrement step
            cmpm_ax_reg_r  <= ex_dst_reg[2:0];    // Ax register number
        end else if (ex_valid && ex_is_cmpm && cmpm_phase_r && mem_ack) begin
            cmpm_phase_r   <= 1'b0;
        end
    end

    // ADDX/SUBX -(Ay),-(Ax) 3-phase FSM
    // Phase 0 (setup, run=0): capture Ay-step/Ax-step addresses from rd_a/rd_b.
    // Phase 0 (run=1):        read M[Ay-step]; on ack fire Ay An write, advance.
    // Phase 1:                read M[Ax-step]; on ack fire Ax An write, advance.
    // Phase 2:                write ALU result; on ack fire CCR, FSM done.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            addx_mem_run_r   <= 1'b0;
            addx_mem_phase_r <= 2'd0;
            addx_src_r       <= 32'h0;
            addx_dst_r       <= 32'h0;
            addx_ay_addr_r   <= 32'h0;
            addx_ax_addr_r   <= 32'h0;
            addx_ay_reg_r    <= 3'b0;
            addx_ax_reg_r    <= 3'b0;
            addx_siz_r       <= 2'b0;
        end else begin
            if (ex_valid && ex_is_addx_mem && !addx_mem_run_r) begin
                // First EX cycle: capture predecremented addresses while rd_a/rd_b are valid
                addx_mem_run_r   <= 1'b1;
                addx_mem_phase_r <= 2'd0;
                addx_ay_addr_r   <= rd_a_data - calc_step(ex_siz, ex_src_reg[2:0] == 3'd7);
                // When Ay==Ax: Ax base is post-Ay address (A-2*step), not the pre-Ay value
                addx_ax_addr_r   <= (ex_src_reg == ex_dst_reg
                                     ? rd_a_data - calc_step(ex_siz, ex_src_reg[2:0] == 3'd7)
                                     : rd_b_data)
                                    - calc_step(ex_siz, ex_dst_reg[2:0] == 3'd7);
                addx_ay_reg_r    <= ex_src_reg[2:0];
                addx_ax_reg_r    <= ex_dst_reg[2:0];
                addx_siz_r       <= ex_siz;
            end else if (addx_mem_run_r && mem_abort) begin
                // A fault on any of the 3 phases (read Ay, read Ax, write
                // result) aborts the whole instruction. Must explicitly
                // reset addx_mem_run_r here (not just rely on the
                // combinational addx_mem_stall exception above dropping
                // `stall`) — otherwise it stays stuck at 1 forever (nothing
                // else ever clears it), corrupting the *next*
                // ADDX/SUBX -(Ay),-(Ax) instruction's own phase-0 setup.
                addx_mem_run_r   <= 1'b0;
                addx_mem_phase_r <= 2'd0;
            end else if (addx_mem_run_r && mem_ack) begin
                case (addx_mem_phase_r)
                    2'd0: begin
                        addx_src_r       <= mem_rdata;   // M[Ay-step]
                        addx_mem_phase_r <= 2'd1;
                    end
                    2'd1: begin
                        addx_dst_r       <= mem_rdata;   // M[Ax-step]
                        addx_mem_phase_r <= 2'd2;
                    end
                    2'd2: begin
                        addx_mem_run_r   <= 1'b0;
                        addx_mem_phase_r <= 2'd0;
                    end
                endcase
            end
        end
    end

    // bit-field memory EA FSM
    // Phase 0 (read): issue longword read from M[An]; on ack: capture data, go to phase 1 if mutating
    // Phase 1 (write): issue write of modified longword back to M[An]; on ack: FSM done
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            bf_mem_run_r     <= 1'b0;
            bf_mem_phase_r   <= 1'b0;
            bf_mem_data_r    <= 32'h0;
            bf_mem_addr_r    <= 32'h0;
            bf_mem_op_r      <= 3'b0;
            bf_mem_offset_r  <= 5'h0;
            bf_mem_width_r   <= 5'h0;
            bf_mem_dn_r      <= 3'b0;
            bf_mem_src_r     <= 32'h0;
            bf_mem_mutates_r <= 1'b0;
        end else begin
            if (ex_valid && ex_is_bf && !ex_bf_reg_ea && !bf_mem_run_r) begin
                // Setup: capture parameters from EX stage
                bf_mem_run_r     <= 1'b1;
                bf_mem_phase_r   <= 1'b0;
                bf_mem_addr_r    <= ex_ea;            // effective address (An, An+d16, or abs)
                bf_mem_op_r      <= ex_bf_op;
                bf_mem_offset_r  <= ex_imm[10:6];
                bf_mem_width_r   <= ex_imm[4:0];
                bf_mem_dn_r      <= ex_dest_reg[2:0]; // result Dn from extension word
                bf_mem_src_r     <= rd_b_data;        // BFINS source Dn (0 if not BFINS)
                bf_mem_mutates_r <= ex_bf_mutates;
            end else if (bf_mem_run_r && mem_ack) begin
                if (!bf_mem_phase_r) begin
                    bf_mem_data_r  <= mem_rdata;      // capture longword
                    if (bf_mem_mutates_r)
                        bf_mem_phase_r <= 1'b1;       // proceed to write phase
                    else
                        bf_mem_run_r   <= 1'b0;       // read-only op: done
                end else begin
                    bf_mem_run_r   <= 1'b0;           // write done
                    bf_mem_phase_r <= 1'b0;
                end
            end else if (bf_mem_run_r && mem_abort) begin
                // A fault on either phase aborts the whole bit-field op —
                // must explicitly reset here, not just rely on
                // bf_mem_stall's own combinational exception dropping
                // `stall`, or this stays stuck for the next BFINS/BFEXTU/
                // BFEXTS/etc. memory-EA instruction.
                bf_mem_run_r   <= 1'b0;
                bf_mem_phase_r <= 1'b0;
            end
        end
    end

    // RTE two-phase read FSM (mirrors RTR pattern)
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rte_phase_r   <= 1'b0;
            rte_sr_r      <= 16'h0;
            rte_a7_next_r <= 32'h0;
            rte_fmt_skip_r <= 8'h0;
        end else if (ex_valid && ex_is_rte && !rte_phase_r && mem_ack && !eu_fmt_err_req) begin
            rte_phase_r    <= 1'b1;
            rte_sr_r       <= mem_rdata[15:0];   // SR from {format_word, SR} longword at A7
            rte_a7_next_r  <= ex_ea + 32'd4;     // A7+4; phase 2 will add 4 + skip
            rte_fmt_skip_r <= rte_frame_extra(mem_rdata[31:28]);
        end else if (ex_valid && ex_is_rte && rte_phase_r && mem_ack) begin
            rte_phase_r   <= 1'b0;
        end else if (ex_valid && ex_is_rte && rte_phase_r && mem_abort) begin
            // A fault on the second (PC) read aborts RTE — must explicitly
            // reset here or this stays stuck for the next RTE instruction.
            // The first (format/SR) read's own fault needs no reset:
            // rte_phase_r is still 0 at that point, its correct idle value.
            rte_phase_r   <= 1'b0;
        end
    end

    // STOP FSM — halt CPU; cleared by exc_sr_wr_en (interrupt taken)
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            stop_r <= 1'b0;
        end else begin
            if (ex_valid && ex_is_stop && !stop_r)
                stop_r <= 1'b1;
            else if (stop_r && exc_sr_wr_en)
                stop_r <= 1'b0;
        end
    end

    // MOVEM two-phase FSM
    //   movem_start_r=1: MOVEM entered EX; wait one cycle so rd_b_data/ex_ea valid.
    //   movem_run_r=1: issue one bus cycle per remaining register in movem_mask_r.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            movem_start_r   <= 1'b0;
            movem_run_r     <= 1'b0;
            movem_mask_r    <= 16'h0;
            movem_addr_r    <= 32'h0;
            movem_an_r      <= 3'h0;
            movem_load_r    <= 1'b0;
            movem_predec_r  <= 1'b0;
            movem_postinc_r <= 1'b0;
            movem_long_r    <= 1'b0;
            movem_mask_hi_r <= 1'b0;
        end else if (!movem_start_r && !movem_run_r && instr_ack && dec_is_movem) begin
            // DECODE accepted MOVEM: capture control bits; stall for one cycle (movem_start_r).
            movem_start_r   <= 1'b1;
            // for 2-ext-word modes mask is in ext_data[31:16]; else [15:0]
            movem_mask_r    <= dec_movem_mask_hi ? ext_data[31:16] : ext_data[15:0];
            movem_mask_hi_r <= dec_movem_mask_hi;
            movem_load_r    <= dec_movem_load;
            movem_predec_r  <= dec_movem_predec;
            movem_postinc_r <= dec_movem_postinc;
            movem_long_r    <= dec_movem_long;
            movem_an_r      <= f_reg;           // base An register number
        end else if (movem_start_r) begin
            // MOVEM entered EX: rd_b_data = base An (standard) or ex_ea valid.
            // Compute initial bus address and start MOVEM bus-cycle loop (movem_run_r).
            movem_start_r <= 1'b0;
            movem_run_r   <= 1'b1;
            // Extended EA modes: start address is ex_ea (already computed with d16/Xn/abs).
            // Standard modes: predec starts at An-step; others start at An (rd_b_data).
            if (movem_mask_hi_r)
                movem_addr_r <= ex_ea;
            else if (movem_predec_r)
                movem_addr_r <= rd_b_data - (movem_long_r ? 32'd4 : 32'd2);
            else
                movem_addr_r <= rd_b_data;
        end else if (movem_run_r && mem_ack) begin
            // MOVEM loop: one register processed; advance to the next.
            movem_mask_r <= movem_next_mask;
            if (!movem_last) begin
                if (movem_predec_r)
                    movem_addr_r <= movem_addr_r - movem_step;
                else
                    movem_addr_r <= movem_addr_r + movem_step;
            end
            if (movem_last) movem_run_r <= 1'b0;
        end else if (movem_run_r && mem_abort) begin
            // A fault partway through the register list aborts the whole
            // instruction — real 68030 doesn't partially complete a MOVEM.
            movem_run_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // TAS (An) RMW FSM
    // Read phase: normal mem_rd with mem_rmw=1 (bus held).
    // When read ack fires (tas_read_ack keeps stall high): set tas_run_r.
    // Write phase (tas_run_r=1): drive write cycle; CCR fires on write ack.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            tas_run_r        <= 1'b0;
            tas_after_write_r <= 1'b0;
            tas_wdata_r      <= 8'h0;
            tas_ccr_r        <= 5'h0;
        end else begin
            // 1-cycle cooldown pulse after write completes; clears re-trigger guard
            tas_after_write_r <= tas_run_r && mem_ack;
            if (!tas_run_r && !tas_after_write_r &&
                ex_valid && ex_is_tas && ex_is_mem_rd && mem_ack) begin
                // Read ack: capture data, start write phase
                tas_run_r   <= 1'b1;
                tas_wdata_r <= mem_rdata[7:0] | 8'h80;
                tas_ccr_r   <= {flag_x, mem_rdata[7], (mem_rdata[7:0] == 8'h0), 1'b0, 1'b0};
            end else if (tas_run_r && (mem_ack || mem_abort)) begin
                // Write ack (or a fault aborting the write phase): end write
                // phase either way — on berr, tas_sr_wr_en (mem_ack-gated)
                // correctly never fires, so no CCR update happens for an
                // aborted TAS.
                tas_run_r   <= 1'b0;
            end
        end
    end

    assign tas_sr_wr_en = tas_run_r && mem_ack;

    // -----------------------------------------------------------------------
    // CMP2/CHK2 two-read FSM
    // First read: normal mem_rd path at EA (An).  On first ack (cmp2_first_ack
    // holds stall one extra cycle) → capture lb and Rn, compute addr2, set
    // cmp2_run_r.  Second read (cmp2_run_r=1): bus cycle at addr2; when it
    // acks, fire CCR update and optionally chk_trap; cmp2_after_r suppresses
    // a spurious third bus cycle for one cooldown cycle.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cmp2_run_r     <= 1'b0;
            cmp2_after_r   <= 1'b0;
            cmp2_lb_r      <= 32'h0;
            cmp2_addr2_r   <= 32'h0;
            cmp2_is_chk2_r <= 1'b0;
            cmp2_is_an_r   <= 1'b0;
            cmp2_siz_r     <= 2'b00;
        end else begin
            cmp2_after_r <= cmp2_run_r && mem_ack;
            if (!cmp2_run_r && !cmp2_after_r &&
                ex_valid && ex_is_cmp2chk2 && ex_is_mem_rd && mem_ack) begin
                // First read ack: capture bounds and start second read. Rn
                // is deliberately NOT captured into a register at all (see
                // cmp2_rn_sext_w's own comment above) -- the swap is gated
                // to not fire until the second read's own ack, so rd_b
                // still correctly holds Xn at this instant, matching what
                // ex_ea (used to derive cmp2_addr2_r) also needs it to hold.
                cmp2_run_r     <= 1'b1;
                cmp2_lb_r      <= mem_rdata;
                cmp2_is_chk2_r <= ex_imm[11];  // ext_data[11] = CHK2 selector
                cmp2_is_an_r   <= ex_imm[15];  // ext_data[15] = D/A flag
                cmp2_siz_r     <= ex_siz;
                case (ex_siz)
                    2'b01: cmp2_addr2_r <= ex_ea + 32'd1;
                    2'b10: cmp2_addr2_r <= ex_ea + 32'd2;
                    default: cmp2_addr2_r <= ex_ea + 32'd4;
                endcase
            end else if (cmp2_run_r && mem_ack) begin
                // Second read ack: this is where dyn_bit_get_Dn's swap
                // actually fires for CMP2/CHK2 (gated to exclude the first
                // read above), so rd_b now correctly holds Rn -- consumed
                // live via rd_b_data by cmp2_c_w/cmp2_z_w's own combinational
                // logic this same cycle, not registered here.
                cmp2_run_r <= 1'b0;
            end else if (cmp2_run_r && mem_abort) begin
                // A fault on the second (bound) read aborts the whole
                // CMP2/CHK2 — must explicitly reset here or this stays
                // stuck for the next CMP2/CHK2 instruction. The first
                // read's own fault is already covered by the generic
                // exclusion-gated mem_rd/mem_wr clause in ex_mem_stall
                // (cmp2_run_r is still 0 at that point).
                cmp2_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // MOVEP byte-interleaved FSM
    // start_r (1 cycle): EX has An in rd_a_data, capture EA and Dn value.
    // run_r: issue one SIZ=byte bus cycle per pending transfer.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            movep_start_r  <= 1'b0;
            movep_pre_r    <= 1'b0;
            movep_run_r    <= 1'b0;
            movep_load_r   <= 1'b0;
            movep_long_r   <= 1'b0;
            movep_byte_r   <= 2'd0;
            movep_addr_r   <= 32'h0;
            movep_dn_r     <= 3'h0;
            movep_dn_val_r <= 32'h0;
            movep_acc_r    <= 32'h0;
            movep_wr_byte_r <= 8'h0;
        end else if (!movep_start_r && !movep_pre_r && !movep_run_r && instr_ack && dec_is_movep) begin
            movep_start_r <= 1'b1;
            movep_load_r  <= dec_movep_load;
            movep_long_r  <= dec_movep_long;
            movep_dn_r    <= f_dn;
        end else if (movep_start_r) begin
            // Cycle 1: EX stage holds MOVEP (ex_ea, rd_b_data valid).
            // Capture Dn value and byte 0 — movep_wr_byte_r will be stable NEXT cycle.
            movep_start_r  <= 1'b0;
            movep_pre_r    <= 1'b1;
            movep_byte_r   <= 2'd0;
            movep_addr_r   <= ex_ea;       // EA = An + d16 from EX combinatorial
            movep_dn_val_r <= rd_b_data;   // Dn value for stores (full longword)
            movep_acc_r    <= 32'h0;
            movep_wr_byte_r <= movep_long_r ? rd_b_data[31:24] : rd_b_data[15:8];
        end else if (movep_pre_r) begin
            // Cycle 2: movep_wr_byte_r is now stable from cycle 1.
            // Assert movep_run_r so eu_req goes high with stable wdata.
            movep_pre_r  <= 1'b0;
            movep_run_r  <= 1'b1;
        end else if (movep_run_r && mem_ack) begin
            movep_byte_r  <= movep_byte_r + 2'd1;
            movep_addr_r  <= movep_addr_r + 32'd2;
            movep_acc_r   <= movep_rd_acc_w;
            if (movep_last) begin
                movep_run_r <= 1'b0;
            end else begin
                // Pre-register next byte — will be stable by the next bus cycle
                if (movep_long_r)
                    movep_wr_byte_r <= (movep_byte_r == 2'd0) ? movep_dn_val_r[23:16] :
                                       (movep_byte_r == 2'd1) ? movep_dn_val_r[15:8]  :
                                                                 movep_dn_val_r[7:0];
                else
                    movep_wr_byte_r <= movep_dn_val_r[7:0];
            end
        end else if (movep_run_r && mem_abort) begin
            // A fault partway through the byte-interleaved sequence aborts
            // the whole instruction — real 68030 doesn't leave a partial
            // MOVEP transfer in place.
            movep_run_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // MOVE16 16-byte block move FSM
    // start_r (1 cycle): capture src/dst base addresses from rd_a/rd_b/ex_imm.
    // run_r phase 0: 4 longword reads from src, accumulate in move16_data_r.
    // run_r phase 1: 4 longword writes to dst from move16_data_r.
    // An postinc (if needed): src An fires on move16_last; dst An fires next cycle.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            move16_start_r       <= 1'b0;
            move16_run_r         <= 1'b0;
            move16_phase_r       <= 1'b0;
            move16_beat_r        <= 2'd0;
            move16_src_r         <= 32'h0;
            move16_dst_r         <= 32'h0;
            move16_src_base_r    <= 32'h0;
            move16_dst_base_r    <= 32'h0;
            move16_data_r[0]     <= 32'h0; move16_data_r[1] <= 32'h0;
            move16_data_r[2]     <= 32'h0; move16_data_r[3] <= 32'h0;
            move16_form_r        <= 2'b0;
            move16_src_postinc_r <= 1'b0;
            move16_dst_postinc_r <= 1'b0;
            move16_src_an_r      <= 3'h0;
            move16_dst_an_r      <= 3'h0;
            move16_an2_wr_r      <= 1'b0;
        end else begin
            // Deferred dst An postinc: fire cycle after move16_last when dst needs postinc
            move16_an2_wr_r <= move16_last && move16_dst_postinc_r;

            if (!move16_start_r && !move16_run_r && instr_ack && dec_is_move16) begin
                move16_start_r       <= 1'b1;
                move16_form_r        <= dec_move16_form;
                move16_src_an_r      <= f_reg;
                move16_dst_an_r      <= ext_data[14:12];
                // src postinc for forms 00 (post/post) and 01 (An+/abs)
                move16_src_postinc_r <= (dec_move16_form == 2'b00) || (dec_move16_form == 2'b01);
                // dst postinc for forms 00 (post/post) and 10 (abs/An+)
                move16_dst_postinc_r <= (dec_move16_form == 2'b00) || (dec_move16_form == 2'b10);
            end else if (move16_start_r) begin
                move16_start_r <= 1'b0;
                move16_run_r   <= 1'b1;
                move16_phase_r <= 1'b0;
                move16_beat_r  <= 2'd0;
                case (move16_form_r)
                    2'b00: begin  // (An)+,(Am)+: src=rd_a, dst=rd_b
                        move16_src_r      <= rd_a_data; move16_src_base_r <= rd_a_data;
                        move16_dst_r      <= rd_b_data; move16_dst_base_r <= rd_b_data;
                    end
                    2'b01: begin  // (An)+,(xxx).L: src=rd_a (An), dst=ex_imm (abs)
                        move16_src_r      <= rd_a_data; move16_src_base_r <= rd_a_data;
                        move16_dst_r      <= ex_imm;    move16_dst_base_r <= ex_imm;
                    end
                    2'b10: begin  // (xxx).L,(An)+: src=ex_imm (abs), dst=rd_a (An)
                        move16_src_r      <= ex_imm;    move16_src_base_r <= ex_imm;
                        move16_dst_r      <= rd_a_data; move16_dst_base_r <= rd_a_data;
                    end
                    2'b11: begin  // (An),(An): src=rd_a, dst=rd_b, no postinc
                        move16_src_r      <= rd_a_data; move16_src_base_r <= rd_a_data;
                        move16_dst_r      <= rd_b_data; move16_dst_base_r <= rd_b_data;
                    end
                endcase
            end else if (move16_run_r && mem_ack) begin
                if (!move16_phase_r) begin
                    // Read phase: capture longword, advance src address
                    case (move16_beat_r)
                        2'd0: move16_data_r[0] <= mem_rdata;
                        2'd1: move16_data_r[1] <= mem_rdata;
                        2'd2: move16_data_r[2] <= mem_rdata;
                        2'd3: move16_data_r[3] <= mem_rdata;
                    endcase
                    if (move16_beat_r == 2'd3) begin
                        move16_phase_r <= 1'b1;
                        move16_beat_r  <= 2'd0;
                        move16_dst_r   <= move16_dst_base_r;  // reset dst to base for writes
                    end else begin
                        move16_beat_r <= move16_beat_r + 2'd1;
                        move16_src_r  <= move16_src_r + 32'd4;
                    end
                end else begin
                    // Write phase
                    if (move16_beat_r == 2'd3) begin
                        move16_run_r <= 1'b0;
                    end else begin
                        move16_beat_r <= move16_beat_r + 2'd1;
                        move16_dst_r  <= move16_dst_r + 32'd4;
                    end
                end
            end else if (move16_run_r && mem_abort) begin
                // A fault on any of the 8 beats (4 reads + 4 writes) aborts
                // the whole block move — real 68030 doesn't partially copy.
                move16_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // FPU coprocessor dispatch FSM
    // On instr_ack of a FPU instruction, issue one CPI read via eu_coproc_req.
    // Address: A[19:16]=0010 (coproc), A[15:13]=ppp, A[12:11]=01 (cpid=1), A[10:0]=0.
    // Full FPU response protocol deferred; stub completes when eu_coproc_ack fires.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            fpu_start_r <= 1'b0;
            fpu_run_r   <= 1'b0;
            fpu_prim_r  <= 3'h0;
        end else begin
            if (!fpu_start_r && !fpu_run_r && instr_ack && dec_is_fpu) begin
                fpu_start_r <= 1'b1;
                fpu_prim_r  <= {f_dir, f_ss};   // ppp from opcode bits [8:6]
            end else if (fpu_start_r) begin
                fpu_start_r <= 1'b0;
                fpu_run_r   <= 1'b1;
            end else if (fpu_run_r && (eu_coproc_ack || eu_coproc_berr)) begin
                fpu_run_r   <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // cpSAVE/cpRESTORE dispatch FSM (Phase 157 Stage 4 stub; real protocol
    // added open-items backlog Stage 14, plan.md).
    // Shares eu_coproc_req/ack/berr with the FPU FSM above -- at most one
    // EU-issued CPU-space cycle is ever in flight, since only one instruction
    // occupies EX at a time.
    //
    // For any EA mode OTHER than (An) (cpsr_real_r==0, captured at dispatch
    // from f_mode -- see the decode block's own comment), this is exactly
    // the original Phase 157 Stage 4 stub: one CIR read, then complete.
    //
    // For (An) mode, the real Section 10.2.3 protocol:
    //   cpSAVE:    cpsr_run_r (read Save CIR, retries in place on NOT_READY)
    //           -> cpsr_mem_fmt_r (write {format,length,0} longword to EA)
    //           -> [VALID only] transfer loop, descending from EA+length
    //   cpRESTORE: cpsr_mem_fmt_r (read format longword FROM memory at EA)
    //           -> cpsr_cir_wr_r (write format word to Restore CIR)
    //           -> cpsr_cir_echo_r (read Restore CIR back -- confirms format)
    //           -> [VALID only] transfer loop, ascending from EA+4
    //   Either: INVALID/reserved format code, or a VALID format whose length
    //           isn't a multiple of 4, routes to cpsr_abort_r (writes $0001
    //           to the Control CIR per 10.2.3.2.3/10.5.1.5) then the
    //           already-existing vector-14 Format Error dispatch
    //           (cpsr_fmt_err_w, folded into eu_fmt_err_req's own assign).
    //
    // Format-branch decisions are made LIVE off eu_coproc_rdata/mem_rdata at
    // the exact ack cycle (not the registered cpsr_fmt_r, which lags by one
    // edge) -- avoids an unnecessary extra "wait one more cycle before it's
    // safe to branch" state, the same lesson BKPT's own bkpt_wait_replacement_r
    // exists to bridge for a genuinely different reason (Stage 13) doesn't
    // apply here, since nothing downstream needs the REGISTERED cpsr_fmt_r
    // to be valid on this exact same edge.
    //
    // Deliberately out of scope, matching this project's own repeated
    // "non-indexed EA first, everything else deferred" precedent: every EA
    // mode besides (An) -- predecrement (cpSAVE), postincrement/displacement/
    // indexed/absolute/PC-relative (either) -- and interrupt servicing during
    // a NOT_READY retry (the retry loop itself is implemented; only the
    // "service pending interrupts between polls" optimization the manual
    // separately describes is skipped, matching real 68030 architecture,
    // which permits but does not require it). No real coprocessor, Harte
    // vector, or Musashi reference exists for this instruction family (same
    // caveat as the FPU stub itself, Phase 55) -- correctness here is
    // necessarily self-consistency against the manual's own protocol
    // description, not independently verified against any oracle.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cpsr_start_r      <= 1'b0;
            cpsr_run_r        <= 1'b0;
            cpsr_is_restore_r <= 1'b0;
            cpsr_fmt_r        <= 16'h0;
            cpsr_real_r       <= 1'b0;
            cpsr_mem_fmt_r    <= 1'b0;
            cpsr_cir_wr_r     <= 1'b0;
            cpsr_cir_echo_r   <= 1'b0;
            cpsr_abort_r      <= 1'b0;
            cpsr_xfer_cir_r   <= 1'b0;
            cpsr_xfer_mem_r   <= 1'b0;
            cpsr_len_r        <= 8'h0;
            cpsr_xfer_cnt_r   <= 8'h0;
            cpsr_xfer_addr_r  <= 32'h0;
            cpsr_xfer_val_r   <= 32'h0;
            cpsr_ea_r         <= 32'h0;
        end else begin
            if (!cpsr_start_r && !cpsr_run_r && !cpsr_mem_fmt_r && !cpsr_cir_wr_r &&
                !cpsr_cir_echo_r && !cpsr_abort_r && !cpsr_xfer_cir_r && !cpsr_xfer_mem_r &&
                instr_ack && (dec_is_cpsave || dec_is_cprestore)) begin
                cpsr_start_r      <= 1'b1;
                cpsr_is_restore_r <= dec_is_cprestore;
                cpsr_real_r       <= (f_mode == 3'b010) ||
                                      (dec_is_cpsave    && f_mode == 3'b100) ||  // -(An)
                                      (dec_is_cprestore && f_mode == 3'b011);    // (An)+
            end else if (cpsr_start_r) begin
                cpsr_start_r <= 1'b0;
                cpsr_ea_r    <= ex_ea;  // capture before cpsr_an_wr_en's own
                                         // register commit can make ex_ea stale
                if (cpsr_is_restore_r && cpsr_real_r) begin
                    // cpRESTORE, real-protocol EA (Stage 6: (An) or (An)+):
                    // first step is a real memory read of the format word,
                    // not a CIR access. Was f_mode==3'b010 only -- widened
                    // to cpsr_real_r (already correctly gates exactly the
                    // set of real-protocol modes, captured the same cycle
                    // one branch up) once (An)+ became real too.
                    cpsr_mem_fmt_r <= 1'b1;
                end else begin
                    // cpSAVE (any mode, since it always starts with the Save
                    // CIR read regardless), or a stub-scope (non-(An)) cpRESTORE.
                    cpsr_run_r <= 1'b1;
                end
            end else if (cpsr_run_r && eu_coproc_ack) begin
                cpsr_fmt_r <= eu_coproc_rdata[31:16];
                if (!cpsr_real_r) begin
                    // Stub scope: capture and complete, exactly as before.
                    cpsr_run_r <= 1'b0;
                end else if (eu_coproc_rdata[31:24] == 8'h01) begin
                    // NOT_READY -- stay in cpsr_run_r, re-issues next cycle.
                end else if (eu_coproc_rdata[31:24] == 8'h00 ||
                             (eu_coproc_rdata[31:24] >= 8'h10 &&
                              eu_coproc_rdata[17:16] == 2'b00)) begin
                    // EMPTY, or VALID with a genuine multiple-of-4 length.
                    cpsr_run_r     <= 1'b0;
                    cpsr_mem_fmt_r <= 1'b1;
                end else begin
                    // INVALID/reserved ($02-$0F), or VALID with a bad length.
                    cpsr_run_r   <= 1'b0;
                    cpsr_abort_r <= 1'b1;
                end
            end else if (cpsr_run_r && eu_coproc_berr) begin
                cpsr_run_r <= 1'b0;
            end else if (cpsr_mem_fmt_r && mem_ack) begin
                if (!cpsr_is_restore_r) begin
                    // cpSAVE: just wrote the format longword to EA.
                    cpsr_mem_fmt_r <= 1'b0;
                    // By construction, cpsr_fmt_r here is guaranteed EMPTY
                    // (0x00) or VALID-with-good-length (>=0x10, already
                    // multiple-of-4-checked) -- anything else was already
                    // routed to cpsr_abort_r back in the cpsr_run_r branch.
                    // Re-checking >=0x10 explicitly (rather than relying
                    // implicitly on "not EMPTY") for defensive clarity.
                    if (cpsr_fmt_r[15:8] >= 8'h10 && cpsr_fmt_r[7:0] != 8'h00) begin
                        // VALID with a nonzero length -- start the transfer
                        // loop, descending from EA+length.
                        cpsr_len_r       <= cpsr_fmt_r[7:0];
                        cpsr_xfer_cnt_r  <= 8'h0;
                        cpsr_xfer_addr_r <= cpsr_ea_r + {24'h0, cpsr_fmt_r[7:0]};
                        cpsr_xfer_cir_r  <= 1'b1;
                    end
                    // else: EMPTY (or VALID-with-zero-length, an edge case the
                    // manual doesn't explicitly address) -- done, nothing more.
                end else begin
                    // cpRESTORE: just read the format longword FROM memory.
                    // Retains the length field from THIS read (per 10.2.3.4.2:
                    // "the main processor retains a copy of the length field"),
                    // used later even though the echo re-read (below) may
                    // return a different format code.
                    cpsr_fmt_r     <= mem_rdata[31:16];
                    cpsr_len_r     <= mem_rdata[23:16];
                    cpsr_mem_fmt_r <= 1'b0;
                    cpsr_cir_wr_r  <= 1'b1;
                end
            end else if (cpsr_cir_wr_r && eu_coproc_ack) begin
                // cpRESTORE: format word landed in the Restore CIR -- read it
                // back to confirm (manual M4).
                cpsr_cir_wr_r   <= 1'b0;
                cpsr_cir_echo_r <= 1'b1;
            end else if (cpsr_cir_wr_r && eu_coproc_berr) begin
                cpsr_cir_wr_r <= 1'b0;
            end else if (cpsr_cir_echo_r && eu_coproc_ack) begin
                cpsr_cir_echo_r <= 1'b0;
                if (eu_coproc_rdata[31:24] == 8'h00) begin
                    // EMPTY -- done.
                end else if (eu_coproc_rdata[31:24] >= 8'h10 && cpsr_len_r != 8'h0 &&
                             cpsr_len_r[1:0] == 2'b00) begin
                    // VALID, using the length retained from the original
                    // memory read -- start the transfer loop, ascending
                    // from EA+4.
                    cpsr_xfer_cnt_r  <= 8'h0;
                    cpsr_xfer_addr_r <= cpsr_ea_r + 32'd4;
                    cpsr_xfer_mem_r  <= 1'b1;
                end else begin
                    // INVALID/reserved, or a bad (non-multiple-of-4 or zero)
                    // retained length.
                    cpsr_abort_r <= 1'b1;
                end
            end else if (cpsr_cir_echo_r && eu_coproc_berr) begin
                cpsr_cir_echo_r <= 1'b0;
            end else if (cpsr_abort_r && (eu_coproc_ack || eu_coproc_berr)) begin
                // Abort-mask write to the Control CIR completed (or itself
                // faulted -- either way, give up cleanly). The format-error
                // exception itself fires via cpsr_fmt_err_w (a combinational
                // one-shot keyed off this exact ack), not from this register.
                cpsr_abort_r <= 1'b0;
            end else if (cpsr_xfer_cir_r && eu_coproc_ack) begin
                if (!cpsr_is_restore_r) begin
                    // cpSAVE: just read one longword from the Operand CIR --
                    // write it to memory next.
                    cpsr_xfer_val_r <= eu_coproc_rdata;
                    cpsr_xfer_cir_r <= 1'b0;
                    cpsr_xfer_mem_r <= 1'b1;
                end else begin
                    // cpRESTORE: just wrote one longword to the Operand CIR --
                    // this completes one loop iteration.
                    cpsr_xfer_cir_r <= 1'b0;
                    if ((cpsr_xfer_cnt_r + 8'd4) < cpsr_len_r) begin
                        cpsr_xfer_cnt_r  <= cpsr_xfer_cnt_r + 8'd4;
                        cpsr_xfer_addr_r <= cpsr_xfer_addr_r + 32'd4;
                        cpsr_xfer_mem_r  <= 1'b1;
                    end
                    // else: this was the last longword -- done.
                end
            end else if (cpsr_xfer_cir_r && eu_coproc_berr) begin
                cpsr_xfer_cir_r <= 1'b0;
            end else if (cpsr_xfer_mem_r && mem_ack) begin
                if (!cpsr_is_restore_r) begin
                    // cpSAVE: just wrote one longword to memory -- this
                    // completes one loop iteration.
                    cpsr_xfer_mem_r <= 1'b0;
                    if ((cpsr_xfer_cnt_r + 8'd4) < cpsr_len_r) begin
                        cpsr_xfer_cnt_r  <= cpsr_xfer_cnt_r + 8'd4;
                        cpsr_xfer_addr_r <= cpsr_xfer_addr_r - 32'd4;
                        cpsr_xfer_cir_r  <= 1'b1;
                    end
                    // else: this was the last longword -- done.
                end else begin
                    // cpRESTORE: just read one longword from memory -- write
                    // it to the Operand CIR next.
                    cpsr_xfer_val_r <= mem_rdata;
                    cpsr_xfer_mem_r <= 1'b0;
                    cpsr_xfer_cir_r <= 1'b1;
                end
            end
        end
    end

    // cpsr_fmt_err_raw's own assign -- see its declaration (near the other
    // cpsr_* registers) for why this needs no Icarus forward-reference split.
    assign cpsr_fmt_err_raw = cpsr_abort_r && (eu_coproc_ack || eu_coproc_berr);

    // -----------------------------------------------------------------------
    // BKPT breakpoint-acknowledge dispatch FSM (Phase 157 Stage 3; live
    // substitution added open-items backlog Stage 13, plan.md)
    // On instr_ack of a BKPT instruction, issue one CPU-space read via
    // eu_bkpt_req -- address per manual Figure 7-42 (type field 0, breakpoint
    // number on A[4:2]). Two outcomes (Section 7.4.2):
    //   DSACK'd/STERM'd: data word is a replacement opcode, captured into
    //   bkpt_replacement_r, then genuinely spliced into the pipeline in
    //   place of BKPT (bkpt_wait_replacement_r/bkpt_subst_active_r below,
    //   feeding m68030_ifu.sv's own new instr_word override mux) -- BKPT
    //   is always exactly 1 word with no extension words of its own, so
    //   the replacement's own extension words (if any) are simply
    //   whatever real memory already holds right after the BKPT opcode --
    //   exactly what a real fetched instruction's own extension words
    //   would be too, needing no special IFU drain handling beyond the
    //   ordinary ext_count computed fresh from the substituted instr_word.
    //   Real memory is never modified -- this is a pure pipeline-internal
    //   substitution, matching the manual's own "spliced... in place of
    //   BKPT" wording exactly.
    //   BERR'd: illegal instruction exception (bkpt_trap_w above).
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            bkpt_start_r             <= 1'b0;
            bkpt_run_r               <= 1'b0;
            bkpt_num_r               <= 3'h0;
            bkpt_replacement_r       <= 16'h0;
            bkpt_wait_replacement_r  <= 1'b0;
            bkpt_subst_active_r      <= 1'b0;
        end else begin
            // open-items backlog Stage 13 (plan.md): the dispatch trigger
            // is dec_valid (decode currently sees a valid BKPT opcode),
            // NOT instr_ack -- with live substitution, instr_ack for a
            // raw, unresolved BKPT opcode must never fire at all (see the
            // new bkpt_raw_stall term folded into ex_mem_stall below,
            // which is exactly what keeps instr_ack low here), so a
            // trigger keyed on instr_ack would never fire, deadlocking
            // the whole mechanism. dec_valid alone is enough: decode
            // genuinely IS looking at a real BKPT opcode this cycle,
            // stall or not.
            //
            // Bug 2 fix: also require !ex_redirect_pending, matching the
            // identical guard added to the ex_mem_stall term above -- see
            // ex_redirect_pending's own declaration/comment for the full
            // derivation (a stale fall-through decode slot, about to be
            // flushed by an older JSR/BSR/RTS/RTR/RTE's own pending
            // redirect, must never be trusted as a real BKPT dispatch).
            if (!bkpt_start_r && !bkpt_run_r && !bkpt_wait_replacement_r &&
                !bkpt_subst_active_r && dec_valid && dec_is_bkpt &&
                !ex_redirect_pending) begin
                bkpt_start_r <= 1'b1;
                bkpt_num_r   <= f_reg;   // breakpoint number, opcode bits [2:0]
            end else if (bkpt_start_r) begin
                bkpt_start_r <= 1'b0;
                bkpt_run_r   <= 1'b1;
            end else if (bkpt_run_r && eu_bkpt_ack) begin
                bkpt_run_r              <= 1'b0;
                bkpt_replacement_r      <= eu_bkpt_rdata[31:16]; // word-aligned read: word lands top-justified
                bkpt_wait_replacement_r <= 1'b1;
            end else if (bkpt_wait_replacement_r) begin
                // bkpt_replacement_r is valid as of THIS cycle (registered
                // the same edge bkpt_run_r cleared) -- now safe to present.
                bkpt_wait_replacement_r <= 1'b0;
                bkpt_subst_active_r     <= 1'b1;
            end else if (bkpt_subst_active_r && instr_ack) begin
                // The substituted decode was accepted -- revert instr_word
                // to the IFU's own q[0] for the instruction after it.
                bkpt_subst_active_r <= 1'b0;
            end else if (bkpt_run_r && eu_bkpt_berr) begin
                bkpt_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // memory-indirect EA FSM
    // Sequence: start_r (1 cycle, An/Xn in rd_a/rd_b) → inner_r (longword
    // read at inner_addr) → outer_r (instruction-sized read at outer addr).
    // Outer address = ptr + post_xn + od.
    // Direct WB fires on outer_r && mem_ack (bypasses WB latch like MOVEM).
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            memind_start_r     <= 1'b0;
            memind_inner_r     <= 1'b0;
            memind_outer_r     <= 1'b0;
            memind_inner_addr_r <= 32'h0;
            memind_ptr_r       <= 32'h0;
            memind_od_r        <= 32'h0;
            memind_post_xn_r   <= 32'h0;
            memind_is_rd_r     <= 1'b1;
            memind_siz_r       <= 2'b00;
            memind_dest_r      <= 4'h0;
            memind_addr_only_r <= 1'b0;
            memind_is_pea_r    <= 1'b0;
            memind_pea_wr_addr_r <= 32'h0;
            memind_is_jsr_r    <= 1'b0;
        end else if (!memind_start_r && !memind_inner_r && !memind_outer_r
                     && instr_ack && dec_is_memind) begin
            memind_start_r     <= 1'b1;
            // memind only supports load ops, except PEA/JSR's own outer
            // phase, which is a write (PEA: resolved EA; JSR: return PC).
            memind_is_rd_r     <= !dec_is_pea && !dec_is_jsr;
            memind_siz_r       <= dec_siz;
            memind_dest_r      <= dec_dest_reg;
            memind_od_r        <= dec_memind_od;
            // 10-item backlog Stage 9b (plan.md): JMP shares LEA's own
            // address-only shape exactly -- it never dereferences its own
            // final EA either, just becomes the new PC directly.
            memind_addr_only_r <= dec_is_lea || dec_is_jmp;
            memind_is_pea_r    <= dec_is_pea;
            memind_is_jsr_r    <= dec_is_jsr;
        end else if (memind_start_r) begin
            // EX holds: rd_a=An (ex_ea = inner addr), rd_b=Xn (for post-indexed outer)
            memind_start_r      <= 1'b0;
            memind_inner_r      <= 1'b1;
            memind_inner_addr_r <= ex_ea;
            // Capture Xn*SCALE for post-indexed outer EA (0 if pre-indexed)
            memind_post_xn_r    <= (ex_is_memind && ex_memind_is_post) ? memind_xn_sc_w : 32'h0;
            // PEA's own push address (A7-4), captured now -- ex_cur_sp
            // itself may reflect a since-applied predecrement by the time
            // the outer write phase actually runs.
            memind_pea_wr_addr_r <= ex_cur_sp - 32'd4;
        end else if (memind_inner_r && mem_ack) begin
            memind_inner_r <= 1'b0;
            // 10-item backlog Stage 9a (plan.md): LEA's own address-only
            // case never dereferences the resolved EA -- complete directly
            // here (memind_addr_wr_en below fires this same cycle) instead
            // of dispatching an outer bus cycle that would read a value
            // LEA never needs.
            memind_outer_r <= !memind_addr_only_r;
            memind_ptr_r   <= mem_rdata;   // 32-bit pointer from inner read
        end else if (memind_outer_r && mem_ack) begin
            memind_outer_r <= 1'b0;
        end else if (memind_inner_r && mem_abort) begin
            // A fault on the inner (pointer) read aborts the whole
            // memory-indirect EA — must explicitly reset here or this
            // stays stuck for the next ([bd,An],Xn,od) instruction.
            memind_inner_r <= 1'b0;
        end else if (memind_outer_r && mem_abort) begin
            // A fault on the outer read aborts the same way.
            memind_outer_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // PFLUSH / PTEST FSM
    // PFLUSH: start_r captures VA; req_r asserts eu_pflush_req until ack.
    // PTEST:  start_r captures VA; run_r asserts eu_ptest_req until ack.
    // PMOVE:  uses normal mem path (dec_is_mem_rd/wr); capture on mem_ack.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            pflush_start_r <= 1'b0; pflush_req_r <= 1'b0;
            pflush_all_r   <= 1'b0; pflush_fc_r  <= 3'b0;
            pflush_va_r    <= 32'h0;
            ptest_start_r  <= 1'b0; ptest_run_r  <= 1'b0;
            ptest_va_r     <= 32'h0; ptest_fc_r  <= 3'b0;
            pload_start_r  <= 1'b0; pload_run_r  <= 1'b0;
            pload_va_r     <= 32'h0; pload_fc_r  <= 3'b0;
            pload_rw_r     <= 1'b1;
            tc_r           <= 32'h0;
            tt0_r          <= 32'h0;
            tt1_r          <= 32'h0;
            mmusr_r        <= 16'h0;
        end else begin
            // ── PFLUSH FSM ───────────────────────────────────────────────────
            if (!pflush_start_r && !pflush_req_r && instr_ack && dec_is_pflush) begin
                pflush_start_r <= 1'b1;
                pflush_all_r   <= dec_pflush_all;
                pflush_fc_r    <= dec_pflush_fc;
            end else if (pflush_start_r) begin
                pflush_start_r <= 1'b0;
                pflush_req_r   <= 1'b1;
                pflush_va_r    <= ex_ea;   // An value (0-offset An-indirect)
            end else if (pflush_req_r && eu_pflush_ack) begin
                pflush_req_r   <= 1'b0;
            end

            // ── PTEST FSM ────────────────────────────────────────────────────
            if (!ptest_start_r && !ptest_run_r && instr_ack && dec_is_ptest) begin
                ptest_start_r <= 1'b1;
                ptest_fc_r    <= dec_ptest_fc;
            end else if (ptest_start_r) begin
                ptest_start_r <= 1'b0;
                ptest_run_r   <= 1'b1;
                ptest_va_r    <= ex_ea;
            end else if (ptest_run_r && eu_ptest_ack) begin
                ptest_run_r   <= 1'b0;
                mmusr_r       <= eu_ptest_mmusr;
            end

            // ── PLOAD FSM (Phase 150 Stage 5) ─────────────────────────────────
            // Same shape as PTEST, but a real (non-PTEST) walk -- U/M
            // write-back and ATC installation happen exactly like an
            // ordinary access would (biu_mmu_if.sv's is_ptest gating is
            // driven false for this request, see m68030_mmu.sv's own
            // pload_req dispatch). No destination register: PLOAD is a
            // pure side-effecting instruction, like PFLUSH.
            if (!pload_start_r && !pload_run_r && instr_ack && dec_is_pload) begin
                pload_start_r <= 1'b1;
                pload_fc_r    <= dec_pload_fc;
                pload_rw_r    <= dec_pload_rw;
            end else if (pload_start_r) begin
                pload_start_r <= 1'b0;
                pload_run_r   <= 1'b1;
                pload_va_r    <= ex_ea;
            end else if (pload_run_r && eu_pload_ack) begin
                pload_run_r   <= 1'b0;
                mmusr_r       <= eu_pload_mmusr;
            end

            // ── PMOVE register capture (EA→MMU register direction) ───────────
            if (ex_valid && ex_is_pmove && !ex_pmove_to_mem && mem_ack) begin
                case (ex_pmove_preg)
                    3'b010: tc_r  <= mem_rdata;
                    3'b001: tt0_r <= mem_rdata;
                    3'b011: tt1_r <= mem_rdata;
                    default: ;
                endcase
            end
        end
    end

    // PMOVE write-data mux (register→EA direction)
    logic [31:0] pmove_wr_data_w;
    always_comb begin
        case (ex_pmove_preg)
            3'b010:  pmove_wr_data_w = tc_r;
            3'b001:  pmove_wr_data_w = tt0_r;
            3'b011:  pmove_wr_data_w = tt1_r;
            3'b000:  pmove_wr_data_w = {16'h0, mmusr_r};
            default: pmove_wr_data_w = 32'h0;
        endcase
    end

    // PACK/UNPK register-form combinational result
    // PACK Dy,Dx,#adj: temp = Dy[15:0] + adj; result byte = {temp[11:8], temp[3:0]}
    logic [15:0] pack_reg_temp_w;
    assign pack_reg_temp_w = rd_a_data[15:0] + ex_imm[15:0];
    // UNPK Dy,Dx,#adj: temp = {0,Dy[7:4],0,Dy[3:0]} + adj; result word = temp
    logic [15:0] unpk_reg_temp_w;
    assign unpk_reg_temp_w = {4'h0, rd_a_data[7:4], 4'h0, rd_a_data[3:0]} + ex_imm[15:0];

    // PACK/UNPK memory-form combinational result (from captured read data)
    logic [15:0] pack_mem_temp_w;
    assign pack_mem_temp_w = pack_mem_is_unpk_r
        ? ({4'h0, pack_mem_src_r[7:4], 4'h0, pack_mem_src_r[3:0]} + pack_mem_adj_r)
        : (pack_mem_src_r[15:0] + pack_mem_adj_r);
    // Write data for phase 1
    logic [31:0] pack_mem_wdata_w;
    assign pack_mem_wdata_w = pack_mem_is_unpk_r
        ? {pack_mem_temp_w, 16'h0}                                       // UNPK: write word in [31:16]
        : {pack_mem_temp_w[11:8], pack_mem_temp_w[3:0], 24'h0};         // PACK: write byte in [31:24]
    // Phase 0 read size / phase 1 write size
    logic [1:0] pack_mem_cur_siz;
    assign pack_mem_cur_siz = pack_mem_phase_r
        ? (pack_mem_is_unpk_r ? 2'b10 : 2'b01)   // write: UNPK=word, PACK=byte
        : (pack_mem_is_unpk_r ? 2'b01 : 2'b10);  // read: UNPK=byte, PACK=word

    // CHK comparison: rd_b = value checked (Dn); upper bound from register/imm or memory.
    // CHK.W only tests/compares the low 16 bits — both operands must be sign-extended
    // to 32 bits before the signed compare, else garbage in Dn[31:16]/bound[31:16]
    // corrupts the result (Musashi: sint src = MAKE_INT_16(DX)).
    logic [31:0] chk_val_w, chk_ub_w, chk_val_ext_w, chk_ub_ext_w;
    logic        chk_below_w, chk_above_w;
    // Cycle-accuracy-closing plan.md, Stage 2: chk_trap_raw/chk_trap_
    // fired_r declared here (near chk_below_w/chk_above_w, which the
    // chk_trap_raw assign further down depends on) so the always_ff block
    // below can reference chk_trap_raw without a forward-declaration issue
    // -- this project has hit that exact Icarus limitation many times
    // before with mid-file continuous assigns.
    logic        chk_trap_raw, chk_trap_fired_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)             chk_trap_fired_r <= 1'b0;
        else if (!ex_valid)     chk_trap_fired_r <= 1'b0;
        else if (chk_trap_raw)  chk_trap_fired_r <= 1'b1;
    end
    // MUL/DIV timing investigation (plan.md): div_trap needs the IDENTICAL
    // one-shot treatment chk_trap already got in the cycle-accuracy-closing
    // plan's own Stage 2 (see that fix's own comment below, and
    // chk_trap_fired_r just above, for the full derivation) -- div_trap's
    // own register-direct divide-by-zero condition (ex_valid && ex_unit==
    // UNIT_DIV && !ex_is_mem_src && md_div_by_zero) is a pure combinational
    // expression with no edge protection, and once DIVS.L/DIVU.L Dn,Dn
    // gained a real internal stall (holding ex_valid for ~350 ticks instead
    // of 1), it re-fires every single tick of that stall instead of once --
    // found via make test's own alu_reg suite hanging (DIV-04, the
    // dedicated divide-by-zero trap test) the moment the stall was added,
    // the exact same symptom class chk_trap's own history already
    // documents ("the register-direct CHK path had never held ex_valid for
    // more than 1 cycle before this stall existed, so nothing needed one").
    logic        div_trap_raw, div_trap_fired_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)             div_trap_fired_r <= 1'b0;
        else if (!ex_valid)     div_trap_fired_r <= 1'b0;
        else if (div_trap_raw)  div_trap_fired_r <= 1'b1;
    end
    assign chk_val_w     = rd_b_data;
    assign chk_ub_w      = ex_use_imm ? ex_imm : rd_a_data;
    assign chk_val_ext_w = ex_chk_word ? {{16{chk_val_w[15]}}, chk_val_w[15:0]} : chk_val_w;
    assign chk_ub_ext_w  = ex_chk_word ? {{16{chk_ub_w[15]}},  chk_ub_w[15:0]}  : chk_ub_w;
    assign chk_below_w   = ex_chk_word ? chk_val_w[15] : chk_val_w[31];
    assign chk_above_w   = $signed(chk_val_ext_w) > $signed(chk_ub_ext_w);

    // CHK with memory-source upper bound — fires when read ack arrives.
    // rd_b_data = Dn (value to check); mem_rdata = upper bound from memory.
    logic [31:0] chk_mem_ub_w;
    logic        chk_mem_below_w, chk_mem_above_w;
    assign chk_mem_ub_w    = ex_chk_word ? {{16{mem_rdata[15]}}, mem_rdata[15:0]} : mem_rdata;
    assign chk_mem_below_w = ex_chk_word ? rd_b_data[15] : rd_b_data[31];
    assign chk_mem_above_w = $signed(chk_val_ext_w) > $signed(chk_mem_ub_w);

    // Z reflects the tested value only (Musashi: FLAG_Z = ZFLAG_16(src), unconditional —
    // set every CHK regardless of trap). N is set from the sign of the tested value only
    // when CHK actually traps (below 0 or above bound); otherwise N is left unchanged
    // ("undefined" on real silicon; Musashi's early-return path never touches FLAG_N).
    logic       chk_z_w;
    logic       chk_traps_w;
    assign chk_z_w     = ex_chk_word ? (chk_val_w[15:0] == 16'h0) : (chk_val_w == 32'h0);
    assign chk_traps_w = ex_is_mem_rd ? (chk_mem_below_w || chk_mem_above_w)
                                       : (chk_below_w     || chk_above_w);

    logic [31:0] ex_src_operand;
    assign ex_src_operand = ex_use_imm ? ex_imm : rd_a_data;

    // UNIT_MOVE result: SWAP swaps halfwords; EXT sign-extends; otherwise imm/reg source.
    // Must be pre-computed assigns to avoid Icarus constant-select warnings.
    logic [31:0] move_result_w;
    assign move_result_w =
        // MOVE Dn/An → (d8,An,Xn) (Phase 149, plan.md): genuine single-phase write,
        // source register value always live on rd_c (no swap-timing gating needed).
        ex_is_move_reg_idx_dst ? rd_c_data :
        ex_is_swap       ? {rd_a_data[15:0], rd_a_data[31:16]} :
        ex_sext          ? (ex_sext_from_byte ? {{24{rd_a_data[7]}},  rd_a_data[7:0]}
                                              : {{16{rd_a_data[15]}}, rd_a_data[15:0]}) :
                           ex_src_operand;

    logic move_result_n_b, move_result_n_w, move_result_n_l;
    logic move_result_z_b, move_result_z_w;
    assign move_result_n_b = move_result_w[7];
    assign move_result_n_w = move_result_w[15];
    assign move_result_n_l = move_result_w[31];
    assign move_result_z_b = (move_result_w[7:0]  == 8'h00);
    assign move_result_z_w = (move_result_w[15:0] == 16'h00);

    // -----------------------------------------------------------------------
    // eu_bitfield combinational unit
    // bf_data: mem_rdata at phase-0 ack (non-mut), bf_mem_data_r at phase-1 (mut), rd_a_data for reg EA
    // -----------------------------------------------------------------------
    logic [31:0] bf_data_mux, bf_src_mux, bf_result, bf_result_w;
    logic [4:0]  bf_offset_mux, bf_width_mux;
    logic [2:0]  bf_op_mux;
    logic        bf_n, bf_z, bf_v, bf_c;

    assign bf_data_mux   = (ex_is_bf && !ex_bf_reg_ea && bf_mem_run_r && !bf_mem_phase_r) ? mem_rdata
                         : (ex_is_bf && !ex_bf_reg_ea && bf_mem_run_r &&  bf_mem_phase_r) ? bf_mem_data_r
                         : rd_a_data;
    assign bf_offset_mux = bf_mem_run_r ? bf_mem_offset_r : ex_imm[10:6];
    assign bf_width_mux  = bf_mem_run_r ? bf_mem_width_r  : ex_imm[4:0];
    assign bf_src_mux    = bf_mem_run_r ? bf_mem_src_r    : rd_b_data;
    assign bf_op_mux     = bf_mem_run_r ? bf_mem_op_r     : ex_bf_op;

    eu_bitfield u_bitfield (
        .bf_data      (bf_data_mux),
        .bf_offset    (bf_offset_mux),
        .bf_raw_width (bf_width_mux),
        .bf_src       (bf_src_mux),
        .bf_op        (bf_op_mux),
        .bf_result    (bf_result),
        .bf_n         (bf_n),
        .bf_z         (bf_z),
        .bf_v         (bf_v),
        .bf_c         (bf_c)
    );
    assign bf_result_w = bf_result;  // alias for clarity

    assign alu_src   = (ex_is_cmpm && cmpm_phase_r) ? cmpm_src_r :
                       (ex_is_addx_mem && addx_mem_run_r && addx_mem_phase_r == 2'd2) ? addx_src_r :
                       (ex_is_cas2 && ex_is_mem_rd)   ? rd_b_data :  // CAS2: Dc1/Dc2 compare reg
                       (ex_is_mem_rmw && !ex_use_imm) ? rd_b_data :  // Dn in rd_b for binary RMW
                       ex_is_mem_src                 ? (ex_sext_src ? {{16{mem_rdata[15]}}, mem_rdata[15:0]} : mem_rdata) :
                       ex_sext_src ? {{16{ex_src_operand[15]}}, ex_src_operand[15:0]}
                                   : ex_src_operand;
    // When reading from memory (RMW read phase, CMPI ea, TST ea, etc.),
    // the loaded mem_rdata is the ALU/BIT destination.
    // For memory-source forms: memory is the ALU source, Dn/An is the ALU destination.
    assign alu_dst   = (ex_is_cmpm && cmpm_phase_r) ? mem_rdata :
                       (ex_is_addx_mem && addx_mem_run_r && addx_mem_phase_r == 2'd2) ? addx_dst_r :
                       // Same-reg pre/post-increment ADDA/SUBA: An_dst = post-update An value
                       ex_is_mem_src ? (ex_an_upd_en && ex_src_reg == ex_dst_reg
                                        ? ex_an_new : rd_b_data) :
                       ex_is_mem_rd                  ? mem_rdata :
                       rd_b_data;
    assign alu_op    = ex_alu_op;
    assign alu_siz   = ex_siz;
    assign alu_x_in  = flag_x;
    assign alu_z_in  = flag_z;

    assign shf_operand = ex_is_mem_rmw ? mem_rdata : rd_a_data;
    assign shf_count   = ex_use_reg_cnt ? rd_b_data[5:0] : ex_shf_imm_cnt;
    assign shf_op      = ex_shf_op;
    assign shf_siz     = ex_siz;
    assign shf_x_in    = flag_x;

    assign md_src = ex_is_mem_src ? mem_rdata : (ex_use_imm ? ex_imm : rd_a_data);  // mem/imm/reg provides multiplier/divisor
    assign md_dst = rd_b_data;
    assign md_op  = ex_md_op;

    // BCD datapath drives
    assign bcd_src  = (bcds_run_r && bcds_phase_r == 2'd2) ? bcds_src_r : rd_a_byte;
    assign bcd_dst  = (bcds_run_r && bcds_phase_r == 2'd2) ? bcds_dst_r :
                      (ex_unit == UNIT_BCD && ex_is_mem_rd)  ? mem_rdata[7:0] :
                      rd_b_byte;
    assign bcd_op   = ex_bcd_op;
    assign bcd_x_in = flag_x;
    assign bcd_z_in = flag_z;

    // Bitops datapath drives
    // For register bit ops targeting memory (BSET Dn,(An)): rd_a=An (EA base), rd_b=Dn (bit count).
    // bit_dst must be mem_rdata; bit_num must come from rd_b[4:0] not rd_a[4:0].
    // BTST Dn,#imm: immediate byte is the bit_dst; otherwise memory or register.
    assign bit_dst = ex_is_bit_imm ? {24'h0, ex_imm[7:0]} :
                     ex_is_mem_rd  ? mem_rdata             : rd_b_data;
    // Memory bit ops: bit# mod 8 (byte EA); reg-to-reg: mod 32 via [4:0].
    // For memory ops (is_mem_rd or is_mem_rmw): rd_b holds Dn (or is overridden to Dn for indexed).
    // For immediate ops (ex_is_bit_imm): byte mode, Dn from rd_a → mask to [2:0].
    // For register-to-register ops (!is_mem_rd): rd_a holds Dn1 (bit count from reg).
    assign bit_num = (ex_bit_from_reg && ex_is_bit_imm)                          ? {2'b00, rd_a_bit_num[2:0]} :
                     (ex_bit_from_reg && (ex_is_mem_rd || ex_is_mem_rmw))        ? {2'b00, rd_b_data[2:0]}    :
                     ex_bit_from_reg                                              ? rd_a_bit_num : ex_bit_num;
    assign bit_op  = ex_bit_op;

    // -----------------------------------------------------------------------
    // Result and CCR mux (combinational) — no bit-selects on external signals
    // -----------------------------------------------------------------------
    logic [31:0] ex_result;
    logic        ex_n, ex_z, ex_v, ex_c, ex_x;
    logic        ex_move_n;  // sized N for MOVE

    always_comb begin
        ex_result = 32'h0;
        ex_n      = 1'b0;
        ex_z      = 1'b1;
        ex_v      = 1'b0;
        ex_c      = 1'b0;
        ex_x      = flag_x;
        ex_move_n = 1'b0;

        // register EA bit-field — single-cycle, bypasses unit case
        if (ex_is_bf && ex_bf_reg_ea) begin
            ex_result = bf_result_w;  // extracted (EXTU/EXTS/FFO) or modified (CLR/SET/INS)
            ex_n      = bf_n;
            ex_z      = bf_z;
            ex_v      = bf_v;
            ex_c      = bf_c;
            ex_x      = flag_x;       // X unchanged by all BF ops
        end else

        case (ex_unit)
            UNIT_ALU: begin
                ex_result = alu_result;
                ex_n      = alu_n;
                ex_z      = alu_z;
                ex_v      = alu_v;
                ex_c      = alu_c;
                ex_x      = ex_x_unchanged ? flag_x : alu_x;
            end
            UNIT_SHF: begin
                ex_result = shf_result;
                ex_n      = shf_n;
                ex_z      = shf_z;
                ex_v      = shf_v;
                ex_c      = shf_c;
                ex_x      = shf_x;
            end
            UNIT_MUL: begin
                ex_result = md_result_lo;
                ex_n      = md_n;
                ex_z      = md_z;
                ex_v      = md_v;
                ex_c      = md_c;
                ex_x      = flag_x;
            end
            UNIT_DIV: begin
                ex_result = md_result_lo;
                ex_v      = md_v;
                // DIVS.W / DIVU.W overflow: V is set, N/Z are unchanged, but C is
                // always CLEARED (not "unchanged" as Musashi's own reference
                // implementation does — hand-verified against 887 DIVS.json.gz and
                // 536 DIVU.json.gz register-direct overflow vectors: C=0 in 100%
                // of cases regardless of the incoming C value; Musashi is wrong
                // here too, same class of "undefined behavior doesn't match real
                // hardware" issue found for ABCD/SBCD/NBCD in Phase 91).
                if (!ex_is_muldivl && md_v && !md_div_by_zero) begin
                    ex_n = flag_n;
                    ex_z = flag_z;
                    ex_c = 1'b0;
                end else begin
                    ex_n = md_n;
                    ex_z = md_z;
                    ex_c = md_c;
                end
                ex_x      = flag_x;
            end
            UNIT_MOVE: begin
                if (ex_is_tas) begin
                    // TAS.B Dn: result = original_byte | 0x80; CCR from original byte
                    ex_result = {24'h0, rd_a_data[7:0] | 8'h80};
                    ex_n      = rd_a_data[7];
                    ex_z      = (rd_a_data[7:0] == 8'h0);
                    ex_move_n = rd_a_data[7];
                    ex_v      = 1'b0;
                    ex_c      = 1'b0;
                    ex_x      = flag_x;
                end else begin
                    ex_result = move_result_w;
                    ex_move_n = (ex_siz == 2'b01) ? move_result_n_b :
                                (ex_siz == 2'b10) ? move_result_n_w : move_result_n_l;
                    ex_n      = ex_move_n;
                    ex_z      = (ex_siz == 2'b01) ? move_result_z_b :
                                (ex_siz == 2'b10) ? move_result_z_w :
                                                    (move_result_w == 32'h0);
                    ex_v      = 1'b0;
                    ex_c      = 1'b0;
                    ex_x      = flag_x;
                end
            end
            UNIT_BCD: begin
                ex_result = {24'h0, bcd_result};  // byte result, zero-extended
                ex_z      = bcd_z;   // already incorporates z_in & (result==0)
                // N/V are "undefined" per the 68k PRM but real hardware
                // produces specific values — see eu_bcd.sv header comment
                // for the empirically-derived formulas (verified 100% match
                // against Tom Harte's register-direct ABCD/SBCD/NBCD vectors).
                ex_n      = bcd_result[7];
                ex_v      = bcd_v;
                ex_c      = bcd_c;
                ex_x      = bcd_c;   // X = C for all BCD ops
            end
            UNIT_BIT: begin
                ex_result = bit_result; // 32-bit result (BTST: unchanged)
                ex_z      = bit_z;      // NOT(original bit value)
                ex_n      = flag_n;     // N unchanged
                ex_v      = flag_v;     // V unchanged
                ex_c      = flag_c;     // C unchanged
                ex_x      = flag_x;     // X unchanged
            end
            default: begin
                if (ex_is_chk) begin
                    ex_n = chk_traps_w ? chk_below_w : flag_n;
                    ex_z = chk_z_w;
                    ex_v = 1'b0;
                    ex_c = 1'b0;
                    ex_x = flag_x;
                end else if (ex_is_pack && !ex_is_pack_mem) begin
                    // PACK Dy,Dx,#adj — register form; CCR unaffected
                    ex_result = {24'h0, pack_reg_temp_w[11:8], pack_reg_temp_w[3:0]};
                    ex_n = flag_n; ex_z = flag_z; ex_v = flag_v; ex_c = flag_c; ex_x = flag_x;
                end else if (ex_is_unpk && !ex_is_pack_mem) begin
                    // UNPK Dy,Dx,#adj — register form; CCR unaffected
                    ex_result = {16'h0, unpk_reg_temp_w};
                    ex_n = flag_n; ex_z = flag_z; ex_v = flag_v; ex_c = flag_c; ex_x = flag_x;
                end
            end
        endcase
    end

    // -----------------------------------------------------------------------
    // PACK/UNPK memory FSM (2-phase: read Ay, write to Ax)
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            pack_mem_run_r     <= 1'b0;
            pack_mem_phase_r   <= 1'b0;
            pack_mem_is_unpk_r <= 1'b0;
            pack_mem_src_r     <= 32'h0;
            pack_mem_ay_addr_r <= 32'h0;
            pack_mem_ax_addr_r <= 32'h0;
            pack_mem_ay_reg_r  <= 3'b0;
            pack_mem_ax_reg_r  <= 3'b0;
            pack_mem_adj_r     <= 16'h0;
        end else begin
            if (ex_valid && (ex_is_pack || ex_is_unpk) && ex_is_pack_mem && !pack_mem_run_r) begin
                // Setup: capture predecremented addresses
                // PACK: Ay-=2 (word read), Ax-=1 (byte write)
                // UNPK: Ay-=1 (byte read), Ax-=2 (word write)
                pack_mem_run_r     <= 1'b1;
                pack_mem_phase_r   <= 1'b0;
                pack_mem_is_unpk_r <= ex_is_unpk;
                pack_mem_adj_r     <= ex_imm[15:0];
                pack_mem_ay_reg_r  <= ex_src_reg[2:0];
                pack_mem_ax_reg_r  <= ex_dst_reg[2:0];
                pack_mem_ay_addr_r <= rd_a_data - (ex_is_unpk ? 32'd1 : 32'd2);
                pack_mem_ax_addr_r <= rd_b_data - (ex_is_unpk ? 32'd2 : 32'd1);
            end else if (pack_mem_run_r && mem_ack) begin
                if (!pack_mem_phase_r) begin
                    pack_mem_src_r   <= mem_rdata;   // capture word or byte from Ay
                    pack_mem_phase_r <= 1'b1;        // advance to write phase
                end else begin
                    pack_mem_run_r   <= 1'b0;        // write done, FSM complete
                    pack_mem_phase_r <= 1'b0;
                end
            end else if (pack_mem_run_r && mem_abort) begin
                // A fault on either phase aborts the whole PACK/UNPK — must
                // explicitly reset here or this stays stuck for the next
                // PACK/UNPK memory-form instruction.
                pack_mem_run_r   <= 1'b0;
                pack_mem_phase_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // RESET instruction FSM — hold RSTOUT high for ~512 sub-clocks
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            reset_run_r <= 1'b0;
            reset_cnt_r <= 11'd0;
        end else begin
            if (ex_valid && ex_is_reset && !reset_run_r) begin
                reset_run_r <= 1'b1;
                reset_cnt_r <= 11'd2047;
            end else if (reset_run_r) begin
                if (reset_cnt_r == 11'd0)
                    reset_run_r <= 1'b0;
                else
                    reset_cnt_r <= reset_cnt_r - 11'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // PMOVE CRP/SRP 64-bit 2-phase FSM
    // Phase 0: bus cycle at An (hi word); phase 1: bus cycle at An+4 (lo word).
    // pmove64_run_r=1 during phase 1 to hold ex_mem_stall and drive bus.
    // pmove64_run_r declared above (before ex_mem_stall) for forward-ref safety.
    // -----------------------------------------------------------------------
    logic        pmove64_to_mem_r;
    logic        pmove64_is_crp_r;
    logic [31:0] pmove64_addr_r;
    logic [31:0] crp_hi_r, crp_lo_r;
    logic [31:0] srp_hi_r, srp_lo_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            pmove64_run_r    <= 1'b0;
            pmove64_skip_r   <= 1'b0;
            pmove64_to_mem_r <= 1'b0;
            pmove64_is_crp_r <= 1'b0;
            pmove64_addr_r   <= 32'h0;
            crp_hi_r <= 32'h0; crp_lo_r <= 32'h0;
            srp_hi_r <= 32'h0; srp_lo_r <= 32'h0;
        end else begin
            if (!pmove64_run_r && ex_valid && ex_is_pmove64 && mem_ack) begin
                // Phase 0 ack: save address, arm skip, move to phase 1.
                // skip_r burns the stale mem_ack that fires in the same clock as
                // pmove64_run_r transitions 0→1 (memory model responded to the old
                // normal-path address, not yet to the new An+4 address).
                pmove64_run_r    <= 1'b1;
                pmove64_skip_r   <= 1'b1;
                pmove64_to_mem_r <= ex_pmove_to_mem;
                pmove64_is_crp_r <= (ex_pmove_preg == 3'b100);
                pmove64_addr_r   <= ex_ea;
                if (!ex_pmove_to_mem) begin
                    if (ex_pmove_preg == 3'b100) crp_hi_r <= mem_rdata;
                    else                          srp_hi_r <= mem_rdata;
                end
            end else if (pmove64_run_r && pmove64_skip_r) begin
                // Skip cycle: address has just switched to An+4.
                // The memory model is responding to the old An; discard and wait.
                pmove64_skip_r <= 1'b0;
            end else if (pmove64_run_r && !pmove64_skip_r && mem_ack) begin
                // Phase 1 ack: fresh response to An+4.
                pmove64_run_r <= 1'b0;
                if (!pmove64_to_mem_r) begin
                    if (pmove64_is_crp_r) crp_lo_r <= mem_rdata;
                    else                  srp_lo_r <= mem_rdata;
                end
            end else if (pmove64_run_r && !pmove64_skip_r && mem_abort) begin
                // A fault on the second (An+4) half aborts the whole 64-bit
                // PMOVE — must explicitly reset here or this stays stuck
                // for the next PMOVE CRP/SRP. The first half's own fault
                // is already covered by the generic exclusion-gated
                // mem_rd/mem_wr clause in ex_mem_stall (pmove64_run_r is
                // still 0 at that point).
                pmove64_run_r <= 1'b0;
            end
        end
    end

    assign crp_out = {crp_hi_r, crp_lo_r};
    assign srp_out = {srp_hi_r, srp_lo_r};

    logic [31:0] pmove64_wr_data_w;
    assign pmove64_wr_data_w =
        (!pmove64_run_r) ? (ex_pmove_preg == 3'b100 ? crp_hi_r : srp_hi_r)
                         : (pmove64_is_crp_r         ? crp_lo_r : srp_lo_r);

    // -----------------------------------------------------------------------
    // general memory RMW FSM
    // Read phase uses the normal ex_is_mem_rd path.  When the read acks
    // (mem_rmw_read_ack), we capture the ALU/SHF/BIT result and EA, then
    // drive a write cycle via mem_rmw_run_r.  CCR fires on write ack.
    // Placed here — after ex_result/ex_x/ex_n/ex_z/ex_v/ex_c are declared.
    // -----------------------------------------------------------------------
    // latch the correct EA for indexed dynamic bit RMW ops.
    // When dyn_bit_get_Dn fires, rd_b_sel switches to Dn which corrupts ex_ea
    // (changes xn_scaled). We pre-latch the correct EA each cycle before ack.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            dyn_bit_ea_r <= 32'h0;
        else if (ex_is_dyn_bit_idx && ex_is_mem_rmw && !mem_rmw_run_r && !mem_rmw_after_r)
            dyn_bit_ea_r <= ex_ea;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mem_rmw_run_r    <= 1'b0;
            mem_rmw_after_r  <= 1'b0;
            mem_rmw_wdata_r  <= 32'h0;
            mem_rmw_ccr_r    <= 5'h0;
            mem_rmw_addr_r   <= 32'h0;
            mem_rmw_ccr_en_r <= 1'b0;
        end else begin
            mem_rmw_after_r <= mem_rmw_run_r && mem_ack;
            if (mem_rmw_read_ack) begin
                mem_rmw_run_r    <= 1'b1;
                mem_rmw_wdata_r  <= (ex_siz==2'b01) ? {ex_result[7:0],  24'h0}
                                 : (ex_siz==2'b10) ? {ex_result[15:0], 16'h0}
                                 :                    ex_result;
                mem_rmw_ccr_r    <= {ex_x, ex_n, ex_z, ex_v, ex_c};
                // For indexed dynamic bit ops, ex_ea is corrupted by rd_b override;
                // use the pre-latched correct EA instead.
                mem_rmw_addr_r   <= ex_is_dyn_bit_idx ? dyn_bit_ea_r : ex_ea;
                mem_rmw_ccr_en_r <= ex_mem_rmw_ccr;  // capture: does this op update CCR?
            end else if (mem_rmw_run_r && mem_ack) begin
                mem_rmw_run_r    <= 1'b0;
                mem_rmw_ccr_en_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // MOVE (src),(dst) memory→memory FSM
    // Read phase: normal ex_is_mem_rd path drives bus. On read ack, capture
    // data + dst address + An update info, then drive write via move_mm_run_r.
    // CCR fires on write ack via move_mm_sr_wr_en.
    // Dst An update fires on write ack via move_mm_dst_an_wr_en.
    // Src An update fires from WB (move_mm_after_r cycle) as usual.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            move_mm_run_r        <= 1'b0;
            move_mm_after_r      <= 1'b0;
            move_mm_data_r       <= 32'h0;
            move_mm_dst_addr_r   <= 32'h0;
            move_mm_siz_r        <= 2'b0;
            move_mm_ccr_r        <= 5'h0;
            move_mm_dst_an_upd_r <= 1'b0;
            move_mm_dst_an_reg_r <= 3'b0;
            move_mm_dst_an_new_r <= 32'h0;
        end else begin
            // Sticky, not a 1-cycle pulse: stays asserted from the write ack until
            // this instruction actually retires (instr_ack). A plain 1-cycle pulse
            // let no_special_bus_op go true again before decode had a valid next
            // instruction ready (e.g. IFU still draining this instruction's extra
            // extension words), re-triggering mem_req off this instruction's still-
            // latched (stale) ex_is_mem_rd/address fields — read-then-write looping
            // indefinitely on the same (wrong-looking, but really just stale) EA.
            if (move_mm_run_r && mem_ack)
                move_mm_after_r <= 1'b1;
            else if (instr_ack)
                move_mm_after_r <= 1'b0;
            if (move_mm_read_ack) begin
                move_mm_run_r        <= 1'b1;
                move_mm_data_r       <= mem_rdata;
                // dst's own xn_wl/xn_scale (ex_dst_*) apply when the SOURCE is also
                // indexed (both sides indexed — the shared ex_xn_wl/ex_xn_scale are
                // taken by the source's own EA in that case); otherwise (src is
                // abs/PC-relative/imm, not indexed) dst uses the shared fields as
                // before, unchanged from the original single-indexed-side behavior.
                move_mm_dst_addr_r   <= ex_abs_dst_ea_en ? ex_abs_dst_ea_val
                                     : ex_is_move_mm_idx_dst
                                       ? (rd_a_data +
                                          ((ex_dst_is_idx
                                             ? (ex_dst_xn_wl ? rd_b_data : {{16{rd_b_data[15]}}, rd_b_data[15:0]})
                                             : (ex_xn_wl     ? rd_b_data : {{16{rd_b_data[15]}}, rd_b_data[15:0]}))
                                           << (ex_dst_is_idx ? ex_dst_xn_scale : ex_xn_scale)) + ex_dst_ea_offset)
                                       : (rd_b_data + ex_dst_ea_offset);
                move_mm_siz_r        <= ex_siz;
                // CCR: {X unchanged, N, Z, 0, 0}; N/Z from sized read data
                move_mm_ccr_r        <= {sr_live[4],
                                         (ex_siz == 2'b01) ? mem_rdata[7]  :
                                         (ex_siz == 2'b10) ? mem_rdata[15] : mem_rdata[31],
                                         (ex_siz == 2'b01) ? (mem_rdata[7:0]  == 8'h0)  :
                                         (ex_siz == 2'b10) ? (mem_rdata[15:0] == 16'h0) :
                                                             (mem_rdata        == 32'h0),
                                         1'b0, 1'b0};
                move_mm_dst_an_upd_r <= ex_dst_an_upd_en;
                move_mm_dst_an_reg_r <= ex_dst_an_upd_reg;
                move_mm_dst_an_new_r <= rd_b_data + ex_dst_an_delta;
            end else if (move_mm_run_r && mem_ack) begin
                move_mm_run_r <= 1'b0;
            end else if (move_mm_run_r && mem_abort) begin
                // A fault on the write phase aborts the whole MOVE mem-mem —
                // must explicitly reset here or this stays stuck for the
                // next indexed-both-sides MOVE. The read phase's own fault
                // is already covered by the generic exclusion-gated
                // mem_rd/mem_wr clause in ex_mem_stall (move_mm_run_r is
                // still 0 at that point).
                move_mm_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // CAS compare-and-swap FSM
    // Uses dec_is_mem_rmw=1 so alu_src=rd_b_data (Dc) during read phase.
    // cas_read_ack fires after read; cas_get_du_r cycle fetches Du via rd_b override.
    // Z=1: write Du to M[EA]. Z=0: write M[EA] to Dc via wr2, fire CCR.
    // -----------------------------------------------------------------------
    // cas_read_ack declared and assigned in early section above

    logic [31:0] cas_rdata_sized;
    assign cas_rdata_sized = (cas_siz_r == 2'b01) ? {24'h0, cas_rdata_r[7:0]} :
                             (cas_siz_r == 2'b10) ? {16'h0, cas_rdata_r[15:0]} :
                                                     cas_rdata_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cas_get_du_r <= 1'b0;
            cas_write_r  <= 1'b0;
            cas_after_r  <= 1'b0;
            cas_active_r <= 1'b0;
            cas_z_r      <= 1'b0;
            cas_ccr_r    <= 5'h0;
            cas_ea_r     <= 32'h0;
            cas_siz_r    <= 2'b0;
            cas_rdata_r  <= 32'h0;
            cas_du_val_r <= 32'h0;
            cas_dc_reg_r <= 4'h0;
        end else begin
            cas_after_r <= cas_write_r && mem_ack;
            if (cas_read_ack) begin
                cas_active_r <= 1'b1;
                cas_get_du_r <= 1'b1;
                cas_z_r      <= ex_z;
                cas_ccr_r    <= {ex_x, ex_n, ex_z, ex_v, ex_c};
                cas_ea_r     <= ex_ea;
                cas_siz_r    <= ex_siz;
                cas_rdata_r  <= mem_rdata;
                cas_dc_reg_r <= ex_dst_reg;
            end else if (cas_get_du_r) begin
                cas_get_du_r <= 1'b0;
                cas_du_val_r <= rd_b_data;
                if (cas_z_r)
                    cas_write_r <= 1'b1;
                else
                    cas_active_r <= 1'b0; // mismatch: FSM done after get_du cycle
            end else if (cas_write_r && mem_ack) begin
                cas_write_r <= 1'b0;
                // cas_after_r will be 1 next cycle; cas_active_r cleared after after_r
            end else if (cas_write_r && mem_abort) begin
                // A fault on the write phase aborts CAS — must explicitly
                // reset both cas_write_r and cas_active_r here (mismatch
                // path already resets cas_active_r directly at cas_get_du_r
                // time, but the match/write path only clears it later via
                // cas_after_r, which requires mem_ack — never fires on an
                // abort), or this stays stuck for the next CAS instruction.
                cas_write_r  <= 1'b0;
                cas_active_r <= 1'b0;
            end else if (cas_after_r) begin
                cas_active_r <= 1'b0; // match: FSM done after write+cooldown
            end
        end
    end

    // ex_cas_mem_done_r: set once the CAS initial read has been acked; cleared when
    // EX advances to the next instruction.  Prevents cas_read_ack from re-firing
    // during the one cycle after the FSM finishes but before EX advances.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            ex_cas_mem_done_r <= 1'b0;
        else if (!ex_mem_stall)        // EX advancing to new instruction
            ex_cas_mem_done_r <= 1'b0;
        else if (cas_read_ack)         // CAS read completed: mark done
            ex_cas_mem_done_r <= 1'b1;
    end

    // -----------------------------------------------------------------------
    // CAS2 compare-and-swap dual-address FSM
    // Match path (z1 && z2): rd1 → rd2 → get_du1 → wr1 → get_du2 → wr2 → after
    // Mismatch path:         rd1 → rd2 → dc1_wr → dc2_wr (reg writes, no bus) → after
    // CCR is captured from the second comparison (ALU CMP Dc2, M[Rn2] via rd_b override)
    // -----------------------------------------------------------------------
    logic [31:0] cas2_rdata1_sized_w, cas2_rdata2_sized_w;
    assign cas2_rdata1_sized_w = (cas2_siz_r == 2'b10) ? {16'h0, cas2_rdata1_r[15:0]} :
                                 (cas2_siz_r == 2'b01) ? {24'h0, cas2_rdata1_r[7:0]}  :
                                                          cas2_rdata1_r;
    assign cas2_rdata2_sized_w = (cas2_siz_r == 2'b10) ? {16'h0, cas2_rdata2_r[15:0]} :
                                 (cas2_siz_r == 2'b01) ? {24'h0, cas2_rdata2_r[7:0]}  :
                                                          cas2_rdata2_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cas2_rd2_r     <= 1'b0;
            cas2_get_du1_r <= 1'b0;
            cas2_wr1_r     <= 1'b0;
            cas2_get_du2_r <= 1'b0;
            cas2_wr2_r     <= 1'b0;
            cas2_dc1_wr_r  <= 1'b0;
            cas2_dc2_wr_r  <= 1'b0;
            cas2_after_r   <= 1'b0;
            cas2_active_r  <= 1'b0;
            cas2_z1_r      <= 1'b0;
            cas2_ea1_r     <= 32'h0;
            cas2_ea2_r     <= 32'h0;
            cas2_siz_r     <= 2'b0;
            cas2_rdata1_r  <= 32'h0;
            cas2_rdata2_r  <= 32'h0;
            cas2_du1_val_r <= 32'h0;
            cas2_du2_val_r <= 32'h0;
            cas2_dc1_reg_r <= 3'b0;
            cas2_dc2_reg_r <= 3'b0;
            cas2_ccr_r     <= 5'h0;
        end else begin
            cas2_after_r <= (cas2_wr2_r && mem_ack) || cas2_dc2_wr_r;
            if (cas2_rd1_ack) begin
                // First read complete: latch context, advance to rd2
                cas2_active_r  <= 1'b1;
                cas2_z1_r      <= ex_z;          // ALU CMP Dc1 vs M[Rn1]
                cas2_ea1_r     <= ex_ea;          // Rn1 address
                cas2_siz_r     <= ex_siz;
                cas2_rdata1_r  <= mem_rdata;
                cas2_dc1_reg_r <= ex_dst_reg[2:0]; // Dc1 register
                cas2_dc2_reg_r <= ex_cas2_dc2_reg;
                cas2_ccr_r     <= {flag_x, ex_n, ex_z, ex_v, ex_c}; // provisional from rd1
                cas2_rd2_r     <= 1'b1;
            end else if (cas2_rd2_r && mem_ack) begin
                // Second read complete: compare Dc2 vs M[Rn2] inline via rd_b/ALU
                cas2_rd2_r     <= 1'b0;
                cas2_ea2_r     <= rd_a_data;       // Rn2 address from rd_a override
                cas2_rdata2_r  <= mem_rdata;
                cas2_ccr_r     <= {flag_x, ex_n, ex_z, ex_v, ex_c}; // CMP Dc2 vs M[Rn2]
                if (cas2_z1_r && cas2_rd2_z_w) begin
                    // Both match: proceed to write Du1
                    cas2_get_du1_r <= 1'b1;
                end else begin
                    // Mismatch: write Dc1←rdata1, Dc2←rdata2
                    cas2_dc1_wr_r  <= 1'b1;
                end
            end else if (cas2_rd2_r && mem_abort) begin
                // A fault on any of CAS2's 4 phases aborts the whole locked
                // sequence — real 68030 CAS2 is atomic, it doesn't leave a
                // partial compare/write in place.
                cas2_rd2_r     <= 1'b0;
                cas2_active_r  <= 1'b0;
            end else if (cas2_get_du1_r) begin
                cas2_get_du1_r <= 1'b0;
                cas2_du1_val_r <= rd_b_data;       // Du1 from rd_b override
                cas2_wr1_r     <= 1'b1;
            end else if (cas2_wr1_r && mem_ack) begin
                cas2_wr1_r     <= 1'b0;
                cas2_get_du2_r <= 1'b1;
            end else if (cas2_wr1_r && mem_abort) begin
                cas2_wr1_r     <= 1'b0;
                cas2_active_r  <= 1'b0;
            end else if (cas2_get_du2_r) begin
                cas2_get_du2_r <= 1'b0;
                cas2_du2_val_r <= rd_b_data;       // Du2 from rd_b override
                cas2_wr2_r     <= 1'b1;
            end else if (cas2_wr2_r && mem_ack) begin
                cas2_wr2_r     <= 1'b0;
            end else if (cas2_wr2_r && mem_abort) begin
                cas2_wr2_r     <= 1'b0;
                cas2_active_r  <= 1'b0;
            end else if (cas2_dc1_wr_r) begin
                // Write Dc1 ← rdata1 via wr2 this cycle
                cas2_dc1_wr_r  <= 1'b0;
                cas2_dc2_wr_r  <= 1'b1;
            end else if (cas2_dc2_wr_r) begin
                cas2_dc2_wr_r  <= 1'b0;
            end else if (cas2_after_r) begin
                cas2_active_r  <= 1'b0;
            end
        end
    end

    // ex_cas2_done_r: blocks cas2_rd1_ack re-firing until EX advances
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            ex_cas2_done_r <= 1'b0;
        else if (!ex_mem_stall)
            ex_cas2_done_r <= 1'b0;
        else if (cas2_rd1_ack)
            ex_cas2_done_r <= 1'b1;
    end

    // CAS2 CCR update: fires on cas2_after_r (match path) or cas2_dc2_wr_r (mismatch)
    logic cas2_sr_wr_en;
    assign cas2_sr_wr_en = cas2_after_r || cas2_dc2_wr_r;

    // CAS2 mismatch: write Dc1←rdata1 (via wr2), Dc2←rdata2 (via wr2 next cycle)
    logic cas2_dc1_wr_en, cas2_dc2_wr_en;
    assign cas2_dc1_wr_en = cas2_dc1_wr_r;
    assign cas2_dc2_wr_en = cas2_dc2_wr_r;

    // -----------------------------------------------------------------------
    // ABCD/SBCD -(Ay),-(Ax) memory FSM
    // Phase 0: read M[Ay-1]. Phase 1: read M[Ax-1]. Phase 2: write BCD result.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            bcds_run_r     <= 1'b0;
            bcds_phase_r   <= 2'd0;
            bcds_is_abcd_r <= 1'b0;
            bcds_src_r     <= 8'h0;
            bcds_dst_r     <= 8'h0;
            bcds_ay_addr_r <= 32'h0;
            bcds_ax_addr_r <= 32'h0;
            bcds_ay_reg_r  <= 3'h0;
            bcds_ax_reg_r  <= 3'h0;
        end else begin
            if (ex_valid && ex_is_abcd_sbcd_mem && !bcds_run_r) begin
                bcds_run_r     <= 1'b1;
                bcds_phase_r   <= 2'd0;
                bcds_is_abcd_r <= ex_is_abcd_mem;
                bcds_ay_reg_r  <= ex_src_reg[2:0];
                bcds_ax_reg_r  <= ex_dst_reg[2:0];
                // Byte-sized -(An) on A7 steps by 2, not 1, to keep the
                // stack pointer word-aligned (same rule as every other
                // byte-op -(A7) case in this codebase). When Ay and Ax are
                // the SAME register (-(A1),-(A1)), Ay's predecrement is
                // applied first as part of evaluating the source operand,
                // so Ax's own predecrement must compound on top of that
                // already-updated address, not the original register value
                // (same "same-register conflict" rule fixed for MOVE in
                // Phase 82).
                bcds_ay_addr_r <= rd_a_data - bcds_ay_step;
                bcds_ax_addr_r <= (ex_src_reg[2:0] == ex_dst_reg[2:0])
                                 ? (rd_a_data - bcds_ay_step - bcds_ax_step)
                                 : (rd_b_data - bcds_ax_step);
            end else if (bcds_run_r && mem_ack) begin
                if (bcds_phase_r == 2'd2) begin
                    bcds_run_r <= 1'b0;
                end else begin
                    if (bcds_phase_r == 2'd0) bcds_src_r <= mem_rdata[7:0];
                    if (bcds_phase_r == 2'd1) bcds_dst_r <= mem_rdata[7:0];
                    bcds_phase_r <= bcds_phase_r + 2'd1;
                end
            end else if (bcds_run_r && mem_abort) begin
                // A fault on any of the 3 phases aborts the whole ABCD/SBCD
                // memory-form instruction — must explicitly reset here or
                // this stays stuck for the next -(Ay),-(Ax) instruction.
                bcds_run_r   <= 1'b0;
                bcds_phase_r <= 2'd0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // WB stage latch
    // When ex_mem_stall: WB gets a bubble (don't advance).
    // When mem_ack arrives (ex_mem_stall=0): WB captures mem_rdata for loads,
    // ex_ea for LEA, ex_result for register ops.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid        <= 1'b0;
            wb_writes_reg   <= 1'b0;
            wb_updates_ccr  <= 1'b0;
            wb_an_upd_en    <= 1'b0;
            wb_is_mem_rd    <= 1'b0;
            wb_is_mem_rmw   <= 1'b0;
            wb_is_movea_w   <= 1'b0;
            wb_is_movec_wr   <= 1'b0;
            wb_movec_rc      <= 12'h0;
            wb_is_move_sr_w  <= 1'b0;
            wb_is_move_ccr_w <= 1'b0;
            wb_is_move_usp   <= 1'b0;
            wb_is_muldivl    <= 1'b0;
            wb_md_dst2       <= 3'b0;
            wb_md_64bit      <= 1'b0;
            wb_md_hi         <= 32'h0;
            wb_is_exg        <= 1'b0;
            wb_exg_dd        <= 1'b0;
        end else if (ex_mem_stall || ex_internal_stall || ex_berr_abort_wb) begin
            // Memory cycle in progress, an artificial internal stall
            // (Phase 162) still counting down, or just aborted by a berr
            // the previous cycle — see ex_berr_abort_wb above: drain WB
            // (bubble), same as the ordinary wait case.
            wb_valid         <= 1'b0;
            wb_writes_reg    <= 1'b0;
            wb_updates_ccr   <= 1'b0;
            wb_an_upd_en     <= 1'b0;
            wb_is_mem_rd     <= 1'b0;
            wb_is_mem_rmw    <= 1'b0;
            wb_is_movea_w    <= 1'b0;
            wb_is_movec_wr   <= 1'b0;
            wb_is_move_sr_w  <= 1'b0;
            wb_is_move_ccr_w <= 1'b0;
            wb_is_move_usp   <= 1'b0;
            wb_is_muldivl    <= 1'b0;
            wb_md_dst2       <= 3'b0;
            wb_md_64bit      <= 1'b0;
            wb_is_exg        <= 1'b0;
            wb_exg_dd        <= 1'b0;
        end else begin
            wb_valid         <= ex_valid;
            wb_writes_reg    <= ex_writes_reg &&
                                !(ex_unit == UNIT_DIV && !ex_is_muldivl && md_v && !md_div_by_zero) &&
                                // DBcc: Dn not decremented when condition is true
                                !(ex_is_dbcc && eval_cc(ex_dbcc_cond, flag_n, flag_z, flag_v, flag_c));
            wb_updates_ccr   <= ex_updates_ccr;
            wb_x_unchanged   <= ex_x_unchanged;
            wb_is_move       <= (ex_unit == UNIT_MOVE);
            wb_move_n        <= ex_move_n;
            wb_dest_reg      <= ex_dest_reg;
            wb_siz           <= ex_siz;
            // Result selection: EXG primary dest gets rd_b (other register value);
            // mem load uses mem_rdata; LEA/LINK use EA; else ALU/MOVE/unit result.
            wb_result        <= ex_is_exg            ? rd_b_data
                              : ex_is_mem_src        ? ex_result    // ALU result → Dn
                              : ex_is_mem_rd          ? mem_rdata
                              : (ex_is_lea || ex_is_link) ? ex_ea
                              :                         ex_result;
            wb_ccr           <= {ex_x, ex_n, ex_z, ex_v, ex_c};
            // RMW ops: mem_rmw_an_wr_en handles An update at write ack; WB must not double-apply
            // cpSAVE/cpRESTORE (Stage 6, plan.md): handled by cpsr_an_wr_en
            // instead, same "dedicated wr_en, WB must not double-apply"
            // shape as ex_is_mem_rmw immediately above.
            wb_an_upd_en     <= ex_an_upd_en && !ex_is_mem_rmw && !ex_is_cpsr;
            wb_an_upd_reg    <= ex_an_upd_reg;
            wb_an_upd_new    <= ex_an_new;
            wb_is_mem_rd     <= ex_is_mem_rd;
            wb_is_mem_rmw    <= ex_is_mem_rmw;
            wb_is_movea_w    <= ex_is_movea_w;
            wb_is_movec_wr   <= ex_is_movec_wr;
            wb_movec_rc      <= ex_movec_rc;
            wb_is_move_sr_w  <= ex_is_move_sr_w;
            wb_is_move_ccr_w <= ex_is_move_ccr_w;
            wb_is_move_usp   <= ex_is_move_usp;
            wb_is_muldivl    <= ex_is_muldivl;
            wb_md_dst2       <= ex_md_dst2;
            wb_md_64bit      <= ex_md_64bit;
            // wb_md_hi: for mul/div captures result_hi; for EXG captures rd_a (primary reg val)
            wb_md_hi         <= ex_is_exg ? rd_a_data : md_result_hi;
            wb_is_exg        <= ex_is_exg;
            wb_exg_dd        <= ex_exg_dd;
        end
    end

    // -----------------------------------------------------------------------
    // Regfile write outputs
    // For memory loads with MOVEA.W: sign-extend wb_result[15:0] before writing.
    // -----------------------------------------------------------------------
    logic [31:0] wb_result_final;
    assign wb_result_final = wb_is_movea_w
                           ? {{16{wb_result[15]}}, wb_result[15:0]}
                           : wb_result;

    // MOVEM load writes directly on each mem_ack (bypasses WB path).
    // WB has wb_writes_reg=0 during MOVEM so no conflict.
    // For (An)+ load: if base An is in register mask, wr_en would fire simultaneously
    // with movem_an_wr_en at movem_last; wr_en has higher regfile priority so we must
    // suppress it — postincrement value (from an_wr_en) must win per 68000 spec.
    logic        movem_wr_en;
    logic [31:0] movem_wr_data;
    assign movem_wr_en  = movem_run_r && movem_load_r && mem_ack &&
                          !(movem_postinc_r && movem_reg_sel == {1'b1, movem_an_r});
    // Word loads sign-extend to 32 bits (68030 sign-extends MOVEM.W loads).
    assign movem_wr_data = movem_long_r ? mem_rdata
                                        : {{16{mem_rdata[15]}}, mem_rdata[15:0]};

    // MOVEP load writes on last byte ack (assembles bytes into Dn).
    // memind outer-read writes directly on mem_ack (bypasses WB latch).
    logic memind_wr_en;
    assign memind_wr_en = memind_outer_r && mem_ack && memind_is_rd_r;

    // 10-item backlog Stage 9a (plan.md): LEA's own memind case completes
    // on the INNER read's own ack instead (no outer bus cycle at all --
    // see memind_addr_only_r's own declaration comment). mem_rdata here is
    // the just-arrived pointer value itself; memind_post_xn_r/memind_od_r
    // were already captured back at memind_start_r, so the final resolved
    // address is available combinationally the same cycle.
    logic        memind_addr_wr_en;
    logic [31:0] memind_addr_wr_data;
    assign memind_addr_wr_en   = memind_inner_r && mem_ack && memind_addr_only_r;
    assign memind_addr_wr_data = mem_rdata + memind_post_xn_r + memind_od_r;

    // BF memory Dn write — non-mutating ops write extracted result to Dn at read ack.
    // BFTST(000) has no Dn destination; BFEXTU/EXTS/FFO(001/010/011) write to ext_data[14:12]=bf_mem_dn_r.
    logic bf_dn_wr_en;
    assign bf_dn_wr_en = bf_mem_run_r && mem_ack && !bf_mem_phase_r && !bf_mem_mutates_r &&
                         (bf_mem_op_r != 3'b000);

    // BF memory CCR — non-mutating at read ack; mutating at write ack.
    logic bf_mem_sr_wr_en;
    assign bf_mem_sr_wr_en = bf_mem_run_r && mem_ack &&
                             ((!bf_mem_mutates_r && !bf_mem_phase_r) ||
                              ( bf_mem_mutates_r &&  bf_mem_phase_r));

    // Word MOVEP writes only [15:0] (siz=10); long writes full 32 bits (siz=00).
    assign wr_en   = movem_wr_en || movep_wr_en || memind_wr_en || memind_addr_wr_en ||
                    bf_dn_wr_en || (wb_valid && wb_writes_reg);
    assign wr_sel  = movem_wr_en       ? movem_reg_sel
                   : movep_wr_en       ? movep_wr_sel
                   : memind_wr_en      ? memind_dest_r
                   : memind_addr_wr_en ? memind_dest_r
                   : bf_dn_wr_en       ? {1'b0, bf_mem_dn_r}
                   :                     wb_dest_reg;
    assign wr_siz  = movem_wr_en       ? 2'b00
                   : movep_wr_en       ? (movep_long_r ? 2'b00 : 2'b10)
                   : memind_wr_en      ? memind_siz_r
                   : memind_addr_wr_en ? memind_siz_r
                   : bf_dn_wr_en       ? 2'b00
                   :                     wb_siz;
    assign wr_data = movem_wr_en       ? movem_wr_data
                   : movep_wr_en       ? movep_wr_data
                   : memind_wr_en      ? mem_rdata
                   : memind_addr_wr_en ? memind_addr_wr_data
                   : bf_dn_wr_en       ? bf_result_w
                   :                     wb_result_final;

    // second Dn write port for 64-bit mul/div high result (Dh or Dr).
    // EXG Dx,Dy also uses wr2 to write primary-reg value to secondary Dn.
    // CAS uses wr2 to write M[EA] back to Dc when compare fails (Z==0).
    // CAS2 mismatch — dc1_wr_r writes Dc1←rdata1, dc2_wr_r writes Dc2←rdata2.
    assign wr2_en   = cas_dc_wr_en || cas2_dc1_wr_en || cas2_dc2_wr_en ||
                      (wb_valid && ((wb_is_muldivl && wb_md_64bit && !div_trap) ||
                                    (wb_is_exg && wb_exg_dd)));
    assign wr2_sel  = cas_dc_wr_en    ? cas_dc_reg_r[2:0]  :
                      cas2_dc1_wr_en  ? cas2_dc1_reg_r     :
                      cas2_dc2_wr_en  ? cas2_dc2_reg_r     : wb_md_dst2;
    assign wr2_data = cas_dc_wr_en    ? cas_rdata_sized     :
                      cas2_dc1_wr_en  ? cas2_rdata1_sized_w :
                      cas2_dc2_wr_en  ? cas2_rdata2_sized_w : wb_md_hi;

    // An update port: MOVEM fires at completion; RTR fires from EX; WB handles normal.
    logic        movem_an_wr_en;
    assign movem_an_wr_en = movem_last && (movem_predec_r || movem_postinc_r);

    // MOVE16 postincrement — src An on move16_last, dst An one cycle later
    logic move16_an1_wr_en;
    assign move16_an1_wr_en = move16_last && move16_src_postinc_r;

    // CMPM postincrement — Ay fires at phase 1 ack, Ax fires at phase 2 ack.
    logic cmpm_ay_wr_en, cmpm_ax_wr_en;
    assign cmpm_ay_wr_en = ex_valid && ex_is_cmpm && !cmpm_phase_r && mem_ack;
    assign cmpm_ax_wr_en = ex_valid && ex_is_cmpm &&  cmpm_phase_r && mem_ack;

    // ADDX/SUBX -(Ay),-(Ax) — Ay fires at phase 0 ack, Ax fires at phase 1 ack.
    logic addx_ay_wr_en, addx_ax_wr_en;
    assign addx_ay_wr_en = ex_valid && ex_is_addx_mem && addx_mem_run_r &&
                           addx_mem_phase_r == 2'd0 && mem_ack;
    assign addx_ax_wr_en = ex_valid && ex_is_addx_mem && addx_mem_run_r &&
                           addx_mem_phase_r == 2'd1 && mem_ack;

    // PACK/UNPK memory An update enables
    // Ay is updated at read ack (phase 0); Ax is updated at write ack (phase 1).
    logic pack_ay_wr_en, pack_ax_wr_en;
    assign pack_ay_wr_en = pack_mem_run_r && !pack_mem_phase_r && mem_ack;
    assign pack_ax_wr_en = pack_mem_run_r &&  pack_mem_phase_r && mem_ack;

    assign an_wr_en  = movem_an_wr_en || rtr_an_wr_en || rte_an_wr_en ||
                       move16_an1_wr_en || move16_an2_wr_r ||
                       addx_ay_wr_en || addx_ax_wr_en ||
                       pack_ay_wr_en || pack_ax_wr_en ||
                       cmpm_ay_wr_en || cmpm_ax_wr_en ||
                       bcds_ay_wr_en || bcds_ax_wr_en ||
                       mem_rmw_an_wr_en || move_mm_dst_an_wr_en || cpsr_an_wr_en ||
                       (wb_valid && wb_an_upd_en);
    // an_wr_sel and an_wr_data share the same 15-arm priority — kept together
    // in one always_comb so they can never get out of sync.
    always_comb begin
        an_wr_sel  = wb_an_upd_reg;   // default: writeback path
        an_wr_data = wb_an_upd_new;
        if      (movem_an_wr_en)       begin an_wr_sel = movem_an_r;           an_wr_data = movem_an_final;                              end
        else if (rtr_an_wr_en)         begin an_wr_sel = 3'b111;               an_wr_data = rtr_an_wr_data;                              end
        else if (rte_an_wr_en)         begin an_wr_sel = 3'b111;               an_wr_data = rte_a7_next_r + 32'd4 + {24'h0, rte_fmt_skip_r}; end
        else if (move16_an1_wr_en)     begin an_wr_sel = move16_src_an_r;      an_wr_data = move16_src_base_r + 32'd16;                  end
        else if (move16_an2_wr_r)      begin an_wr_sel = move16_dst_an_r;      an_wr_data = move16_dst_base_r + 32'd16;                  end
        else if (addx_ay_wr_en)        begin an_wr_sel = addx_ay_reg_r;        an_wr_data = addx_ay_addr_r;                              end
        else if (addx_ax_wr_en)        begin an_wr_sel = addx_ax_reg_r;        an_wr_data = addx_ax_addr_r;                              end
        else if (pack_ay_wr_en)        begin an_wr_sel = pack_mem_ay_reg_r;    an_wr_data = pack_mem_ay_addr_r;                          end
        else if (pack_ax_wr_en)        begin an_wr_sel = pack_mem_ax_reg_r;    an_wr_data = pack_mem_ax_addr_r;                          end
        else if (cmpm_ay_wr_en)        begin an_wr_sel = ex_src_reg[2:0];      an_wr_data = rd_a_data + cmpm_ay_step;                    end
        else if (cmpm_ax_wr_en)        begin an_wr_sel = cmpm_ax_reg_r;        an_wr_data = cmpm_ax_addr_r + cmpm_step_r;                end
        else if (bcds_ay_wr_en)        begin an_wr_sel = bcds_ay_reg_r;        an_wr_data = bcds_ay_addr_r;                              end
        else if (bcds_ax_wr_en)        begin an_wr_sel = bcds_ax_reg_r;        an_wr_data = bcds_ax_addr_r;                              end
        else if (mem_rmw_an_wr_en)     begin an_wr_sel = ex_an_upd_reg;        an_wr_data = rd_a_data + ex_an_delta;                     end
        else if (move_mm_dst_an_wr_en) begin an_wr_sel = move_mm_dst_an_reg_r; an_wr_data = move_mm_dst_an_new_r;                        end
        else if (cpsr_an_wr_en)        begin an_wr_sel = ex_an_upd_reg;        an_wr_data = rd_a_data + ex_an_delta;                     end
    end

    // -----------------------------------------------------------------------
    // CCR / SR write outputs
    // For MOVE: N and Z must reflect the RESULT, not rd_a_data.
    // For register/immediate-source MOVE, wb_move_n/wb_ccr[2] hold the correct values.
    // For memory-source MOVE (wb_is_mem_rd AND NOT wb_is_mem_rmw), rd_a_data holds the EA
    // (address), so wb_move_n and wb_ccr[2] were computed from the address.  Override N and Z
    // from wb_result (mem_rdata latched at memory ack).
    // For RMW-based MOVE (MOVE #imm→indexed, MOVE Dn→indexed): wb_is_mem_rmw=1; wb_move_n
    // and wb_ccr[2] were computed from the actual source value (imm or Dn) at read ack, so
    // they are correct — do not override with mem_rdata.
    // -----------------------------------------------------------------------
    logic [4:0] final_ccr;
    logic [1:0] move_nz_live;
    always_comb begin
        if (wb_is_mem_rd && !wb_is_mem_rmw && wb_is_move) begin
            case (wb_siz)
                2'b01:   move_nz_live = {wb_result[7],  wb_result[7:0]  == 8'h00};
                2'b10:   move_nz_live = {wb_result[15], wb_result[15:0] == 16'h00};
                default: move_nz_live = {wb_result[31], wb_result       == 32'h00};
            endcase
        end else begin
            move_nz_live = {wb_move_n, wb_ccr[2]};
        end
    end
    assign final_ccr = wb_is_move ? {wb_ccr[4], move_nz_live, 2'b00} : wb_ccr;
    // WB→EX SR forwarding assigns — here so all wb_* and final_ccr are in scope.
    assign sr_fwd_en  = wb_valid && (wb_is_move_sr_w || wb_is_move_ccr_w || wb_updates_ccr);
    assign sr_fwd_val = wb_is_move_sr_w  ? wb_result[15:0]
                      : wb_is_move_ccr_w ? {sr_out[15:8], 3'b000, wb_result[4:0]}
                      :                    {sr_out[15:8], 3'b000, final_ccr};
    assign sr_live    = sr_fwd_en ? sr_fwd_val : sr_out;

    // memind outer-read CCR update (MOVE sets N/Z, clears V/C)
    logic memind_ccr_wr_en;
    logic [4:0] memind_ccr_w;
    assign memind_ccr_wr_en = memind_wr_en;   // fires same cycle as the WB
    always_comb begin
        case (memind_siz_r)
            2'b01: memind_ccr_w = {flag_x, mem_rdata[7],  (mem_rdata[7:0]  == 8'h0),  1'b0, 1'b0};
            2'b10: memind_ccr_w = {flag_x, mem_rdata[15], (mem_rdata[15:0] == 16'h0), 1'b0, 1'b0};
            default: memind_ccr_w = {flag_x, mem_rdata[31], (mem_rdata == 32'h0), 1'b0, 1'b0};
        endcase
    end

    // ADDX/SUBX mem CCR fires at write ack; ALU mux already drives addx_src/dst.
    logic addx_mem_sr_wr_en;
    assign addx_mem_sr_wr_en = ex_valid && ex_is_addx_mem && addx_mem_run_r &&
                               addx_mem_phase_r == 2'd2 && mem_ack;

    // SR write: RTE/STOP write full SR; RTR/MOVE CCR write CCR-only; others normal WB.
    // wb_is_move_sr_w fires full SR write; wb_is_move_ccr_w fires CCR-only write.
    assign sr_wr_en   = rte_sr_wr_en || stop_sr_wr_en ||
                        rtr_sr_wr_en || tas_sr_wr_en || cmp2_sr_wr_en || memind_ccr_wr_en ||
                        mem_rmw_sr_wr_en || addx_mem_sr_wr_en || bf_mem_sr_wr_en ||
                        move_mm_sr_wr_en || cas_sr_wr_en || bcds_sr_wr_en || cas2_sr_wr_en ||
                        (wb_valid && (wb_updates_ccr || wb_is_move_sr_w || wb_is_move_ccr_w));
    assign sr_wr_data = rte_sr_wr_en        ? rte_sr_r
                      : stop_sr_wr_en       ? ex_stop_sr
                      : rtr_sr_wr_en        ? rtr_sr_wr_data
                      : tas_sr_wr_en        ? {sr_live[15:8], 3'b000, tas_ccr_r}
                      : cmp2_sr_wr_en       ? {sr_live[15:8], 3'b000, flag_x, flag_n, cmp2_z_w, flag_v, cmp2_c_w}
                      : memind_ccr_wr_en    ? {sr_live[15:8], 3'b000, memind_ccr_w}
                      : mem_rmw_sr_wr_en    ? {sr_live[15:8], 3'b000, mem_rmw_ccr_r}
                      : addx_mem_sr_wr_en   ? {sr_live[15:8], 3'b000, ex_x, ex_n, ex_z, ex_v, ex_c}
                      : bf_mem_sr_wr_en     ? {sr_live[15:8], 3'b000, flag_x, bf_n, bf_z, bf_v, bf_c}
                      : move_mm_sr_wr_en    ? {sr_live[15:8], 3'b000, move_mm_ccr_r}
                      : cas_sr_wr_en        ? {sr_live[15:8], 3'b000, cas_ccr_r}
                      : bcds_sr_wr_en       ? {sr_live[15:8], 3'b000, bcd_c, bcd_result[7], bcd_z, bcd_v, bcd_c}
                      : cas2_sr_wr_en       ? {sr_live[15:8], 3'b000, cas2_ccr_r}
                      : wb_is_move_sr_w     ? (wb_result[15:0] & 16'hF71F)
                      : wb_is_move_ccr_w    ? {sr_live[15:8], 3'b000, wb_result[4:0]}
                      :                       {sr_live[15:8], 3'b000, final_ccr};
    assign sr_ccr_only = (rte_sr_wr_en || stop_sr_wr_en ||
                          (wb_valid && wb_is_move_sr_w)) ? 1'b0 : 1'b1;

    // -----------------------------------------------------------------------
    // Divide-by-zero trap / CHK-CHK2 out-of-bounds trap (combinational)
    // -----------------------------------------------------------------------
    // Gated the same way as chk_trap below: for a memory-source divide,
    // md_div_by_zero is derived combinationally from mem_rdata, which reads
    // as 0 (its default/idle value) before the bus read actually completes —
    // without the mem_ack gate, div_trap fired immediately on ex_valid using
    // that premature all-zero "divisor", triggering a bogus trap sequence
    // that collided with the still-pending ex_mem_stall and hung the
    // pipeline permanently (found via $display tracing: mem_ack=0,
    // mem_rdata=0, md_div_by_zero=1, ex_mem_stall=1, forever).
    //
    // MUL/DIV timing investigation (plan.md): div_trap_raw (this same
    // condition, renamed) now feeds div_trap_fired_r's own one-shot latch
    // (declared earlier, next to chk_trap_fired_r) -- see that signal's own
    // comment for the full derivation of why this is now necessary (the new
    // internal stall on DIVS.L/DIVU.L Dn,Dn holds ex_valid for ~350 ticks,
    // and this condition would otherwise re-fire on every one of them).
    assign div_trap_raw = (ex_valid && (ex_unit == UNIT_DIV) && !ex_is_mem_src && md_div_by_zero)
                    || (ex_valid && (ex_unit == UNIT_DIV) && ex_is_mem_src && mem_ack && md_div_by_zero);
    assign div_trap = div_trap_raw && !div_trap_fired_r;
    // CHK: trap on reg/imm comparison, memory-source ack, or CHK2 second-read ack.
    assign chk_trap_raw = (ex_valid && ex_is_chk && !ex_is_mem_rd && (chk_below_w || chk_above_w))
                        || (ex_valid && ex_is_chk && ex_is_mem_rd && mem_ack &&
                            (chk_mem_below_w || chk_mem_above_w))
                        || (cmp2_run_r && mem_ack && cmp2_is_chk2_r && cmp2_c_w);
    // Cycle-accuracy-closing plan.md, Stage 2: chk_trap_fired_r makes this
    // edge-triggered -- fires at most once per instruction occupying EX,
    // not on every cycle its own raw condition stays true. Phase 166's own
    // attempted CHK Dn,Dn artificial-stall whitelist entry found this the
    // hard way: the register-direct branch above is a pure combinational
    // condition on ex_valid, which the ex_internal_stall mechanism holds
    // high for multiple extra cycles once an instruction gets a stall
    // entry -- chk_trap re-fired on every one of those ticks (chk_trap_cnt
    // incremented 11x instead of 1x in tb/exception_tb.sv's own CHK-02/03/
    // 06 checks), never a problem before since the register-direct CHK
    // path had never held ex_valid for more than 1 cycle. chk_trap_fired_r
    // (declared/updated near ex_valid's own EX-latch block) clears whenever
    // ex_valid drops (the instruction retires or gets flushed, ready for
    // the next one) and latches the instant chk_trap_raw first fires,
    // suppressing every subsequent tick of the same instance.
    assign chk_trap = chk_trap_raw && !chk_trap_fired_r;

    // -----------------------------------------------------------------------
    // BRA/Bcc branch — decided at decode time once CCR hazards are clear.
    // -----------------------------------------------------------------------
    assign dec_branch_taken = dec_valid && !stall && dec_is_branch &&
                              eval_cc(dec_branch_cond, flag_n, flag_z, flag_v, flag_c);

    // synthesis translate_off
    integer _bcc1_tk, _bcc1_nt, _bcc2_tk, _bcc2_nt;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            _bcc1_tk <= 0; _bcc1_nt <= 0; _bcc2_tk <= 0; _bcc2_nt <= 0;
        end else begin
            if (dec_valid && !stall && dec_is_branch && dec_branch_cond == 4'h4) begin
                if (decode_pc[15:0] == 16'h0082) begin
                    if (dec_branch_taken) _bcc1_tk <= _bcc1_tk + 1;
                    else                  _bcc1_nt <= _bcc1_nt + 1;
                    if ((_bcc1_tk + _bcc1_nt + 1) % 5000 == 0)
                        $display("BCC1_STAT iter=%0d taken=%0d notaken=%0d",
                                 _bcc1_tk+_bcc1_nt+1, _bcc1_tk, _bcc1_nt);
                end
                if (decode_pc[15:0] == 16'h008c) begin
                    if (dec_branch_taken) _bcc2_tk <= _bcc2_tk + 1;
                    else                  _bcc2_nt <= _bcc2_nt + 1;
                    if ((_bcc2_tk + _bcc2_nt + 1) % 5000 == 0)
                        $display("BCC2_STAT iter=%0d taken=%0d notaken=%0d",
                                 _bcc2_tk+_bcc2_nt+1, _bcc2_tk, _bcc2_nt);
                end
            end
        end
    end
    // -----------------------------------------------------------------------
    // DBcc branch — decided at EX stage (needs ALU result to check counter).
    // Branch taken when: condition is FALSE AND decremented counter != 0xFFFF.
    // -----------------------------------------------------------------------
    assign ex_alu_result_w = alu_result[15:0];

    assign ex_dbcc_taken = ex_valid && ex_is_dbcc &&
                           !eval_cc(ex_dbcc_cond, flag_n, flag_z, flag_v, flag_c) &&
                           (ex_alu_result_w != 16'hFFFF);

    // -----------------------------------------------------------------------
    // JMP/JSR/BSR/RTS/RTR branches — decided from EX stage.
    // JMP: fires when JMP enters EX (no memory op).
    // JSR/BSR: fires when push (mem_ack=1) completes.
    // RTS: fires when stack-read completes (mem_ack=1).
    // RTR: fires after BOTH reads complete (rtr_phase_r=1 and mem_ack=1).
    // -----------------------------------------------------------------------
    // 10-item backlog Stage 9b (plan.md): JMP's own genuine memory-indirect
    // case shares LEA's own memind_addr_only_r shape (no outer bus access,
    // completes the instant the inner pointer read's own ack arrives) --
    // the ordinary (non-memind) case is unchanged, still firing the
    // instant JMP enters EX.
    assign ex_jmp_taken = ex_is_memind ? (ex_valid && ex_is_jmp && memind_inner_r && mem_ack && memind_addr_only_r)
                                        : (ex_valid && ex_is_jmp);
    // 10-item backlog Stage 9b (plan.md): JSR's own genuine memory-indirect
    // case needs the OUTER write (the return-PC push) to complete before
    // jumping, not the inner pointer read's own ack -- otherwise this
    // would fire a whole bus cycle too early.
    assign ex_jsr_taken = ex_is_memind ? (ex_valid && ex_is_jsr && memind_outer_r && mem_ack)
                                        : (ex_valid && ex_is_jsr && mem_ack);
    assign ex_bsr_taken = ex_valid && ex_is_bsr && mem_ack;
    assign ex_rts_taken = ex_valid && ex_is_rts && mem_ack;
    assign ex_rtr_taken = ex_valid && ex_is_rtr && rtr_phase_r && mem_ack;
    assign ex_rte_taken = ex_valid && ex_is_rte && rte_phase_r && mem_ack;

    assign branch_taken  = dec_branch_taken | ex_dbcc_taken |
                           ex_jmp_taken | ex_jsr_taken | ex_bsr_taken |
                           ex_rts_taken | ex_rtr_taken | ex_rte_taken;

    assign branch_target = dec_branch_taken                         ? (decode_pc    + 32'd2 + dec_branch_disp)
                         : ex_dbcc_taken                            ? (ex_decode_pc + 32'd2 + ex_dbcc_disp)
                         : ex_bsr_taken                             ? ex_bsr_target
                         : (ex_rts_taken || ex_rtr_taken || ex_rte_taken) ? mem_rdata
                         // 10-item backlog Stage 9b (plan.md): JMP's own
                         // genuine memory-indirect target -- same resolved-
                         // address formula as LEA's own memind_addr_wr_data.
                         : (ex_is_jmp && ex_is_memind)               ? (mem_rdata + memind_post_xn_r + memind_od_r)
                         // JSR's own memind target -- fires later, once the
                         // outer (return-PC push) write completes, so
                         // memind_ptr_r is already latched (unlike JMP's
                         // own case above, which fires during the inner
                         // read's own ack and must use the combinational
                         // mem_rdata directly).
                         : (ex_is_jsr && ex_is_memind)               ? memind_outer_addr_w
                         :                                             ex_jmp_target;  // JMP or JSR

    // -----------------------------------------------------------------------
    // RTR completion: CCR write and A7 update fire directly from EX stage.
    // Normal WB an_wr/sr_wr handles RTS, JSR, BSR stack updates.
    // rtr_sr_wr_en/rtr_an_wr_en declared in early section for forward-ref safety.
    // -----------------------------------------------------------------------
    assign rtr_sr_wr_en  = ex_rtr_taken;
    assign rtr_sr_wr_data = {sr_live[15:8], rtr_ccr_r};
    assign rtr_an_wr_en  = ex_rtr_taken;
    assign rtr_an_wr_data = rtr_a7_next_r + 32'd4;

    // RTE completion — full SR restore + A7 update
    assign rte_sr_wr_en  = ex_rte_taken;
    assign rte_an_wr_en  = ex_rte_taken;

    // Format Error — RTE with unrecognised frame format code fires vector 14.
    // The first RTE longword at A7 is {format_word, SR}; format code in mem_rdata[31:28].
    // Valid codes: $0, $2, $3, $4, $8, $9, $A, $B.  All others raise Format Error.
    function automatic logic rte_fmt_valid(input logic [3:0] code);
        case (code)
            4'h0, 4'h2, 4'h3, 4'h4, 4'h8, 4'h9, 4'hA, 4'hB: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // Extra bytes to pop beyond the base 8 (2 LW: {fmtvec,SR} + PC) already consumed.
    // Frame sizes: $0=2LW $2=3LW $3=4LW $4=8LW $8=29LW $9=12LW $A=16LW $B=46LW
    function automatic logic [7:0] rte_frame_extra(input logic [3:0] code);
        case (code)
            4'h0:    return 8'd0;    // 8 bytes total
            4'h2:    return 8'd4;    // 12 bytes total (TRAPV, CHK)
            4'h3:    return 8'd8;    // 16 bytes total
            4'h4:    return 8'd24;   // 32 bytes total
            4'h8:    return 8'd108;  // 116 bytes total
            4'h9:    return 8'd40;   // 48 bytes total
            4'hA:    return 8'd56;   // 64 bytes total
            4'hB:    return 8'd176;  // 184 bytes total
            default: return 8'd0;
        endcase
    endfunction
    // Open-items backlog Stage 14 (plan.md): cpsr_fmt_err_w widens this same
    // vector-14 dispatch to also cover cpSAVE/cpRESTORE's own invalid coprocessor
    // state-frame format word (Section 10.5.1.5) -- architecturally the same
    // Format Error exception RTE's own bad stack-frame format triggers, just a
    // different trigger source.
    assign eu_fmt_err_req = (ex_valid && ex_is_rte && !rte_phase_r && mem_ack &&
                             !rte_fmt_valid(mem_rdata[31:28])) ||
                            cpsr_fmt_err_w;

    // STOP — SR write fires first cycle STOP is in EX (before stop_r is set)
    assign stop_sr_wr_en = ex_valid && ex_is_stop && !stop_r;

    // -----------------------------------------------------------------------
    // Memory bus outputs — driven from EX stage when a memory op is active.
    // RTR phase 1: word read (mem_siz=10); phase 2: longword from rtr_a7_next_r.
    // JSR/BSR write: mem_wdata = return PC (not rd_a_data).
    // -----------------------------------------------------------------------
    // MOVEM drives the bus directly during movem_run_r; normal path otherwise.
    // tas_run_r drives the TAS write phase (second bus cycle).
    // cmp2_run_r drives the CMP2/CHK2 second read (upper bound at EA+size).
    // movep_run_r drives byte bus cycles for MOVEP.
    // move16_run_r drives 4 longword reads then 4 longword writes.
    // True when no multi-cycle bus op is active or cooling down; gate for the normal EU mem path.
    logic no_special_bus_op;
    assign no_special_bus_op = !tas_after_write_r && !cmp2_run_r   && !cmp2_after_r   &&
                                !memind_start_r   && !memind_inner_r && !memind_outer_r &&
                                !mem_rmw_run_r    && !mem_rmw_after_r && !pmove64_run_r &&
                                !move_mm_run_r    && !move_mm_after_r &&
                                !cas_get_du_r     && !cas_write_r  && !cas_after_r  && !ex_cas_mem_done_r &&
                                !cas2_rd2_r       && !cas2_get_du1_r && !cas2_wr1_r &&
                                !cas2_get_du2_r   && !cas2_wr2_r  && !cas2_dc1_wr_r && !cas2_dc2_wr_r &&
                                !cas2_after_r     && !ex_cas2_done_r;

    assign mem_req   = movem_run_r || tas_run_r  || cmp2_run_r  || movep_run_r || move16_run_r ||
                       memind_inner_r || memind_outer_r || mem_rmw_run_r || move_mm_run_r ||
                       addx_mem_run_r || bf_mem_run_r || pack_mem_run_r || pmove64_run_r ||
                       cas_write_r || bcds_run_r ||
                       cas2_rd2_r || cas2_wr1_r || cas2_wr2_r ||
                       cpsr_mem_fmt_r || cpsr_xfer_mem_r ||
                       (no_special_bus_op && ex_valid && (ex_is_mem_rd || ex_is_mem_wr));
    assign mem_rw    = movem_run_r    ? movem_load_r
                     : tas_run_r      ? 1'b0
                     : cmp2_run_r     ? 1'b1
                     : movep_run_r    ? movep_load_r
                     : move16_run_r   ? !move16_phase_r
                     : memind_inner_r ? 1'b1        // inner: always longword read
                     : memind_outer_r ? memind_is_rd_r
                     : mem_rmw_run_r  ? 1'b0        // write phase of RMW
                     : move_mm_run_r  ? 1'b0        // write phase of move_mm
                     : addx_mem_run_r ? (addx_mem_phase_r != 2'd2)
                     : bf_mem_run_r   ? !bf_mem_phase_r
                     : pack_mem_run_r ? !pack_mem_phase_r
                     : pmove64_run_r  ? !pmove64_to_mem_r
                     : cas_write_r    ? 1'b0
                     : bcds_run_r     ? (bcds_phase_r != 2'd2)
                     : cas2_rd2_r     ? 1'b1        // CAS2 second read
                     : cas2_wr1_r     ? 1'b0        // CAS2 write Du1→M[Rn1]
                     : cas2_wr2_r     ? 1'b0        // CAS2 write Du2→M[Rn2]
                     // cpSAVE writes (format word / transfer loop -> memory);
                     // cpRESTORE reads (memory -> format word / transfer loop).
                     : (cpsr_mem_fmt_r || cpsr_xfer_mem_r) ? cpsr_is_restore_r
                     : ex_is_mem_rd;
    assign mem_siz   = movem_run_r    ? (movem_long_r ? 2'b00 : 2'b10) :
                       cmp2_run_r     ? cmp2_siz_r :
                       movep_run_r    ? 2'b01 :
                       move16_run_r   ? 2'b00 :
                       memind_inner_r ? 2'b00 :
                       memind_outer_r ? memind_siz_r :
                       mem_rmw_run_r  ? ex_siz :
                       move_mm_run_r  ? move_mm_siz_r :
                       addx_mem_run_r ? addx_siz_r :
                       bf_mem_run_r   ? 2'b00 :
                       pack_mem_run_r ? pack_mem_cur_siz :
                       pmove64_run_r  ? 2'b00 :
                       cas_write_r    ? cas_siz_r :
                       bcds_run_r     ? 2'b01 :
                       (cas2_rd2_r || cas2_wr1_r || cas2_wr2_r) ? cas2_siz_r :
                       (cpsr_mem_fmt_r || cpsr_xfer_mem_r) ? 2'b00 :  // always longword
                       (ex_is_rtr && !rtr_phase_r) ? 2'b10 :
                       (ex_is_rte && !rte_phase_r) ? 2'b00 :  // longword: reads {format_word,SR} together
                       (ex_mem_rd_siz != 2'b00)    ? ex_mem_rd_siz :
                       ex_siz;
    // MOVES uses SFC for loads (ea→Rn) and DFC for stores (Rn→ea)
    assign mem_fc    = (ex_is_moves && ex_moves_load)  ? sfc_in :
                       (ex_is_moves && !ex_moves_load) ? dfc_in :
                                                         {sr_live[13], 1'b0, 1'b1};
    assign mem_addr  = movem_run_r    ? movem_addr_r :
                       cmp2_run_r     ? cmp2_addr2_r :
                       movep_run_r    ? movep_addr_r :
                       move16_run_r   ? (!move16_phase_r ? move16_src_r : move16_dst_r) :
                       memind_inner_r ? memind_inner_addr_r :
                       memind_outer_r ? ((memind_is_pea_r || memind_is_jsr_r) ? memind_pea_wr_addr_r : memind_outer_addr_w) :
                       mem_rmw_run_r  ? mem_rmw_addr_r :
                       move_mm_run_r  ? move_mm_dst_addr_r :
                       addx_mem_run_r ? (addx_mem_phase_r == 2'd0 ? addx_ay_addr_r : addx_ax_addr_r) :
                       bf_mem_run_r   ? bf_mem_addr_r :
                       pack_mem_run_r ? (pack_mem_phase_r ? pack_mem_ax_addr_r : pack_mem_ay_addr_r) :
                       pmove64_run_r  ? (pmove64_addr_r + 32'd4) :
                       cas_write_r    ? cas_ea_r :
                       bcds_run_r     ? (bcds_phase_r == 2'd0 ? bcds_ay_addr_r : bcds_ax_addr_r) :
                       cas2_rd2_r     ? rd_a_data :       // Rn2 from rd_a override
                       cas2_wr1_r     ? cas2_ea1_r :      // write Du1→M[Rn1]
                       cas2_wr2_r     ? cas2_ea2_r :      // write Du2→M[Rn2]
                       cpsr_mem_fmt_r ? cpsr_ea_r :           // format word always at EA itself
                       cpsr_xfer_mem_r ? cpsr_xfer_addr_r :
                       (ex_is_rtr && rtr_phase_r)            ? rtr_a7_next_r :
                       (ex_is_rte && rte_phase_r)            ? rte_a7_next_r :
                       (ex_is_cmpm && cmpm_phase_r)          ? cmpm_ax_addr_r : ex_ea;
    // For MOVEM store: rd_a_data provides the register value (rd_a_sel overridden above).
    // For TAS write phase: drive tas_wdata_r (original byte | 0x80).
    // For MOVEP store: drive the appropriate byte of Dn.
    // For MOVE16 write phase: drive the buffered longword for the current beat.
    assign mem_wdata = cas2_wr1_r               ? cas2_du1_val_r
                     : cas2_wr2_r              ? cas2_du2_val_r
                     : cas_write_r             ? cas_du_val_r
                     // cpSAVE only (mem_rw=0 -- cpRESTORE's own cpsr_mem_fmt_r/
                     // cpsr_xfer_mem_r phases are reads, this value is unused
                     // then): format+length word in the upper half, reserved
                     // lower half per Figure 10-14; the just-read Operand CIR
                     // value for the transfer loop.
                     : cpsr_mem_fmt_r          ? {cpsr_fmt_r, 16'h0}
                     : cpsr_xfer_mem_r         ? cpsr_xfer_val_r
                     : (bcds_run_r && bcds_phase_r == 2'd2) ? {bcd_result, 24'h0}
                     : mem_rmw_run_r            ? mem_rmw_wdata_r
                     : move_mm_run_r            ? eu_lane(move_mm_data_r, move_mm_siz_r)
                     : (addx_mem_run_r && addx_mem_phase_r == 2'd2) ?
                                                  eu_lane(ex_result, ex_siz)
                     : (bf_mem_run_r && bf_mem_phase_r) ? bf_result_w
                     : (pack_mem_run_r && pack_mem_phase_r) ? pack_mem_wdata_w
                     : tas_run_r               ? {tas_wdata_r, 24'h0}
                     : movep_run_r             ? {movep_wr_byte_r, 24'h0}
                     : move16_run_r            ? move16_wdata_w
                     : (ex_is_pmove && ex_pmove_to_mem) ? pmove_wr_data_w
                     : (ex_is_pmove64 && ex_pmove_to_mem) ? pmove64_wr_data_w
                     : (pmove64_run_r && pmove64_to_mem_r) ? pmove64_wr_data_w
                     // 10-item backlog Stage 9a (plan.md): PEA's own memind
                     // outer phase pushes the RESOLVED indirect address
                     // (ptr+post_xn+od), not the ordinary An+d+Xn value the
                     // generic ex_is_pea case below computes.
                     : (memind_outer_r && memind_is_pea_r) ? memind_outer_addr_w
                     : ex_is_pea               ? (ex_abs_jmp_en ? (ex_abs_ea_val + (ex_is_idx ? ex_xn_scaled : 32'h0))
                                                                 : (rd_a_data + ex_jump_offset + ex_xn_scaled))
                     : (ex_is_jsr || ex_is_bsr) ? ex_return_pc
                     : (ex_is_mem_wr && ex_use_imm) ? eu_lane(ex_imm, ex_siz)
                     : (movem_run_r && !movem_load_r && !movem_long_r) ? {rd_a_data[15:0], 16'h0}
                     // LINK A7: push decremented SP (A7-4), not original A7
                     : (ex_is_link && ex_src_reg == ex_dst_reg) ? ex_ea
                     // MOVE Dn/An → (d8,An,Xn) (Phase 149, plan.md): rd_a/rd_b hold the
                     // indexed EA's An/Xn; the source register's value is on rd_c.
                     : ex_is_move_reg_idx_dst  ? eu_lane(rd_c_data, ex_siz)
                     :                                             eu_lane(rd_a_data, ex_siz);
    // RMW — assert during TAS (An) read phase (not during write or cooldown).
    assign mem_rmw   = ex_valid && ex_is_tas && ex_is_mem_rd && !tas_run_r && !tas_after_write_r;

    // Phase 158 Stage 3: mem_rmw_lookup — TAS (same condition as mem_rmw
    // above) OR CAS's own read phase (cas_read_ack's own condition, minus
    // mem_ack, so it's true for the whole in-flight read not just the ack
    // cycle) OR CAS2's own two read phases (cas2_rd1_ack's own condition
    // minus mem_ack, for rd1; cas2_rd2_r, an existing register already
    // representing "currently issuing the second read", for rd2).
    assign mem_rmw_lookup =
        (ex_valid && ex_is_tas  && ex_is_mem_rd && !tas_run_r && !tas_after_write_r) ||
        (ex_valid && ex_is_cas  && ex_is_mem_rd && !cas_get_du_r && !cas_active_r &&
         !ex_cas_mem_done_r) ||
        (ex_valid && ex_is_cas2 && ex_is_mem_rd && !cas2_active_r && !ex_cas2_done_r) ||
        cas2_rd2_r;

    // -----------------------------------------------------------------------
    // FPU coprocessor / cpSAVE / cpRESTORE bus interface outputs
    // eu_coproc_req asserted while fpu_run_r (CPI read, cpid=1 register 0)
    // or any of the cpsr_* CIR-touching phases (Phase 157 Stage 4's own
    // Save/Restore CIR read, plus Stage 14's own Restore-CIR-write/echo,
    // Control-CIR abort-mask write, and Operand-CIR transfer-loop access) --
    // mutually exclusive, only one instruction occupies EX at a time.
    // FPU address: A[31:20]=0, A[19:16]=0010, A[15:13]=ppp, A[12:11]=01
    // (cpid=1), A[10:0]=0. NOTE (found while implementing Stage 4, out of
    // scope to fix here): per the real manual's Figure 10-3, A[15:13]
    // should be CpID (not ppp) with the CIR register selector at A[4:0] --
    // this pre-existing FPU stub address layout (Phase 55) doesn't match
    // that, but nothing in this project exercises it against a real
    // coprocessor, so it's flagged, not touched, matching this rollout's
    // own "found but out of scope" convention. cpSAVE/cpRESTORE below use
    // the real Figure 10-3 layout directly, since this is fresh code.
    // CIR select values (byte offset per Figure 10-5): Save=0x04,
    // Restore=0x06, Control=0x02, Operand=0x10.
    // -----------------------------------------------------------------------
    assign eu_coproc_req   = fpu_run_r || cpsr_run_r || cpsr_cir_wr_r ||
                             cpsr_cir_echo_r || cpsr_abort_r || cpsr_xfer_cir_r;
    // Reads by default (Save/Restore CIR read, Restore-CIR echo read, and
    // the save-direction Operand CIR read) -- explicit writes for
    // cpsr_cir_wr_r (format word -> Restore CIR), cpsr_abort_r (abort mask
    // -> Control CIR), and the restore-direction Operand CIR write.
    assign eu_coproc_rw    = cpsr_cir_wr_r ? 1'b0
                            : cpsr_abort_r ? 1'b0
                            : (cpsr_xfer_cir_r && cpsr_is_restore_r) ? 1'b0
                            : 1'b1;
    assign eu_coproc_fc    = 3'b111;        // CPU Space
    assign eu_coproc_siz   = 2'b00;         // longword
    assign eu_coproc_wdata = cpsr_cir_wr_r  ? {cpsr_fmt_r, 16'h0}
                            : cpsr_abort_r  ? {16'h0001, 16'h0}
                            : cpsr_xfer_cir_r ? cpsr_xfer_val_r
                            : 32'h0;
    assign eu_coproc_addr  = (cpsr_cir_wr_r || cpsr_cir_echo_r)
        ? {12'h000, 4'b0010, 3'b001, 8'h00, 5'h06}                   // Restore CIR
        : cpsr_abort_r
        ? {12'h000, 4'b0010, 3'b001, 8'h00, 5'h02}                   // Control CIR
        : cpsr_xfer_cir_r
        ? {12'h000, 4'b0010, 3'b001, 8'h00, 5'h10}                   // Operand CIR
        : cpsr_run_r
        ? {12'h000, 4'b0010, 3'b001, 8'h00, cpsr_is_restore_r ? 5'h06 : 5'h04}
        : {12'h000, 4'b0010, fpu_prim_r, 2'b01, 11'h000};

    // -----------------------------------------------------------------------
    // BKPT bus interface outputs (Phase 157 Stage 3)
    // eu_bkpt_req asserted while bkpt_run_r; always a read.
    // Address per manual Figure 7-42: A[31:5]=0, breakpoint type field
    // (A[19:16]) is 0, breakpoint number on A[4:2], A[1:0]=0.
    // -----------------------------------------------------------------------
    assign eu_bkpt_req   = bkpt_run_r;
    assign eu_bkpt_rw    = 1'b1;
    assign eu_bkpt_fc    = 3'b111;        // CPU Space
    assign eu_bkpt_siz   = 2'b10;         // word
    assign eu_bkpt_wdata = 32'h0;
    assign eu_bkpt_addr  = {27'h0, bkpt_num_r, 2'b00};

    // -----------------------------------------------------------------------
    // MOVEC Rn→Rc write outputs — fire from WB stage
    // -----------------------------------------------------------------------
    assign vbr_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h801);
    assign vbr_wr_data = wb_result;
    assign sfc_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h000);
    assign sfc_wr_data = wb_result[2:0];
    assign dfc_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h001);
    assign dfc_wr_data = wb_result[2:0];
    assign cacr_wr_en  = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h002);
    assign cacr_wr_data= wb_result;
    assign caar_wr_en  = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h802);
    assign caar_wr_data= wb_result;
    assign usp_wr_en   = (wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h800)) ||
                         (wb_valid && wb_is_move_usp);
    assign usp_wr_data = wb_result;
    assign isp_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h804);
    assign isp_wr_data = wb_result;
    assign msp_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h803);
    assign msp_wr_data = wb_result;

    // -----------------------------------------------------------------------
    // MMU instruction output assignments
    // -----------------------------------------------------------------------
    assign eu_pflush_req = pflush_req_r;
    assign eu_pflush_all = pflush_all_r;
    assign eu_pflush_fc  = pflush_fc_r;
    assign eu_pflush_va  = pflush_va_r;
    assign eu_ptest_req  = ptest_run_r;
    assign eu_ptest_va   = ptest_va_r;
    assign eu_ptest_fc   = ptest_fc_r;
    assign eu_pload_req  = pload_run_r;
    assign eu_pload_va   = pload_va_r;
    assign eu_pload_fc   = pload_fc_r;
    assign eu_pload_rw   = pload_rw_r;
    assign tc_out        = tc_r;
    assign tt0_out       = tt0_r;
    assign tt1_out       = tt1_r;

    // -----------------------------------------------------------------------
    // OS exception/control output assigns
    // -----------------------------------------------------------------------
    assign eu_trap_req    = ex_valid && ex_is_trap;
    assign eu_trap_num    = ex_trap_num;
    assign eu_trapv_req   = ex_valid && ex_is_trapv;
    assign eu_illegal_req = ex_valid && ex_is_illegal;
    assign eu_stop        = stop_r;

    // -----------------------------------------------------------------------
    // new exception output assigns
    // eu_trace_req fires when the instruction is fully done (!ex_mem_stall) and
    // trace mode (T1 or T0+flow-change) is set.  Gated by !ex_mem_stall so it
    // fires exactly once, on the cycle the last (or only) bus cycle completes.
    // -----------------------------------------------------------------------
    assign eu_priv_req  = ex_valid && ex_is_priv;
    assign eu_linea_req = ex_valid && ex_is_linea;
    assign eu_linef_req = ex_valid && ex_is_linef;
    assign eu_trace_req = ex_valid && ex_is_trace && !ex_mem_stall && !ex_internal_stall;

