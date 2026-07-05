`default_nettype none

// MC68030 Micro-sequencer — purely combinational glue between IFU and EU.
//
// Responsibilities:
//   1. Decode instruction word count (opcode + 0/1/2 extension words).
//   2. Convert IFU ext_data format → EU format:
//        IFU: {q[1], q[2]} = {first_ext_word[15:0], second_ext_word[15:0]}
//        EU:  immediate in low bits (zero-extended)
//        Byte/word immediate  → {16'h0, first_ext_word}
//        Long immediate (32b) → {first_ext_word, second_ext_word} (= ifu_ext_data as-is)
//        Bit number (BTST…)   → {16'h0, first_ext_word}
//   3. Drive IFU drain: advance queue by (1 + ext_count) words when EU accepts.
//   4. Pass instr_word / instr_valid / ext_valid to EU unchanged
//      (EU handles its own need_ext stall when ext_valid=0).
//
// Extension-word count rule (register-direct EA, current scope):
//   Group 0000, f_dir=0, f_mode=000 — ALL need ≥1 extension word:
//     f_dn=100 (bit ops imm):  1 ext word (bit number)
//     f_dn≠100, f_ss=10 (long):  2 ext words (32-bit immediate)
//     f_dn≠100, f_ss≠10 (byte/word): 1 ext word
//   All other supported groups: 0 ext words
//
// IFU ext_valid uses the q_cnt≥3 threshold from m68030_ifu.  This is
// conservative for 1-extension-word instructions (q_cnt≥2 would suffice),
// but is always correct: EU stalls on need_ext until ext_valid rises.

module m68030_seq (
    // From m68030_ifu
    input  logic [15:0] instr_word,       // q[0] — current opcode word
    input  logic [31:0] ifu_ext_data,     // {q[1],q[2]} — two extension words
    input  logic        instr_valid,      // IFU has ≥1 word (q_cnt ≥ 1)
    input  logic        ifu_ext_valid,    // IFU has ≥3 words (q_cnt ≥ 3)
    output logic [1:0]  drain,            // words to remove from IFU queue

    // To m68030_eu
    output logic [15:0] eu_instr_word,
    output logic [31:0] eu_ext_data,      // immediate in low bits (EU convention)
    output logic        eu_instr_valid,
    output logic        eu_ext_valid,

    // From m68030_eu
    input  logic        eu_instr_ack,     // EU accepted instruction this cycle
    input  logic        eu_busy           // EU pipeline stalled (informational)
);

    // -----------------------------------------------------------------------
    // Pre-extract instruction fields
    // -----------------------------------------------------------------------
    logic [3:0] f_group;  assign f_group = instr_word[15:12];
    logic [2:0] f_dn;     assign f_dn    = instr_word[11:9];
    logic       f_dir;    assign f_dir   = instr_word[8];
    logic [1:0] f_ss;     assign f_ss    = instr_word[7:6];
    logic [2:0] f_mode;   assign f_mode  = instr_word[5:3];

    // -----------------------------------------------------------------------
    // Extension-word count (0, 1, or 2)
    // -----------------------------------------------------------------------
    // Group 0000, f_dir=0, Dn-direct EA: immediate ops need extension words
    logic is_imm_g0;
    assign is_imm_g0 = (f_group == 4'h0) && (!f_dir) && (f_mode == 3'b000);

    // Group 0101, f_ss=11, f_mode=001: DBcc Dn, d16 needs 1 extension word
    logic is_dbcc;
    assign is_dbcc = (f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b001);

    // Group 0110: BRA.W/Bcc.W (disp8=0x00) needs 1; BRA.L/Bcc.L (disp8=0xFF) needs 2
    logic [7:0] f_disp8_s;
    assign f_disp8_s = instr_word[7:0];
    logic is_branch_w, is_branch_l;
    assign is_branch_w = (f_group == 4'h6) && (instr_word[11:8] != 4'h1) && (f_disp8_s == 8'h00);
    assign is_branch_l = (f_group == 4'h6) && (instr_word[11:8] != 4'h1) && (f_disp8_s == 8'hFF);

    // Groups 1/2/3 (MOVE/MOVEA): (d16,An) src mode = f_mode=101; dst mode = {f_dir,f_ss}=101
    logic [2:0] f_move_dst_mode_s;
    assign f_move_dst_mode_s = {f_dir, f_ss};  // instr_word[8:6] for MOVE dst EA
    logic is_move_d16;
    assign is_move_d16 = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                         ((f_mode == 3'b101) || (f_move_dst_mode_s == 3'b101));

    // Group 4, LEA with (d16,An): f_dir=1, f_ss=11, f_mode=101
    logic is_lea_d16;
    assign is_lea_d16 = (f_group == 4'h4) && f_dir && (f_ss == 2'b11) && (f_mode == 3'b101);

    logic [1:0] ext_count;
    always_comb begin
        if (is_imm_g0)
            ext_count = ((f_dn != 3'b100) && (f_ss == 2'b10)) ? 2'd2 : 2'd1;
        else if (is_branch_l)
            ext_count = 2'd2;
        else if (is_branch_w || is_dbcc || is_move_d16 || is_lea_d16)
            ext_count = 2'd1;
        else
            ext_count = 2'd0;
    end

    // -----------------------------------------------------------------------
    // IFU drain: advance queue when EU accepts the instruction
    // -----------------------------------------------------------------------
    assign drain = eu_instr_ack ? (2'd1 + ext_count) : 2'd0;

    // -----------------------------------------------------------------------
    // EU ext_data format conversion
    //   2-ext-word (long imm, BRA.L): full 32-bit value unchanged
    //   1-ext-word (byte/word imm, bit#, BRA.W, DBcc d16): first ext word in [15:0]
    // EU reads: byte/word imm → ext_data[15:0]; long imm/BRA.L → ext_data[31:0]
    // -----------------------------------------------------------------------
    assign eu_ext_data = (ext_count == 2'd2) ? ifu_ext_data
                                              : {16'h0, ifu_ext_data[31:16]};

    // -----------------------------------------------------------------------
    // Pass-through to EU
    // -----------------------------------------------------------------------
    assign eu_instr_word  = instr_word;
    assign eu_instr_valid = instr_valid;
    assign eu_ext_valid   = ifu_ext_valid;

endmodule

`default_nettype wire
