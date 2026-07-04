`default_nettype none

// MC68030 Address Generation Unit — purely combinational.
//
// Computes the effective address (EA) for all 68030 addressing modes except
// memory indirect (full extension word I/IS != 000), which requires a BIU
// memory read and is deferred to Phase 30 integration.
//
// Extension word format reference:
//   Brief (ext0[8]=0):  [15]=D/A [14:12]=Reg [11]=W/L [10:9]=Scale [8]=0 [7:0]=d8
//   Full  (ext0[8]=1):  [15]=D/A [14:12]=Reg [11]=W/L [10:9]=Scale [8]=1
//                        [7]=BS  [6]=IS [5:4]=BDsize [3]=0 [2:0]=I/IS
//
// All bit-selects on input signals are pre-extracted via assign to avoid
// Icarus 13 "sorry: constant selects in always_*" sensitivity issues.

module eu_agu (
    // EA specification from instruction decode
    input  logic [2:0]  mode,        // EA mode field [5:3] of instruction
    input  logic [2:0]  reg_field,   // EA reg  field [2:0] of instruction
    input  logic [1:0]  siz,         // transfer size: 00=long(4B), 01=byte(1B), 10=word(2B), 11=line(16B)

    // Full register file (caller provides after reading regfile)
    input  logic [31:0] an_in [0:7], // A0-A7
    input  logic [31:0] dn_in [0:7], // D0-D7
    input  logic [31:0] pc_in,       // current PC (address of first ext word)

    // Extension words from prefetch queue (up to 3 provided)
    input  logic [15:0] ext0,        // 1st extension word
    input  logic [15:0] ext1,        // 2nd extension word (abs.L MSW, or full-ext bd)
    input  logic [15:0] ext2,        // 3rd extension word (full-ext bd=long only)

    // Outputs
    output logic [31:0] ea_out,      // computed effective address
    output logic        is_direct,   // 1 = register direct (caller uses register, no bus cycle)
    output logic        is_an_dir,   // 1 = An direct; 0 = Dn direct (valid when is_direct)
    output logic [1:0]  ext_count,   // extension words consumed (0..3)

    // An pre/post update (for (An)+ and -(An) modes)
    output logic        an_upd_en,   // 1 = write an_upd_new to an_upd_reg
    output logic [2:0]  an_upd_reg,  // which An to update (= reg_field for std modes)
    output logic [31:0] an_upd_new   // new An value
);

    // -----------------------------------------------------------------------
    // Base register: An[reg_field]
    // -----------------------------------------------------------------------
    logic [31:0] an_base;
    assign an_base = an_in[reg_field];

    // -----------------------------------------------------------------------
    // Step size for (An)+ and -(An)
    // Byte access to A7 uses step=2 to maintain word alignment.
    // -----------------------------------------------------------------------
    logic        is_a7;   assign is_a7   = (reg_field == 3'b111);
    logic [31:0] step;
    assign step = (siz == 2'b11) ? 32'd16 :          // line
                  (siz == 2'b00) ? 32'd4  :          // long
                  (siz == 2'b10) ? 32'd2  :          // word
                  is_a7          ? 32'd2  : 32'd1;   // byte (A7→2, else 1)

    // -----------------------------------------------------------------------
    // Brief / full extension word field extraction (all via assign)
    // -----------------------------------------------------------------------
    logic        ext_da;     assign ext_da     = ext0[15];      // 0=Dn, 1=An
    logic [2:0]  ext_xreg;   assign ext_xreg   = ext0[14:12];   // index register number
    logic        ext_wl;     assign ext_wl     = ext0[11];      // 0=sign-extend to W, 1=long
    logic [1:0]  ext_scale;  assign ext_scale  = ext0[10:9];    // 00=1x 01=2x 10=4x 11=8x
    logic        is_full;    assign is_full     = ext0[8];       // 0=brief, 1=full
    logic [7:0]  brief_d8;   assign brief_d8   = ext0[7:0];

    // Full extension word additional fields
    logic        full_bs;    assign full_bs    = ext0[7];       // base suppress
    logic        full_is;    assign full_is    = ext0[6];       // index suppress
    logic [1:0]  full_bdsz;  assign full_bdsz  = ext0[5:4];    // 01=null 10=word 11=long
    logic [2:0]  full_iis;   assign full_iis   = ext0[2:0];    // indirect selection (000=none)

    // -----------------------------------------------------------------------
    // Index register selection and scaling
    // -----------------------------------------------------------------------
    logic [31:0] xn_sel;
    assign xn_sel  = ext_da ? an_in[ext_xreg] : dn_in[ext_xreg];

    // Word-sign-extend if W/L=0; otherwise use full 32 bits
    logic [31:0] xn_ext;
    assign xn_ext  = ext_wl ? xn_sel : {{16{xn_sel[15]}}, xn_sel[15:0]};

    // Apply scale
    logic [31:0] xn_sc;
    assign xn_sc   = (ext_scale == 2'b00) ? xn_ext              :
                     (ext_scale == 2'b01) ? {xn_ext[30:0], 1'b0} :
                     (ext_scale == 2'b10) ? {xn_ext[29:0], 2'b00} :
                                            {xn_ext[28:0], 3'b000};

    // -----------------------------------------------------------------------
    // Sign-extended displacements
    // -----------------------------------------------------------------------
    logic [31:0] d8_sx;    assign d8_sx   = {{24{brief_d8[7]}}, brief_d8};
    logic [31:0] d16_sx;   assign d16_sx  = {{16{ext0[15]}}, ext0};

    // -----------------------------------------------------------------------
    // Absolute addressing
    // -----------------------------------------------------------------------
    logic [31:0] abs_short; assign abs_short = {{16{ext0[15]}}, ext0};
    logic [31:0] abs_long;  assign abs_long  = {ext0, ext1};

    // -----------------------------------------------------------------------
    // Brief extension word EA
    //   EA = base + xn_sc + d8_sx   (base = An or PC)
    // -----------------------------------------------------------------------
    logic [31:0] brief_ea_an; assign brief_ea_an = an_base + xn_sc + d8_sx;
    logic [31:0] brief_ea_pc; assign brief_ea_pc = pc_in   + xn_sc + d8_sx;

    // -----------------------------------------------------------------------
    // Full extension word: base displacement
    //   BDsize: 01=null(0), 10=word(sign-ext ext1), 11=long({ext1,ext2})
    // -----------------------------------------------------------------------
    logic [31:0] full_bd;
    assign full_bd = (full_bdsz == 2'b10) ? {{16{ext1[15]}}, ext1} :
                     (full_bdsz == 2'b11) ? {ext1, ext2}           :
                                             32'h0;                  // null or reserved

    // Extension word count for full ext mode
    logic [1:0]  full_ec;
    assign full_ec = (full_bdsz == 2'b11) ? 2'd3 :   // long bd: ext0 + ext1 + ext2
                     (full_bdsz == 2'b10) ? 2'd2 :   // word bd: ext0 + ext1
                                             2'd1;    // null bd: ext0 only

    // Full EA components
    logic [31:0] full_base_an; assign full_base_an = full_bs ? 32'h0 : an_base;
    logic [31:0] full_base_pc; assign full_base_pc = full_bs ? 32'h0 : pc_in;
    logic [31:0] full_idx;     assign full_idx      = full_is ? 32'h0 : xn_sc;

    logic [31:0] full_ea_an;   assign full_ea_an    = full_base_an + full_idx + full_bd;
    logic [31:0] full_ea_pc;   assign full_ea_pc    = full_base_pc + full_idx + full_bd;

    // -----------------------------------------------------------------------
    // Output mux — uses only pre-extracted signals, no bit-selects inside
    // -----------------------------------------------------------------------
    always_comb begin
        ea_out      = 32'h0;
        is_direct   = 1'b0;
        is_an_dir   = 1'b0;
        ext_count   = 2'd0;
        an_upd_en   = 1'b0;
        an_upd_reg  = reg_field;
        an_upd_new  = 32'h0;

        case (mode)

            3'b000: begin   // Dn — data register direct
                is_direct = 1'b1;
                is_an_dir = 1'b0;
            end

            3'b001: begin   // An — address register direct
                is_direct = 1'b1;
                is_an_dir = 1'b1;
            end

            3'b010: begin   // (An)
                ea_out = an_base;
            end

            3'b011: begin   // (An)+
                ea_out     = an_base;
                an_upd_en  = 1'b1;
                an_upd_reg = reg_field;
                an_upd_new = an_base + step;
            end

            3'b100: begin   // -(An)
                ea_out     = an_base - step;
                an_upd_en  = 1'b1;
                an_upd_reg = reg_field;
                an_upd_new = an_base - step;
            end

            3'b101: begin   // (d16,An)
                ea_out    = an_base + d16_sx;
                ext_count = 2'd1;
            end

            3'b110: begin   // (brief,An) or (full,An)
                if (!is_full) begin
                    ea_out    = brief_ea_an;
                    ext_count = 2'd1;
                end else begin
                    ea_out    = full_ea_an;
                    ext_count = full_ec;
                    // Memory indirect (full_iis != 0): caller must handle BIU read.
                    // ea_out is the intermediate address; caller detects via full_iis.
                end
            end

            3'b111: begin
                case (reg_field)
                    3'b000: begin   // (xxx).W — absolute short (sign-extended)
                        ea_out    = abs_short;
                        ext_count = 2'd1;
                    end
                    3'b001: begin   // (xxx).L — absolute long
                        ea_out    = abs_long;
                        ext_count = 2'd2;
                    end
                    3'b010: begin   // (d16,PC)
                        ea_out    = pc_in + d16_sx;
                        ext_count = 2'd1;
                    end
                    3'b011: begin   // (brief,PC) or (full,PC)
                        if (!is_full) begin
                            ea_out    = brief_ea_pc;
                            ext_count = 2'd1;
                        end else begin
                            ea_out    = full_ea_pc;
                            ext_count = full_ec;
                        end
                    end
                    default: begin  // 100=immediate (handled by decoder), 101-111=rsvd
                        ea_out = 32'hDEAD_BEEF;
                    end
                endcase
            end

            default: begin
                ea_out = 32'h0;
            end

        endcase
    end

    // Memory-indirect detection (caller reads ea_out as intermediate address then re-calls)
    // full_iis output lets caller know a BIU read is required before the final EA is known.
    // (Unused in Phase 29; wired in eu_seq Phase 30+ integration.)

endmodule

`default_nettype wire
