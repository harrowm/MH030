`timescale 1ns/1ps
`default_nettype none

// MC68030 EU micro-sequencer / decode
// Pipeline: DECODE (comb) → EX (1-cycle latch) → WB (1-cycle latch)
//
// Supported instructions (Dn register-direct EA mode):
//   MOVE.B/W/L  Dn,Dn
//   ADD/SUB/AND/OR/EOR.B/W/L  Dn,Dn  (ea→Dn and Dn→ea)
//   ADDI/SUBI/ANDI/ORI/EORI.B/W/L  #imm,Dn
//   CMP.B/W/L Dn,Dn  ;  CMPI.B/W/L  #imm,Dn
//   NEG/NEGX/NOT/CLR/TST.B/W/L  Dn
//   ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR.B/W/L  Dn (immediate or register count)
//   MULU.W / MULS.W  Dn,Dn
//   DIVU.W / DIVS.W  Dn,Dn
//
// Hazard model: stall decode 2 cycles when EX or WB dest conflicts with decode read.
// WB signals declared early (before stall assigns) to avoid Icarus forward-ref errors.
// Instruction field bit-selects pre-extracted as assigns to avoid Icarus
// "sorry: constant selects in always_*" in the decode always_comb.

module eu_seq (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Instruction word and pre-fetched 32-bit immediate (from IFU / testbench)
    input  logic [15:0] instr_word,
    input  logic        instr_valid,
    input  logic [31:0] ext_data,    // immediate value, full 32 bits
    input  logic        ext_valid,   // ext_data is valid this cycle
    input  logic [15:0] q3_word,     // third extension word (for MOVE.L #imm, abs.W)
    input  logic [31:0] ext34_data,  // ext words 3+4 (for MOVE.L #imm, abs.L)
    input  logic [15:0] q5_word,     // fifth extension word (Phase 145, plan.md)
    input  logic [15:0] q6_word,     // sixth extension word (10-item backlog
                                      // Stage 8, plan.md)

    // Register file read port A — source operand
    output logic [3:0]  rd_a_sel,
    output logic [1:0]  rd_a_siz,
    input  logic [31:0] rd_a_data,

    // Register file read port B — destination / second operand
    output logic [3:0]  rd_b_sel,
    output logic [1:0]  rd_b_siz,
    input  logic [31:0] rd_b_data,

    // Register file read port C (Phase 148, plan.md) — genuine 3rd
    // simultaneous read, for MOVE Dn,(d8,An,Xn) (Phase 149; unused until
    // then — dec_c_reg/dec_reads_c below default to 0/Dn0).
    output logic [3:0]  rd_c_sel,
    output logic [1:0]  rd_c_siz,
    input  logic [31:0] rd_c_data,

    // Register file write port
    output logic        wr_en,
    output logic [3:0]  wr_sel,
    output logic [1:0]  wr_siz,
    output logic [31:0] wr_data,

    // SR / CCR update
    output logic        sr_wr_en,
    output logic [15:0] sr_wr_data,
    output logic        sr_ccr_only,
    input  logic [15:0] sr_out,

    // ALU datapath
    output logic [31:0] alu_src,
    output logic [31:0] alu_dst,
    output logic [3:0]  alu_op,
    output logic [1:0]  alu_siz,
    output logic        alu_x_in,
    output logic        alu_z_in,
    input  logic [31:0] alu_result,
    input  logic        alu_n,
    input  logic        alu_z,
    input  logic        alu_v,
    input  logic        alu_c,
    input  logic        alu_x,

    // Shifter datapath
    output logic [31:0] shf_operand,
    output logic [5:0]  shf_count,
    output logic [3:0]  shf_op,
    output logic [1:0]  shf_siz,
    output logic        shf_x_in,
    input  logic [31:0] shf_result,
    input  logic        shf_n,
    input  logic        shf_z,
    input  logic        shf_v,
    input  logic        shf_c,
    input  logic        shf_x,

    // Multiply / divide datapath
    output logic [31:0] md_src,
    output logic [31:0] md_dst,
    output logic [2:0]  md_op,
    input  logic [31:0] md_result_lo,
    input  logic [31:0] md_result_hi,
    input  logic        md_n,
    input  logic        md_z,
    input  logic        md_v,
    input  logic        md_c,
    input  logic        md_div_by_zero,

    // BCD datapath
    output logic [7:0]  bcd_src,
    output logic [7:0]  bcd_dst,
    output logic [1:0]  bcd_op,
    output logic        bcd_x_in,
    output logic        bcd_z_in,
    input  logic [7:0]  bcd_result,
    input  logic        bcd_c,
    input  logic        bcd_z,
    input  logic        bcd_v,

    // Bitops datapath
    output logic [31:0] bit_dst,
    output logic [4:0]  bit_num,
    output logic [1:0]  bit_op,
    input  logic [31:0] bit_result,
    input  logic        bit_z,

    output logic        instr_ack,    // consumed this instruction
    output logic        seq_busy,     // pipeline stall
    output logic        div_trap,     // divide-by-zero trap
    output logic        chk_trap,     // CHK/CHK2 out-of-bounds trap
    output logic        eu_need_ext,  // 10-item backlog Stage 5 (plan.md): mirrors
                                       // need_ext (eu_seq_execute.svh) -- decode
                                       // wants an extension word for the CURRENT
                                       // opcode and it isn't queued yet. Fed back
                                       // to the IFU so a speculative-prefetch BERR
                                       // can stay pending until decode genuinely
                                       // needs the faulted word, instead of firing
                                       // the instant the speculative fetch itself
                                       // fails.

    // ── Interrupt dispatch-race handshake (with m68030_exc, via m68030_eu) ──
    input  logic        int_pending,  // exc's combinational int_pending
    output logic        eu_int_ready, // pulses the one cycle a ready-to-dispatch
                                       // instruction is deliberately held in
                                       // DECODE instead of launching, so exc can
                                       // safely sample decode_pc as the not-yet-
                                       // started next instruction (see stall)

    // ── Exception-active (with m68030_exc, via m68030_eu) ───────────────────
    input  logic        exc_active,   // independent abort trigger for an
                                       // in-flight memory-op FSM: mem_ack/
                                       // mem_berr are both forced to 0 for the
                                       // EU once exc_active=1 (m68030_top's
                                       // arbiter mux), so a fault detected via
                                       // a different path (e.g. IFU) can win
                                       // the race and lock the EU out before
                                       // its own mem_berr pulse ever arrives

    // ── Branch control ──────────────────────────────────────────────────────
    input  logic [31:0] decode_pc,    // PC of instruction at decode stage
    output logic [31:0] ex_decode_pc_out, // Phase 150 Stage 1 (plan.md): PC of
                                       // whatever instruction is/was most
                                       // recently in EX -- latched from
                                       // decode_pc at the decode->EX transfer
                                       // and held (not re-latched) for the
                                       // entire time that instruction remains
                                       // in EX (ex_mem_stall's own "keep all
                                       // EX latch signals unchanged" branch,
                                       // and stall's own bubble branch, both
                                       // deliberately never touch the
                                       // internal ex_decode_pc register). The
                                       // raw decode_pc input above is WRONG
                                       // for capturing a mid-EX fault's own
                                       // address (a multi-cycle EX-stage
                                       // access lets decode legitimately race
                                       // ahead to the next instruction while
                                       // this one is still executing) --
                                       // confirmed via a Stage 1 investigation
                                       // probe (a real MMU translation fault
                                       // on MOVE.L's own data read) showing
                                       // the exception frame's own captured
                                       // PC pointing 2 bytes past the actual
                                       // faulting instruction, at whatever
                                       // instruction decode had already
                                       // reached by fault-detection time.
    output logic        branch_taken, // combinational: taken branch this cycle
    output logic [31:0] branch_target,// combinational: branch destination

    // ── Memory bus interface (to BIU via m68030_eu/m68030_top) ──────────────
    output logic        mem_req,      // request bus cycle
    output logic        mem_rw,       // 1=read, 0=write
    output logic [1:0]  mem_siz,      // transfer size (matches ex_siz)
    output logic [2:0]  mem_fc,       // function code
    output logic [31:0] mem_addr,     // effective address
    output logic [31:0] mem_wdata,    // write data (for stores)
    input  logic [31:0] mem_rdata,    // read data (from BIU)
    input  logic        mem_ack,      // bus cycle complete
    input  logic        mem_berr,     // bus error for the EU's own in-flight
                                       // access; forced to 0 once exc_active
                                       // fires (see mem_abort below, which
                                       // covers both this and the exc_active
                                       // race — do not use this raw signal
                                       // directly for FSM abort logic)
    output logic        mem_rmw,      // 1=hold bus for RMW (TAS)
    // Phase 158 Stage 3: separate from mem_rmw above (which only ever
    // covers TAS, and feeds biu_cycle_gen.sv's own bus-level "hold AS"
    // mechanism — untouched here). This is a pure D-cache lookup-forcing
    // signal, true for the entire read phase of TAS, CAS, or CAS2 (both
    // reads), consumed only by biu_cache_if.sv to force dhit=0 per manual
    // §6.1.2.2: "The read portion of a read-modify-write cycle is always
    // forced to miss in the data cache." NOTE, corrected by the open-
    // items backlog Stage 9 investigation (plan.md): this comment used
    // to claim "bus_lock is declared but never driven anywhere" — false;
    // bus_lock's own assign in biu_cycle_gen.sv has included is_cas2
    // since the initial commit, and Phase 213 gave CAS2 genuine AS
    // continuity too (cas2_as_hold) — CAS2 already has full bus-level
    // lock. Single-address CAS genuinely still lacks it (mem_rmw above
    // is TAS-only) and also skips its own write bus cycle entirely on a
    // failed compare, when real silicon performs it unconditionally
    // (MC68030UM.pdf 3.5.1/7.3.6, confirmed directly) — both real,
    // deferred gaps, with the exact blocking complexity (a register-port
    // timing mismatch in CAS's own FSM vs. the shared RMW dispatch
    // machinery) documented in plan.md §Phase 194 rather than guessed.
    output logic        mem_rmw_lookup,

    // ── FPU coprocessor interface (FC=111 CPU Space) ──────────────
    output logic        eu_coproc_req,
    output logic        eu_coproc_rw,
    output logic [1:0]  eu_coproc_siz,
    output logic [2:0]  eu_coproc_fc,
    output logic [31:0] eu_coproc_addr,
    output logic [31:0] eu_coproc_wdata,
    input  logic [31:0] eu_coproc_rdata,
    input  logic        eu_coproc_ack,
    input  logic        eu_coproc_berr,

    // ── BKPT breakpoint-acknowledge interface (FC=111 CPU Space, Phase 157 Stage 3) ──
    output logic        eu_bkpt_req,
    output logic        eu_bkpt_rw,
    output logic [1:0]  eu_bkpt_siz,
    output logic [2:0]  eu_bkpt_fc,
    output logic [31:0] eu_bkpt_addr,
    output logic [31:0] eu_bkpt_wdata,
    input  logic [31:0] eu_bkpt_rdata,
    input  logic        eu_bkpt_ack,
    input  logic        eu_bkpt_berr,
    output logic        eu_bkpt_illegal_req,  // one-cycle pulse: BERR'd BKPT -> illegal instr
    // open-items backlog Stage 13 (plan.md): live opcode substitution --
    // threaded all the way up to m68030_ifu.sv's own instr_word mux.
    output logic        eu_bkpt_subst_active,
    output logic [15:0] eu_bkpt_subst_word,

    // ── Address register update port (for (An)+ and -(An)) ──────────────────
    output logic        an_wr_en,
    output logic [2:0]  an_wr_sel,
    output logic [31:0] an_wr_data,

    // ── second Dn write port for 64-bit mul/div high result ────────
    output logic        wr2_en,
    output logic [2:0]  wr2_sel,
    output logic [31:0] wr2_data,

    // ── Control register reads (for MOVEC Rc→Rn) ─────────────────────────────
    input  logic [2:0]  sfc_in,
    input  logic [2:0]  dfc_in,
    input  logic [31:0] vbr_in,
    input  logic [31:0] usp_in,
    input  logic [31:0] isp_in,
    input  logic [31:0] msp_in,
    input  logic [31:0] cacr_in,
    input  logic [31:0] caar_in,

    // ── Control register writes (from MOVEC Rn→Rc, fired in WB stage) ────────
    output logic        vbr_wr_en,
    output logic [31:0] vbr_wr_data,
    output logic        sfc_wr_en,
    output logic [2:0]  sfc_wr_data,
    output logic        dfc_wr_en,
    output logic [2:0]  dfc_wr_data,
    output logic        cacr_wr_en,
    output logic [31:0] cacr_wr_data,
    output logic        caar_wr_en,
    output logic [31:0] caar_wr_data,
    output logic        usp_wr_en,
    output logic [31:0] usp_wr_data,
    output logic        isp_wr_en,
    output logic [31:0] isp_wr_data,
    output logic        msp_wr_en,
    output logic [31:0] msp_wr_data,

    // ── MMU instruction interface ──────────────────────────────────
    output logic        eu_pflush_req,   // asserted while PFLUSH pending MMU ack
    output logic        eu_pflush_all,   // 1=flush all (PFLUSHA), 0=selective
    output logic [2:0]  eu_pflush_fc,    // FC for selective flush
    output logic [31:0] eu_pflush_va,    // VA for selective flush
    input  logic        eu_pflush_ack,   // MMU one-cycle ack
    output logic        eu_ptest_req,    // asserted while PTEST pending MMU ack
    output logic [31:0] eu_ptest_va,     // VA to test
    output logic [2:0]  eu_ptest_fc,     // FC for PTEST
    input  logic        eu_ptest_ack,    // MMU one-cycle ack
    input  logic [15:0] eu_ptest_mmusr,  // MMUSR result (valid when ptest_ack)
    // Phase 150 Stage 5: PLOAD -- explicitly load an ATC entry for a given
    // VA/FC, performing a real (non-PTEST) walk so U/M write-back and ATC
    // installation happen exactly like an ordinary access would.
    output logic        eu_pload_req,    // asserted while PLOAD pending MMU ack
    output logic [31:0] eu_pload_va,     // VA to load
    output logic [2:0]  eu_pload_fc,     // FC for PLOAD
    output logic        eu_pload_rw,     // 1=read, 0=write access type (68030 rw convention)
    input  logic        eu_pload_ack,    // MMU one-cycle ack
    input  logic [15:0] eu_pload_mmusr,  // MMUSR result (valid when pload_ack; BIU-088)
    output logic [31:0] tc_out,          // TC register → MMU
    output logic [31:0] tt0_out,         // TT0 register → MMU
    output logic [31:0] tt1_out,         // TT1 register → MMU
    output logic [63:0] crp_out,         // CRP register → MMU
    output logic [63:0] srp_out,         // SRP register → MMU
    // OS exception/control instructions
    output logic        eu_trap_req,     // one-cycle pulse: TRAP #n firing
    output logic [3:0]  eu_trap_num,     // trap vector number (0–15)
    output logic        eu_trapv_req,    // one-cycle pulse: TRAPV fired (V was set)
    output logic        eu_illegal_req,  // one-cycle pulse: ILLEGAL instruction
    output logic        eu_stop,         // 1 while STOP state active
    output logic        eu_reset_req,    // RESET instruction — pulse RSTOUT low
    output logic        eu_priv_req,     // privilege violation → vector 8
    output logic        eu_trace_req,    // trace exception → vector 9
    output logic        eu_linea_req,    // Line-A opcode → vector 10
    output logic        eu_linef_req,    // Line-F non-FPU → vector 11
    output logic        eu_fmt_err_req,  // RTE format error → vector 14
    input  logic        exc_sr_wr_en     // from exc controller: interrupt taken, resume STOP
);

    // -----------------------------------------------------------------------
    // Unit / op constants (must match submodule localparams)
    // -----------------------------------------------------------------------
    localparam [2:0] UNIT_NONE = 3'h7,
                     UNIT_ALU  = 3'h0,
                     UNIT_SHF  = 3'h1,
                     UNIT_MUL  = 3'h2,
                     UNIT_DIV  = 3'h3,
                     UNIT_MOVE = 3'h4,
                     UNIT_BCD  = 3'h5,
                     UNIT_BIT  = 3'h6;

    localparam [1:0] BCD_ADD=2'b00, BCD_SUB=2'b01, BCD_NEG=2'b10;
    localparam [1:0] BIT_TST=2'b00, BIT_CHG=2'b01, BIT_CLR=2'b10, BIT_SET=2'b11;

    localparam [3:0] ALU_ADD=4'h0, ALU_ADDX=4'h1, ALU_SUB=4'h2, ALU_SUBX=4'h3,
                     ALU_NEG=4'h4, ALU_NEGX=4'h5, ALU_AND=4'h6, ALU_OR=4'h7,
                     ALU_EOR=4'h8, ALU_NOT=4'h9,  ALU_CMP=4'hA, ALU_TST=4'hB,
                     ALU_CLR=4'hC;

    localparam [3:0] SHF_ASL=4'h0, SHF_ASR=4'h1, SHF_LSL=4'h2, SHF_LSR=4'h3,
                     SHF_ROL=4'h4, SHF_ROR=4'h5, SHF_ROXL=4'h6, SHF_ROXR=4'h7;

    localparam [2:0] MUL_UW=3'h0, MUL_SW=3'h1, MUL_UL=3'h2, MUL_SL=3'h3,
                     DIV_UW=3'h4, DIV_SW=3'h5, DIV_UL=3'h6, DIV_SL=3'h7;

    // -----------------------------------------------------------------------
    // Pre-extract instruction word fields as assigns.
    // Avoids "sorry: constant selects in always_* processes" in Icarus 13.
    // -----------------------------------------------------------------------
    logic [3:0] f_group;   // instr_word[15:12] — primary opcode group
    logic [2:0] f_dn;      // instr_word[11:9]  — dest Dn / subop / shift ccc
    logic       f_dir;     // instr_word[8]     — direction / shift d
    logic [1:0] f_ss;      // instr_word[7:6]   — size field (00=byte,01=word,10=long)
    logic [2:0] f_mode;    // instr_word[5:3]   — EA mode
    logic [2:0] f_reg;     // instr_word[2:0]   — EA register
    logic       f_shf_i;   // instr_word[5]     — shift: 0=immediate count, 1=register
    logic [1:0] f_shf_tt;  // instr_word[4:3]   — shift type (00=AS,01=LS,10=ROX,11=RO)
    logic [1:0] f_move_sz; // MOVE size from [15:12]: 01=byte,11=word,10=long

    // See rtl/opcode_fields.sv (ext_count de-duplication plan, plan.md,
    // Stage 2) -- the shared, single-source-of-truth primitive extraction
    // m68030_seq.sv's own identical fields are also built from.
    assign f_group   = opf_group(instr_word);
    assign f_dn      = opf_dn(instr_word);
    assign f_dir     = opf_dir(instr_word);
    assign f_ss      = opf_ss(instr_word);
    assign f_mode    = opf_mode(instr_word);
    assign f_reg     = opf_reg(instr_word);
    assign f_shf_i   = instr_word[5];
    assign f_shf_tt  = instr_word[4:3];
    // MOVE size: [15:12] encodes 01=byte, 10=long, 11=word → internal: byte=01,word=10,long=00
    assign f_move_sz = (instr_word[15:12] == 4'h1) ? 2'b01 :
                       (instr_word[15:12] == 4'h3) ? 2'b10 : 2'b00;

    // Branch/Scc/DBcc condition [11:8]; byte displacement or MOVEQ immediate [7:0]
    logic [3:0] f_cond;
    logic [7:0] f_disp8;
    assign f_cond  = instr_word[11:8];
    assign f_disp8 = instr_word[7:0];

    // MOVE instruction (groups 1/2/3): dst_mode = instr_word[8:6] = {f_dir, f_ss}
    logic [2:0] f_move_dst_mode;
    assign f_move_dst_mode = {f_dir, f_ss};

    // ADDQ/SUBQ immediate: f_dn=000 → 8, else f_dn
    logic [31:0] f_addq_imm;
    assign f_addq_imm = (f_dn == 3'b000) ? 32'd8 : {29'h0, f_dn};

    // Standard size field → internal siz convention
    // f_ss: 00→byte(01), 01→word(10), 10→long(00)
    logic [1:0] f_siz;
    assign f_siz = (f_ss == 2'b00) ? 2'b01 :
                   (f_ss == 2'b01) ? 2'b10 : 2'b00;

    // TRAP #n vector number (bits [3:0] of opcode)
    logic [3:0] f_trap_num;
    assign f_trap_num = instr_word[3:0];

    // Pre-extract CCR flags to avoid bit-selects inside always_comb
    logic flag_x, flag_z, flag_n, flag_v, flag_c;
    // WB→EX SR forwarding bypass: when WB is writing SR/CCR in the same cycle that
    // EX reads flags, bypass the new value combinationally so EX sees correct SR.
    // Declarations here; assigns placed after wb_* and final_ccr are declared below.
    wire        sr_fwd_en;
    wire [15:0] sr_fwd_val;
    wire [15:0] sr_live;
    assign flag_x = sr_live[4];
    assign flag_z = sr_live[2];
    assign flag_n = sr_live[3];
    assign flag_v = sr_live[1];
    assign flag_c = sr_live[0];

    // Condition code evaluator used by Bcc/Scc/DBcc decode and EX stages.
    function automatic logic eval_cc(
        input logic [3:0] cond,
        input logic n, z, v, c
    );
        case (cond)
            4'h0: eval_cc = 1'b1;
            4'h1: eval_cc = 1'b0;
            4'h2: eval_cc = ~c & ~z;
            4'h3: eval_cc = c | z;
            4'h4: eval_cc = ~c;
            4'h5: eval_cc = c;
            4'h6: eval_cc = ~z;
            4'h7: eval_cc = z;
            4'h8: eval_cc = ~v;
            4'h9: eval_cc = v;
            4'ha: eval_cc = ~n;
            4'hb: eval_cc = n;
            4'hc: eval_cc = ~(n ^ v);
            4'hd: eval_cc = n ^ v;
            4'he: eval_cc = ~z & ~(n ^ v);
            4'hf: eval_cc = z | (n ^ v);
            default: eval_cc = 1'b0;
        endcase
    endfunction

    // Step size for (An)+ and -(An): longword=4, word=2, byte=1 (A7→2)
    function automatic [31:0] calc_step(
        input logic [1:0] siz,
        input logic       is_a7
    );
        case (siz)
            2'b00:   calc_step = 32'd4;
            2'b10:   calc_step = 32'd2;
            default: calc_step = is_a7 ? 32'd2 : 32'd1;
        endcase
    endfunction

    // Shift data to the correct EU bus lane: byte→[31:24], word→[31:16], long→[31:0].
    // Matches the convention expected by biu_byte_lane_ctrl on the write side.
    function automatic logic [31:0] eu_lane(
        input logic [31:0] d,
        input logic [1:0]  siz
    );
        case (siz)
            2'b01:   eu_lane = {d[7:0],  24'h0};
            2'b10:   eu_lane = {d[15:0], 16'h0};
            default: eu_lane = d;
        endcase
    endfunction

    // ALU base op (SUB or ADD) and extend op (SUBX or ADDX) for Groups 9/D.
    function automatic [3:0] grp_aop(input logic [3:0] grp);
        return (grp == 4'h9) ? ALU_SUB : ALU_ADD;
    endfunction
    function automatic [3:0] grp_xop(input logic [3:0] grp);
        return (grp == 4'h9) ? ALU_SUBX : ALU_ADDX;
    endfunction

    // Sets dec_an_upd_* and dec_ea_offset for (An)+ and -(An) EA modes.
    task setup_mem_incdec(
        input  logic [1:0]  siz,
        inout  logic        en,
        inout  logic [2:0]  areg,
        inout  logic [31:0] adelta,
        inout  logic [31:0] eaoff
    );
        case (f_mode)
            3'b011: begin
                en     = 1'b1;
                areg   = f_reg;
                adelta = calc_step(siz, f_reg == 3'b111);
            end
            3'b100: begin
                en     = 1'b1;
                areg   = f_reg;
                adelta = ~calc_step(siz, f_reg == 3'b111) + 32'h1;
                eaoff  = adelta;
            end
            default: ;
        endcase
    endtask

    // Pre-extract bit-selects used by BCD and bitops to avoid Icarus issues
    logic [7:0] rd_a_byte, rd_b_byte;
    logic [4:0] rd_a_bit_num;
    logic [4:0] ext_bit_num;
    assign rd_a_byte    = rd_a_data[7:0];
    assign rd_b_byte    = rd_b_data[7:0];
    assign rd_a_bit_num = rd_a_data[4:0];
    assign ext_bit_num  = ext_data[4:0];

    // MMU instruction second-word field pre-extractions from ext_data[15:0]
    logic [2:0]  mmu_op_type;    assign mmu_op_type    = ext_data[15:13]; // 001=PFLUSH,010=PMOVE,011=PLOAD(Stage 5),100=PTEST
    logic [2:0]  mmu_sub_mode;   assign mmu_sub_mode   = ext_data[11:9];  // flush mode / PMOVE preg
    logic        mmu_dr;         assign mmu_dr         = ext_data[8];     // PMOVE direction
    logic [1:0]  mmu_fc_mode;    assign mmu_fc_mode    = ext_data[4:3];   // FC selection (PFLUSH)
    logic [2:0]  mmu_fc_val;     assign mmu_fc_val     = ext_data[2:0];   // FC value (PFLUSH imm)
    logic [1:0]  mmu_pt_fc_mode; assign mmu_pt_fc_mode = ext_data[3:2];   // FC mode (PTEST)
    logic [1:0]  mmu_pt_fc_val;  assign mmu_pt_fc_val  = ext_data[1:0];   // FC value (PTEST imm)

    // full extension word field extractions from ext_data[15:0] = ext0
    // (ext_data[15:0] is the first extension word; ext_data[31:16] is the second.)
    // eaf_is_full/eaf_bdsz/eaf_iis: shared with m68030_seq.sv's own
    // peek_fi_*/peek_fi_*_movem/peek_fi_*_q3 (rtl/opcode_fields.sv,
    // ext_count de-duplication plan Stage 3, plan.md) -- previously these
    // exact bit positions (8/[5:4]/[2:0]) were hand-copied 4 separate times
    // across the two files.
    logic        fi_is_full;  assign fi_is_full = eaf_is_full(ext_data[15:0]); // 0=brief, 1=full
    logic        fi_bs;       assign fi_bs      = ext_data[7];       // base suppress
    logic        fi_is_s;     assign fi_is_s    = ext_data[6];       // index suppress
    logic [1:0]  fi_bdsz;     assign fi_bdsz    = eaf_bdsz(ext_data[15:0]); // bd size: 01=null,10=word,11=long
    logic [2:0]  fi_iis;      assign fi_iis     = eaf_iis(ext_data[15:0]);  // I/IS: 000=none, 001-011=indirect
    // base displacement: word in ext_data[31:16] when fi_bdsz==10 (word);
    // long (fi_bdsz==11) needs a second word -- ext_data[31:16] is already
    // the high half (m68030_seq.sv's memind-specific q1/q2 swap puts the
    // descriptor in the low half and the word right after it in the high
    // half), so the low half of a long bd is one word further out, at
    // q3_word (Phase 121, plan.md) -- the same word MOVEM's own bd
    // (Phase 119) and abs.L reconstruction already reuse for an analogous
    // "one word further out" need. Only the *non-indirect* case
    // (fi_iis==000) is correctly served this way for every family that
    // already reads fi_bd via the `fi_is_full ? fi_bd : ...` template
    // (Stages 1-3) -- this single definition change propagates to all of
    // them automatically, no per-site changes needed. Genuine indirect
    // combined with a long bd needs q3 for bd's own low half *and* another
    // word (q4 or q5, depending on od's own size) for od -- fi_od below
    // handles every bd/od size combination correctly as of Phase 146
    // (plan.md), including long bd + long od together (the last
    // previously-unsupported combination, unlocked by Phase 145's own q5
    // plumbing).
    logic [31:0] fi_bd;       assign fi_bd      = (fi_bdsz == 2'b10) ? {{16{ext_data[31]}}, ext_data[31:16]}
                                                 : (fi_bdsz == 2'b11) ? {ext_data[31:16], q3_word}
                                                 : 32'h0;
    // outer displacement: word- OR long-size od (Phase 146 adds long od;
    // word od unchanged from Phase 140), for both pre- (fi_iis=0xx) and
    // post-indexed (fi_iis=1xx) -- fi_iis[1:0] alone (ignoring bit 2, the
    // pre/post selector) already fully encodes od's own size in the
    // standard 68020 I/IS field: 00=null, 10=word, 11=long (01=reserved).
    // Position depends on how many words bd itself already consumed after
    // the descriptor (ext_data[31:16]=q2, via m68030_seq.sv's memind-
    // specific q1/q2 swap): null bd (01) consumes 0 words, word bd (10)
    // consumes 1 (q2), long bd (11) consumes 2 (q2 high half, q3 low
    // half) -- od's own word(s) always start immediately after wherever
    // bd's own words end. Originally missing the post-indexed case (and
    // the word-bd-and-word-od combination) entirely -- found via
    // tests/memind2.s's own Musashi-cosim run (plan.md Phase 107/115).
    // The long-bd+word-od combination was ALSO wrong until Phase 140: the
    // old code's else-branch fired for both null and long bd identically,
    // reading ext_data[31:16] (q2) in either case -- for long bd that slot
    // is bd's OWN high half (already consumed by fi_bd), so od silently
    // aliased onto it instead of reading its real value at q4. Genuine
    // indirect combined with LONG od (needing a 5th extension word, q5,
    // stacked on top of whatever bd itself consumed) was unsupported until
    // Phase 146 (plan.md) -- q5 is now wired (Phase 145) and
    // m68030_seq.sv's own memind_od_words/memind_ext_count already sized
    // this correctly beforehand (verified by reading the formula directly
    // before writing this: memind_od_words already returns 2 for long od,
    // giving memind_ext_count=1+2+2=5 for the long-bd+long-od case, i.e.
    // opcode+5=6 total words -- exactly the new q5-gated ext_count>=5
    // tier Phase 145 itself added to eu_ext_valid) -- so this phase is
    // purely the missing VALUE extraction, no sizing change needed.
    logic [31:0] fi_od;       assign fi_od      =
        (fi_iis[1:0] == 2'b00) ? 32'h0                                    // null od
      : (fi_iis[1:0] == 2'b10)                                            // word od
        ? ((fi_bdsz == 2'b10) ? {{16{q3_word[15]}}, q3_word}              //   word bd: od@q3
         : (fi_bdsz == 2'b11) ? {{16{ext34_data[15]}}, ext34_data[15:0]}  //   long bd: od@q4
                               : {{16{ext_data[31]}}, ext_data[31:16]})   //   null bd: od@q2
      : (fi_iis[1:0] == 2'b11)                                            // long od (Phase 146)
        ? ((fi_bdsz == 2'b10) ? {q3_word, ext34_data[15:0]}               //   word bd: od_hi@q3,od_lo@q4
         : (fi_bdsz == 2'b11) ? {ext34_data[15:0], q5_word}               //   long bd: od_hi@q4,od_lo@q5
                               : {ext_data[31:16], q3_word})              //   null bd: od_hi@q2,od_lo@q3
      : 32'h0;                                                            // reserved (01)


    // -----------------------------------------------------------------------
    // Module body continues via `` `include `` -- split for navigability, not
    // behavior. Both files are pure text substituted back in at exactly this
    // point (same mechanism as tb/common_helpers.svh /
    // tb/ext_count_overlap_flags.svh); see each file's own header for detail.
    // The full module used to be one 11,001-line file; this spine
    // (rtl/eu_seq.sv itself) keeps only the port list, local parameters,
    // pre-extracted instruction-field assigns, and shared helper
    // functions/tasks that both included files depend on.
    // -----------------------------------------------------------------------
`include "eu_seq_decode.svh"
`include "eu_seq_execute.svh"

    // 10-item backlog Stage 5 (plan.md): need_ext itself is declared inside
    // eu_seq_execute.svh, only in scope from this point on -- assign the
    // output port here rather than at the port declaration.
    assign eu_need_ext = need_ext;

endmodule

`default_nettype wire
