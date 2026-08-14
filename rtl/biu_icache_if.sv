`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Instruction Cache Interface
//
// Interposed between m68030_ifu's existing longword-fetch port and
// biu_cycle_gen's existing ifu_* port — same protocol on both sides, so
// this is a drop-in insertion (Phase 127, plan: cache correctness+timing).
// Read-only (no write state, unlike biu_cache_if.sv's combined I+D module).
//
// icache_en=0: pure combinational bypass, zero added latency, byte-for-byte
// identical to the pre-existing direct-to-cycle_gen IFU path (the mode
// every regression test has run in for the entire project until now).
//
// icache_en=1, hit: served from the cache array, no bus cycle at all.
// icache_en=1, miss: full 4-longword linefill (IC_FILL_0..3, one ordinary
// read cycle per word — genuine SIZ=11 pin-level bursts are a deferred
// follow-up, see plan.md), then the line is marked valid regardless of
// CACR's IBE (burst-enable) bit. This deliberately does NOT reproduce
// biu_cache_if.sv's own D-cache-side quirk, where an I-cache miss with
// IBE=0 falls through to a single-word fetch that never updates the I$
// array at all — IBE only ever meant "use burst pin protocol", not
// "whether the cache fills"; a non-burst-but-enabled miss must still fill.

module biu_icache_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // IFU side — identical protocol to the port m68030_ifu already drives
    input  logic [31:0] ifu_addr,
    input  logic        ifu_req,
    output logic [31:0] ifu_rdata,
    output logic        ifu_ack,
    output logic        ifu_berr,

    // biu_cycle_gen side — identical protocol to its existing ifu_* port
    output logic [31:0] cg_addr,
    output logic        cg_req,
    input  logic [31:0] cg_rdata,
    input  logic        cg_ack,    // 1-tick pulse
    input  logic        cg_berr,

    // Control registers (written by EU via MOVEC)
    input  logic [31:0] cacr,
    input  logic [31:0] caar
);

    // CACR bit aliases (shared encoding with biu_cache_if.sv)
    wire icache_en = cacr[0];
    // NOTE: cacr[4] (IBE) intentionally unused here — see header comment.

    // Cache storage: 16 lines x 4 longwords x 32 bits = 256 bytes.
    logic        valid_i [0:15];
    logic [23:0] tag_i   [0:15];
    logic [31:0] data_i  [0:15][0:3];

    // cg_ack is a 1-tick pulse — edge detect for safety (mirrors
    // biu_cache_if.sv's own sf_ack_rise technique).
    logic cg_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) cg_ack_prev_r <= 1'b0;
        else        cg_ack_prev_r <= cg_ack;
    wire cg_ack_rise = cg_ack && !cg_ack_prev_r;

    // Disabled-cache accesses never enter this state machine at all (see
    // the combinational bypass in the output block below), so there is no
    // dedicated "single passthrough fetch" state here.
    typedef enum logic [2:0] {
        IC_IDLE   = 3'd0,
        IC_HIT    = 3'd1,
        IC_FILL_0 = 3'd2,
        IC_FILL_1 = 3'd3,
        IC_FILL_2 = 3'd4,
        IC_FILL_3 = 3'd5,
        IC_DONE   = 3'd6
    } ic_state_t;
    // BERR is signalled via a dedicated flag rather than a separate state,
    // since a BERR-vs-normal IC_DONE would otherwise be identical except
    // for which output fires — kept as one "finishing" state to halve the
    // state space; see the output block below.
    ic_state_t state;
    logic      berr_r;

    logic [31:0] addr_r, fill_base_r, fill_rdata_r;
    logic [3:0]  idx_r;
    logic [1:0]  woff_r;
    logic [23:0] vtag_r;

    // cg_req/cg_addr are registered (not driven combinationally from
    // `state`), mirroring biu_sizing_fsm.sv's own documented reason for
    // existing: "one cycle of latency (registered to break combinatorial
    // loops with cycle_gen)". The raw IFU->cycle_gen wiring this module
    // replaces always drove biu_cycle_gen's ifu_* port from an
    // already-registered source (fetch_pend_r); a purely combinational
    // case(state)-driven cg_req here reproducibly hung biu_cycle_gen's
    // S6->S7 transition on the very first real linefill miss (found via
    // this project's own bisection-against-a-known-working-path
    // technique: an equivalent D-cache-enabled read via biu_cache_if.sv,
    // which *does* register through biu_sizing_fsm, completed cleanly).
    logic        cg_req_r;
    logic [31:0] cg_addr_r;

    wire [3:0]  idx  = ifu_addr[7:4];
    wire [1:0]  woff = ifu_addr[3:2];
    wire [23:0] vtag = ifu_addr[31:8];
    wire        ihit = icache_en && valid_i[idx] && (tag_i[idx] == vtag);

    integer k;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IC_IDLE;
            berr_r    <= 1'b0;
            cg_req_r  <= 1'b0;
            cg_addr_r <= 32'h0;
            for (k = 0; k < 16; k++) valid_i[k] <= 1'b0;
        end else begin
            // CACR cache-clear operations (level-sensitive while asserted,
            // same convention as biu_cache_if.sv).
            if (cacr[3]) for (k = 0; k < 16; k++) valid_i[k] <= 1'b0; // CI
            if (cacr[2]) valid_i[caar[7:4]] <= 1'b0;                  // CEI

            case (state)
                IC_IDLE: begin
                    // Only the enabled (state-machine-driven) path passes
                    // through IC_IDLE; the disabled path is a pure
                    // combinational bypass below and never touches `state`.
                    if (ifu_req && icache_en) begin
                        addr_r      <= ifu_addr;
                        idx_r       <= idx;
                        woff_r      <= woff;
                        vtag_r      <= vtag;
                        fill_base_r <= {ifu_addr[31:4], 4'h0};
                        if (ihit) begin
                            state <= IC_HIT;
                        end else begin
                            state     <= IC_FILL_0;
                            cg_req_r  <= 1'b1;
                            cg_addr_r <= {ifu_addr[31:4], 4'h0};
                        end
                    end
                end

                IC_HIT: state <= IC_IDLE; // eu-style: ack fires combinationally, one-shot

                IC_FILL_0: begin
                    if (cg_ack_rise) begin
                        data_i[idx_r][0] <= cg_rdata;
                        if (woff_r == 2'd0) fill_rdata_r <= cg_rdata;
                        state     <= IC_FILL_1;
                        cg_addr_r <= fill_base_r + 32'd4;
                    end else if (cg_berr) begin
                        berr_r   <= 1'b1;
                        state    <= IC_DONE;
                        cg_req_r <= 1'b0;
                    end
                end
                IC_FILL_1: begin
                    if (cg_ack_rise) begin
                        data_i[idx_r][1] <= cg_rdata;
                        if (woff_r == 2'd1) fill_rdata_r <= cg_rdata;
                        state     <= IC_FILL_2;
                        cg_addr_r <= fill_base_r + 32'd8;
                    end else if (cg_berr) begin
                        berr_r   <= 1'b1;
                        state    <= IC_DONE;
                        cg_req_r <= 1'b0;
                    end
                end
                IC_FILL_2: begin
                    if (cg_ack_rise) begin
                        data_i[idx_r][2] <= cg_rdata;
                        if (woff_r == 2'd2) fill_rdata_r <= cg_rdata;
                        state     <= IC_FILL_3;
                        cg_addr_r <= fill_base_r + 32'd12;
                    end else if (cg_berr) begin
                        berr_r   <= 1'b1;
                        state    <= IC_DONE;
                        cg_req_r <= 1'b0;
                    end
                end
                IC_FILL_3: begin
                    if (cg_ack_rise) begin
                        data_i[idx_r][3] <= cg_rdata;
                        if (woff_r == 2'd3) fill_rdata_r <= cg_rdata;
                        tag_i[idx_r]   <= vtag_r;
                        valid_i[idx_r] <= 1'b1;
                        state    <= IC_DONE;
                        cg_req_r <= 1'b0;
                    end else if (cg_berr) begin
                        berr_r   <= 1'b1;
                        state    <= IC_DONE;
                        cg_req_r <= 1'b0;
                    end
                end

                IC_DONE: begin
                    berr_r <= 1'b0;
                    state  <= IC_IDLE;
                end

                default: state <= IC_IDLE;
            endcase
        end
    end

    // Output logic — disabled path is a pure combinational bypass (zero
    // added latency vs. the pre-existing direct ifu->cycle_gen wiring);
    // enabled path's cg_req/cg_addr come from the registers driven above
    // (see their own declaration comment for why), everything else is
    // still simple combinational state decode.
    always_comb begin
        if (!icache_en) begin
            cg_addr   = ifu_addr;
            cg_req    = ifu_req;
            ifu_rdata = cg_rdata;
            ifu_ack   = cg_ack;
            ifu_berr  = cg_berr;
        end else begin
            cg_addr   = cg_addr_r;
            cg_req    = cg_req_r;
            ifu_rdata = 32'h0;
            ifu_ack   = 1'b0;
            ifu_berr  = 1'b0;

            case (state)
                IC_HIT: begin
                    ifu_rdata = data_i[idx_r][woff_r];
                    ifu_ack   = 1'b1;
                end
                IC_DONE: begin
                    if (berr_r) ifu_berr = 1'b1;
                    else begin
                        ifu_rdata = fill_rdata_r;
                        ifu_ack   = 1'b1;
                    end
                end
                default: ; // IC_IDLE, IC_FILL_0..3 (cg_req/cg_addr already set above)
            endcase
        end
    end

endmodule

`default_nettype wire
