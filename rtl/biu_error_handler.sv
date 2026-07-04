`default_nettype none

// MC68030 BIU — Bus Error Timeout Watchdog (Phase 11)
//
// Asserts berr_timeout when a bus cycle has been active for TIMEOUT_CLKS
// 4x-clock ticks without any of: DSACK0, DSACK1, STERM, external BERR,
// or bus returning to idle.
//
// berr_timeout is latched and held until bus_idle deasserts (ST_IDLE), so
// biu_cycle_gen's FSM is guaranteed to sample it at phase_r==3 regardless
// of which phase the threshold is crossed on.
//
// The caller combines berr_timeout with the synchronised external BERR:
//   berr_s_combined = berr_s_ext | berr_timeout
// and feeds berr_s_combined into biu_cycle_gen.berr_s.
//
// The watchdog's berr_s input must be the EXTERNAL-only BERR (not the
// combined signal) to avoid the combinational loop:
//   terminated = dsack0_s | dsack1_s | sterm_s | berr_s_ext | bus_idle
//
// halt_out: asserts when any BERR (external or timeout) fires during a
// retry cycle — this is the MC68030 double bus fault condition.  The
// signal should be held by the EU/top-level to stop execution.

module biu_error_handler #(
    parameter int TIMEOUT_CLKS = 128   // 4x-clock ticks before timeout
) (
    input  logic       clk_4x,
    input  logic       rst_n,

    // From biu_cycle_gen
    input  logic       bus_idle,           // 1 when FSM is in ST_IDLE
    input  logic       bus_reset_inst,     // 1 while RESET instruction is executing
    input  logic       retry_pending,      // 1 while a BERR+HALT retry is in progress

    // Synchronised bus termination signals (from biu_config / testbench mux)
    // These are the SAME signals fed to biu_cycle_gen — sampled here to know
    // when a cycle has terminated normally.
    input  logic       dsack0_s,      // active-high: DSACK0 asserted
    input  logic       dsack1_s,
    input  logic       sterm_s,       // active-high: STERM asserted
    input  logic       berr_s,        // active-high: external BERR only (not combined)

    // Outputs
    output logic       berr_timeout,  // latch: 1 from threshold until bus_idle
    output logic       halt_out       // 1 = double bus fault (BERR during retry)
);

    // -----------------------------------------------------------------------
    // Counter width derived from parameter
    // -----------------------------------------------------------------------
    localparam int CNT_W = $clog2(TIMEOUT_CLKS + 1);

    // -----------------------------------------------------------------------
    // Watchdog counter
    // Any termination event resets it; it counts while the bus is busy
    // with no response.
    // -----------------------------------------------------------------------
    logic [CNT_W-1:0] wdog_r;
    logic             terminated;

    // bus_reset_inst: RESET instruction holds RSTOUT# for ~500 ticks with no
    // bus activity; suppress the watchdog during that window so it doesn't
    // generate a spurious timeout BERR.
    assign terminated = dsack0_s | dsack1_s | sterm_s | berr_s | bus_idle | bus_reset_inst;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            wdog_r <= '0;
        else if (terminated)
            wdog_r <= '0;
        else if (wdog_r != CNT_W'(TIMEOUT_CLKS))
            wdog_r <= wdog_r + 1'b1;
    end

    // -----------------------------------------------------------------------
    // berr_timeout latch
    // Set when the counter reaches TIMEOUT_CLKS - 1 (fires one tick before
    // saturation so the latch is asserted for the full TIMEOUT_CLKS tick).
    // Cleared when bus returns to idle (cycle abort complete).
    // -----------------------------------------------------------------------
    logic berr_timeout_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)
            berr_timeout_r <= 1'b0;
        else if (bus_idle)
            berr_timeout_r <= 1'b0;
        else if (wdog_r == CNT_W'(TIMEOUT_CLKS - 1))
            berr_timeout_r <= 1'b1;
    end

    assign berr_timeout = berr_timeout_r;

    // -----------------------------------------------------------------------
    // Double bus fault detection
    // Any BERR (external or internal timeout) during a retry cycle.
    // halt_out is combinational — the top-level should register it to avoid
    // glitches propagating to the halt pin.
    // -----------------------------------------------------------------------
    assign halt_out = (berr_s | berr_timeout_r) & retry_pending;

endmodule

`default_nettype wire
