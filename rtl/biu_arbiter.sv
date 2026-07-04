`default_nettype none

// MC68030 BIU — Bus Arbiter
//
// Implements the internal bus priority scheme (BIU-097 to BIU-101):
//   Priority: MMU (highest) > EU > IFU (lowest)
//
// A grant is issued when the bus is idle (bus_idle=1 from cycle_gen).
// The grant register is held until the bus returns to idle at the end of
// the current cycle; this ensures the cycle_gen sees a stable grant
// throughout the entire bus cycle.
//
// External DMA (BR/BG/BGACK, BIU-037): when BR# asserts and the bus is
// idle, all internal grants are suppressed and ext_bg_n is asserted.
// When BGACK is received, the bus is handed to the external device.
// When BGACK deasserts AND AS# has been released (as_n_fb=1), normal
// arbitration resumes.
//
// BG# glitch prevention: ext_bg_n is explicitly deasserted in every
// branch that does not keep the DMA handshake active, so it cannot
// remain asserted if BR# withdraws before BGACK is received.

module biu_arbiter (
    input  logic clk_4x,
    input  logic rst_n,

    // Internal bus requests (active-high)
    input  logic mmu_req,
    input  logic eu_req,
    input  logic ifu_req,

    // Bus availability from biu_cycle_gen
    input  logic bus_idle,      // 1 = bus is in ST_IDLE, ready to accept new grant
    input  logic bus_lock,      // 1 = RMW/CAS2 in progress; suppress external DMA grant

    // Registered grants to biu_cycle_gen (one-hot)
    output logic grant_mmu,
    output logic grant_eu,
    output logic grant_ifu,

    // DMA busy flag: cycle_gen tri-states all outputs when this is high
    output logic dma_active,

    // External DMA signals (synchronised inputs)
    input  logic br_s,          // Bus Request   — synchronised, active-low (0 = asserted)
    output logic ext_bg_n,      // Bus Grant to external DMA (active-low)
    input  logic bgack_s,       // Bus Grant Ack — synchronised, active-low (0 = asserted)
    // AS# pin-level feedback: 1 = deasserted by external device.
    // After BGACK deasserts the arbiter waits for this to go high before
    // re-enabling internal grants, preventing bus contention on AS#.
    input  logic as_n_fb
);

    logic grant_mmu_r, grant_eu_r, grant_ifu_r;
    logic dma_r;
    logic bg_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            grant_mmu_r <= 1'b0;
            grant_eu_r  <= 1'b0;
            grant_ifu_r <= 1'b0;
            dma_r       <= 1'b0;
            bg_r        <= 1'b1;   // BG# deasserted (active-low, 1=deasserted)
        end else begin
            // -------------------------------------------------------------------
            // DMA release: wait until both BGACK and the external AS# are
            // deasserted before handing the bus back to internal units.
            // -------------------------------------------------------------------
            if (dma_r && bgack_s && as_n_fb)
                dma_r <= 1'b0;

            // -------------------------------------------------------------------
            // BG# and internal grant arbitration.
            // Only acts while DMA does not currently own the bus.
            // -------------------------------------------------------------------
            if (!dma_r) begin
                if (bus_idle && !br_s && !bus_lock) begin
                    // External DMA request pending and bus is free.
                    // Suppress internal grants and assert BG#.
                    grant_mmu_r <= 1'b0;
                    grant_eu_r  <= 1'b0;
                    grant_ifu_r <= 1'b0;
                    bg_r        <= 1'b0;     // assert BG# (active-low)
                    if (!bgack_s) begin
                        // BGACK received: DMA device has taken the bus.
                        // Deassert BG# and set dma_r so cycle_gen tri-states.
                        dma_r <= 1'b1;
                        bg_r  <= 1'b1;
                    end
                end else begin
                    // BR# not asserted (or bus busy / bus_lock): BG# must be
                    // deasserted. This covers the case where BR# withdraws
                    // before BGACK, preventing a lingering BG# glitch.
                    bg_r <= 1'b1;

                    // Internal arbitration — only reassign when bus is idle.
                    if (bus_idle) begin
                        if (mmu_req) begin
                            grant_mmu_r <= 1'b1;
                            grant_eu_r  <= 1'b0;
                            grant_ifu_r <= 1'b0;
                        end else if (eu_req) begin
                            grant_mmu_r <= 1'b0;
                            grant_eu_r  <= 1'b1;
                            grant_ifu_r <= 1'b0;
                        end else if (ifu_req) begin
                            grant_mmu_r <= 1'b0;
                            grant_eu_r  <= 1'b0;
                            grant_ifu_r <= 1'b1;
                        end else begin
                            grant_mmu_r <= 1'b0;
                            grant_eu_r  <= 1'b0;
                            grant_ifu_r <= 1'b0;
                        end
                    end
                    // When bus is not idle, hold all grant registers (no change)
                end
            end
        end
    end

    assign grant_mmu  = grant_mmu_r;
    assign grant_eu   = grant_eu_r;
    assign grant_ifu  = grant_ifu_r;
    assign dma_active = dma_r;
    assign ext_bg_n   = bg_r;

endmodule

`default_nettype wire
