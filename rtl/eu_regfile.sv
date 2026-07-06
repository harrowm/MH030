`default_nettype none

module eu_regfile (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Combinational read port A (source operand 1)
    input  logic [3:0]  rd_a_sel,   // 0-7=D0-D7, 8-14=A0-A6, 15=A7
    input  logic [1:0]  rd_a_siz,   // 00=long, 01=byte, 10=word
    output logic [31:0] rd_a_data,

    // Combinational read port B (source operand 2)
    input  logic [3:0]  rd_b_sel,
    input  logic [1:0]  rd_b_siz,
    output logic [31:0] rd_b_data,

    // Write port (registered, takes effect next posedge)
    input  logic        wr_en,
    input  logic [3:0]  wr_sel,
    input  logic [1:0]  wr_siz,
    input  logic [31:0] wr_data,

    // PC
    input  logic        pc_wr_en,
    input  logic [31:0] pc_wr_data,
    output logic [31:0] pc_out,

    // SR  [15:14]=T1,T0  [13]=S  [12]=M  [11]=0  [10:8]=IPL  [7:0]=CCR
    input  logic        sr_wr_en,
    input  logic [15:0] sr_wr_data,
    input  logic        sr_ccr_only,   // 1 = update only SR[7:0]
    output logic [15:0] sr_out,

    // VBR
    input  logic        vbr_wr_en,
    input  logic [31:0] vbr_wr_data,
    output logic [31:0] vbr_out,

    // Stack pointer exposure for exception handler
    output logic [31:0] usp_out,
    output logic [31:0] msp_out,
    output logic [31:0] isp_out,

    // Convenience outputs
    output logic        supervisor,    // SR[13]
    output logic        master_mode,   // SR[12]
    output logic [2:0]  ipl_mask,      // SR[10:8]

    // Second write port — An update from (An)+ / -(An) (always longword)
    input  logic        an_wr_en,
    input  logic [2:0]  an_wr_sel,    // 0=A0..6=A6, 7=A7 (routes via S/M)
    input  logic [31:0] an_wr_data,

    // SFC / DFC — source/destination function codes (3 bits each)
    input  logic        sfc_wr_en,
    input  logic [2:0]  sfc_wr_data,
    output logic [2:0]  sfc_out,
    input  logic        dfc_wr_en,
    input  logic [2:0]  dfc_wr_data,
    output logic [2:0]  dfc_out,

    // CACR / CAAR — cache control registers (Phase 46: stored but not decoded)
    input  logic        cacr_wr_en,
    input  logic [31:0] cacr_wr_data,
    output logic [31:0] cacr_out,
    input  logic        caar_wr_en,
    input  logic [31:0] caar_wr_data,
    output logic [31:0] caar_out,

    // USP / ISP / MSP — explicit write ports (MOVEC bypasses S/M routing)
    input  logic        usp_wr_en,
    input  logic [31:0] usp_wr_data,
    input  logic        isp_wr_en,
    input  logic [31:0] isp_wr_data,
    input  logic        msp_wr_en,
    input  logic [31:0] msp_wr_data
);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    logic [31:0] d_reg [0:7];
    logic [31:0] a_reg [0:6];
    logic [31:0] usp_r, isp_r, msp_r;
    logic [31:0] pc_r;
    logic [15:0] sr_r;
    logic [31:0] vbr_r;
    logic [2:0]  sfc_r, dfc_r;
    logic [31:0] cacr_r, caar_r;

    // -----------------------------------------------------------------------
    // A7 routing (combinational; S=0 => USP regardless of M)
    // -----------------------------------------------------------------------
    logic [31:0] a7_current;
    assign a7_current = ({sr_r[13], sr_r[12]} == 2'b10) ? isp_r :
                        ({sr_r[13], sr_r[12]} == 2'b11) ? msp_r : usp_r;

    // -----------------------------------------------------------------------
    // SR write pre-computation
    // -----------------------------------------------------------------------
    logic [15:0] sr_next;
    logic [1:0]  sr_old_sm, sr_new_sm;
    assign sr_next   = sr_ccr_only ? {sr_r[15:8], sr_wr_data[7:0]} : sr_wr_data;
    assign sr_old_sm = {sr_r[13], sr_r[12]};
    assign sr_new_sm = {sr_next[13], sr_next[12]};

    // -----------------------------------------------------------------------
    // Combinational read ports — use assign + ternary to avoid always_comb
    // bit-select Icarus limitation ("sorry: constant selects")
    // -----------------------------------------------------------------------
    logic [31:0] rd_a_raw, rd_b_raw;
    logic        rd_a_is_addr, rd_b_is_addr;

    assign rd_a_is_addr = rd_a_sel[3];
    assign rd_a_raw     = !rd_a_sel[3] ? d_reg[rd_a_sel[2:0]] :
                          (rd_a_sel != 4'd15) ? a_reg[rd_a_sel[2:0]] : a7_current;
    assign rd_a_data    = (rd_a_siz == 2'b01) ?
                              (rd_a_is_addr ? {{24{rd_a_raw[7]}},  rd_a_raw[7:0]}
                                           : {24'b0,               rd_a_raw[7:0]}) :
                          (rd_a_siz == 2'b10) ?
                              (rd_a_is_addr ? {{16{rd_a_raw[15]}}, rd_a_raw[15:0]}
                                           : {16'b0,               rd_a_raw[15:0]}) :
                          rd_a_raw;

    assign rd_b_is_addr = rd_b_sel[3];
    assign rd_b_raw     = !rd_b_sel[3] ? d_reg[rd_b_sel[2:0]] :
                          (rd_b_sel != 4'd15) ? a_reg[rd_b_sel[2:0]] : a7_current;
    assign rd_b_data    = (rd_b_siz == 2'b01) ?
                              (rd_b_is_addr ? {{24{rd_b_raw[7]}},  rd_b_raw[7:0]}
                                           : {24'b0,               rd_b_raw[7:0]}) :
                          (rd_b_siz == 2'b10) ?
                              (rd_b_is_addr ? {{16{rd_b_raw[15]}}, rd_b_raw[15:0]}
                                           : {16'b0,               rd_b_raw[15:0]}) :
                          rd_b_raw;

    // -----------------------------------------------------------------------
    // D0-D7: byte/word writes preserve upper bits
    // -----------------------------------------------------------------------
    generate
        genvar gi;
        for (gi = 0; gi < 8; gi++) begin : g_dreg
            always_ff @(posedge clk_4x or negedge rst_n) begin
                if (!rst_n)
                    d_reg[gi] <= 32'h0;
                else if (wr_en && (wr_sel == gi)) begin
                    case (wr_siz)
                        2'b01: d_reg[gi] <= {d_reg[gi][31:8],  wr_data[7:0]};
                        2'b10: d_reg[gi] <= {d_reg[gi][31:16], wr_data[15:0]};
                        default: d_reg[gi] <= wr_data;
                    endcase
                end
            end
        end

        // A0-A6: byte/word writes sign-extend to 32 bits; an_wr is always longword
        for (gi = 0; gi < 7; gi++) begin : g_areg
            always_ff @(posedge clk_4x or negedge rst_n) begin
                if (!rst_n)
                    a_reg[gi] <= 32'h0;
                else if (wr_en && (wr_sel == (gi + 8))) begin
                    case (wr_siz)
                        2'b01: a_reg[gi] <= {{24{wr_data[7]}},  wr_data[7:0]};
                        2'b10: a_reg[gi] <= {{16{wr_data[15]}}, wr_data[15:0]};
                        default: a_reg[gi] <= wr_data;
                    endcase
                end else if (an_wr_en && (an_wr_sel == gi[2:0])) begin
                    a_reg[gi] <= an_wr_data;
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Stack pointers + SR (combined block for atomic switch)
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            usp_r <= 32'h0;
            isp_r <= 32'h0;
            msp_r <= 32'h0;
            sr_r  <= 16'h2700;   // supervisor, IPL=7 at reset
        end else begin
            // an_wr for A7 (always longword, uses current S/M routing)
            if (an_wr_en && (an_wr_sel == 3'b111)) begin
                case (sr_old_sm)
                    2'b10: isp_r <= an_wr_data;
                    2'b11: msp_r <= an_wr_data;
                    default: usp_r <= an_wr_data;
                endcase
            end

            // A7 write (wr_sel == 15) — main port takes priority
            if (wr_en && (wr_sel == 4'd15)) begin
                case (sr_old_sm)
                    2'b10: begin   // ISP active
                        case (wr_siz)
                            2'b01: isp_r <= {{24{wr_data[7]}},  wr_data[7:0]};
                            2'b10: isp_r <= {{16{wr_data[15]}}, wr_data[15:0]};
                            default: isp_r <= wr_data;
                        endcase
                    end
                    2'b11: begin   // MSP active
                        case (wr_siz)
                            2'b01: msp_r <= {{24{wr_data[7]}},  wr_data[7:0]};
                            2'b10: msp_r <= {{16{wr_data[15]}}, wr_data[15:0]};
                            default: msp_r <= wr_data;
                        endcase
                    end
                    default: begin // USP active (S=0)
                        case (wr_siz)
                            2'b01: usp_r <= {{24{wr_data[7]}},  wr_data[7:0]};
                            2'b10: usp_r <= {{16{wr_data[15]}}, wr_data[15:0]};
                            default: usp_r <= wr_data;
                        endcase
                    end
                endcase
            end

            // SR write — save current A7 if mode changes, then update SR
            if (sr_wr_en) begin
                if (sr_old_sm != sr_new_sm) begin
                    case (sr_old_sm)
                        2'b10:   isp_r <= a7_current;
                        2'b11:   msp_r <= a7_current;
                        default: usp_r <= a7_current;
                    endcase
                end
                sr_r <= sr_next;
            end

            // MOVEC explicit stack pointer writes — bypass S/M mode routing
            if (usp_wr_en) usp_r <= usp_wr_data;
            if (isp_wr_en) isp_r <= isp_wr_data;
            if (msp_wr_en) msp_r <= msp_wr_data;
        end
    end

    // -----------------------------------------------------------------------
    // PC and VBR
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)        pc_r <= 32'h0;
        else if (pc_wr_en) pc_r <= pc_wr_data;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)         vbr_r <= 32'h0;
        else if (vbr_wr_en) vbr_r <= vbr_wr_data;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            sfc_r  <= 3'h0;
            dfc_r  <= 3'h0;
            cacr_r <= 32'h0;
            caar_r <= 32'h0;
        end else begin
            if (sfc_wr_en)  sfc_r  <= sfc_wr_data;
            if (dfc_wr_en)  dfc_r  <= dfc_wr_data;
            if (cacr_wr_en) cacr_r <= cacr_wr_data;
            if (caar_wr_en) caar_r <= caar_wr_data;
        end
    end

    // -----------------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------------
    assign pc_out      = pc_r;
    assign sr_out      = sr_r;
    assign vbr_out     = vbr_r;
    assign usp_out     = usp_r;
    assign isp_out     = isp_r;
    assign msp_out     = msp_r;
    assign supervisor  = sr_r[13];
    assign master_mode = sr_r[12];
    assign ipl_mask    = sr_r[10:8];
    assign sfc_out     = sfc_r;
    assign dfc_out     = dfc_r;
    assign cacr_out    = cacr_r;
    assign caar_out    = caar_r;

endmodule

`default_nettype wire
