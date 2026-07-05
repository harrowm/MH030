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

    // ── Address register update port (for (An)+ and -(An)) ──────────────────
    output logic        an_wr_en,
    output logic [2:0]  an_wr_sel,
    output logic [31:0] an_wr_data
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
                    end
                end

                // ----------------------------------------------------------------
                // Group 0100: NEG/NEGX/NOT/CLR/TST / SWAP / EXT / NOP
                // ----------------------------------------------------------------
                4'h4: begin
                    if (f_mode == 3'b000) begin
                        if (f_ss != 2'b11) begin
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
                        end else begin
                            // f_ss==11, f_mode==000: EXT.L (f_dir=0) / EXTB.L (f_dir=1)
                            if (f_dn == 3'b100) begin
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
                        end
                    end else if (instr_word == 16'h4E71) begin
                        // NOP: 0100 1110 0111 0001
                        dec_valid = 1'b1;
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
                // Group 0110: BRA / Bcc (BSR f_cond=0001 not implemented)
                // ----------------------------------------------------------------
                4'h6: begin
                    if (f_cond != 4'h1) begin
                        dec_valid          = 1'b1;
                        dec_is_branch      = 1'b1;
                        dec_reads_ccr      = 1'b1;
                        dec_branch_cond    = f_cond;
                        if (f_disp8 == 8'h00) begin
                            // .W: 16-bit displacement in first ext word (low 16)
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = {{16{ext_data[15]}}, ext_data[15:0]};
                        end else if (f_disp8 == 8'hFF) begin
                            // .L: 32-bit displacement across two ext words
                            dec_needs_ext   = 1'b1;
                            dec_branch_disp = ext_data;
                        end else begin
                            // .B: signed 8-bit displacement in opcode word
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

    // -----------------------------------------------------------------------
    // Stall / hazard logic — checks both EX and WB for RAW conflicts.
    // 2 stall cycles cover EX→WB→regfile-commit latency.
    // ex_mem_stall: EX holds a memory op waiting for BIU ack.
    // -----------------------------------------------------------------------
    logic        ex_valid, ex_writes_reg, ex_updates_ccr;
    logic [3:0]  ex_dest_reg;
    logic        ex_is_mem_rd, ex_is_mem_wr, ex_is_lea, ex_is_movea_w;

    logic ex_mem_stall;
    assign ex_mem_stall = (ex_is_mem_rd || ex_is_mem_wr) && !mem_ack;

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
        end
    end

    // -----------------------------------------------------------------------
    // Drive functional unit inputs from EX stage + register file
    // For memory ops: rd_a/rd_b must provide full 32-bit values (An for EA
    // base, Dn for write data). Override siz to longword so no sign-extension.
    // -----------------------------------------------------------------------
    assign rd_a_sel = ex_src_reg;
    assign rd_a_siz = (ex_is_mem_rd || ex_is_mem_wr || ex_is_lea) ? 2'b00 : ex_siz;
    assign rd_b_sel = ex_dst_reg;
    assign rd_b_siz = ex_is_mem_wr ? 2'b00 : ex_siz;

    // EA computation: An base from rd_a (loads/LEA) or rd_b (stores).
    logic [31:0] ex_an_base;
    assign ex_an_base = ex_is_mem_wr ? rd_b_data : rd_a_data;

    logic [31:0] ex_ea;       // effective address for bus cycle or LEA result
    assign ex_ea = ex_an_base + ex_ea_offset;

    logic [31:0] ex_an_new;   // updated An value for (An)+ / -(An)
    assign ex_an_new = ex_an_base + ex_an_delta;

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
            default: ;
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
        end else if (ex_mem_stall) begin
            // Memory cycle in progress: drain WB (bubble).
            wb_valid        <= 1'b0;
            wb_writes_reg   <= 1'b0;
            wb_updates_ccr  <= 1'b0;
            wb_an_upd_en    <= 1'b0;
            wb_is_mem_rd    <= 1'b0;
            wb_is_movea_w   <= 1'b0;
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
            wb_result       <= ex_is_mem_rd ? mem_rdata
                             : ex_is_lea    ? ex_ea
                             :                ex_result;
            wb_ccr          <= {ex_x, ex_n, ex_z, ex_v, ex_c};
            wb_an_upd_en    <= ex_an_upd_en;
            wb_an_upd_reg   <= ex_an_upd_reg;
            wb_an_upd_new   <= ex_an_new;
            wb_is_mem_rd    <= ex_is_mem_rd;
            wb_is_movea_w   <= ex_is_movea_w;
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

    assign wr_en   = wb_valid && wb_writes_reg;
    assign wr_sel  = wb_dest_reg;
    assign wr_siz  = wb_siz;
    assign wr_data = wb_result_final;

    // An update port (post/pre-increment: fires in WB alongside or instead of wr_en)
    assign an_wr_en   = wb_valid && wb_an_upd_en;
    assign an_wr_sel  = wb_an_upd_reg;
    assign an_wr_data = wb_an_upd_new;

    // -----------------------------------------------------------------------
    // CCR / SR write outputs
    // For MOVE: replace the N bit with wb_move_n (sized MSB)
    // -----------------------------------------------------------------------
    logic [4:0] final_ccr;
    assign final_ccr = wb_is_move ? {wb_ccr[4], wb_move_n, wb_ccr[2:0]} : wb_ccr;

    assign sr_wr_en   = wb_valid && wb_updates_ccr;
    assign sr_wr_data = {sr_out[15:8], 3'b000, final_ccr};
    assign sr_ccr_only = 1'b1;

    // -----------------------------------------------------------------------
    // Divide-by-zero trap (combinational from EX stage)
    // -----------------------------------------------------------------------
    assign div_trap = ex_valid && (ex_unit == UNIT_DIV) && md_div_by_zero;

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

    assign branch_taken  = dec_branch_taken | ex_dbcc_taken;
    assign branch_target = dec_branch_taken ? (decode_pc     + 32'd2 + dec_branch_disp)
                                            : (ex_decode_pc  + 32'd2 + ex_dbcc_disp);

    // -----------------------------------------------------------------------
    // Memory bus outputs — driven from EX stage when a memory op is active.
    // -----------------------------------------------------------------------
    assign mem_req   = ex_valid && (ex_is_mem_rd || ex_is_mem_wr);
    assign mem_rw    = ex_is_mem_rd;     // 1=read, 0=write
    assign mem_siz   = ex_siz;
    assign mem_fc    = {sr_out[13], 1'b0, 1'b1};  // 001=user data, 101=supervisor data
    assign mem_addr  = ex_ea;
    assign mem_wdata = rd_a_data;        // Dn source for stores (rd_a_sel=Dn for stores)

endmodule

`default_nettype wire
