`default_nettype none

// MC68030 BIU Burst Controller
// Owns the burst linefill read and MOVE16 burst write data paths.
// biu_cycle_gen retains all S-state transitions; this module consumes
// decoded phase/state signals from cycle_gen and drives beat counters,
// address/data capture registers, and EU completion strobes.

module biu_burst_ctrl (
    input  logic        clk_4x,
    input  logic        rst_n,

    // 4× clock phase from cycle_gen (all registers update at phase_r==3)
    input  logic [1:0]  phase_r,

    // State decode from cycle_gen (derived from the bus state machine)
    input  logic        is_burst_read,   // in any ST_BURST_* or ST_BURST_NEXT_* state
    input  logic        is_burst_write,  // in any ST_BWRITE_* or ST_BWRITE_NEXT_* state
    input  logic        at_burst_data,   // at S4/S5 of any burst sub-cycle (read or write)
    input  logic        data_capture_ok, // (!dsack_wait || sterm_active) && !berr_s
    input  logic        at_burst_s7,     // at S7 of any burst sub-cycle (read or write)
    input  logic        at_idle,         // state == ST_IDLE

    // Termination and bus signals
    input  logic        berr_abort_r,    // BERR abort captured by cycle_gen
    input  logic        cback_s,         // synchronized CBACK# (0=asserted = burst ok)
    input  logic [31:0] ext_d_in,        // read data bus

    // EU burst linefill read request
    input  logic        eu_burst_req,
    input  logic [31:0] eu_burst_addr,
    input  logic [2:0]  eu_burst_fc,

    // EU MOVE16 burst write request
    input  logic        eu_m16_req,
    input  logic [31:0] eu_m16_addr,
    input  logic [2:0]  eu_m16_fc,
    input  logic [31:0] eu_m16_wdata0,
    input  logic [31:0] eu_m16_wdata1,
    input  logic [31:0] eu_m16_wdata2,
    input  logic [31:0] eu_m16_wdata3,

    // Burst state exported to cycle_gen for address mux and state transitions
    output logic [1:0]  burst_beat,      // current beat (0-3)
    output logic [31:0] burst_addr,      // current beat's bus address
    output logic [2:0]  burst_fc,        // function code for this burst
    output logic        cback_ok,        // CBACK# was asserted during beat-0 sampling

    // MOVE16 write data mux (beat-indexed, for cycle_gen cyc_wdata mux)
    output logic [31:0] m16_wdata_mux,

    // Captured read data, one longword per beat
    output logic [31:0] burst_rdata0,
    output logic [31:0] burst_rdata1,
    output logic [31:0] burst_rdata2,
    output logic [31:0] burst_rdata3,

    // CBREQ# control: assert at beat-0 S0/S1 of any burst
    output logic        cbreq_assert,

    // EU completion pulses
    output logic        eu_burst_ack,
    output logic        eu_burst_berr,
    output logic        eu_m16_ack,
    output logic        eu_m16_berr
);

    logic [1:0]  burst_beat_r;
    logic [31:0] burst_addr_r;
    logic [2:0]  burst_fc_r;
    logic [31:0] burst_rdata_r [0:3];
    logic        cback_ok_r;
    logic [31:0] m16_wdata_r   [0:3];

    logic is_burst;
    assign is_burst = is_burst_read | is_burst_write;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            burst_beat_r     <= 2'd0;
            burst_addr_r     <= 32'h0;
            burst_fc_r       <= 3'b0;
            cback_ok_r       <= 1'b0;
            burst_rdata_r[0] <= 32'h0; burst_rdata_r[1] <= 32'h0;
            burst_rdata_r[2] <= 32'h0; burst_rdata_r[3] <= 32'h0;
            m16_wdata_r[0]   <= 32'h0; m16_wdata_r[1]   <= 32'h0;
            m16_wdata_r[2]   <= 32'h0; m16_wdata_r[3]   <= 32'h0;
        end else if (phase_r == 2'd3) begin
            // Latch burst read parameters at IDLE
            if (at_idle && eu_burst_req) begin
                burst_addr_r <= eu_burst_addr;
                burst_fc_r   <= eu_burst_fc;
                burst_beat_r <= 2'd0;
                cback_ok_r   <= 1'b0;
            end
            // Latch MOVE16 write parameters at IDLE
            if (at_idle && eu_m16_req) begin
                burst_addr_r   <= eu_m16_addr;
                burst_fc_r     <= eu_m16_fc;
                burst_beat_r   <= 2'd0;
                cback_ok_r     <= 1'b0;
                m16_wdata_r[0] <= eu_m16_wdata0; m16_wdata_r[1] <= eu_m16_wdata1;
                m16_wdata_r[2] <= eu_m16_wdata2; m16_wdata_r[3] <= eu_m16_wdata3;
            end
            // Capture read data at S4/S5 of burst read sub-cycles (when DSACK valid)
            if (at_burst_data && is_burst_read && data_capture_ok) begin
                case (burst_beat_r)
                    2'd0: burst_rdata_r[0] <= ext_d_in;
                    2'd1: burst_rdata_r[1] <= ext_d_in;
                    2'd2: burst_rdata_r[2] <= ext_d_in;
                    2'd3: burst_rdata_r[3] <= ext_d_in;
                endcase
            end
            // Advance beat counter and address at S7 of each sub-cycle.
            // burst_beat_r is read here at its PRE-NBA value (before this clock's
            // increment), which is what the eu_burst_ack registered logic also reads.
            if (at_burst_s7 && burst_beat_r != 2'd3) begin
                burst_beat_r <= burst_beat_r + 2'd1;
                burst_addr_r <= burst_addr_r + 32'd4;
            end
            // OR-accumulate CBACK# during beat-0 S4/S5 (read and write bursts).
            // cback_s active-low: 0 = asserted = peripheral supports burst continuation.
            if (burst_beat_r == 2'd0 && at_burst_data)
                cback_ok_r <= cback_ok_r | !cback_s;
        end
    end

    // Pass registers to cycle_gen wires
    assign burst_beat  = burst_beat_r;
    assign burst_addr  = burst_addr_r;
    assign burst_fc    = burst_fc_r;
    assign cback_ok    = cback_ok_r;

    assign burst_rdata0 = burst_rdata_r[0];
    assign burst_rdata1 = burst_rdata_r[1];
    assign burst_rdata2 = burst_rdata_r[2];
    assign burst_rdata3 = burst_rdata_r[3];

    // MOVE16 write data mux: select word for current beat
    always_comb begin
        case (burst_beat_r)
            2'd0: m16_wdata_mux = m16_wdata_r[0];
            2'd1: m16_wdata_mux = m16_wdata_r[1];
            2'd2: m16_wdata_mux = m16_wdata_r[2];
            2'd3: m16_wdata_mux = m16_wdata_r[3];
        endcase
    end

    // CBREQ# should assert during beat-0 S0/S1 of any burst (read or write)
    assign cbreq_assert = is_burst && (burst_beat_r == 2'd0);

    // EU completion pulses: registered to eliminate the delta-cycle race where
    // burst_beat_r's NBA (advancing 2→3) could race with at_burst_s7 clearing.
    // Registering means we read burst_beat_r at its stable PRE-NBA value each edge;
    // beat 2's S7 sees burst_beat_r=2 (not yet 3), so no spurious ack fires.
    // The pulse appears one 4x-clock tick after the S7 edge (still within S7's
    // bus cycle from the perspective of the 25 MHz external bus).
    logic eu_burst_ack_r, eu_burst_berr_r;
    logic eu_m16_ack_r,   eu_m16_berr_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            eu_burst_ack_r  <= 1'b0; eu_burst_berr_r <= 1'b0;
            eu_m16_ack_r    <= 1'b0; eu_m16_berr_r   <= 1'b0;
        end else begin
            eu_burst_ack_r  <= 1'b0; eu_burst_berr_r <= 1'b0;
            eu_m16_ack_r    <= 1'b0; eu_m16_berr_r   <= 1'b0;
            if (phase_r == 2'd3 && at_burst_s7) begin
                if (is_burst_read) begin
                    if (berr_abort_r)
                        eu_burst_berr_r <= 1'b1;
                    else if (burst_beat_r == 2'd3 || !cback_ok_r)
                        eu_burst_ack_r  <= 1'b1;
                end else if (is_burst_write) begin
                    if (berr_abort_r)
                        eu_m16_berr_r <= 1'b1;
                    else if (burst_beat_r == 2'd3 || !cback_ok_r)
                        eu_m16_ack_r  <= 1'b1;
                end
            end
        end
    end

    assign eu_burst_ack  = eu_burst_ack_r;
    assign eu_burst_berr = eu_burst_berr_r;
    assign eu_m16_ack    = eu_m16_ack_r;
    assign eu_m16_berr   = eu_m16_berr_r;

endmodule

`default_nettype wire
