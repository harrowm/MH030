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

    // Register file read port A — source operand
    output logic [3:0]  rd_a_sel,
    output logic [1:0]  rd_a_siz,
    input  logic [31:0] rd_a_data,

    // Register file read port B — destination / second operand
    output logic [3:0]  rd_b_sel,
    output logic [1:0]  rd_b_siz,
    input  logic [31:0] rd_b_data,

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

    // ── Branch control ──────────────────────────────────────────────────────
    input  logic [31:0] decode_pc,    // PC of instruction at decode stage
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
    input  logic        mem_berr,     // bus error (ignored in Phase 37)
    output logic        mem_rmw,      // 1=hold bus for RMW (TAS)

    // ── Phase 52: FPU coprocessor interface (FC=111 CPU Space) ──────────────
    output logic        eu_coproc_req,
    output logic        eu_coproc_rw,
    output logic [1:0]  eu_coproc_siz,
    output logic [2:0]  eu_coproc_fc,
    output logic [31:0] eu_coproc_addr,
    output logic [31:0] eu_coproc_wdata,
    input  logic [31:0] eu_coproc_rdata,
    input  logic        eu_coproc_ack,
    input  logic        eu_coproc_berr,

    // ── Address register update port (for (An)+ and -(An)) ──────────────────
    output logic        an_wr_en,
    output logic [2:0]  an_wr_sel,
    output logic [31:0] an_wr_data,

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

    // ── Phase 54: MMU instruction interface ──────────────────────────────────
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
    output logic [31:0] tc_out,          // TC register → MMU
    output logic [31:0] tt0_out,         // TT0 register → MMU
    output logic [31:0] tt1_out          // TT1 register → MMU
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
                     DIV_UW=3'h4, DIV_SW=3'h5;

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

    // Pre-extract CCR flags to avoid bit-selects inside always_comb
    logic flag_x, flag_z, flag_n, flag_v, flag_c;
    assign flag_x = sr_out[4];
    assign flag_z = sr_out[2];
    assign flag_n = sr_out[3];
    assign flag_v = sr_out[1];
    assign flag_c = sr_out[0];

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

    // Pre-extract bit-selects used by BCD and bitops to avoid Icarus issues
    logic [7:0] rd_a_byte, rd_b_byte;
    logic [4:0] rd_a_bit_num;
    logic [4:0] ext_bit_num;
    assign rd_a_byte    = rd_a_data[7:0];
    assign rd_b_byte    = rd_b_data[7:0];
    assign rd_a_bit_num = rd_a_data[4:0];
    assign ext_bit_num  = ext_data[4:0];

    // Phase 54: MMU instruction second-word field pre-extractions from ext_data[15:0]
    logic [2:0]  mmu_op_type;    assign mmu_op_type    = ext_data[15:13]; // 001=PFLUSH,100=PTEST,010=PMOVE
    logic [2:0]  mmu_sub_mode;   assign mmu_sub_mode   = ext_data[11:9];  // flush mode / PMOVE preg
    logic        mmu_dr;         assign mmu_dr         = ext_data[8];     // PMOVE direction
    logic [1:0]  mmu_fc_mode;    assign mmu_fc_mode    = ext_data[4:3];   // FC selection (PFLUSH)
    logic [2:0]  mmu_fc_val;     assign mmu_fc_val     = ext_data[2:0];   // FC value (PFLUSH imm)
    logic [1:0]  mmu_pt_fc_mode; assign mmu_pt_fc_mode = ext_data[3:2];   // FC mode (PTEST)
    logic [1:0]  mmu_pt_fc_val;  assign mmu_pt_fc_val  = ext_data[1:0];   // FC value (PTEST imm)

    // Phase 53: full extension word field extractions from ext_data[15:0] = ext0
    // (ext_data[15:0] is the first extension word; ext_data[31:16] is the second.)
    logic        fi_is_full;  assign fi_is_full = ext_data[8];       // 0=brief, 1=full
    logic        fi_bs;       assign fi_bs      = ext_data[7];       // base suppress
    logic        fi_is_s;     assign fi_is_s    = ext_data[6];       // index suppress
    logic [1:0]  fi_bdsz;     assign fi_bdsz    = ext_data[5:4];     // bd size: 01=null,10=word,11=long
    logic [2:0]  fi_iis;      assign fi_iis     = ext_data[2:0];     // I/IS: 000=none, 001-011=indirect
    // base displacement: word in ext_data[31:16] when fi_bdsz==10; else 0
    logic [31:0] fi_bd;       assign fi_bd      = (fi_bdsz == 2'b10) ? {{16{ext_data[31]}}, ext_data[31:16]} : 32'h0;
    // outer displacement: word in ext_data[31:16] only when fi_bdsz==01 (null bd) and fi_iis==010
    logic [31:0] fi_od;       assign fi_od      = (fi_iis == 3'b010 && fi_bdsz == 2'b01)
                                                   ? {{16{ext_data[31]}}, ext_data[31:16]} : 32'h0;

    // -----------------------------------------------------------------------
    // DECODE stage — purely combinational
    // All instr_word bit-selects replaced with pre-extracted signals.
    // -----------------------------------------------------------------------
    logic        dec_valid, dec_writes_reg, dec_updates_ccr;
    logic        dec_x_unchanged, dec_use_imm, dec_use_reg_cnt, dec_needs_ext;
    logic        dec_reads_src, dec_reads_dst;
    logic [2:0]  dec_unit;
    logic [3:0]  dec_alu_op, dec_shf_op;
    logic [2:0]  dec_md_op;
    logic [3:0]  dec_src_reg;   // rd_a: source operand register
    logic [3:0]  dec_dst_reg;   // rd_b: destination/second-operand register
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
    // Phase 38: subroutine / jump instructions
    logic        dec_is_jmp;      // JMP ea
    logic        dec_is_jsr;      // JSR ea (push return PC then jump)
    logic        dec_is_bsr;      // BSR disp (push return PC then relative branch)
    logic        dec_is_rts;      // RTS (pop PC from stack)
    logic        dec_is_rtr;      // RTR (pop CCR+PC from stack; 2 reads)
    logic        dec_is_link;     // LINK An, #d16
    logic        dec_is_unlk;     // UNLK An
    // Phase 40: absolute EA
    logic        dec_abs_ea_en;   // EA is absolute (overrides An+offset for bus cycle)
    logic        dec_abs_jmp_en;  // branch target is absolute (for JMP/JSR abs; separate from EA)
    logic [31:0] dec_abs_ea_val;  // pre-computed absolute address (shared by both flags)
    logic [31:0] dec_return_pc;   // return address pushed by JSR/BSR
    logic [31:0] dec_bsr_target;  // pre-computed BSR target = decode_pc+2+disp
    logic [31:0] dec_jump_offset; // JMP/JSR target offset (0 for (An), d16 for (d16,An))
    // Phase 41: brief indexed EA (d8,An,Xn)
    logic        dec_is_idx;     // brief indexed EA mode active
    logic        dec_xn_wl;     // Xn size: 0=word(sign-ext to 32), 1=longword
    logic [1:0]  dec_xn_scale;  // Xn scale: 00=×1, 01=×2, 10=×4, 11=×8
    // Phase 43: MOVEM register save/restore
    logic        dec_is_movem;      // MOVEM instruction
    logic        dec_movem_load;    // 1=mem→reg (load), 0=reg→mem (store)
    logic        dec_movem_predec;  // 1=-(An) predecrement mode (store only)
    logic        dec_movem_postinc; // 1=(An)+ post-increment mode (load only)
    logic        dec_movem_long;    // 1=longword (f_ss[0]), 0=word
    // Phase 46: MOVEC / MOVES
    logic        dec_is_movec;      // MOVEC instruction (Rn→Rc direction only; Rc→Rn uses dec_use_imm)
    logic        dec_movec_to_ctrl; // 1=Rn→Rc (write to ctrl reg)
    logic        dec_is_moves;      // MOVES instruction
    logic        dec_moves_load;    // 1=load (ea→Rn, SFC), 0=store (Rn→ea, DFC)
    // Phase 47: TAS
    logic        dec_is_tas;        // TAS.B instruction (test and set byte)
    // Phase 48: CHK, CMP2, CHK2
    logic        dec_is_chk;        // CHK <ea>,Dn
    logic        dec_chk_word;      // 1=CHK.W (size word), 0=CHK.L (size long)
    logic        dec_is_cmp2chk2;   // CMP2 or CHK2 two-bound compare
    // Phase 49: MOVEP
    logic        dec_is_movep;      // MOVEP instruction
    logic        dec_movep_load;    // 1=mem→Dn (load), 0=Dn→mem (store)
    logic        dec_movep_long;    // 1=longword (4 bytes), 0=word (2 bytes)
    // Phase 50: MOVE16
    logic        dec_is_move16;     // MOVE16 instruction
    logic [1:0]  dec_move16_form;   // 00=(An)+/(Am)+, 01=(An)+/abs, 10=abs/(An)+, 11=(An)/(An)
    // Phase 52: FPU coprocessor dispatch stub
    logic        dec_is_fpu;        // Group F FPU instruction (cpid=1)
    // Phase 53: memory-indirect EA ([bd,An],Xn,od)
    logic        dec_is_memind;       // instruction uses memory-indirect EA (full ext, fi_iis != 0)
    logic        dec_memind_is_post;  // 1=post-indexed (IS=1: Xn to outer), 0=pre-indexed
    logic [31:0] dec_memind_od;       // outer displacement

    // Phase 54: MMU instruction decode signals
    logic        dec_is_pflush;
    logic        dec_pflush_all;
    logic [2:0]  dec_pflush_fc;
    logic        dec_is_ptest;
    logic [2:0]  dec_ptest_fc;
    logic        dec_is_pmove;
    logic [2:0]  dec_pmove_preg;
    logic        dec_pmove_to_mem;   // 1=register→EA (write), 0=EA→register (read)

    // Control register read mux for MOVEC Rc→Rn (ext_data[11:0] = Rc code)
    logic [31:0] ctrl_reg_rd_val;
    always_comb begin
        case (ext_data[11:0])
            12'h000: ctrl_reg_rd_val = {29'h0, sfc_in};
            12'h001: ctrl_reg_rd_val = {29'h0, dfc_in};
            12'h002: ctrl_reg_rd_val = cacr_in;
            12'h800: ctrl_reg_rd_val = usp_in;
            12'h801: ctrl_reg_rd_val = vbr_in;
            12'h802: ctrl_reg_rd_val = caar_in;
            12'h803: ctrl_reg_rd_val = msp_in;
            12'h804: ctrl_reg_rd_val = isp_in;
            default: ctrl_reg_rd_val = 32'h0;
        endcase
    end

    always_comb begin
        dec_valid        = 1'b0;
        dec_unit         = UNIT_NONE;
        dec_alu_op       = ALU_ADD;
        dec_shf_op       = SHF_LSL;
        dec_md_op        = MUL_UW;
        dec_bcd_op       = BCD_ADD;
        dec_bit_op       = BIT_TST;
        dec_bit_num      = 5'h0;
        dec_bit_from_reg = 1'b0;
        dec_src_reg      = 4'h0;
        dec_dst_reg      = 4'h0;
        dec_dest_reg     = 4'h0;
        dec_siz          = 2'b00;
        dec_imm          = ext_data;
        dec_use_imm      = 1'b0;
        dec_use_reg_cnt  = 1'b0;
        dec_writes_reg   = 1'b0;
        dec_updates_ccr  = 1'b0;
        dec_x_unchanged  = 1'b0;
        dec_needs_ext    = 1'b0;
        dec_reads_src    = 1'b0;
        dec_reads_dst    = 1'b0;
        dec_shf_imm_cnt    = 6'd1;
        dec_is_branch      = 1'b0;
        dec_is_dbcc        = 1'b0;
        dec_reads_ccr      = 1'b0;
        dec_branch_cond    = 4'h0;
        dec_branch_disp    = 32'h0;
        dec_is_swap        = 1'b0;
        dec_sext           = 1'b0;
        dec_sext_from_byte = 1'b0;
        dec_is_mem_rd  = 1'b0;
        dec_is_mem_wr  = 1'b0;
        dec_is_lea     = 1'b0;
        dec_is_movea_w = 1'b0;
        dec_ea_offset  = 32'h0;
        dec_an_delta   = 32'h0;
        dec_an_upd_en  = 1'b0;
        dec_an_upd_reg = 3'h0;
        dec_is_jmp      = 1'b0;
        dec_is_jsr      = 1'b0;
        dec_is_bsr      = 1'b0;
        dec_is_rts      = 1'b0;
        dec_is_rtr      = 1'b0;
        dec_is_link     = 1'b0;
        dec_is_unlk     = 1'b0;
        dec_abs_ea_en   = 1'b0;
        dec_abs_jmp_en  = 1'b0;
        dec_abs_ea_val  = 32'h0;
        dec_return_pc   = 32'h0;
        dec_bsr_target  = 32'h0;
        dec_jump_offset = 32'h0;
        dec_is_idx      = 1'b0;
        dec_xn_wl       = 1'b0;
        dec_xn_scale    = 2'b00;
        dec_is_movem    = 1'b0;
        dec_movem_load  = 1'b0;
        dec_movem_predec  = 1'b0;
        dec_movem_postinc = 1'b0;
        dec_movem_long  = 1'b0;
        dec_is_movec      = 1'b0;
        dec_movec_to_ctrl = 1'b0;
        dec_is_moves      = 1'b0;
        dec_moves_load    = 1'b0;
        dec_is_tas        = 1'b0;
        dec_is_chk        = 1'b0;
        dec_chk_word      = 1'b0;
        dec_is_cmp2chk2   = 1'b0;
        dec_is_movep      = 1'b0;
        dec_movep_load    = 1'b0;
        dec_movep_long    = 1'b0;
        dec_is_move16     = 1'b0;
        dec_move16_form   = 2'b0;
        dec_is_fpu        = 1'b0;
        dec_is_memind      = 1'b0;
        dec_memind_is_post = 1'b0;
        dec_memind_od      = 32'h0;
        dec_is_pflush      = 1'b0;
        dec_pflush_all     = 1'b0;
        dec_pflush_fc      = 3'b0;
        dec_is_ptest       = 1'b0;
        dec_ptest_fc       = 3'b0;
        dec_is_pmove       = 1'b0;
        dec_pmove_preg     = 3'b0;
        dec_pmove_to_mem   = 1'b0;

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
                    end else if (!f_dir && f_ss == 2'b11 && !f_dn[0] &&
                                 f_dn != 3'b110 && f_mode == 3'b010) begin
                        // CMP2/CHK2 <ea>,Rn — 0000 ss00 11 010 rrr + ext
                        // ext[15]=D/A, ext[14:12]=Rn, ext[11]=CHK2(1)/CMP2(0)
                        // EA: (An) only (Phase 48)
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_is_cmp2chk2 = 1'b1;
                        dec_needs_ext   = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_src_reg     = {1'b1, f_reg};                     // An → rd_a (EA base)
                        dec_reads_src   = 1'b1;
                        dec_dst_reg     = {ext_data[15], ext_data[14:12]};   // Rn → rd_b
                        dec_reads_dst   = 1'b1;
                        case (f_dn)
                            3'b000: dec_siz = 2'b01;   // byte
                            3'b010: dec_siz = 2'b10;   // word
                            default: dec_siz = 2'b00;  // long (f_dn=3'b100)
                        endcase
                    end else if (!f_dir && f_dn == 3'b111 &&
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
                        case (f_mode)
                            3'b010: ;  // (An): offset = 0
                            3'b011: begin  // (An)+
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = calc_step(f_siz, f_reg==3'b111);
                            end
                            3'b100: begin  // -(An)
                                dec_an_upd_en  = 1'b1;
                                dec_an_upd_reg = f_reg;
                                dec_an_delta   = ~calc_step(f_siz, f_reg==3'b111)+32'h1;
                                dec_ea_offset  = dec_an_delta;
                            end
                            default: ;
                        endcase
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
                            // MOVE.B/W/L (special EA), Dn — abs or PC-relative source
                            dec_valid     = 1'b1;
                            dec_is_mem_rd = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_abs_ea_en = 1'b1;
                            dec_needs_ext = 1'b1;
                            case (f_reg)
                                3'b000: dec_abs_ea_val = {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b001: dec_abs_ea_val = ext_data;
                                3'b010: // (d16,PC): EA = PC+2 + sign_ext(d16)
                                    dec_abs_ea_val = decode_pc + 32'd2
                                                   + {{16{ext_data[15]}}, ext_data[15:0]};
                                3'b011: begin // (d8,PC,Xn): EA = PC+2 + d8 + scaled(Xn)
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
                                // FULL, memory-indirect: ([bd,An],Xn,od) — Phase 53
                                // FSM owns all bus cycles and WB (memind_wr_en); suppress
                                // normal mem_rd path and WB to avoid spurious post-FSM read.
                                dec_valid          = 1'b1;
                                dec_is_mem_rd      = 1'b0;
                                dec_writes_reg     = 1'b0;
                                dec_unit           = UNIT_MOVE;
                                dec_is_memind      = 1'b1;
                                dec_memind_is_post = fi_is_s;
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s; // Xn in inner for pre-indexed
                                dec_ea_offset      = fi_bd;
                            end
                        end

                    end else if (f_move_dst_mode == 3'b001) begin
                        // ── dst = An → MOVEA ──
                        dec_dest_reg    = {1'b1, f_dn};
                        dec_writes_reg  = 1'b1;
                        dec_is_movea_w  = (f_group == 4'h3);  // MOVEA.W: sign-extend
                        dec_siz         = 2'b00;              // always longword to An

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
                            // MOVEA (special EA), An — abs or PC-relative source
                            dec_valid     = 1'b1;
                            dec_is_mem_rd = 1'b1;
                            dec_unit      = UNIT_MOVE;
                            dec_abs_ea_en = 1'b1;
                            dec_needs_ext = 1'b1;
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
                                dec_memind_is_post = fi_is_s;
                                dec_memind_od      = fi_od;
                                dec_is_idx         = !fi_is_s;
                                dec_ea_offset      = fi_bd;
                            end
                        end

                    end else if (f_move_dst_mode[2:1] == 2'b01 ||
                                 f_move_dst_mode == 3'b100 ||
                                 f_move_dst_mode == 3'b101) begin
                        // ── dst = memory; src = register (Dn or An) ──
                        if (f_mode == 3'b000 || f_mode == 3'b001) begin
                            dec_valid      = 1'b1;
                            dec_is_mem_wr  = 1'b1;
                            dec_unit       = UNIT_MOVE;
                            // rd_a = source register (Dn or An → write data)
                            dec_src_reg    = (f_mode == 3'b000) ? {1'b0, f_reg}
                                                                 : {1'b1, f_reg};
                            // rd_b = An for EA base
                            dec_dst_reg    = {1'b1, f_dn};
                            dec_reads_src  = 1'b1;
                            dec_reads_dst  = 1'b1;
                            dec_writes_reg = 1'b0;   // no regfile write (memory dest)
                            dec_updates_ccr = (f_mode == 3'b000);  // Dn src updates CCR
                            case (f_move_dst_mode)
                                3'b010: ;  // (An): offset=0
                                3'b011: begin  // (An)+
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = calc_step(f_move_sz, f_dn==3'b111);
                                end
                                3'b100: begin  // -(An)
                                    dec_an_upd_en  = 1'b1;
                                    dec_an_upd_reg = f_dn;
                                    dec_an_delta   = ~calc_step(f_move_sz, f_dn==3'b111)+32'h1;
                                    dec_ea_offset  = dec_an_delta;
                                end
                                3'b101: begin  // (d16,An)
                                    dec_ea_offset = {{16{ext_data[15]}}, ext_data[15:0]};
                                    dec_needs_ext = 1'b1;
                                end
                                default: ;
                            endcase
                        end
                    end else if (f_move_dst_mode == 3'b111) begin
                        // ── dst = absolute address; src = Dn or An ──
                        // f_dn encodes EA sub-type: 000=abs.W, 001=abs.L
                        if (f_mode == 3'b000 || f_mode == 3'b001) begin
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
                            dec_updates_ccr = (f_mode == 3'b000);
                            dec_needs_ext   = 1'b1;
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
                            // f_ss==11, f_mode==000
                            if (f_dn == 3'b100) begin
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
                            // LEA (d8,An,Xn), An — brief indexed EA
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
                            dec_ea_offset  = {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext  = 1'b1;
                        end
                    end else if (f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                                 f_mode == 3'b111 && f_reg == 3'b100) begin
                        // CHK #imm, Dn: 0100 DDD1 ss 111 100 + ext
                        // f_dir=1, f_ss=10→CHK.W, f_ss=00→CHK.L, f_mode=7, f_reg=4
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_NONE;  // N via wb_ccr[3], not wb_move_n
                        dec_is_chk      = 1'b1;
                        dec_chk_word    = (f_ss == 2'b10);
                        dec_siz         = (f_ss == 2'b10) ? 2'b10 : 2'b00;
                        dec_updates_ccr = 1'b1;
                        dec_x_unchanged = 1'b1;
                        dec_dst_reg     = {1'b0, f_dn};    // value checked → rd_b
                        dec_reads_dst   = 1'b1;
                        dec_use_imm     = 1'b1;
                        dec_needs_ext   = 1'b1;
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
                            // JSR (special EA) — abs or PC-relative target, push return PC
                            // (d8,PC,Xn) deferred: needs A7 + Xn + PC simultaneously
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
                                // 3'b011 (d8,PC,Xn) deferred — 3-register conflict
                                default: ;
                            endcase
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
                            // JMP (d8,An,Xn) — brief indexed target
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
                            dec_jump_offset = {{24{ext_data[7]}}, ext_data[7:0]};
                            dec_needs_ext   = 1'b1;
                        end
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
                        dec_writes_reg = 1'b1;            // An ← A7-4 in WB (wb_result=ex_ea)
                        dec_dest_reg   = {1'b1, f_reg};   // destination = An
                        dec_an_upd_en  = 1'b1;
                        dec_an_upd_reg = 3'b111;          // A7 update
                        // A7_new = A7-4 + d16 = A7 + (d16-4); -4 = 32'hFFFF_FFFC
                        dec_an_delta   = {{16{ext_data[15]}}, ext_data[15:0]} + 32'hFFFF_FFFC;
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
                    end else if (instr_word == 16'h4E71) begin
                        // NOP: 0100 1110 0111 0001
                        dec_valid = 1'b1;

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
                        // MOVEC Rn,Rc: read general register → write to control register
                        // Extension word: [15]=D/A, [14:12]=Rn, [11:0]=Rc
                        dec_valid          = 1'b1;
                        dec_unit           = UNIT_MOVE;
                        dec_siz            = 2'b00;
                        dec_is_movec       = 1'b1;
                        dec_movec_to_ctrl  = 1'b1;
                        dec_src_reg        = {ext_data[15], ext_data[14:12]};
                        dec_reads_src      = 1'b1;
                        dec_needs_ext      = 1'b1;

                    // ----------------------------------------------------------------
                    // Phase 47: TAS.B (An) — memory indirect RMW: 0100 1010 11 010 rrr
                    // f_dn=101, f_dir=0, f_ss=11, f_mode=010.
                    // TAS.B Dn (f_mode=000) is decoded inside the f_mode==000/f_ss==11 block above.
                    // N=bit7(original), Z=(original_byte==0), V=0, C=0, X unchanged.
                    // ----------------------------------------------------------------
                    end else if (f_dn == 3'b101 && !f_dir && f_ss == 2'b11 && f_mode == 3'b010) begin
                        // TAS.B (An) — memory indirect, RMW
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_MOVE;
                        dec_siz         = 2'b01;    // byte
                        dec_src_reg     = {1'b1, f_reg};  // An → rd_a
                        dec_reads_src   = 1'b1;
                        dec_is_mem_rd   = 1'b1;
                        dec_updates_ccr = 1'b0;  // CCR fires via tas_sr_wr path
                        dec_x_unchanged = 1'b1;
                        dec_is_tas      = 1'b1;

                    // ----------------------------------------------------------------
                    // Phase 43: MOVEM — register list save/restore
                    // Store (reg→mem): f_dn=100, !f_dir, f_ss[1]=1
                    //   EA: -(An) f_mode=100 or (An) f_mode=010
                    // Load (mem→reg): f_dn=110, !f_dir, f_ss[1]=1
                    //   EA: (An)+ f_mode=011 or (An) f_mode=010
                    // Mask always in ext_data[15:0] (1 extension word).
                    // f_ss[0]: 0=word, 1=longword.
                    // ----------------------------------------------------------------
                    end else if (!f_dir && f_ss[1] &&
                                 (f_dn == 3'b100 || f_dn == 3'b110)) begin
                        // MOVEM store: f_dn=100  EA: -(An)(100) or (An)(010)
                        // MOVEM load:  f_dn=110  EA: (An)+(011) or (An)(010)
                        if ( (f_dn == 3'b110 && (f_mode == 3'b011 || f_mode == 3'b010)) ||
                             (f_dn == 3'b100 && (f_mode == 3'b100 || f_mode == 3'b010)) ) begin
                            dec_valid         = 1'b1;
                            dec_is_movem      = 1'b1;
                            dec_movem_load    = (f_dn == 3'b110);
                            dec_movem_predec  = (f_dn == 3'b100) && (f_mode == 3'b100);
                            dec_movem_postinc = (f_dn == 3'b110) && (f_mode == 3'b011);
                            dec_movem_long    = f_ss[0];
                            // rd_b reads the base An (for address computation at EX time)
                            dec_dst_reg       = {1'b1, f_reg};
                            dec_reads_dst     = 1'b1;
                            dec_siz           = 2'b00;  // longword An read
                            dec_needs_ext     = 1'b1;   // mask in first ext word
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
                        end
                    end else if (f_mode == 3'b000) begin
                        // ADDQ / SUBQ #imm3, Dn
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
                        end else if (f_dir && f_ss == 2'b00) begin
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
                    end
                end

                // ----------------------------------------------------------------
                // Group 1001: SUB
                // ----------------------------------------------------------------
                4'h9: begin
                    if (f_mode == 3'b000 && f_ss != 2'b11) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_SUB;
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
                end

                // ----------------------------------------------------------------
                // Group 1011: CMP (f_dir=0) / EOR (f_dir=1)
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
                        end else if (f_dir && f_ss == 2'b00) begin
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
                        end else begin
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
                    end
                end

                // ----------------------------------------------------------------
                // Group 1101: ADD
                // ----------------------------------------------------------------
                4'hd: begin
                    if (f_mode == 3'b000 && f_ss != 2'b11) begin
                        dec_valid       = 1'b1;
                        dec_unit        = UNIT_ALU;
                        dec_alu_op      = ALU_ADD;
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
                    end
                end

                // ----------------------------------------------------------------
                // Group 1111: MOVE16 (Phase 50) and FPU coprocessor (Phase 52)
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
                    end else if (f_dn == 3'b001) begin
                        // FPU coprocessor (Phase 52 stub): cpid=1, any ppp or EA mode 4-7.
                        // Issues one CPI CPU Space bus cycle; full protocol in later phases.
                        dec_valid     = 1'b1;
                        dec_is_fpu    = 1'b1;
                        dec_unit      = UNIT_NONE;
                        dec_needs_ext = 1'b1;   // FPU opcode always has extension word (CIR)
                    end else if (f_dn == 3'b000) begin
                        // MMU cpid=0: PFLUSH / PTEST / PMOVE (Phase 54)
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
                                // PMOVE (32-bit registers: TC/TT0/TT1/MMUSR)
                                // Skip 64-bit CRP/SRP (mmu_sub_mode=100/110).
                                if (f_mode == 3'b010 &&
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
                    end
                end

                default: ;

            endcase
        end
    end

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
    logic        wb_is_movea_w;
    // Phase 46: MOVEC Rn→Rc write-back
    logic        wb_is_movec_wr;
    logic [11:0] wb_movec_rc;

    // -----------------------------------------------------------------------
    // Stall / hazard logic — checks both EX and WB for RAW conflicts.
    // 2 stall cycles cover EX→WB→regfile-commit latency.
    // ex_mem_stall: EX holds a memory op waiting for BIU ack.
    // -----------------------------------------------------------------------
    logic        ex_valid, ex_writes_reg, ex_updates_ccr;
    logic [3:0]  ex_dest_reg;
    logic        ex_is_mem_rd, ex_is_mem_wr, ex_is_lea, ex_is_movea_w;
    // Phase 38: declared here (before stall assigns) for Icarus forward-ref safety
    logic        ex_is_jmp, ex_is_jsr, ex_is_bsr, ex_is_rts, ex_is_rtr;
    // Phase 39
    logic        ex_is_link;
    // Phase 40: absolute EA
    logic        ex_abs_ea_en;
    logic        ex_abs_jmp_en;
    logic [31:0] ex_abs_ea_val;
    // Phase 41: brief indexed EA
    logic        ex_is_idx;
    logic        ex_xn_wl;
    logic [1:0]  ex_xn_scale;
    // Phase 43: MOVEM
    logic        ex_is_movem;
    logic        ex_movem_load;
    logic        ex_movem_predec;
    logic        ex_movem_postinc;
    logic        ex_movem_long;
    // Phase 46: MOVEC / MOVES
    logic        ex_is_movec_wr;   // MOVEC Rn→Rc in EX
    logic [11:0] ex_movec_rc;      // Rc code latched from extension word
    logic        ex_is_moves;      // MOVES in EX
    logic        ex_moves_load;    // 1=load (SFC), 0=store (DFC)
    // Phase 47: TAS
    logic        ex_is_tas;        // TAS in EX stage
    // Phase 48: CHK, CMP2/CHK2
    logic        ex_is_chk;        // CHK in EX stage
    logic        ex_chk_word;      // 1=CHK.W, 0=CHK.L
    logic        ex_is_cmp2chk2;   // CMP2 or CHK2 in EX stage
    logic        ex_is_movep;      // MOVEP in EX stage
    logic        ex_is_fpu;        // FPU instruction in EX stage (Phase 52)
    // Phase 53: memory-indirect EA state in EX
    logic        ex_is_memind;
    logic        ex_memind_is_post;
    logic [31:0] ex_memind_od;
    // Phase 54: MMU instruction EX stage signals
    logic        ex_is_pflush;
    logic        ex_pflush_all;
    logic [2:0]  ex_pflush_fc;
    logic        ex_is_ptest;
    logic [2:0]  ex_ptest_fc;
    logic        ex_is_pmove;
    logic [2:0]  ex_pmove_preg;
    logic        ex_pmove_to_mem;
    logic        ex_movep_load;    // 1=load, 0=store
    logic        ex_movep_long;    // 1=longword, 0=word
    logic        ex_is_move16;     // MOVE16 in EX stage
    logic [1:0]  ex_move16_form;

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

    // Phase 43: MOVEM FSM state registers
    logic        movem_start_r;    // 1-cycle stall while waiting for An to appear in rd_b
    logic        movem_run_r;      // MOVEM bus sequence active
    logic        movem_load_r;     // 1=mem→reg load, 0=reg→mem store
    logic        movem_predec_r;   // -(An) predecrement mode
    logic        movem_postinc_r;  // (An)+ post-increment mode
    logic        movem_long_r;     // 1=longword, 0=word
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

    // Phase 49: MOVEP byte-interleaved FSM state — declared early for ex_mem_stall
    logic        movep_start_r;       // 1-cycle EA-capture stall
    logic        movep_run_r;         // bus sequence active
    logic        movep_load_r;        // 1=mem→Dn (load), 0=Dn→mem (store)
    logic        movep_long_r;        // 1=longword (4 bytes), 0=word (2 bytes)
    logic [1:0]  movep_byte_r;        // current byte index (0=first)
    logic [31:0] movep_addr_r;        // current byte address
    logic [2:0]  movep_dn_r;          // Dn number for writeback
    logic [31:0] movep_dn_val_r;      // captured Dn value for stores
    logic [31:0] movep_acc_r;         // accumulated load data
    logic        movep_last;          // final byte this cycle
    logic [7:0]  movep_wr_byte_w;     // byte to send for stores
    logic [31:0] movep_rd_acc_w;      // accumulator updated with current byte
    logic        movep_wr_en;         // register writeback for loads
    logic [31:0] movep_wr_data;
    logic [3:0]  movep_wr_sel;

    assign movep_last = movep_run_r && mem_ack &&
                        ((movep_long_r && movep_byte_r == 2'd3) ||
                         (!movep_long_r && movep_byte_r == 2'd1));

    always_comb begin
        movep_wr_byte_w = 8'h0;
        if (movep_long_r) begin
            case (movep_byte_r)
                2'd0: movep_wr_byte_w = movep_dn_val_r[31:24];
                2'd1: movep_wr_byte_w = movep_dn_val_r[23:16];
                2'd2: movep_wr_byte_w = movep_dn_val_r[15:8];
                2'd3: movep_wr_byte_w = movep_dn_val_r[7:0];
            endcase
        end else begin
            movep_wr_byte_w = movep_byte_r[0] ? movep_dn_val_r[7:0] : movep_dn_val_r[15:8];
        end
    end

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

    // Phase 50: MOVE16 16-byte block move FSM — declared early for ex_mem_stall
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

    // Phase 52: FPU dispatch FSM state — declared early for ex_mem_stall
    logic        fpu_start_r;      // one-cycle setup after instr_ack
    logic        fpu_run_r;        // eu_coproc_req active, waiting for ack
    logic [2:0]  fpu_prim_r;       // captured ppp = {f_dir, f_ss} for address generation

    // Phase 54: MMU instruction FSM state — declared early for ex_mem_stall
    logic        pflush_start_r, pflush_req_r;
    logic        pflush_all_r;
    logic [2:0]  pflush_fc_r;
    logic [31:0] pflush_va_r;
    logic        ptest_start_r, ptest_run_r;
    logic [31:0] ptest_va_r;
    logic [2:0]  ptest_fc_r;
    // MMU control registers (internal to EU)
    logic [31:0] tc_r   = 32'h0;
    logic [31:0] tt0_r  = 32'h0;
    logic [31:0] tt1_r  = 32'h0;
    logic [15:0] mmusr_r = 16'h0;

    // Phase 53: memory-indirect EA FSM state — declared early for ex_mem_stall
    logic        memind_start_r;       // 1 cycle: An/Xn available in rd_a/rd_b
    logic        memind_inner_r;       // inner longword read in progress
    logic        memind_outer_r;       // outer instruction-sized read in progress
    logic [31:0] memind_inner_addr_r;  // inner bus address
    logic [31:0] memind_ptr_r;         // pointer value from inner read
    logic [31:0] memind_od_r;          // outer displacement
    logic [31:0] memind_post_xn_r;     // scaled Xn for post-indexed outer EA
    logic        memind_is_rd_r;       // 1=outer is a read (always true for Phase 53)
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

    // Phase 48: CMP2/CHK2 two-read FSM state — declared early for ex_mem_stall
    logic        cmp2_run_r;        // second read in progress
    logic        cmp2_after_r;      // 1-cycle cooldown after second read ack
    logic [31:0] cmp2_lb_r;         // lower bound captured from first read
    logic [31:0] cmp2_addr2_r;      // address for second read (EA + size_step)
    logic [31:0] cmp2_rn_r;         // Rn value captured at FSM start
    logic        cmp2_is_chk2_r;    // 1=CHK2 (trap on range fail), 0=CMP2
    logic        cmp2_is_an_r;      // 1=Rn is An (always 32-bit compare)
    logic [1:0]  cmp2_siz_r;        // instruction size for sign extension
    logic        cmp2_first_ack;    // first read just acked — hold stall while FSM starts
    logic        cmp2_sr_wr_en;     // fire CCR update when second read acks

    // CMP2/CHK2 sign-extended comparison values (combinational from FSM state + mem_rdata)
    logic [31:0] cmp2_lb_sext_w, cmp2_ub_sext_w, cmp2_rn_sext_w;
    logic        cmp2_c_w, cmp2_z_w;
    always_comb begin
        case (cmp2_siz_r)
            2'b01: begin  // byte
                cmp2_lb_sext_w = {{24{cmp2_lb_r[7]}},  cmp2_lb_r[7:0]};
                cmp2_ub_sext_w = {{24{mem_rdata[7]}},   mem_rdata[7:0]};
                cmp2_rn_sext_w = cmp2_is_an_r ? cmp2_rn_r : {{24{cmp2_rn_r[7]}},  cmp2_rn_r[7:0]};
            end
            2'b10: begin  // word
                cmp2_lb_sext_w = {{16{cmp2_lb_r[15]}}, cmp2_lb_r[15:0]};
                cmp2_ub_sext_w = {{16{mem_rdata[15]}},  mem_rdata[15:0]};
                cmp2_rn_sext_w = cmp2_is_an_r ? cmp2_rn_r : {{16{cmp2_rn_r[15]}}, cmp2_rn_r[15:0]};
            end
            default: begin  // long
                cmp2_lb_sext_w = cmp2_lb_r;
                cmp2_ub_sext_w = mem_rdata;
                cmp2_rn_sext_w = cmp2_rn_r;
            end
        endcase
        cmp2_c_w = ($signed(cmp2_rn_sext_w) < $signed(cmp2_lb_sext_w)) ||
                   ($signed(cmp2_rn_sext_w) > $signed(cmp2_ub_sext_w));
        cmp2_z_w = (cmp2_rn_sext_w == cmp2_lb_sext_w) || (cmp2_rn_sext_w == cmp2_ub_sext_w);
    end

    logic rtr_stall, ex_mem_stall;
    assign rtr_stall    = ex_is_rtr && !(rtr_phase_r && mem_ack);
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
    assign ex_mem_stall = tas_run_r || tas_read_ack || movem_start_r || movem_run_r ||
                          movep_start_r || movep_run_r ||
                          move16_start_r || move16_run_r ||
                          fpu_start_r || fpu_run_r ||
                          memind_start_r || memind_inner_r || memind_outer_r ||
                          pflush_start_r || pflush_req_r ||
                          ptest_start_r  || ptest_run_r  ||
                          cmp2_run_r || cmp2_first_ack ||
                          (!tas_after_write_r && !cmp2_run_r && !cmp2_after_r &&
                           !memind_start_r && !memind_inner_r && !memind_outer_r &&
                           (ex_is_mem_rd || ex_is_mem_wr) && !mem_ack) ||
                          rtr_stall;

    logic hazard_ex, hazard_wb, hazard_ccr, need_ext, stall;
    assign hazard_ex  = ex_valid && ex_writes_reg && (
                            (dec_reads_src && ex_dest_reg == dec_src_reg) ||
                            (dec_reads_dst && ex_dest_reg == dec_dst_reg));
    assign hazard_wb  = wb_valid && wb_writes_reg && (
                            (dec_reads_src && wb_dest_reg == dec_src_reg) ||
                            (dec_reads_dst && wb_dest_reg == dec_dst_reg));
    assign hazard_ccr = dec_reads_ccr && (
                            (ex_valid && ex_updates_ccr) ||
                            (wb_valid && wb_updates_ccr));
    assign need_ext   = dec_needs_ext && !ext_valid;
    // ex_mem_stall freezes the entire pipeline regardless of dec_valid
    assign stall      = ex_mem_stall || (dec_valid && (hazard_ex || hazard_wb || hazard_ccr || need_ext));
    assign seq_busy  = stall;
    assign instr_ack = dec_valid && !stall;

    // -----------------------------------------------------------------------
    // EX stage latch
    // -----------------------------------------------------------------------
    logic [2:0]  ex_unit;
    logic [3:0]  ex_alu_op, ex_shf_op;
    logic [2:0]  ex_md_op;
    logic [1:0]  ex_bcd_op;
    logic [1:0]  ex_bit_op;
    logic [4:0]  ex_bit_num;
    logic        ex_bit_from_reg;
    logic [3:0]  ex_src_reg, ex_dst_reg;
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
    // Memory-access EX signals
    logic [31:0] ex_ea_offset;   // displacement for EA (0 or d16 or -step)
    logic [31:0] ex_an_delta;    // An update amount
    logic        ex_an_upd_en;
    logic [2:0]  ex_an_upd_reg;
    // Phase 38: subroutine / jump EX signals
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
            ex_is_idx         <= 1'b0;
            ex_xn_wl          <= 1'b0;
            ex_xn_scale       <= 2'b00;
            ex_return_pc      <= 32'h0;
            ex_bsr_target     <= 32'h0;
            ex_jump_offset    <= 32'h0;
            ex_is_movem       <= 1'b0;
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
            ex_is_pflush      <= 1'b0;
            ex_pflush_all     <= 1'b0;
            ex_pflush_fc      <= 3'b0;
            ex_is_ptest       <= 1'b0;
            ex_ptest_fc       <= 3'b0;
            ex_is_pmove       <= 1'b0;
            ex_pmove_preg     <= 3'b0;
            ex_pmove_to_mem   <= 1'b0;
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
            ex_abs_ea_en      <= 1'b0;
            ex_abs_jmp_en     <= 1'b0;
            ex_is_idx         <= 1'b0;
            ex_is_movem       <= 1'b0;
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
            ex_is_pmove       <= 1'b0;
            ex_pmove_preg     <= 3'b0;
            ex_pmove_to_mem   <= 1'b0;
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
            ex_is_pmove       <= dec_is_pmove;
            ex_pmove_preg     <= dec_pmove_preg;
            ex_pmove_to_mem   <= dec_pmove_to_mem;
        end
    end

    // -----------------------------------------------------------------------
    // Drive functional unit inputs from EX stage + register file
    // For memory ops: rd_a/rd_b must provide full 32-bit values (An for EA
    // base, Dn for write data). Override siz to longword so no sign-extension.
    // -----------------------------------------------------------------------
    // Phase 43: during MOVEM store, override rd_a_sel to read the current register to store.
    assign rd_a_sel = (movem_run_r && !movem_load_r) ? movem_reg_sel : ex_src_reg;
    assign rd_a_siz = (movem_run_r || ex_is_mem_rd || ex_is_mem_wr || ex_is_lea) ? 2'b00 : ex_siz;
    assign rd_b_sel = ex_dst_reg;
    // Phase 41: for indexed EA and CMP2/CHK2, rd_b carries Xn/Rn — full longword needed
    // Phase 53: memind post-indexed also needs full longword Xn in rd_b (for outer EA scaling)
    assign rd_b_siz = (ex_is_mem_wr || ex_is_idx || ex_is_cmp2chk2 || ex_is_memind) ? 2'b00 : ex_siz;

    // EA computation: An base from rd_a (loads/LEA) or rd_b (stores).
    logic [31:0] ex_an_base;
    assign ex_an_base = ex_is_mem_wr ? rd_b_data : rd_a_data;

    // Phase 41: brief indexed — scaled index register value added to EA and jump target
    logic [31:0] ex_xn_val;
    logic [31:0] ex_xn_scaled;
    assign ex_xn_val    = ex_xn_wl ? rd_b_data : {{16{rd_b_data[15]}}, rd_b_data[15:0]};
    assign ex_xn_scaled = ex_is_idx ? (ex_xn_val << ex_xn_scale) : 32'h0;

    // Phase 53: post-indexed memind Xn*SCALE (valid during memind_start_r when EX holds)
    logic [31:0] memind_xn_sc_w;
    assign memind_xn_sc_w = ex_xn_val << ex_xn_scale;  // always computed; selected by FSM
    // Outer EA: pointer + post-indexed Xn (pre-indexed already in pointer) + od
    logic [31:0] memind_outer_addr_w;
    assign memind_outer_addr_w = memind_ptr_r + memind_post_xn_r + memind_od_r;

    logic [31:0] ex_ea;       // effective address for bus cycle or LEA result
    // Phase 42: ex_xn_scaled always added — zero when !ex_is_idx; handles (d8,PC,Xn)
    // where ex_abs_ea_val = PC+2+d8 and ex_xn_scaled carries the scaled index.
    assign ex_ea = ex_abs_ea_en ? (ex_abs_ea_val + ex_xn_scaled)
                                : (ex_an_base + ex_ea_offset + ex_xn_scaled);

    logic [31:0] ex_an_new;   // updated An value for (An)+ / -(An)
    assign ex_an_new = ex_an_base + ex_an_delta;

    // Phase 38: jump target = An_jump + offset (rd_a is the An base for JMP/JSR)
    // Phase 40: absolute EA overrides; Phase 41/42: ex_xn_scaled adds index for (d8,PC,Xn)
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
            // Simplified: use A7+4 for PC read (real 68030 uses A7+2; fix in later phase)
            rtr_a7_next_r <= ex_ea + 32'd4;
        end else if (ex_valid && ex_is_rtr && rtr_phase_r && mem_ack) begin
            rtr_phase_r   <= 1'b0;
        end
    end

    // Phase 43: MOVEM two-phase FSM
    //   Phase A (movem_start_r=1): MOVEM entered EX; wait one cycle so rd_b_data = An value.
    //   Phase B (movem_run_r=1): issue one bus cycle per remaining register in movem_mask_r.
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
        end else if (!movem_start_r && !movem_run_r && instr_ack && dec_is_movem) begin
            // DECODE accepted MOVEM: capture control bits; stall for one cycle (Phase A).
            // rd_b_data is still from previous EX instruction here — use registered signals.
            movem_start_r   <= 1'b1;
            movem_mask_r    <= ext_data[15:0];  // register list mask
            movem_load_r    <= dec_movem_load;
            movem_predec_r  <= dec_movem_predec;
            movem_postinc_r <= dec_movem_postinc;
            movem_long_r    <= dec_movem_long;
            movem_an_r      <= f_reg;           // base An register number
        end else if (movem_start_r) begin
            // Phase A: MOVEM is now in EX; rd_b_data = base An value.
            // Compute initial bus address and start Phase B.
            movem_start_r <= 1'b0;
            movem_run_r   <= 1'b1;
            // Predecrement: first access at An-step; post-inc/(An): first access at An.
            if (movem_predec_r)
                movem_addr_r <= rd_b_data - (movem_long_r ? 32'd4 : 32'd2);
            else
                movem_addr_r <= rd_b_data;
        end else if (movem_run_r && mem_ack) begin
            // Phase B: one register processed; advance to the next.
            movem_mask_r <= movem_next_mask;
            if (!movem_last) begin
                if (movem_predec_r)
                    movem_addr_r <= movem_addr_r - movem_step;
                else
                    movem_addr_r <= movem_addr_r + movem_step;
            end
            if (movem_last) movem_run_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // Phase 47: TAS (An) RMW FSM
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
            end else if (tas_run_r && mem_ack) begin
                // Write ack: end write phase
                tas_run_r   <= 1'b0;
            end
        end
    end

    assign tas_sr_wr_en = tas_run_r && mem_ack;

    // -----------------------------------------------------------------------
    // Phase 48: CMP2/CHK2 two-read FSM
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
            cmp2_rn_r      <= 32'h0;
            cmp2_is_chk2_r <= 1'b0;
            cmp2_is_an_r   <= 1'b0;
            cmp2_siz_r     <= 2'b00;
        end else begin
            cmp2_after_r <= cmp2_run_r && mem_ack;
            if (!cmp2_run_r && !cmp2_after_r &&
                ex_valid && ex_is_cmp2chk2 && ex_is_mem_rd && mem_ack) begin
                // First read ack: capture bounds and start second read
                cmp2_run_r     <= 1'b1;
                cmp2_lb_r      <= mem_rdata;
                cmp2_rn_r      <= rd_b_data;   // rd_b = Rn (read as 32-bit; see rd_b_siz)
                cmp2_is_chk2_r <= ex_imm[11];  // ext_data[11] = CHK2 selector
                cmp2_is_an_r   <= ex_imm[15];  // ext_data[15] = D/A flag
                cmp2_siz_r     <= ex_siz;
                case (ex_siz)
                    2'b01: cmp2_addr2_r <= ex_ea + 32'd1;
                    2'b10: cmp2_addr2_r <= ex_ea + 32'd2;
                    default: cmp2_addr2_r <= ex_ea + 32'd4;
                endcase
            end else if (cmp2_run_r && mem_ack) begin
                cmp2_run_r <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Phase 49: MOVEP byte-interleaved FSM
    // start_r (1 cycle): EX has An in rd_a_data, capture EA and Dn value.
    // run_r: issue one SIZ=byte bus cycle per pending transfer.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            movep_start_r  <= 1'b0;
            movep_run_r    <= 1'b0;
            movep_load_r   <= 1'b0;
            movep_long_r   <= 1'b0;
            movep_byte_r   <= 2'd0;
            movep_addr_r   <= 32'h0;
            movep_dn_r     <= 3'h0;
            movep_dn_val_r <= 32'h0;
            movep_acc_r    <= 32'h0;
        end else if (!movep_start_r && !movep_run_r && instr_ack && dec_is_movep) begin
            movep_start_r <= 1'b1;
            movep_load_r  <= dec_movep_load;
            movep_long_r  <= dec_movep_long;
            movep_dn_r    <= f_dn;
        end else if (movep_start_r) begin
            movep_start_r  <= 1'b0;
            movep_run_r    <= 1'b1;
            movep_byte_r   <= 2'd0;
            movep_addr_r   <= ex_ea;       // EA = An + d16 from EX combinatorial
            movep_dn_val_r <= rd_b_data;   // Dn value for stores
            movep_acc_r    <= 32'h0;
        end else if (movep_run_r && mem_ack) begin
            movep_byte_r  <= movep_byte_r + 2'd1;
            movep_addr_r  <= movep_addr_r + 32'd2;
            movep_acc_r   <= movep_rd_acc_w;
            if (movep_last) movep_run_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // Phase 50: MOVE16 16-byte block move FSM
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
            end
        end
    end

    // -----------------------------------------------------------------------
    // Phase 52: FPU coprocessor dispatch FSM
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
    // Phase 53: memory-indirect EA FSM
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
            memind_is_rd_r <= 1'b1;   // Phase 53: memind only supports load ops
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
        end
    end

    // -----------------------------------------------------------------------
    // Phase 54: PFLUSH / PTEST FSM
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

    // CHK comparison: rd_b = value checked (sign-extended by regfile to ex_siz);
    // upper bound: rd_a_data (register mode) or ex_imm (immediate mode).
    logic [31:0] chk_val_w, chk_ub_w;
    logic        chk_below_w, chk_above_w;
    assign chk_val_w   = rd_b_data;
    assign chk_ub_w    = ex_use_imm ? ex_imm : rd_a_data;
    // Regfile zero-extends word reads for Dn, so check the size-appropriate sign bit.
    assign chk_below_w = ex_chk_word ? chk_val_w[15] : chk_val_w[31];
    assign chk_above_w = $signed(chk_val_w) > $signed(chk_ub_w);    // above upper bound

    logic [31:0] ex_src_operand;
    assign ex_src_operand = ex_use_imm ? ex_imm : rd_a_data;

    // UNIT_MOVE result: SWAP swaps halfwords; EXT sign-extends; otherwise imm/reg source.
    // Must be pre-computed assigns to avoid Icarus constant-select warnings.
    logic [31:0] move_result_w;
    assign move_result_w =
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

    assign alu_src   = ex_src_operand;
    assign alu_dst   = rd_b_data;
    assign alu_op    = ex_alu_op;
    assign alu_siz   = ex_siz;
    assign alu_x_in  = flag_x;
    assign alu_z_in  = flag_z;

    assign shf_operand = rd_a_data;
    assign shf_count   = ex_use_reg_cnt ? rd_b_data[5:0] : ex_shf_imm_cnt;
    assign shf_op      = ex_shf_op;
    assign shf_siz     = ex_siz;
    assign shf_x_in    = flag_x;

    assign md_src = rd_a_data;
    assign md_dst = rd_b_data;
    assign md_op  = ex_md_op;

    // BCD datapath drives
    assign bcd_src  = rd_a_byte;      // source byte (from rd_a port)
    assign bcd_dst  = rd_b_byte;      // destination byte (from rd_b port)
    assign bcd_op   = ex_bcd_op;
    assign bcd_x_in = flag_x;
    assign bcd_z_in = flag_z;

    // Bitops datapath drives
    assign bit_dst = rd_b_data;       // destination register (full 32-bit)
    assign bit_num = ex_bit_from_reg ? rd_a_bit_num : ex_bit_num;
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
                ex_n      = md_n;
                ex_z      = md_z;
                ex_v      = md_v;
                ex_c      = md_c;
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
                ex_n      = 1'b0;    // undefined — set to 0
                ex_v      = 1'b0;    // undefined — set to 0
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
                    ex_n = chk_below_w;
                    ex_z = flag_z;
                    ex_v = 1'b0;
                    ex_c = 1'b0;
                    ex_x = flag_x;
                end
            end
        endcase
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
            wb_is_movea_w   <= 1'b0;
            wb_is_movec_wr  <= 1'b0;
            wb_movec_rc     <= 12'h0;
        end else if (ex_mem_stall) begin
            // Memory cycle in progress: drain WB (bubble).
            wb_valid        <= 1'b0;
            wb_writes_reg   <= 1'b0;
            wb_updates_ccr  <= 1'b0;
            wb_an_upd_en    <= 1'b0;
            wb_is_mem_rd    <= 1'b0;
            wb_is_movea_w   <= 1'b0;
            wb_is_movec_wr  <= 1'b0;
        end else begin
            wb_valid        <= ex_valid;
            wb_writes_reg   <= ex_writes_reg;
            wb_updates_ccr  <= ex_updates_ccr;
            wb_x_unchanged  <= ex_x_unchanged;
            wb_is_move      <= (ex_unit == UNIT_MOVE);
            wb_move_n       <= ex_move_n;
            wb_dest_reg     <= ex_dest_reg;
            wb_siz          <= ex_siz;
            // Result selection: memory load uses mem_rdata, LEA uses EA, else ALU/MOVE
            wb_result       <= ex_is_mem_rd         ? mem_rdata
                             : (ex_is_lea || ex_is_link) ? ex_ea
                             :                             ex_result;
            wb_ccr          <= {ex_x, ex_n, ex_z, ex_v, ex_c};
            wb_an_upd_en    <= ex_an_upd_en;
            wb_an_upd_reg   <= ex_an_upd_reg;
            wb_an_upd_new   <= ex_an_new;
            wb_is_mem_rd    <= ex_is_mem_rd;
            wb_is_movea_w   <= ex_is_movea_w;
            wb_is_movec_wr  <= ex_is_movec_wr;
            wb_movec_rc     <= ex_movec_rc;
        end
    end

    // -----------------------------------------------------------------------
    // Regfile write outputs
    // For memory loads with MOVEA.W: sign-extend wb_result[15:0] before writing.
    // -----------------------------------------------------------------------
    logic [31:0] wb_result_final;
    assign wb_result_final = (wb_is_mem_rd && wb_is_movea_w)
                           ? {{16{wb_result[15]}}, wb_result[15:0]}
                           : wb_result;

    // Phase 43: MOVEM load writes directly on each mem_ack (bypasses WB path).
    // WB has wb_writes_reg=0 during MOVEM so no conflict.
    logic        movem_wr_en;
    logic [31:0] movem_wr_data;
    assign movem_wr_en  = movem_run_r && movem_load_r && mem_ack;
    // Word loads sign-extend to 32 bits (68030 sign-extends MOVEM.W loads).
    assign movem_wr_data = movem_long_r ? mem_rdata
                                        : {{16{mem_rdata[15]}}, mem_rdata[15:0]};

    // Phase 49: MOVEP load writes on last byte ack (assembles bytes into Dn).
    // Phase 53: memind outer-read writes directly on mem_ack (bypasses WB latch).
    logic memind_wr_en;
    assign memind_wr_en = memind_outer_r && mem_ack && memind_is_rd_r;

    // Word MOVEP writes only [15:0] (siz=10); long writes full 32 bits (siz=00).
    assign wr_en   = movem_wr_en || movep_wr_en || memind_wr_en || (wb_valid && wb_writes_reg);
    assign wr_sel  = movem_wr_en  ? movem_reg_sel
                   : movep_wr_en  ? movep_wr_sel
                   : memind_wr_en ? memind_dest_r
                   :                wb_dest_reg;
    assign wr_siz  = movem_wr_en  ? 2'b00
                   : movep_wr_en  ? (movep_long_r ? 2'b00 : 2'b10)
                   : memind_wr_en ? memind_siz_r
                   :                wb_siz;
    assign wr_data = movem_wr_en  ? movem_wr_data
                   : movep_wr_en  ? movep_wr_data
                   : memind_wr_en ? mem_rdata
                   :                wb_result_final;

    // An update port: MOVEM fires at completion; RTR fires from EX; WB handles normal.
    logic        movem_an_wr_en;
    assign movem_an_wr_en = movem_last && (movem_predec_r || movem_postinc_r);

    // Phase 50: MOVE16 postincrement — src An on move16_last, dst An one cycle later
    logic move16_an1_wr_en;
    assign move16_an1_wr_en = move16_last && move16_src_postinc_r;

    assign an_wr_en  = movem_an_wr_en || rtr_an_wr_en ||
                       move16_an1_wr_en || move16_an2_wr_r ||
                       (wb_valid && wb_an_upd_en);
    assign an_wr_sel = movem_an_wr_en    ? movem_an_r
                     : rtr_an_wr_en      ? 3'b111
                     : move16_an1_wr_en  ? move16_src_an_r
                     : move16_an2_wr_r   ? move16_dst_an_r
                     :                     wb_an_upd_reg;
    assign an_wr_data = movem_an_wr_en   ? movem_an_final
                      : rtr_an_wr_en     ? rtr_an_wr_data
                      : move16_an1_wr_en ? move16_src_base_r + 32'd16
                      : move16_an2_wr_r  ? move16_dst_base_r + 32'd16
                      :                    wb_an_upd_new;

    // -----------------------------------------------------------------------
    // CCR / SR write outputs
    // For MOVE: replace the N bit with wb_move_n (sized MSB)
    // -----------------------------------------------------------------------
    logic [4:0] final_ccr;
    assign final_ccr = wb_is_move ? {wb_ccr[4], wb_move_n, wb_ccr[2:0]} : wb_ccr;

    // Phase 53: memind outer-read CCR update (MOVE sets N/Z, clears V/C)
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

    // SR write: RTR fires CCR update from EX (phase 2); TAS (An) fires from write ack;
    // CMP2/CHK2 fires from second-read ack (cmp2_sr_wr_en); memind fires on outer read ack;
    // normal WB handles all others.
    assign sr_wr_en   = rtr_sr_wr_en || tas_sr_wr_en || cmp2_sr_wr_en || memind_ccr_wr_en
                      || (wb_valid && wb_updates_ccr);
    assign sr_wr_data = rtr_sr_wr_en      ? rtr_sr_wr_data
                      : tas_sr_wr_en      ? {sr_out[15:8], 3'b000, tas_ccr_r}
                      : cmp2_sr_wr_en     ? {sr_out[15:8], 3'b000, flag_x, flag_n, cmp2_z_w, flag_v, cmp2_c_w}
                      : memind_ccr_wr_en  ? {sr_out[15:8], 3'b000, memind_ccr_w}
                      :                     {sr_out[15:8], 3'b000, final_ccr};
    assign sr_ccr_only = 1'b1;

    // -----------------------------------------------------------------------
    // Divide-by-zero trap / CHK-CHK2 out-of-bounds trap (combinational)
    // -----------------------------------------------------------------------
    assign div_trap = ex_valid && (ex_unit == UNIT_DIV) && md_div_by_zero;
    // CHK: trap on current cycle (register/imm mode) or when second operand arrives (mem not implemented yet)
    assign chk_trap = (ex_valid && ex_is_chk && !ex_is_mem_rd && (chk_below_w || chk_above_w))
                   || (cmp2_run_r && mem_ack && cmp2_is_chk2_r && cmp2_c_w);

    // -----------------------------------------------------------------------
    // BRA/Bcc branch — decided at decode time once CCR hazards are clear.
    // -----------------------------------------------------------------------
    logic dec_branch_taken;
    assign dec_branch_taken = dec_valid && !stall && dec_is_branch &&
                              eval_cc(dec_branch_cond, flag_n, flag_z, flag_v, flag_c);

    // -----------------------------------------------------------------------
    // DBcc branch — decided at EX stage (needs ALU result to check counter).
    // Branch taken when: condition is FALSE AND decremented counter != 0xFFFF.
    // -----------------------------------------------------------------------
    logic [15:0] ex_alu_result_w;
    assign ex_alu_result_w = alu_result[15:0];

    logic ex_dbcc_taken;
    assign ex_dbcc_taken = ex_valid && ex_is_dbcc &&
                           !eval_cc(ex_dbcc_cond, flag_n, flag_z, flag_v, flag_c) &&
                           (ex_alu_result_w != 16'hFFFF);

    // -----------------------------------------------------------------------
    // Phase 38: JMP/JSR/BSR/RTS/RTR branches — decided from EX stage.
    // JMP: fires when JMP enters EX (no memory op).
    // JSR/BSR: fires when push (mem_ack=1) completes.
    // RTS: fires when stack-read completes (mem_ack=1).
    // RTR: fires after BOTH reads complete (rtr_phase_r=1 and mem_ack=1).
    // -----------------------------------------------------------------------
    logic ex_jmp_taken, ex_jsr_taken, ex_bsr_taken, ex_rts_taken, ex_rtr_taken;
    assign ex_jmp_taken = ex_valid && ex_is_jmp;
    assign ex_jsr_taken = ex_valid && ex_is_jsr && mem_ack;
    assign ex_bsr_taken = ex_valid && ex_is_bsr && mem_ack;
    assign ex_rts_taken = ex_valid && ex_is_rts && mem_ack;
    assign ex_rtr_taken = ex_valid && ex_is_rtr && rtr_phase_r && mem_ack;

    assign branch_taken  = dec_branch_taken | ex_dbcc_taken |
                           ex_jmp_taken | ex_jsr_taken | ex_bsr_taken |
                           ex_rts_taken | ex_rtr_taken;

    assign branch_target = dec_branch_taken              ? (decode_pc    + 32'd2 + dec_branch_disp)
                         : ex_dbcc_taken                 ? (ex_decode_pc + 32'd2 + ex_dbcc_disp)
                         : ex_bsr_taken                  ? ex_bsr_target
                         : (ex_rts_taken || ex_rtr_taken) ? mem_rdata
                         :                                  ex_jmp_target;  // JMP or JSR

    // -----------------------------------------------------------------------
    // RTR completion: CCR write and A7 update fire directly from EX stage.
    // Normal WB an_wr/sr_wr handles RTS, JSR, BSR stack updates.
    // rtr_sr_wr_en/rtr_an_wr_en declared in early section for forward-ref safety.
    // -----------------------------------------------------------------------
    assign rtr_sr_wr_en  = ex_rtr_taken;
    assign rtr_sr_wr_data = {sr_out[15:8], rtr_ccr_r};
    assign rtr_an_wr_en  = ex_rtr_taken;
    assign rtr_an_wr_data = rtr_a7_next_r + 32'd4;

    // -----------------------------------------------------------------------
    // Memory bus outputs — driven from EX stage when a memory op is active.
    // RTR phase 1: word read (mem_siz=10); phase 2: longword from rtr_a7_next_r.
    // JSR/BSR write: mem_wdata = return PC (not rd_a_data).
    // -----------------------------------------------------------------------
    // Phase 43: MOVEM drives the bus directly during movem_run_r; normal path otherwise.
    // Phase 47: tas_run_r drives the TAS write phase (second bus cycle).
    // Phase 48: cmp2_run_r drives the CMP2/CHK2 second read (upper bound at EA+size).
    // Phase 49: movep_run_r drives byte bus cycles for MOVEP.
    // Phase 50: move16_run_r drives 4 longword reads then 4 longword writes.
    // During cooldown periods, suppress normal mem_req so no spurious bus cycle fires.
    assign mem_req   = movem_run_r || tas_run_r || cmp2_run_r || movep_run_r || move16_run_r ||
                       memind_inner_r || memind_outer_r ||
                       (!tas_after_write_r && !cmp2_run_r && !cmp2_after_r &&
                        !memind_start_r && !memind_inner_r && !memind_outer_r &&
                        ex_valid && (ex_is_mem_rd || ex_is_mem_wr));
    assign mem_rw    = movem_run_r    ? movem_load_r
                     : tas_run_r      ? 1'b0
                     : cmp2_run_r     ? 1'b1
                     : movep_run_r    ? movep_load_r
                     : move16_run_r   ? !move16_phase_r
                     : memind_inner_r ? 1'b1        // inner: always longword read
                     : memind_outer_r ? memind_is_rd_r
                     : ex_is_mem_rd;
    assign mem_siz   = movem_run_r    ? (movem_long_r ? 2'b00 : 2'b10) :
                       cmp2_run_r     ? cmp2_siz_r :
                       movep_run_r    ? 2'b01 :
                       move16_run_r   ? 2'b00 :
                       memind_inner_r ? 2'b00 :     // inner: longword
                       memind_outer_r ? memind_siz_r :
                       (ex_is_rtr && !rtr_phase_r) ? 2'b10 : ex_siz;
    // Phase 46: MOVES uses SFC for loads (ea→Rn) and DFC for stores (Rn→ea)
    assign mem_fc    = (ex_is_moves && ex_moves_load)  ? sfc_in :
                       (ex_is_moves && !ex_moves_load) ? dfc_in :
                                                         {sr_out[13], 1'b0, 1'b1};
    assign mem_addr  = movem_run_r    ? movem_addr_r :
                       cmp2_run_r     ? cmp2_addr2_r :
                       movep_run_r    ? movep_addr_r :
                       move16_run_r   ? (!move16_phase_r ? move16_src_r : move16_dst_r) :
                       memind_inner_r ? memind_inner_addr_r :
                       memind_outer_r ? memind_outer_addr_w :
                       (ex_is_rtr && rtr_phase_r) ? rtr_a7_next_r : ex_ea;
    // For MOVEM store: rd_a_data provides the register value (rd_a_sel overridden above).
    // For TAS write phase: drive tas_wdata_r (original byte | 0x80).
    // For MOVEP store: drive the appropriate byte of Dn.
    // For MOVE16 write phase: drive the buffered longword for the current beat.
    assign mem_wdata = tas_run_r               ? {24'h0, tas_wdata_r}
                     : movep_run_r             ? {24'h0, movep_wr_byte_w}
                     : move16_run_r            ? move16_wdata_w
                     : (ex_is_pmove && ex_pmove_to_mem) ? pmove_wr_data_w
                     : (ex_is_jsr || ex_is_bsr) ? ex_return_pc : rd_a_data;
    // Phase 47: RMW — assert during TAS (An) read phase (not during write or cooldown).
    assign mem_rmw   = ex_valid && ex_is_tas && ex_is_mem_rd && !tas_run_r && !tas_after_write_r;

    // -----------------------------------------------------------------------
    // Phase 52: FPU coprocessor bus interface outputs
    // eu_coproc_req asserted while fpu_run_r; CPI read (rw=1) of cpid=1 register 0.
    // Address: A[31:20]=0, A[19:16]=0010, A[15:13]=ppp, A[12:11]=01 (cpid=1), A[10:0]=0.
    // -----------------------------------------------------------------------
    assign eu_coproc_req   = fpu_run_r;
    assign eu_coproc_rw    = 1'b1;
    assign eu_coproc_fc    = 3'b111;        // CPU Space
    assign eu_coproc_siz   = 2'b00;         // longword
    assign eu_coproc_wdata = 32'h0;
    assign eu_coproc_addr  = {12'h000, 4'b0010, fpu_prim_r, 2'b01, 11'h000};

    // -----------------------------------------------------------------------
    // Phase 46: MOVEC Rn→Rc write outputs — fire from WB stage
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
    assign usp_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h800);
    assign usp_wr_data = wb_result;
    assign isp_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h804);
    assign isp_wr_data = wb_result;
    assign msp_wr_en   = wb_valid && wb_is_movec_wr && (wb_movec_rc == 12'h803);
    assign msp_wr_data = wb_result;

    // -----------------------------------------------------------------------
    // Phase 54: MMU instruction output assignments
    // -----------------------------------------------------------------------
    assign eu_pflush_req = pflush_req_r;
    assign eu_pflush_all = pflush_all_r;
    assign eu_pflush_fc  = pflush_fc_r;
    assign eu_pflush_va  = pflush_va_r;
    assign eu_ptest_req  = ptest_run_r;
    assign eu_ptest_va   = ptest_va_r;
    assign eu_ptest_fc   = ptest_fc_r;
    assign tc_out        = tc_r;
    assign tt0_out       = tt0_r;
    assign tt1_out       = tt1_r;

endmodule

`default_nettype wire
