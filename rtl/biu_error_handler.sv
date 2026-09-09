`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Bus Error Timeout Watchdog 
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
// retry_exhausted (renamed from halt_out, Phase 250 Part B): asserts when
// any BERR (external or timeout) fires during a retry cycle. This is a
// real, useful, simulation-only escape hatch for an otherwise-infinite
// BERR+HALT retry -- but it is NOT the MC68030's own "double bus fault"
// condition, despite this signal's own former name and comment here once
// claiming that association. MC68030UM.pdf §7.5.4 is explicit that a
// retried bus cycle "does not constitute a bus error or contribute to a
// double bus fault" -- genuine double bus fault (a bus/address error
// occurring WHILE the exception controller is already dispatching a prior
// one, confirmed and implemented in `m68030_exc.sv`'s own new
// `EXC_DBLFAULT` state/`double_fault` output) is an entirely separate,
// unrelated condition from this signal. `status_n` (Phase 250 F10) is
// wired to THAT signal now, not this one. Kept as its own internal
// control signal (the EU/top-level should still stop execution while it's
// asserted, since real hardware would legitimately retry forever here,
// which isn't testable in a finite harness) -- just correctly named and
// documented.

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
    output logic       retry_exhausted // 1 = BERR fired during a retry cycle
                                         // (renamed from halt_out, Phase 250
                                         // Part B -- NOT the same thing as a
                                         // genuine double bus fault; see
                                         // header comment above)
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
    // Retry-exhausted detection (NOT double bus fault -- see header comment)
    // Any BERR (external or internal timeout) during a retry cycle.
    // retry_exhausted is combinational — the top-level should register it
    // to avoid glitches propagating to whatever consumes it.
    // -----------------------------------------------------------------------
    assign retry_exhausted = (berr_s | berr_timeout_r) & retry_pending;

endmodule

`default_nettype wire
