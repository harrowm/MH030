`default_nettype none

// MC68030 BIU — Configuration / Input Synchronizer (Phase 9)
//
// Two-stage synchroniser flip-flops for every asynchronous input pin.
// This prevents metastability from propagating into the synchronous FSM.
//
// Output signal polarities match the conventions used by biu_cycle_gen:
//   Active-high (inverted from pin): dsack0_s, dsack1_s, sterm_s, berr_s, avec_s
//   Active-low  (pin polarity kept): halt_s, vpa_s, br_s, bgack_s, cback_s
//   Pin value   (no inversion):      ipl_s[2:0]  (all-ones = no interrupt on pin)
//
// pins_released: asserts one cycle after rst_n deasserts, indicating that the
// internal sync chain has had at least one clock to settle.  biu_pin_driver
// uses this to gate the data bus OE during power-on reset.

module biu_config (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Raw asynchronous chip pins (all active-low as on the real 68030)
    input  logic        dsack0_n,   // DSACK0#
    input  logic        dsack1_n,   // DSACK1#
    input  logic        sterm_n,    // STERM#
    input  logic        berr_n,     // BERR#
    input  logic        halt_n,     // HALT#
    input  logic        avec_n,     // AVEC# (autovector)
    input  logic        vpa_n,      // VPA#  (valid peripheral address)
    input  logic [2:0]  ipl_n,      // IPL2:0 pins (all-ones = no interrupt)
    input  logic        br_n,       // BR#   (bus request from DMA)
    input  logic        bgack_n,    // BGACK# (bus grant acknowledge)
    input  logic        cback_n,    // CBACK# (cache burst acknowledge)

    // Synchronised outputs — to biu_cycle_gen and biu_arbiter
    output logic        dsack0_s,   // 1 = DSACK0 asserted (active-high)
    output logic        dsack1_s,   // 1 = DSACK1 asserted
    output logic        sterm_s,    // 1 = STERM  asserted
    output logic        berr_s,     // 1 = BERR   asserted
    output logic        avec_s,     // 1 = AVEC   asserted
    output logic        halt_s,     // 0 = HALT   asserted (active-low retained)
    output logic        vpa_s,      // 0 = VPA    asserted (active-low retained)
    output logic [2:0]  ipl_s,      // pin value — all-ones = no interrupt
    output logic        br_s,       // 0 = BR     asserted (active-low retained)
    output logic        bgack_s,    // 0 = BGACK  asserted (active-low retained)
    output logic        cback_s,    // 0 = CBACK# asserted (active-low retained)

    // Asserts one cycle after rst_n deasserts; used by biu_pin_driver
    output logic        pins_released
);

    // -----------------------------------------------------------------------
    // Active-high outputs: invert pin on entry to stage 1
    // -----------------------------------------------------------------------
    logic dsack0_m, dsack0_q;
    logic dsack1_m, dsack1_q;
    logic sterm_m,  sterm_q;
    logic berr_m,   berr_q;
    logic avec_m,   avec_q;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            dsack0_m <= 1'b0; dsack0_q <= 1'b0;
            dsack1_m <= 1'b0; dsack1_q <= 1'b0;
            sterm_m  <= 1'b0; sterm_q  <= 1'b0;
            berr_m   <= 1'b0; berr_q   <= 1'b0;
            avec_m   <= 1'b0; avec_q   <= 1'b0;
        end else begin
            dsack0_m <= !dsack0_n;  dsack0_q <= dsack0_m;
            dsack1_m <= !dsack1_n;  dsack1_q <= dsack1_m;
            sterm_m  <= !sterm_n;   sterm_q  <= sterm_m;
            berr_m   <= !berr_n;    berr_q   <= berr_m;
            avec_m   <= !avec_n;    avec_q   <= avec_m;
        end
    end

    assign dsack0_s = dsack0_q;
    assign dsack1_s = dsack1_q;
    assign sterm_s  = sterm_q;
    assign berr_s   = berr_q;
    assign avec_s   = avec_q;

    // -----------------------------------------------------------------------
    // Active-low / pin-polarity-retained outputs: sample pin value directly
    // Reset values: deasserted state for each pin (all active-low → reset to 1)
    // -----------------------------------------------------------------------
    logic        halt_m,  halt_q;
    logic        vpa_m,   vpa_q;
    logic        br_m,    br_q;
    logic        bgack_m, bgack_q;
    logic        cback_m, cback_q;
    logic [2:0]  ipl_m,   ipl_q;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            halt_m  <= 1'b1;   halt_q  <= 1'b1;   // HALT# deasserted
            vpa_m   <= 1'b1;   vpa_q   <= 1'b1;
            br_m    <= 1'b1;   br_q    <= 1'b1;
            bgack_m <= 1'b1;   bgack_q <= 1'b1;
            cback_m <= 1'b1;   cback_q <= 1'b1;
            ipl_m   <= 3'b111; ipl_q   <= 3'b111; // no interrupt
        end else begin
            halt_m  <= halt_n;   halt_q  <= halt_m;
            vpa_m   <= vpa_n;    vpa_q   <= vpa_m;
            br_m    <= br_n;     br_q    <= br_m;
            bgack_m <= bgack_n;  bgack_q <= bgack_m;
            cback_m <= cback_n;  cback_q <= cback_m;
            ipl_m   <= ipl_n;    ipl_q   <= ipl_m;
        end
    end

    assign halt_s  = halt_q;
    assign vpa_s   = vpa_q;
    assign br_s    = br_q;
    assign bgack_s = bgack_q;
    assign cback_s = cback_q;
    assign ipl_s   = ipl_q;

    // -----------------------------------------------------------------------
    // pins_released: one cycle after rst_n rises so biu_pin_driver
    // knows the sync chain has settled and external pins may be driven.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) pins_released <= 1'b0;
        else        pins_released <= 1'b1;
    end

endmodule

`default_nettype wire
