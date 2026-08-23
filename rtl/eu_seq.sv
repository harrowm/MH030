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
    // forced to miss in the data cache." NOTE (found while implementing,
    // documented, out of scope): CAS/CAS2 have no real bus-level lock at
    // all today (bus_lock is declared but never driven anywhere; mem_rmw
    // above only ever fires for TAS) — a separate, deeper gap from this
    // stage's own cache-behavior scope, not fixed here.
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

    assign f_group   = instr_word[15:12];
    assign f_dn      = instr_word[11:9];
    assign f_dir     = instr_word[8];
    assign f_ss      = instr_word[7:6];
    assign f_mode    = instr_word[5:3];
    assign f_reg     = instr_word[2:0];
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
    logic        fi_is_full;  assign fi_is_full = ext_data[8];       // 0=brief, 1=full
    logic        fi_bs;       assign fi_bs      = ext_data[7];       // base suppress
    logic        fi_is_s;     assign fi_is_s    = ext_data[6];       // index suppress
    logic [1:0]  fi_bdsz;     assign fi_bdsz    = ext_data[5:4];     // bd size: 01=null,10=word,11=long
    logic [2:0]  fi_iis;      assign fi_iis     = ext_data[2:0];     // I/IS: 000=none, 001-011=indirect
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

    // bit-field instructions (BFTST/BFEXTU/BFEXTS/BFFFO/BFCLR/BFSET/BFINS)
    logic        dec_is_bf;        // bit-field instruction
    logic [2:0]  dec_bf_op;        // {f_dn[1:0], f_dir}: 000=TST 001=EXTU 010=EXTS 011=FFO 100=CLR 110=SET 111=INS
    logic        dec_bf_reg_ea;    // 1=register EA (Dn), 0=memory EA ((An))
    logic        dec_bf_mutates;   // 1=CLR/SET/INS (modifies field in place)

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
                            // MOVE (d8,An_src,Xn), (indirect_dst): indexed source, indirect dst.
                            // ext_count depends on dst: 1 for modes 2/3/4, 2 for mode 5 (d16).
                            // eu_ext_data layout: ext_count=1→{16'h0,brief}, ext_count=2→{brief,d16}.
                            // brief_ext: in ext_data[15:0] when dst modes 2/3/4 (no dst ext word);
                            //            in ext_data[31:16] when dst mode 5 (d16 in ext_data[15:0]).
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
                                // dst = (d16,An): ext_count=2, brief in [31:16], d16 in [15:0]
                                dec_dst_reg   = {ext_data[31], ext_data[30:28]}; // src_Xn → rd_b
                                dec_xn_wl     = ext_data[27];
                                dec_xn_scale  = ext_data[26:25];
                                dec_ea_offset = {{24{ext_data[23]}}, ext_data[23:16]};  // d8_src
                                dec_dst_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                            end else begin
                                // dst = (An)/(An)+/-(An): ext_count=1, brief in [15:0]
                                dec_dst_reg   = {ext_data[15], ext_data[14:12]}; // src_Xn → rd_b
                                dec_xn_wl     = ext_data[11];
                                dec_xn_scale  = ext_data[10:9];
                                dec_ea_offset = {{24{ext_data[7]}}, ext_data[7:0]};  // d8_src
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
                            // analogous "one word further out" need. Long bd stays
                            // unsupported for (d16,An)-src specifically (would need a
                            // genuine q4 on top of its already-2-word baseline -- q4
                            // itself exists but isn't wired for this sub-case, out of
                            // scope this phase); word bd is the value this phase adds.
                            dec_dst_ea_offset      = (f_mode == 3'b101)
                                                   ? ((ext_data[8] && ext_data[5:4] == 2'b10 && ext_data[2:0] == 3'b000)
                                                      ? {{16{q3_word[15]}}, q3_word}
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
                                        dec_md_op    = ext_data[6] ? MUL_SL : MUL_UL;
                                        dec_md_64bit = ext_data[10];
                                    end else if (f_ss == 2'b01) begin
                                        // DIVU.L / DIVS.L
                                        dec_valid    = 1'b1;
                                        dec_unit     = UNIT_DIV;
                                        dec_md_op    = ext_data[6] ? DIV_SL : DIV_UL;
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
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd extension,
                            // same template as Stage 1/2.
                            dec_ea_offset  = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext  = 1'b1;
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
                            dec_is_jsr_idx  = 1'b1;
                            dec_is_mem_wr   = 1'b1;
                            dec_src_reg     = {1'b1, f_reg};                    // An → rd_a
                            dec_dst_reg     = {ext_data[15], ext_data[14:12]};  // Xn → rd_b
                            dec_reads_src   = 1'b1;
                            dec_reads_dst   = 1'b1;
                            dec_siz         = 2'b00;
                            dec_is_idx      = 1'b1;
                            dec_xn_wl       = ext_data[11];
                            dec_xn_scale    = ext_data[10:9];
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                            dec_jump_offset = fi_is_full ? fi_bd
                                            : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_return_pc   = decode_pc + 32'd4;
                            dec_an_upd_en   = 1'b1;
                            dec_an_upd_reg  = 3'b111;
                            dec_an_delta    = 32'hFFFF_FFFC;
                            dec_needs_ext   = 1'b1;
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
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                            dec_jump_offset = fi_is_full ? fi_bd
                                            : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext   = 1'b1;
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
                            dec_is_pea_idx  = 1'b1;
                            dec_is_idx      = 1'b1;
                            dec_xn_wl       = ext_data[11];
                            dec_xn_scale    = ext_data[10:9];
                            // Stage 3 (plan.md Phase 118): fi_is_full/fi_bd.
                            dec_jump_offset = fi_is_full ? fi_bd
                                            : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext   = 1'b1;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        dec_md_op          = f_dir ? DIV_SW : DIV_UW;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
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
                            // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                            // same template as Stage 1 -- see TAS's own comment in the
                            // mode=110 unary-op family for the full reasoning.
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;  // An_dst (addr reg) read after mem_ack
                            dec_dyn_bit_is_an  = 1'b1;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
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
                            // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                            // same template as Stage 1 -- see TAS's own comment in the
                            // mode=110 unary-op family for the full reasoning.
                            dec_ea_offset      = fi_is_full ? fi_bd
                                               : {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_is_dyn_bit_idx = 1'b1;
                            dec_dyn_bit_reg    = f_dn;  // An (addr reg) read after mem_ack
                            dec_dyn_bit_is_an  = 1'b1;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
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
                        // Stage 2 (plan.md Phase 116/117): fi_is_full/fi_bd extension,
                        // same template as Stage 1 -- see TAS's own comment in the
                        // mode=110 unary-op family for the full reasoning.
                        dec_ea_offset      = fi_is_full ? fi_bd
                                           : {{24{ext_data[7]}}, ext_data[7:0]};
                        dec_is_dyn_bit_idx = 1'b1;
                        dec_dyn_bit_reg    = f_dn;
                        dec_md_op          = f_dir ? MUL_SW : MUL_UW;
                        dec_mem_rd_siz     = 2'b10;  // word read despite longword result
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
                    // BFTST=1000 BFEXTU=1001 BFEXTS=1010 BFFFO=1011
                    // BFCLR=1100 BFSET=1110  BFINS=1111 (bits 11:8 of opcode)
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
                        dec_bf_mutates = (f_dn[1:0] == 2'b10 || f_dn[1:0] == 2'b11);
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
                                3'b000: dec_updates_ccr = 1'b1;
                                3'b001, 3'b010, 3'b011: begin  // BFEXTU/BFEXTS/BFFFO
                                    dec_writes_reg  = 1'b1;
                                    dec_dest_reg    = {1'b0, bf_spec_w[14:12]};
                                    dec_updates_ccr = 1'b1;
                                end
                                default: begin  // BFCLR/BFSET/BFINS: write back to Dn
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
                        // ordinary EA). Stub scope (Phase 157 Stage 4): issues one
                        // CIR read to the Save CIR; does not implement the real
                        // format-word-driven multi-longword transfer protocol --
                        // same "one CPI cycle, full protocol later" scope as the
                        // existing FPU stub (Phase 55).
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid     = 1'b1;
                            dec_is_cpsave = 1'b1;
                            dec_unit      = UNIT_NONE;
                            dec_needs_ext = (f_mode == 3'b101 || f_mode == 3'b110 ||
                                             f_mode == 3'b111);
                        end
                    end else if (f_dn == 3'b001 && {f_dir, f_ss} == 3'b101) begin
                        // cpRESTORE: cpid=1, TYPE=101 (manual Figure 10-17). Same
                        // privilege check and stub scope as cpSAVE above.
                        if (!sr_live[13]) begin
                            dec_valid   = 1'b1;
                            dec_is_priv = 1'b1;
                        end else begin
                            dec_valid        = 1'b1;
                            dec_is_cprestore = 1'b1;
                            dec_unit         = UNIT_NONE;
                            dec_needs_ext    = (f_mode == 3'b101 || f_mode == 3'b110 ||
                                                f_mode == 3'b111);
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

    // cpSAVE/cpRESTORE dispatch FSM (Phase 157 Stage 4) — declared early for ex_mem_stall
    logic        cpsr_start_r;     // one-cycle setup after instr_ack
    logic        cpsr_run_r;       // eu_coproc_req active, waiting for ack (shared w/ FPU)
    logic        cpsr_is_restore_r; // 0=cpSAVE (Save CIR), 1=cpRESTORE (Restore CIR)
    logic [15:0] cpsr_fmt_r;       // captured format word (not acted upon -- stub scope)

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
                          bkpt_start_r || bkpt_run_r ||
                          cpsr_start_r || cpsr_run_r ||
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
    // race against) and eu_trace_req (already separately gated on
    // !ex_mem_stall and, being genuinely post-instruction-retirement by
    // design, is a different hazard shape not reproduced here -- left for
    // a dedicated follow-up rather than bundled in speculatively).
    // BKPT's BERR outcome (Phase 157 Stage 3) is decided later than decode
    // time -- only once eu_bkpt_berr arrives, mid-FSM -- same shape as
    // chk_trap/div_trap immediately below, not the plain ex_is_illegal
    // decode-time case. Per the manual (Section 7.4.2): a BERR'd
    // breakpoint-acknowledge cycle takes an illegal instruction exception.
    wire bkpt_trap_w = bkpt_run_r && eu_bkpt_berr;
    assign eu_bkpt_illegal_req = bkpt_trap_w;

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
        end else if (ex_mem_stall) begin
            // EX holds waiting for BIU ack — keep all EX latch signals unchanged.
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
    // for JSR/PEA indexed, A7 update uses ex_cur_sp (rd_b holds Xn, not A7)
    assign ex_an_new = (ex_is_jsr_idx || ex_is_pea_idx) ? (ex_cur_sp + ex_an_delta)
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
    // cpSAVE/cpRESTORE dispatch FSM (Phase 157 Stage 4)
    // Shares eu_coproc_req/ack/berr with the FPU FSM above -- at most one
    // EU-issued CPU-space cycle is ever in flight, since only one instruction
    // occupies EX at a time. Issues one CIR read (Save CIR=0x04, Restore
    // CIR=0x06 per Figure 10-5) and completes -- does not implement the real
    // format-word-driven multi-longword transfer protocol (same stub scope
    // as the FPU FSM's own "one CPI cycle" comment above).
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cpsr_start_r      <= 1'b0;
            cpsr_run_r        <= 1'b0;
            cpsr_is_restore_r <= 1'b0;
            cpsr_fmt_r        <= 16'h0;
        end else begin
            if (!cpsr_start_r && !cpsr_run_r && instr_ack &&
                (dec_is_cpsave || dec_is_cprestore)) begin
                cpsr_start_r      <= 1'b1;
                cpsr_is_restore_r <= dec_is_cprestore;
            end else if (cpsr_start_r) begin
                cpsr_start_r <= 1'b0;
                cpsr_run_r   <= 1'b1;
            end else if (cpsr_run_r && eu_coproc_ack) begin
                cpsr_run_r <= 1'b0;
                // Format word, not acted upon -- stub scope (see header comment).
                cpsr_fmt_r <= eu_coproc_rdata[31:16];
            end else if (cpsr_run_r && eu_coproc_berr) begin
                cpsr_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // BKPT breakpoint-acknowledge dispatch FSM (Phase 157 Stage 3)
    // On instr_ack of a BKPT instruction, issue one CPU-space read via
    // eu_bkpt_req -- address per manual Figure 7-42 (type field 0, breakpoint
    // number on A[4:2]). Two outcomes (Section 7.4.2):
    //   DSACK'd/STERM'd: data word is a replacement opcode, captured here.
    //   Real live re-decode/substitution of that word into the pipeline is
    //   NOT implemented -- instr_word is a plain combinational alias of the
    //   IFU's own prefetch-queue head (m68030_ifu.sv) with no override mux
    //   anywhere, and correctly interacting with the IFU's own ext_count/
    //   drain logic for whatever the replacement opcode turns out to need
    //   is a substantial separate undertaking (confirmed via direct
    //   investigation before implementing this stage). This mirrors the
    //   FPU coprocessor stub's own scope boundary (Phase 55: "issues one
    //   CPI CPU Space bus cycle; full protocol in later phases") --
    //   bkpt_replacement_r proves the bus protocol/data-lane extraction are
    //   correct; PC simply advances past BKPT normally, same as any other
    //   1-word instruction.
    //   BERR'd: illegal instruction exception (bkpt_trap_w above).
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            bkpt_start_r       <= 1'b0;
            bkpt_run_r         <= 1'b0;
            bkpt_num_r         <= 3'h0;
            bkpt_replacement_r <= 16'h0;
        end else begin
            if (!bkpt_start_r && !bkpt_run_r && instr_ack && dec_is_bkpt) begin
                bkpt_start_r <= 1'b1;
                bkpt_num_r   <= f_reg;   // breakpoint number, opcode bits [2:0]
            end else if (bkpt_start_r) begin
                bkpt_start_r <= 1'b0;
                bkpt_run_r   <= 1'b1;
            end else if (bkpt_run_r && eu_bkpt_ack) begin
                bkpt_run_r         <= 1'b0;
                bkpt_replacement_r <= eu_bkpt_rdata[31:16]; // word-aligned read: word lands top-justified
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
        end else if (!memind_start_r && !memind_inner_r && !memind_outer_r
                     && instr_ack && dec_is_memind) begin
            memind_start_r <= 1'b1;
            memind_is_rd_r <= 1'b1;   // memind only supports load ops
            memind_siz_r   <= dec_siz;
            memind_dest_r  <= dec_dest_reg;
            memind_od_r    <= dec_memind_od;
        end else if (memind_start_r) begin
            // EX holds: rd_a=An (ex_ea = inner addr), rd_b=Xn (for post-indexed outer)
            memind_start_r      <= 1'b0;
            memind_inner_r      <= 1'b1;
            memind_inner_addr_r <= ex_ea;
            // Capture Xn*SCALE for post-indexed outer EA (0 if pre-indexed)
            memind_post_xn_r    <= (ex_is_memind && ex_memind_is_post) ? memind_xn_sc_w : 32'h0;
        end else if (memind_inner_r && mem_ack) begin
            memind_inner_r <= 1'b0;
            memind_outer_r <= 1'b1;
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
        end else if (ex_mem_stall || ex_berr_abort_wb) begin
            // Memory cycle in progress (or just aborted by a berr the
            // previous cycle — see ex_berr_abort_wb above): drain WB
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
            wb_an_upd_en     <= ex_an_upd_en && !ex_is_mem_rmw;
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
    assign wr_en   = movem_wr_en || movep_wr_en || memind_wr_en || bf_dn_wr_en ||
                    (wb_valid && wb_writes_reg);
    assign wr_sel  = movem_wr_en  ? movem_reg_sel
                   : movep_wr_en  ? movep_wr_sel
                   : memind_wr_en ? memind_dest_r
                   : bf_dn_wr_en  ? {1'b0, bf_mem_dn_r}
                   :                wb_dest_reg;
    assign wr_siz  = movem_wr_en  ? 2'b00
                   : movep_wr_en  ? (movep_long_r ? 2'b00 : 2'b10)
                   : memind_wr_en ? memind_siz_r
                   : bf_dn_wr_en  ? 2'b00
                   :                wb_siz;
    assign wr_data = movem_wr_en  ? movem_wr_data
                   : movep_wr_en  ? movep_wr_data
                   : memind_wr_en ? mem_rdata
                   : bf_dn_wr_en  ? bf_result_w
                   :                wb_result_final;

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
                       mem_rmw_an_wr_en || move_mm_dst_an_wr_en ||
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
    assign div_trap = (ex_valid && (ex_unit == UNIT_DIV) && !ex_is_mem_src && md_div_by_zero)
                    || (ex_valid && (ex_unit == UNIT_DIV) && ex_is_mem_src && mem_ack && md_div_by_zero);
    // CHK: trap on reg/imm comparison, memory-source ack, or CHK2 second-read ack.
    assign chk_trap = (ex_valid && ex_is_chk && !ex_is_mem_rd && (chk_below_w || chk_above_w))
                   || (ex_valid && ex_is_chk && ex_is_mem_rd && mem_ack &&
                       (chk_mem_below_w || chk_mem_above_w))
                   || (cmp2_run_r && mem_ack && cmp2_is_chk2_r && cmp2_c_w);

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
    assign ex_jmp_taken = ex_valid && ex_is_jmp;
    assign ex_jsr_taken = ex_valid && ex_is_jsr && mem_ack;
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
    assign eu_fmt_err_req = ex_valid && ex_is_rte && !rte_phase_r && mem_ack &&
                            !rte_fmt_valid(mem_rdata[31:28]);

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
                       memind_outer_r ? memind_outer_addr_w :
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
    // or cpsr_run_r (Phase 157 Stage 4: cpSAVE/cpRESTORE, one CIR read) --
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
    // -----------------------------------------------------------------------
    assign eu_coproc_req   = fpu_run_r || cpsr_run_r;
    assign eu_coproc_rw    = 1'b1;
    assign eu_coproc_fc    = 3'b111;        // CPU Space
    assign eu_coproc_siz   = 2'b00;         // longword
    assign eu_coproc_wdata = 32'h0;
    assign eu_coproc_addr  = cpsr_run_r
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
    assign eu_trace_req = ex_valid && ex_is_trace && !ex_mem_stall;

endmodule

`default_nettype wire
