`default_nettype none

// E-clock generator — MC68030 BIU, Phase 1
//
// Generates the E output at CLK/10 with a 60/40 duty cycle:
//   6 external clock cycles low, then 4 external clock cycles high.
//
// The internal 4x clock (clk_4x) represents 4 ticks per external bus clock.
// An internal phase counter (0–3) divides clk_4x back to the external rate;
// the E counter (0–9) then counts external clocks to produce the E waveform.
//
// eclk_cnt is exposed so the VPA synchroniser in biu_cycle_gen can determine
// which E-clock boundary the current bus cycle should terminate on.

module biu_eclk_gen (
    input  logic       clk_4x,
    input  logic       rst_n,
    output logic       e,            // E-clock output (to external pin)
    output logic [3:0] eclk_cnt      // Current E-clock phase 0–9 (for VPA sync)
);

    localparam int E_PERIOD   = 10;  // E clock = external CLK / 10
    localparam int E_LOW_END  = 5;   // counts 0–5 are low (6 clocks)
                                     // counts 6–9 are high (4 clocks)

    logic [1:0] phase;               // 0–3: position within one external clock
    logic [3:0] cnt;                 // 0–9: external-clock count within E period

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 2'd0;
            cnt   <= 4'd0;
            e     <= 1'b0;
        end else if (phase == 2'd3) begin
            // End of external clock — advance E counter
            phase <= 2'd0;
            if (cnt == 4'(E_PERIOD - 1)) begin
                cnt <= 4'd0;
                e   <= 1'b0;        // count 0 is low
            end else begin
                cnt <= cnt + 4'd1;
                // e tracks the NEW count value, set simultaneously
                e   <= (cnt + 4'd1 > 4'(E_LOW_END));
            end
        end else begin
            phase <= phase + 2'd1;
        end
    end

    assign eclk_cnt = cnt;

endmodule

`default_nettype wire
