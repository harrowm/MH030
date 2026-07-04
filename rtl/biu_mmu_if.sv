`default_nettype none

// MC68030 BIU — MMU Interface (Phase 6)
// Implements:
//   - TT0/TT1 transparent translation (address bypass, no ATC)
//   - 22-entry fully-associative ATC (Address Translation Cache)
//   - 3-level table walker using the existing mmu_req port on cycle_gen
//
// TC register layout (68030 manual):
//   [31]    = E   (MMU enable)
//   [30]    = SRE (use SRP for supervisor FC[2]=1)
//   [27:24] = PS  (page size in bits: PS=12 → 4096-byte pages)
//   [23:20] = IS  (initial shift: skip IS bits from top of VA)
//   [19:16] = TIA (table index A field width in bits)
//   [15:12] = TIB (table index B field width in bits)
//   [11:8]  = TIC (table index C field width in bits)
//   [7:4]   = TID (table index D — unused in tests)
//
// TT register layout:
//   [31:24] = LAB (logical address base, VA[31:24])
//   [23:16] = LAM (address mask: 1 bits = don't care)
//   [15]    = E   (enable this TT register)
//   [13]    = CI  (cache inhibit for this range)
//   [7:5]   = FCM (function code mask)
//   [4:2]   = FCB (function code base)
//   [1]     = RWM (read/write mask)
//   [0]     = RW  (when RWM=1)
//
// Descriptor format (short, 4-byte):
//   [31:4] = base address (next table base or page frame base, 16B aligned)
//   [3]    = CI (cache inhibit bit in page descriptor)
//   [1:0]  = DT: 00=invalid, 01=page(leaf), 10=table, 11=long-table(treat as table)

module biu_mmu_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Translation request
    input  logic [31:0] va,
    input  logic [2:0]  fc,
    input  logic        rw,
    input  logic        req,

    // Translation result (registered; hold until next req)
    output logic [31:0] pa,
    output logic        hit,        // ATC hit
    output logic        walk_done,  // TT bypass or walk complete
    output logic        fault,
    output logic        ci,

    // Bus port → cycle_gen mmu_req
    output logic [31:0] mmu_req_addr,
    output logic [2:0]  mmu_req_fc,
    output logic        mmu_req,
    input  logic [31:0] mmu_rdata,
    input  logic        mmu_ack,    // combinatorial, holds for 4 ticks at S7
    input  logic        mmu_berr,

    // Control registers
    input  logic [31:0] tc,
    input  logic [63:0] crp,        // [31:0] = lower longword used as root base
    input  logic [63:0] srp,
    input  logic [31:0] tt0,
    input  logic [31:0] tt1,

    output logic [15:0] mmusr,

    // PFLUSH — invalidate ATC entries (synchronous, 1-cycle ack)
    input  logic        pflush_req,
    input  logic        pflush_all,     // 0=single VA, 1=all matching FC
    input  logic [2:0]  pflush_fc,
    input  logic [31:0] pflush_va,
    output logic        pflush_ack
);

    // -----------------------------------------------------------------------
    // mmu_ack rising-edge detection (mmu_ack holds for 4 ticks in S7)
    // -----------------------------------------------------------------------
    logic mmu_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) mmu_ack_prev_r <= 1'b0;
        else        mmu_ack_prev_r <= mmu_ack;
    wire mmu_ack_rise = mmu_ack && !mmu_ack_prev_r;

    // -----------------------------------------------------------------------
    // TC field extraction
    // -----------------------------------------------------------------------
    wire        tc_e   = tc[31];
    wire [4:0]  ps     = {1'b0, tc[27:24]};   // page size in bits (e.g. 12 for 4KB)
    wire [4:0]  is_b   = {1'b0, tc[23:20]};   // initial shift
    wire [3:0]  tia    = tc[19:16];
    wire [3:0]  tib    = tc[15:12];
    wire [3:0]  tic    = tc[11:8];

    // Page mask (0 in page offset bits, 1 elsewhere)
    wire [31:0] page_mask = ~((32'h1 << ps) - 32'h1);

    // CRP/SRP base (use lower 32-bit, bits[31:4] give base >> 4)
    wire [31:0] crp_base = {crp[31:4], 4'h0};

    // -----------------------------------------------------------------------
    // TT match function
    // -----------------------------------------------------------------------
    function automatic logic tt_match(
        input logic [31:0] tt_r,
        input logic [31:0] va_in,
        input logic [2:0]  fc_in,
        input logic        rw_in
    );
        logic addr_m, fc_m, rw_m;
        addr_m = tt_r[15] &&
                 ((va_in[31:24] & ~tt_r[23:16]) == (tt_r[31:24] & ~tt_r[23:16]));
        fc_m   = (fc_in & ~tt_r[7:5]) == (tt_r[4:2] & ~tt_r[7:5]);
        rw_m   = !tt_r[1] || (rw_in == tt_r[0]);
        tt_match = addr_m && fc_m && rw_m;
    endfunction

    // -----------------------------------------------------------------------
    // ATC (22-entry, fully associative, round-robin replacement)
    // -----------------------------------------------------------------------
    localparam int ATC_SIZE = 22;
    logic        atc_valid [0:ATC_SIZE-1];
    logic [31:0] atc_va    [0:ATC_SIZE-1];
    logic [2:0]  atc_fc    [0:ATC_SIZE-1];
    logic [31:0] atc_pa    [0:ATC_SIZE-1];
    logic        atc_ci    [0:ATC_SIZE-1];
    logic        atc_wp    [0:ATC_SIZE-1];
    logic [4:0]  atc_victim;
    logic        pflush_ack_r;

    // ATC lookup (fully associative, unrolled for loop)
    logic        atc_hit_found;
    logic [4:0]  atc_hit_idx;
    logic [31:0] atc_hit_pa;
    logic        atc_hit_ci;
    always_comb begin
        atc_hit_found = 1'b0;
        atc_hit_idx   = 5'd0;
        atc_hit_pa    = 32'h0;
        atc_hit_ci    = 1'b0;
        for (int i = 0; i < ATC_SIZE; i++) begin
            if (atc_valid[i] && (atc_fc[i] == fc) &&
                ((va & page_mask) == (atc_va[i] & page_mask))) begin
                atc_hit_found = 1'b1;
                atc_hit_idx   = 5'(i);
                atc_hit_pa    = (atc_pa[i] & page_mask) | (va & ~page_mask);
                atc_hit_ci    = atc_ci[i];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Walk index calculations (combinatorial, based on current va + latched state)
    // -----------------------------------------------------------------------
    // Field A: VA bits [31-IS : 31-IS-TIA+1]
    wire [4:0] fa_lo_w  = 5'd31 - is_b - {1'b0, tia} + 5'd1;
    wire [31:0] idx_a_w = (va >> fa_lo_w) & ((32'h1 << {1'b0, tia}) - 32'h1);
    wire [31:0] walk_a_addr_w = crp_base + (idx_a_w << 2);

    // -----------------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------------
    typedef enum logic [2:0] {
        MS_IDLE      = 3'd0,
        MS_TT_HIT    = 3'd1,
        MS_ATC_HIT   = 3'd2,
        MS_WALK_A    = 3'd3,
        MS_WALK_B    = 3'd4,
        MS_WALK_C    = 3'd5,
        MS_WALK_DONE = 3'd6,
        MS_FAULT     = 3'd7
    } ms_state_t;

    ms_state_t ms_state;

    // Walk registers
    logic [31:0] walk_va_r;
    logic [2:0]  walk_fc_r;
    logic        walk_rw_r;
    logic [31:0] walk_desc_r;     // last read descriptor
    logic [31:0] walk_req_addr_r; // address to issue in current walk state
    logic [4:0]  fa_lo_r;         // latched fa_lo for B index computation
    logic [31:0] walk_pa_r;
    logic        walk_ci_r;
    logic        walk_wp_r;

    // Latched outputs (hold until next req)
    logic [31:0] pa_r;
    logic        ci_r;
    logic        hit_r, walk_done_r, fault_r;

    integer m;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ms_state       <= MS_IDLE;
            pa_r           <= 32'h0;
            ci_r           <= 1'b0;
            hit_r          <= 1'b0;
            walk_done_r    <= 1'b0;
            fault_r        <= 1'b0;
            atc_victim      <= 5'd0;
            walk_req_addr_r <= 32'h0;
            fa_lo_r         <= 5'd22;
            pflush_ack_r    <= 1'b0;
            for (m = 0; m < ATC_SIZE; m++) begin
                atc_valid[m] <= 1'b0;
                atc_ci[m]    <= 1'b0;
                atc_wp[m]    <= 1'b0;
            end
        end else begin
            // Default: clear one-cycle pulse outputs
            hit_r        <= 1'b0;
            walk_done_r  <= 1'b0;
            fault_r      <= 1'b0;
            pflush_ack_r <= 1'b0;

            case (ms_state)
                MS_IDLE: begin
                    if (pflush_req) begin
                        // Invalidate matching ATC entries; ack next cycle
                        for (int i = 0; i < ATC_SIZE; i++) begin
                            if (pflush_all
                                    ? (atc_fc[i] == pflush_fc)
                                    : (atc_fc[i] == pflush_fc &&
                                       (atc_va[i] & page_mask) ==
                                       (pflush_va  & page_mask)))
                                atc_valid[i] <= 1'b0;
                        end
                        pflush_ack_r <= 1'b1;
                    end else if (req) begin
                        walk_va_r  <= va;
                        walk_fc_r  <= fc;
                        walk_rw_r  <= rw;

                        if (!tc_e) begin
                            // MMU disabled: identity mapping
                            pa_r     <= va;
                            ci_r     <= 1'b0;
                            ms_state <= MS_TT_HIT;
                        end else if (tt_match(tt0, va, fc, rw)) begin
                            pa_r     <= va;
                            ci_r     <= tt0[13];
                            ms_state <= MS_TT_HIT;
                        end else if (tt_match(tt1, va, fc, rw)) begin
                            pa_r     <= va;
                            ci_r     <= tt1[13];
                            ms_state <= MS_TT_HIT;
                        end else if (atc_hit_found) begin
                            pa_r     <= atc_hit_pa;
                            ci_r     <= atc_hit_ci;
                            ms_state <= MS_ATC_HIT;
                        end else begin
                            // ATC miss → start table walk level A
                            walk_req_addr_r <= walk_a_addr_w;
                            fa_lo_r         <= fa_lo_w;
                            ms_state        <= MS_WALK_A;
                        end
                    end
                end

                MS_TT_HIT: begin
                    walk_done_r <= 1'b1;
                    ms_state    <= MS_IDLE;
                end

                MS_ATC_HIT: begin
                    hit_r    <= 1'b1;
                    ms_state <= MS_IDLE;
                end

                MS_WALK_A: begin
                    if (mmu_berr) begin
                        fault_r  <= 1'b1;
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        walk_desc_r <= mmu_rdata;
                        case (mmu_rdata[1:0])
                            2'b00: begin  // invalid descriptor
                                fault_r  <= 1'b1;
                                ms_state <= MS_FAULT;
                            end
                            2'b01: begin  // page descriptor (leaf at level A)
                                walk_pa_r  <= (mmu_rdata & page_mask) |
                                              (walk_va_r & ~page_mask);
                                walk_ci_r  <= mmu_rdata[3];
                                walk_wp_r  <= mmu_rdata[2];
                                ms_state   <= MS_WALK_DONE;
                            end
                            default: begin  // 2'b10 or 2'b11: table descriptor
                                if (tib == 4'h0) begin
                                    // No level B defined → use current descriptor as leaf
                                    walk_pa_r  <= ({mmu_rdata[31:4], 4'h0} & page_mask) |
                                                  (walk_va_r & ~page_mask);
                                    walk_ci_r  <= 1'b0;
                                    walk_wp_r  <= 1'b0;
                                    ms_state   <= MS_WALK_DONE;
                                end else begin
                                    // Compute level B address
                                    begin
                                        logic [4:0]  fb_lo;
                                        logic [31:0] idx_b;
                                        logic [31:0] next_base;
                                        fb_lo    = fa_lo_r - {1'b0, tib};
                                        idx_b    = (walk_va_r >> fb_lo) &
                                                   ((32'h1 << {1'b0, tib}) - 32'h1);
                                        next_base = {mmu_rdata[31:4], 4'h0};
                                        walk_req_addr_r <= next_base + (idx_b << 2);
                                    end
                                    ms_state <= MS_WALK_B;
                                end
                            end
                        endcase
                    end
                end

                MS_WALK_B: begin
                    if (mmu_berr) begin
                        fault_r  <= 1'b1;
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        walk_desc_r <= mmu_rdata;
                        case (mmu_rdata[1:0])
                            2'b00: begin
                                fault_r  <= 1'b1;
                                ms_state <= MS_FAULT;
                            end
                            2'b01: begin  // page descriptor (leaf at level B)
                                walk_pa_r  <= (mmu_rdata & page_mask) |
                                              (walk_va_r & ~page_mask);
                                walk_ci_r  <= mmu_rdata[3];
                                walk_wp_r  <= mmu_rdata[2];
                                ms_state   <= MS_WALK_DONE;
                            end
                            default: begin  // table descriptor → level C
                                if (tic == 4'h0) begin
                                    walk_pa_r  <= ({mmu_rdata[31:4], 4'h0} & page_mask) |
                                                  (walk_va_r & ~page_mask);
                                    walk_ci_r  <= 1'b0;
                                    walk_wp_r  <= 1'b0;
                                    ms_state   <= MS_WALK_DONE;
                                end else begin
                                    begin
                                        logic [4:0]  fc_lo;
                                        logic [31:0] idx_c;
                                        logic [31:0] next_base;
                                        fc_lo    = fa_lo_r - {1'b0, tib} - {1'b0, tic};
                                        idx_c    = (walk_va_r >> fc_lo) &
                                                   ((32'h1 << {1'b0, tic}) - 32'h1);
                                        next_base = {mmu_rdata[31:4], 4'h0};
                                        walk_req_addr_r <= next_base + (idx_c << 2);
                                    end
                                    ms_state <= MS_WALK_C;
                                end
                            end
                        endcase
                    end
                end

                MS_WALK_C: begin
                    if (mmu_berr) begin
                        fault_r  <= 1'b1;
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        // Must be a page descriptor
                        if (mmu_rdata[1:0] == 2'b01) begin
                            walk_pa_r  <= (mmu_rdata & page_mask) |
                                          (walk_va_r & ~page_mask);
                            walk_ci_r  <= mmu_rdata[3];
                            walk_wp_r  <= mmu_rdata[2];
                            ms_state   <= MS_WALK_DONE;
                        end else begin
                            fault_r  <= 1'b1;
                            ms_state <= MS_FAULT;
                        end
                    end
                end

                MS_WALK_DONE: begin
                    // Load ATC entry
                    atc_valid[atc_victim] <= 1'b1;
                    atc_va[atc_victim]    <= walk_va_r;
                    atc_fc[atc_victim]    <= walk_fc_r;
                    atc_pa[atc_victim]    <= walk_pa_r;
                    atc_ci[atc_victim]    <= walk_ci_r;
                    atc_wp[atc_victim]    <= walk_wp_r;
                    atc_victim <= (atc_victim == 5'd21) ? 5'd0 : atc_victim + 5'd1;
                    // Output PA
                    pa_r        <= walk_pa_r;
                    ci_r        <= walk_ci_r;
                    walk_done_r <= 1'b1;
                    ms_state    <= MS_IDLE;
                end

                MS_FAULT: begin
                    fault_r  <= 1'b1;
                    ms_state <= MS_IDLE;
                end

                default: ms_state <= MS_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------------
    assign pa        = pa_r;
    assign ci        = ci_r;
    assign hit       = hit_r;
    assign walk_done = walk_done_r;
    assign fault     = fault_r;
    assign pflush_ack = pflush_ack_r;
    assign mmusr     = 16'h0;  // Phase 6: basic placeholder

    // mmu_req: assert while issuing walk read cycles
    assign mmu_req      = (ms_state == MS_WALK_A) ||
                          (ms_state == MS_WALK_B) ||
                          (ms_state == MS_WALK_C);
    assign mmu_req_addr = walk_req_addr_r;
    assign mmu_req_fc   = 3'b101;  // supervisor data space for all walk cycles

endmodule

`default_nettype wire
