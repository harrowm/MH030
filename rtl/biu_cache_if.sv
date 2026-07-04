`default_nettype none

// MC68030 BIU — Cache Interface (Phase 6)
// Implements I-cache + D-cache hit/miss detection and linefill sequencing.
// On I-cache miss (EI+IBE): issues 4 sequential longword reads (linefill).
// On D-cache read miss (ED): issues 1 longword read, stores one word.
// On any write (ED): write-through — always issues write to bus; updates cache on hit.
// Cache inhibit (mmu_ci): bypasses cache allocation even if enabled.

module biu_cache_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // EU side
    input  logic [31:0] eu_addr,
    input  logic [2:0]  eu_fc,
    input  logic        eu_rw,         // 1=read, 0=write
    input  logic [1:0]  eu_siz,
    input  logic [31:0] eu_wdata,
    input  logic        eu_req,
    input  logic        eu_is_icache,  // 1=use I-cache, 0=use D-cache
    output logic [31:0] eu_rdata,
    output logic        eu_ack,
    output logic        eu_berr,

    // Cache Inhibit from MMU
    input  logic        mmu_ci,

    // Sizing-FSM side (for miss / write cycles)
    output logic [31:0] sf_addr,
    output logic [2:0]  sf_fc,
    output logic        sf_rw,
    output logic [1:0]  sf_siz,
    output logic [31:0] sf_wdata,
    output logic        sf_is_op,
    output logic        sf_req,
    input  logic [31:0] sf_rdata,
    input  logic        sf_ack,    // 1-tick pulse from sizing_fsm SS_DONE
    input  logic        sf_berr,

    // Control registers (written by EU via MOVEC)
    input  logic [31:0] cacr,
    input  logic [31:0] caar
);

    // CACR bit aliases
    wire icache_en = cacr[0];
    wire iburst_en = cacr[4];
    wire dcache_en = cacr[9];

    // Cache storage arrays
    logic        valid_i [0:15];
    logic [23:0] tag_i   [0:15];
    logic [31:0] data_i  [0:15][0:3];

    logic        valid_d [0:15];
    logic [23:0] tag_d   [0:15];
    logic [31:0] data_d  [0:15][0:3];

    // sf_ack is a 1-tick pulse — edge detect is same as raw, but kept for safety
    logic sf_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) sf_ack_prev_r <= 1'b0;
        else        sf_ack_prev_r <= sf_ack;
    wire sf_ack_rise = sf_ack && !sf_ack_prev_r;

    // State machine
    typedef enum logic [3:0] {
        CI_IDLE   = 4'd0,
        CI_HIT    = 4'd1,
        CI_FILL_0 = 4'd2,
        CI_FILL_1 = 4'd3,
        CI_FILL_2 = 4'd4,
        CI_FILL_3 = 4'd5,
        CI_D_MISS = 4'd6,
        CI_WRITE  = 4'd7,
        CI_DONE   = 4'd8
    } ci_state_t;

    ci_state_t state;

    // Latched request parameters
    logic [31:0] addr_r, wdata_r, fill_base_r;
    logic [2:0]  fc_r;
    logic        rw_r;
    logic [1:0]  siz_r;
    logic        is_icache_r;
    logic [3:0]  idx_r;
    logic [1:0]  woff_r;
    logic [23:0] vtag_r;
    logic [31:0] fill_rdata_r;  // captured rdata for CI_DONE return

    // Combinatorial hit detection (in CI_IDLE, before latching)
    wire [3:0]  idx  = eu_addr[7:4];
    wire [1:0]  woff = eu_addr[3:2];
    wire [23:0] vtag = eu_addr[31:8];
    wire ihit = icache_en && valid_i[idx] && (tag_i[idx] == vtag) && !mmu_ci;
    wire dhit = dcache_en && valid_d[idx] && (tag_d[idx] == vtag) && !mmu_ci;

    // Also need dhit based on latched idx_r/vtag_r for write update in CI_WRITE
    wire dhit_r = dcache_en && valid_d[idx_r] && (tag_d[idx_r] == vtag_r) && !mmu_ci;

    integer k;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state       <= CI_IDLE;
            fill_rdata_r <= 32'h0;
            for (k = 0; k < 16; k++) begin
                valid_i[k] <= 1'b0;
                valid_d[k] <= 1'b0;
            end
        end else begin
            // CACR cache-clear operations (level-sensitive while bit asserted)
            if (cacr[3])  for (k = 0; k < 16; k++) valid_i[k] <= 1'b0; // CI
            if (cacr[12]) for (k = 0; k < 16; k++) valid_d[k] <= 1'b0; // CD
            if (cacr[2])  valid_i[caar[7:4]] <= 1'b0;  // CEI
            if (cacr[11]) valid_d[caar[7:4]] <= 1'b0;  // CED

            case (state)
                CI_IDLE: begin
                    if (eu_req) begin
                        addr_r      <= eu_addr;
                        wdata_r     <= eu_wdata;
                        fc_r        <= eu_fc;
                        rw_r        <= eu_rw;
                        siz_r       <= eu_siz;
                        is_icache_r <= eu_is_icache;
                        idx_r       <= idx;
                        woff_r      <= woff;
                        vtag_r      <= vtag;
                        fill_base_r <= {eu_addr[31:4], 4'h0};

                        if (!eu_rw) begin
                            state <= CI_WRITE;
                        end else if (eu_is_icache ? ihit : dhit) begin
                            // Cache hit — serve from cache array (idx_r/woff_r latched above)
                            state <= CI_HIT;
                        end else if (eu_is_icache && icache_en && iburst_en) begin
                            state <= CI_FILL_0;
                        end else begin
                            state <= CI_D_MISS;
                        end
                    end
                end

                CI_HIT: begin
                    // eu_ack fires combinatorially this cycle; return next cycle
                    state <= CI_IDLE;
                end

                CI_FILL_0: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][0] <= sf_rdata;
                        if (woff_r == 2'd0) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_1;
                    end
                end
                CI_FILL_1: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][1] <= sf_rdata;
                        if (woff_r == 2'd1) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_2;
                    end
                end
                CI_FILL_2: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][2] <= sf_rdata;
                        if (woff_r == 2'd2) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_3;
                    end
                end
                CI_FILL_3: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][3] <= sf_rdata;
                        if (woff_r == 2'd3) fill_rdata_r <= sf_rdata;
                        tag_i[idx_r]   <= vtag_r;
                        valid_i[idx_r] <= 1'b1;
                        state <= CI_DONE;
                    end
                end

                CI_D_MISS: begin
                    if (sf_ack_rise) begin
                        fill_rdata_r <= sf_rdata;
                        if (dcache_en && !mmu_ci) begin
                            data_d[idx_r][woff_r] <= sf_rdata;
                            tag_d[idx_r]          <= vtag_r;
                            valid_d[idx_r]        <= 1'b1;
                        end
                        state <= CI_DONE;
                    end
                end

                CI_WRITE: begin
                    if (sf_ack_rise) begin
                        // Write-through: if D-cache hit, update cache line too
                        if (dhit_r) begin
                            data_d[idx_r][woff_r] <= wdata_r;
                        end
                        state <= CI_DONE;
                    end
                end

                CI_DONE: begin
                    // eu_ack fires this cycle; return to idle
                    state <= CI_IDLE;
                end

                default: state <= CI_IDLE;
            endcase
        end
    end

    // Output logic
    always_comb begin
        eu_rdata = 32'h0;
        eu_ack   = 1'b0;
        eu_berr  = 1'b0;
        sf_addr  = addr_r;
        sf_fc    = fc_r;
        sf_rw    = rw_r;
        sf_siz   = siz_r;
        sf_wdata = wdata_r;
        sf_is_op = 1'b0;
        sf_req   = 1'b0;

        case (state)
            CI_HIT: begin
                // Serve directly from cache; no sf_req
                if (is_icache_r)
                    eu_rdata = data_i[idx_r][woff_r];
                else
                    eu_rdata = data_d[idx_r][woff_r];
                eu_ack = 1'b1;
            end

            CI_FILL_0: begin
                sf_addr = fill_base_r;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_1: begin
                sf_addr = fill_base_r + 32'd4;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_2: begin
                sf_addr = fill_base_r + 32'd8;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_3: begin
                sf_addr = fill_base_r + 32'd12;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end

            CI_D_MISS: begin
                sf_siz  = 2'b00;  // always fetch a full longword for cache fill
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end

            CI_WRITE: begin
                sf_rw   = 1'b0;
                sf_req  = !sf_ack;
            end

            CI_DONE: begin
                eu_rdata = fill_rdata_r;
                eu_ack   = 1'b1;
            end

            default: ;  // CI_IDLE: sf_req=0, eu_ack=0
        endcase
    end

endmodule

`default_nettype wire
