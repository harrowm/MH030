`default_nettype none

// MC68030 BIU — Core Bus Cycle Generator
// Phase 4 adds: STERM fast termination (BIU-049/050/150), BERR fault capture
// (BIU-015/090/093), BERR+HALT retry (BIU-148), IACK cycles (BIU-043-048),
// and RESET instruction RSTOUT assertion (BIU-063/012).
// Phase 5 adds: RMW atomic lock (BIU-035), CAS2 four-cycle lock (BIU-057),
// bus_lock output to suppress DMA during locked sequences.
// Phase 7 adds: true burst read (CBREQ#/CBACK# handshake, AS held across 4 beats),
// MOVE16 burst write, MMU walk FC codes, CAS2 conditional gating.

module biu_cycle_gen #(
    parameter int RSTOUT_CLKS = 124
) (
    input  logic        clk_4x,
    input  logic        rst_n,

    // External bus outputs
    output logic [31:0] ext_a,
    output logic        ext_as_n,
    output logic        ext_ds_n,       // Data Strobe (68030 single DS pin)
    output logic        ext_rw,
    output logic [2:0]  ext_fc,
    output logic [1:0]  ext_siz,
    output logic        ext_ecs_n,
    output logic        ext_ocs_n,
    output logic [31:0] ext_d_out,
    output logic        ext_d_oe,
    output logic        ext_rstout_n,
    output logic        ext_cbreq_n,

    // External bus read data input
    input  logic [31:0] ext_d_in,

    // Synchronised async inputs
    input  logic        dsack0_s,
    input  logic        dsack1_s,
    input  logic        sterm_s,
    input  logic        berr_s,
    input  logic        halt_s,
    input  logic        avec_s,
    input  logic        vpa_s,
    input  logic [2:0]  ipl_s,
    input  logic        bgack_s,
    input  logic        cback_s,

    // Grant inputs from biu_arbiter (one-hot)
    input  logic        grant_mmu,
    input  logic        grant_eu,
    input  logic        grant_ifu,
    input  logic        dma_active,

    // Internal — Execution Unit
    input  logic [31:0] eu_addr,
    input  logic [31:0] eu_wdata,
    output logic [31:0] eu_rdata,
    input  logic [2:0]  eu_fc,
    input  logic        eu_rw,
    input  logic [1:0]  eu_siz,
    input  logic        eu_is_operand,
    input  logic        eu_req,
    output logic        eu_ack,
    output logic        eu_berr,
    output logic        eu_retry,

    // Internal — Instruction Fetch Unit
    input  logic [31:0] ifu_addr,
    input  logic        ifu_req,
    output logic [31:0] ifu_rdata,
    output logic        ifu_ack,
    output logic        ifu_berr,

    // Internal — MMU table walk
    input  logic [31:0] mmu_addr,
    input  logic [2:0]  mmu_fc,
    input  logic        mmu_req,
    output logic [31:0] mmu_rdata,
    output logic        mmu_ack,
    output logic        mmu_berr,

    // IACK cycle interface
    input  logic        eu_iack_req,
    input  logic [2:0]  eu_iack_level,
    output logic [7:0]  eu_iack_vec,
    output logic        eu_iack_avec,
    output logic        eu_iack_ack,

    // RESET instruction (BIU-063)
    input  logic        eu_rst_req,

    // E-clock for VPA sync
    input  logic [3:0]  eclk_cnt,

    // Status outputs
    output logic [1:0]  phase,
    output logic [6:0]  s_state,
    output logic        bus_idle,
    output logic        bus_reset_inst,  // 1 while ST_RESET_INST is running (watchdog inhibit)
    output logic        bus_halted,      // 1 while HALT# is suspending new bus cycles
    output logic        init_done,
    output logic [31:0] init_ssp,
    output logic [31:0] init_pc,
    output logic [1:0]  cyc_port_dsack,

    // Fault capture outputs (BIU-090)
    output logic [31:0] fault_addr,
    output logic [31:0] fault_data,
    output logic [2:0]  fault_fc,
    output logic        fault_rw,
    output logic [1:0]  fault_siz,
    output logic        fault_valid,
    output logic        retry_pending,
    output logic        fault_retry,     // 1 = fault occurred during a retry cycle (RC)
    output logic        fault_is_rmw,    // 1 = fault occurred during RMW write phase (RM)

    // RMW atomic lock (BIU-035): EU sets eu_rmw with eu_req for TAS/CAS etc.
    input  logic        eu_rmw,          // request RMW read→write without bus release
    output logic        bus_lock,        // high during RMW or CAS2 (suppresses DMA grant)

    // CAS2 four-cycle atomic lock (BIU-057)
    input  logic        eu_cas2_req,
    input  logic [31:0] eu_cas2_addr1,
    input  logic [31:0] eu_cas2_addr2,
    input  logic [2:0]  eu_cas2_fc,
    input  logic [1:0]  eu_cas2_siz,
    input  logic [31:0] eu_cas2_wdata1,
    input  logic [31:0] eu_cas2_wdata2,
    input  logic        eu_cas2_do_write1,
    input  logic        eu_cas2_do_write2,
    output logic [31:0] eu_cas2_rdata1,
    output logic [31:0] eu_cas2_rdata2,
    output logic        eu_cas2_ack,

    // Burst read (line fill, 4×LW, AS held; CBREQ#/CBACK# handshake)
    input  logic        eu_burst_req,
    input  logic [31:0] eu_burst_addr,
    input  logic [2:0]  eu_burst_fc,
    output logic [31:0] eu_burst_rdata0,
    output logic [31:0] eu_burst_rdata1,
    output logic [31:0] eu_burst_rdata2,
    output logic [31:0] eu_burst_rdata3,
    output logic        eu_burst_ack,
    output logic        eu_burst_berr,

    // MOVE16 burst write (4×LW, AS held)
    input  logic        eu_m16_req,
    input  logic [31:0] eu_m16_addr,
    input  logic [2:0]  eu_m16_fc,
    input  logic [31:0] eu_m16_wdata0,
    input  logic [31:0] eu_m16_wdata1,
    input  logic [31:0] eu_m16_wdata2,
    input  logic [31:0] eu_m16_wdata3,
    output logic        eu_m16_ack,
    output logic        eu_m16_berr,

    // Coprocessor (FPU) CPU Space interface (Phase 10)
    // FC=111, A[19:16]=0010 (coprocessor category), A[15:13]=primitive type
    // Distinct from IACK (eu_iack_req / A[19:16]=1111) by address pattern.
    input  logic        eu_coproc_req,
    input  logic        eu_coproc_rw,     // 1=read, 0=write
    input  logic [31:0] eu_coproc_addr,   // full address, EU sets A[19:16]=0010
    input  logic [2:0]  eu_coproc_fc,     // must be 3'b111
    input  logic [1:0]  eu_coproc_siz,
    input  logic [31:0] eu_coproc_wdata,
    output logic [31:0] eu_coproc_rdata,
    output logic        eu_coproc_ack,
    output logic        eu_coproc_berr,

    // Address error detection (Phase 19)
    // Asserted combinationally for one cycle when a request is rejected at IDLE.
    // EU/IFU must deassert their req on the next cycle after seeing this.
    output logic        eu_addr_err,    // 1 = word access to odd address
    output logic        ifu_addr_err    // 1 = instruction fetch to odd address
);

    typedef enum logic [6:0] {
        ST_RESET         = 7'd0,
        ST_IDLE          = 7'd1,
        ST_INIT_SSP_S0   = 7'd2,
        ST_INIT_SSP_S1   = 7'd3,
        ST_INIT_SSP_S2   = 7'd4,
        ST_INIT_SSP_S3   = 7'd5,
        ST_INIT_SSP_S4   = 7'd6,
        ST_INIT_SSP_S5   = 7'd7,
        ST_INIT_SSP_S6   = 7'd8,
        ST_INIT_SSP_S7   = 7'd9,
        ST_INIT_PC_S0    = 7'd10,
        ST_INIT_PC_S1    = 7'd11,
        ST_INIT_PC_S2    = 7'd12,
        ST_INIT_PC_S3    = 7'd13,
        ST_INIT_PC_S4    = 7'd14,
        ST_INIT_PC_S5    = 7'd15,
        ST_INIT_PC_S6    = 7'd16,
        ST_INIT_PC_S7    = 7'd17,
        ST_READ_S0       = 7'd18,
        ST_READ_S1       = 7'd19,
        ST_READ_S2       = 7'd20,
        ST_READ_S3       = 7'd21,
        ST_READ_S4       = 7'd22,
        ST_READ_S5       = 7'd23,
        ST_READ_S6       = 7'd24,
        ST_READ_S7       = 7'd25,
        ST_WRITE_S0      = 7'd26,
        ST_WRITE_S1      = 7'd27,
        ST_WRITE_S2      = 7'd28,
        ST_WRITE_S3      = 7'd29,
        ST_WRITE_S4      = 7'd30,
        ST_WRITE_S5      = 7'd31,
        ST_WRITE_S6      = 7'd32,
        ST_WRITE_S7      = 7'd33,
        ST_BURST_S0      = 7'd34,
        ST_BURST_S1      = 7'd35,
        ST_BURST_S2      = 7'd36,
        ST_BURST_S3      = 7'd37,
        ST_BURST_S4      = 7'd38,
        ST_BURST_S5      = 7'd39,
        ST_BURST_S6      = 7'd40,
        ST_BURST_S7      = 7'd41,
        ST_BURST_NEXT_S3 = 7'd42,
        ST_BURST_NEXT_S4 = 7'd43,
        ST_BURST_NEXT_S5 = 7'd44,
        ST_BURST_NEXT_S6 = 7'd45,
        ST_BURST_NEXT_S7 = 7'd46,
        ST_RMW_READ_S0   = 7'd47,
        ST_RMW_READ_S1   = 7'd48,
        ST_RMW_READ_S2   = 7'd49,
        ST_RMW_READ_S3   = 7'd50,
        ST_RMW_READ_S4   = 7'd51,
        ST_RMW_READ_S5   = 7'd52,
        ST_RMW_READ_S6   = 7'd53,
        ST_RMW_WRITE_S0  = 7'd54,
        ST_RMW_WRITE_S1  = 7'd55,
        ST_RMW_WRITE_S2  = 7'd56,
        ST_RMW_WRITE_S3  = 7'd57,
        ST_RMW_WRITE_S4  = 7'd58,
        ST_RMW_WRITE_S5  = 7'd59,
        ST_RMW_WRITE_S6  = 7'd60,
        ST_RMW_WRITE_S7  = 7'd61,
        ST_IACK_S0       = 7'd62,
        ST_IACK_S1       = 7'd63,
        ST_IACK_S2       = 7'd64,
        ST_IACK_S3       = 7'd65,
        ST_IACK_S4       = 7'd66,
        ST_IACK_S5       = 7'd67,
        ST_IACK_S6       = 7'd68,
        ST_IACK_S7       = 7'd69,
        ST_RESET_INST    = 7'd70,
        // RMW: missing S7 added; S0-S6 already defined above at 7'd47-53
        ST_RMW_READ_S7   = 7'd71,
        // CAS2: R1(read addr1) W1(write addr1) R2(read addr2) W2(write addr2)
        ST_CAS2_R1_S0    = 7'd72,  ST_CAS2_R1_S1 = 7'd73,
        ST_CAS2_R1_S2    = 7'd74,  ST_CAS2_R1_S3 = 7'd75,
        ST_CAS2_R1_S4    = 7'd76,  ST_CAS2_R1_S5 = 7'd77,
        ST_CAS2_R1_S6    = 7'd78,  ST_CAS2_R1_S7 = 7'd79,
        ST_CAS2_W1_S0    = 7'd80,  ST_CAS2_W1_S1 = 7'd81,
        ST_CAS2_W1_S2    = 7'd82,  ST_CAS2_W1_S3 = 7'd83,
        ST_CAS2_W1_S4    = 7'd84,  ST_CAS2_W1_S5 = 7'd85,
        ST_CAS2_W1_S6    = 7'd86,  ST_CAS2_W1_S7 = 7'd87,
        ST_CAS2_R2_S0    = 7'd88,  ST_CAS2_R2_S1 = 7'd89,
        ST_CAS2_R2_S2    = 7'd90,  ST_CAS2_R2_S3 = 7'd91,
        ST_CAS2_R2_S4    = 7'd92,  ST_CAS2_R2_S5 = 7'd93,
        ST_CAS2_R2_S6    = 7'd94,  ST_CAS2_R2_S7 = 7'd95,
        ST_CAS2_W2_S0    = 7'd96,  ST_CAS2_W2_S1 = 7'd97,
        ST_CAS2_W2_S2    = 7'd98,  ST_CAS2_W2_S3 = 7'd99,
        ST_CAS2_W2_S4    = 7'd100, ST_CAS2_W2_S5 = 7'd101,
        ST_CAS2_W2_S6    = 7'd102, ST_CAS2_W2_S7 = 7'd103,
        // MOVE16 burst write: first beat (S0-S7) + continuation beats (S3-S7)
        ST_BWRITE_S0      = 7'd104, ST_BWRITE_S1      = 7'd105,
        ST_BWRITE_S2      = 7'd106, ST_BWRITE_S3      = 7'd107,
        ST_BWRITE_S4      = 7'd108, ST_BWRITE_S5      = 7'd109,
        ST_BWRITE_S6      = 7'd110, ST_BWRITE_S7      = 7'd111,
        ST_BWRITE_NEXT_S3 = 7'd112, ST_BWRITE_NEXT_S4 = 7'd113,
        ST_BWRITE_NEXT_S5 = 7'd114, ST_BWRITE_NEXT_S6 = 7'd115,
        ST_BWRITE_NEXT_S7 = 7'd116
    } bus_state_t;

    bus_state_t state, state_nxt;

    logic rst_s1, rst_s2;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin rst_s1 <= 1'b0; rst_s2 <= 1'b0; end
        else begin rst_s1 <= 1'b1; rst_s2 <= rst_s1; end
    end

    logic [1:0] phase_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)       phase_r <= 2'd0;
        else if (!rst_s2) phase_r <= 2'd0;
        else              phase_r <= phase_r + 2'd1;
    end

    assign phase   = phase_r;
    assign s_state = 7'(state);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)              state <= ST_RESET;
        else if (phase_r == 2'd3) state <= state_nxt;
    end

    logic dsack_wait;
    assign dsack_wait = !dsack0_s & !dsack1_s;

    // Helper: which class of states we are in
    logic is_init_ssp, is_init_pc, is_iack, is_S4_or_S5, is_S6, is_S7;
    logic is_rmw_write, rmw_as_hold;
    logic is_cas2_r1, is_cas2_w1, is_cas2_r2, is_cas2_w2, is_cas2;
    logic is_burst_read, is_burst_write, is_burst;

    assign is_init_ssp = (state == ST_INIT_SSP_S0) | (state == ST_INIT_SSP_S1) |
                         (state == ST_INIT_SSP_S2) | (state == ST_INIT_SSP_S3) |
                         (state == ST_INIT_SSP_S4) | (state == ST_INIT_SSP_S5) |
                         (state == ST_INIT_SSP_S6) | (state == ST_INIT_SSP_S7);

    assign is_init_pc  = (state == ST_INIT_PC_S0)  | (state == ST_INIT_PC_S1)  |
                         (state == ST_INIT_PC_S2)  | (state == ST_INIT_PC_S3)  |
                         (state == ST_INIT_PC_S4)  | (state == ST_INIT_PC_S5)  |
                         (state == ST_INIT_PC_S6)  | (state == ST_INIT_PC_S7);

    assign is_iack     = (state == ST_IACK_S0) | (state == ST_IACK_S1) |
                         (state == ST_IACK_S2) | (state == ST_IACK_S3) |
                         (state == ST_IACK_S4) | (state == ST_IACK_S5) |
                         (state == ST_IACK_S6) | (state == ST_IACK_S7);

    assign is_rmw_write = (state == ST_RMW_WRITE_S0) | (state == ST_RMW_WRITE_S1) |
                          (state == ST_RMW_WRITE_S2) | (state == ST_RMW_WRITE_S3) |
                          (state == ST_RMW_WRITE_S4) | (state == ST_RMW_WRITE_S5) |
                          (state == ST_RMW_WRITE_S6) | (state == ST_RMW_WRITE_S7);

    assign is_cas2_r1 = (state == ST_CAS2_R1_S0) | (state == ST_CAS2_R1_S1) |
                        (state == ST_CAS2_R1_S2) | (state == ST_CAS2_R1_S3) |
                        (state == ST_CAS2_R1_S4) | (state == ST_CAS2_R1_S5) |
                        (state == ST_CAS2_R1_S6) | (state == ST_CAS2_R1_S7);

    assign is_cas2_w1 = (state == ST_CAS2_W1_S0) | (state == ST_CAS2_W1_S1) |
                        (state == ST_CAS2_W1_S2) | (state == ST_CAS2_W1_S3) |
                        (state == ST_CAS2_W1_S4) | (state == ST_CAS2_W1_S5) |
                        (state == ST_CAS2_W1_S6) | (state == ST_CAS2_W1_S7);

    assign is_cas2_r2 = (state == ST_CAS2_R2_S0) | (state == ST_CAS2_R2_S1) |
                        (state == ST_CAS2_R2_S2) | (state == ST_CAS2_R2_S3) |
                        (state == ST_CAS2_R2_S4) | (state == ST_CAS2_R2_S5) |
                        (state == ST_CAS2_R2_S6) | (state == ST_CAS2_R2_S7);

    assign is_cas2_w2 = (state == ST_CAS2_W2_S0) | (state == ST_CAS2_W2_S1) |
                        (state == ST_CAS2_W2_S2) | (state == ST_CAS2_W2_S3) |
                        (state == ST_CAS2_W2_S4) | (state == ST_CAS2_W2_S5) |
                        (state == ST_CAS2_W2_S6) | (state == ST_CAS2_W2_S7);

    assign is_cas2     = is_cas2_r1 | is_cas2_w1 | is_cas2_r2 | is_cas2_w2;

    assign is_burst_read  = (state == ST_BURST_S0)  | (state == ST_BURST_S1)  |
                            (state == ST_BURST_S2)  | (state == ST_BURST_S3)  |
                            (state == ST_BURST_S4)  | (state == ST_BURST_S5)  |
                            (state == ST_BURST_S6)  | (state == ST_BURST_S7)  |
                            (state == ST_BURST_NEXT_S3) | (state == ST_BURST_NEXT_S4) |
                            (state == ST_BURST_NEXT_S5) | (state == ST_BURST_NEXT_S6) |
                            (state == ST_BURST_NEXT_S7);

    assign is_burst_write = (state == ST_BWRITE_S0) | (state == ST_BWRITE_S1) |
                            (state == ST_BWRITE_S2) | (state == ST_BWRITE_S3) |
                            (state == ST_BWRITE_S4) | (state == ST_BWRITE_S5) |
                            (state == ST_BWRITE_S6) | (state == ST_BWRITE_S7) |
                            (state == ST_BWRITE_NEXT_S3) | (state == ST_BWRITE_NEXT_S4) |
                            (state == ST_BWRITE_NEXT_S5) | (state == ST_BWRITE_NEXT_S6) |
                            (state == ST_BWRITE_NEXT_S7);

    assign is_burst = is_burst_read | is_burst_write;

    assign is_S4_or_S5 = (state == ST_READ_S4)      | (state == ST_READ_S5)      |
                         (state == ST_WRITE_S4)     | (state == ST_WRITE_S5)     |
                         (state == ST_IACK_S4)      | (state == ST_IACK_S5)      |
                         (state == ST_RMW_READ_S4)  | (state == ST_RMW_READ_S5)  |
                         (state == ST_RMW_WRITE_S4) | (state == ST_RMW_WRITE_S5) |
                         (state == ST_CAS2_R1_S4)   | (state == ST_CAS2_R1_S5)   |
                         (state == ST_CAS2_W1_S4)   | (state == ST_CAS2_W1_S5)   |
                         (state == ST_CAS2_R2_S4)   | (state == ST_CAS2_R2_S5)   |
                         (state == ST_CAS2_W2_S4)   | (state == ST_CAS2_W2_S5)   |
                         (state == ST_BURST_S4)     | (state == ST_BURST_S5)     |
                         (state == ST_BURST_NEXT_S4)| (state == ST_BURST_NEXT_S5)|
                         (state == ST_BWRITE_S4)    | (state == ST_BWRITE_S5)    |
                         (state == ST_BWRITE_NEXT_S4)|(state == ST_BWRITE_NEXT_S5);

    assign is_S6       = (state == ST_READ_S6)      | (state == ST_WRITE_S6)     |
                         (state == ST_IACK_S6)     |
                         (state == ST_RMW_READ_S6) | (state == ST_RMW_WRITE_S6) |
                         (state == ST_CAS2_R1_S6)  | (state == ST_CAS2_W1_S6)   |
                         (state == ST_CAS2_R2_S6)  | (state == ST_CAS2_W2_S6)   |
                         (state == ST_BURST_S6)    | (state == ST_BURST_NEXT_S6) |
                         (state == ST_BWRITE_S6)   | (state == ST_BWRITE_NEXT_S6);

    assign is_S7       = (state == ST_READ_S7)     | (state == ST_WRITE_S7)     |
                         (state == ST_IACK_S7)     |
                         (state == ST_RMW_READ_S7) | (state == ST_RMW_WRITE_S7) |
                         (state == ST_CAS2_R1_S7)  | (state == ST_CAS2_W1_S7)   |
                         (state == ST_CAS2_R2_S7)  | (state == ST_CAS2_W2_S7)   |
                         (state == ST_BURST_S7)    | (state == ST_BURST_NEXT_S7) |
                         (state == ST_BWRITE_S7)   | (state == ST_BWRITE_NEXT_S7);

    // AS# must stay asserted through the RMW read→write transition: deassert is
    // suppressed at READ_S6/S7 and WRITE_S0/S1; it naturally re-asserts at WRITE_S2.
    assign rmw_as_hold = (state == ST_RMW_READ_S6)  | (state == ST_RMW_READ_S7) |
                         (state == ST_RMW_WRITE_S0) | (state == ST_RMW_WRITE_S1);

    // bus_lock: suppress DMA during RMW, CAS2, and burst sequences
    assign bus_lock = (state == ST_RMW_READ_S0)  | (state == ST_RMW_READ_S1)  |
                      (state == ST_RMW_READ_S2)  | (state == ST_RMW_READ_S3)  |
                      (state == ST_RMW_READ_S4)  | (state == ST_RMW_READ_S5)  |
                      (state == ST_RMW_READ_S6)  | (state == ST_RMW_READ_S7)  |
                      is_rmw_write | is_cas2 | is_burst;

    // Init-done and captured init vectors
    logic        init_done_r;
    logic [31:0] init_ssp_r, init_pc_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            init_done_r <= 1'b0; init_ssp_r <= 32'h0; init_pc_r <= 32'h0;
        end else begin
            if (phase_r == 2'd3 && !dsack_wait) begin
                if (state == ST_INIT_SSP_S4 || state == ST_INIT_SSP_S5) init_ssp_r <= ext_d_in;
                if (state == ST_INIT_PC_S4  || state == ST_INIT_PC_S5)  init_pc_r  <= ext_d_in;
            end
            if (state == ST_INIT_PC_S7 && phase_r == 2'd3) init_done_r <= 1'b1;
        end
    end

    assign init_done = init_done_r;
    assign init_ssp  = init_ssp_r;
    assign init_pc   = init_pc_r;

    // STERM fast termination (BIU-049): latched at S2
    logic sterm_latched_r;
    wire  sterm_active = sterm_latched_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) sterm_latched_r <= 1'b0;
        else if (phase_r == 2'd3) begin
            if (state == ST_IDLE || state == ST_RMW_READ_S7)
                sterm_latched_r <= 1'b0;  // clear between RMW phases too
            else if ((state == ST_READ_S2 || state == ST_WRITE_S2 ||
                      state == ST_RMW_READ_S2 || state == ST_RMW_WRITE_S2 ||
                      state == ST_CAS2_R1_S2 || state == ST_CAS2_W1_S2 ||
                      state == ST_CAS2_R2_S2 || state == ST_CAS2_W2_S2 ||
                      state == ST_BURST_S2    || state == ST_BWRITE_S2) && sterm_s)
                sterm_latched_r <= 1'b1;
        end
    end

    // BERR / retry / fault registers
    logic        berr_abort_r;
    logic        berr_is_halt_retry_r;  // 1 = BERR+HALT (retry), 0 = BERR (exception)
    logic [31:0] fault_addr_r, fault_data_r;
    logic [2:0]  fault_fc_r;
    logic        fault_rw_r;
    logic [1:0]  fault_siz_r;
    logic        fault_valid_r;
    logic        fault_retry_r, fault_is_rmw_r;
    logic        retry_r, in_retry_r;
    logic [31:0] retry_addr_r, retry_wdata_r;
    logic [2:0]  retry_fc_r;
    logic        retry_rw_r;
    logic [1:0]  retry_siz_r;
    logic        retry_is_op_r;

    // IACK capture and RSTOUT counter
    logic [7:0] iack_vec_r;
    logic       iack_avec_r;
    logic [7:0] rstout_cnt_r;

    // CAS2 read-data capture registers
    logic [31:0] cas2_rdata1_r, cas2_rdata2_r;

    // Burst data path delegated to biu_burst_ctrl (wires declared below)

    // Coprocessor cycle parameter latches and discriminator flag (Phase 10)
    logic [31:0] coproc_addr_r;
    logic [2:0]  coproc_fc_r;
    logic [1:0]  coproc_siz_r;
    logic        coproc_rw_r;
    logic [31:0] coproc_wdata_r;
    logic        cyc_is_coproc_r;   // 1 while ST_READ/WRITE serves a coproc req

    // Cycle parameter mux (declared here; needed by BERR capture block)
    logic [31:0] cyc_addr;
    logic [2:0]  cyc_fc;
    logic [1:0]  cyc_siz;
    logic        cyc_rw;
    logic        cyc_is_op;
    logic [31:0] cyc_wdata;

    // Byte lane control — UDS_n/LDS_n enables and steered write data
    logic [31:0] blc_wdata;

    biu_byte_lane_ctrl u_blc (
        .siz      (cyc_siz),
        .addr     (cyc_addr[1:0]),
        .wdata_in (cyc_wdata),
        .wdata_out(blc_wdata)
    );

    // -----------------------------------------------------------------------
    // Burst state decode signals fed to biu_burst_ctrl
    // -----------------------------------------------------------------------
    logic at_burst_data_phase;
    assign at_burst_data_phase =
        (state == ST_BURST_S4)       | (state == ST_BURST_S5)       |
        (state == ST_BURST_NEXT_S4)  | (state == ST_BURST_NEXT_S5)  |
        (state == ST_BWRITE_S4)      | (state == ST_BWRITE_S5)      |
        (state == ST_BWRITE_NEXT_S4) | (state == ST_BWRITE_NEXT_S5);

    logic at_burst_s7_wire;
    assign at_burst_s7_wire =
        (state == ST_BURST_S7)      | (state == ST_BURST_NEXT_S7) |
        (state == ST_BWRITE_S7)     | (state == ST_BWRITE_NEXT_S7);

    // VPA termination: VPA# asserted (vpa_s=0, active-low) AND E-clock is at
    // count 9 (E falls on this same clock edge: 9→0 transition fires at phase_r==3).
    // Cycles that receive VPA# instead of DSACK# synchronize their termination
    // to the E-clock falling edge per the 68030 UM section 7.4.2.
    logic vpa_terminate;
    assign vpa_terminate = !vpa_s && (eclk_cnt == 4'd9);

    // Address error conditions (Phase 19).
    // eu_ae_cond:  word access (SIZ=10) to odd address.  Byte is always legal;
    //              longword misalignment is resolved by the BIU via multiple cycles.
    // ifu_ae_cond: any instruction fetch to an odd address; instructions are
    //              always word-aligned on the 68030.
    logic eu_ae_cond;
    assign eu_ae_cond  = eu_siz[1] & ~eu_siz[0] & eu_addr[0];
    logic ifu_ae_cond;
    assign ifu_ae_cond = ifu_addr[0];

    logic data_capture_ok;
    assign data_capture_ok = ((!dsack_wait || sterm_active) || vpa_terminate) && !berr_s;

    // biu_burst_ctrl output wires
    logic [1:0]  bc_burst_beat;
    logic [31:0] bc_burst_addr;
    logic [2:0]  bc_burst_fc;
    logic        bc_cback_ok;
    logic [31:0] bc_m16_wdata_mux;
    logic [31:0] bc_burst_rdata0, bc_burst_rdata1;
    logic [31:0] bc_burst_rdata2, bc_burst_rdata3;
    logic        bc_cbreq_assert;
    logic        bc_eu_burst_ack, bc_eu_burst_berr;
    logic        bc_eu_m16_ack,   bc_eu_m16_berr;

    biu_burst_ctrl u_bc (
        .clk_4x          (clk_4x),
        .rst_n           (rst_n),
        .phase_r         (phase_r),
        .is_burst_read   (is_burst_read),
        .is_burst_write  (is_burst_write),
        .at_burst_data   (at_burst_data_phase),
        .data_capture_ok (data_capture_ok),
        .at_burst_s7     (at_burst_s7_wire),
        .at_idle         (state == ST_IDLE),
        .berr_abort_r    (berr_abort_r),
        .cback_s         (cback_s),
        .ext_d_in        (ext_d_in),
        .eu_burst_req    (eu_burst_req),
        .eu_burst_addr   (eu_burst_addr),
        .eu_burst_fc     (eu_burst_fc),
        .eu_m16_req      (eu_m16_req),
        .eu_m16_addr     (eu_m16_addr),
        .eu_m16_fc       (eu_m16_fc),
        .eu_m16_wdata0   (eu_m16_wdata0),
        .eu_m16_wdata1   (eu_m16_wdata1),
        .eu_m16_wdata2   (eu_m16_wdata2),
        .eu_m16_wdata3   (eu_m16_wdata3),
        .burst_beat      (bc_burst_beat),
        .burst_addr      (bc_burst_addr),
        .burst_fc        (bc_burst_fc),
        .cback_ok        (bc_cback_ok),
        .m16_wdata_mux   (bc_m16_wdata_mux),
        .burst_rdata0    (bc_burst_rdata0),
        .burst_rdata1    (bc_burst_rdata1),
        .burst_rdata2    (bc_burst_rdata2),
        .burst_rdata3    (bc_burst_rdata3),
        .cbreq_assert    (bc_cbreq_assert),
        .eu_burst_ack    (bc_eu_burst_ack),
        .eu_burst_berr   (bc_eu_burst_berr),
        .eu_m16_ack      (bc_eu_m16_ack),
        .eu_m16_berr     (bc_eu_m16_berr)
    );

    always_comb begin
        cyc_addr  = 32'h0; cyc_fc = 3'b110; cyc_siz = 2'b00;
        cyc_rw    = 1'b1;  cyc_is_op = 1'b0; cyc_wdata = 32'h0;
        if (cyc_is_coproc_r) begin
            cyc_addr  = coproc_addr_r; cyc_fc    = coproc_fc_r;
            cyc_siz   = coproc_siz_r;  cyc_rw    = coproc_rw_r;
            cyc_wdata = coproc_wdata_r;
        end else if (is_burst_read) begin
            cyc_addr  = bc_burst_addr; cyc_fc = bc_burst_fc;
            cyc_siz   = 2'b11; cyc_rw = 1'b1;
        end else if (is_burst_write) begin
            cyc_addr  = bc_burst_addr; cyc_fc = bc_burst_fc;
            cyc_siz   = 2'b11; cyc_rw = 1'b0; cyc_wdata = bc_m16_wdata_mux;
        end else if (is_init_ssp) begin
            cyc_addr = 32'h0000_0000; cyc_fc = 3'b110;
        end else if (is_init_pc) begin
            cyc_addr = 32'h0000_0004; cyc_fc = 3'b110;
        end else if (is_iack) begin
            cyc_addr  = 32'hFFFFFFF0 | {28'h0, eu_iack_level, 1'b0};
            cyc_fc    = 3'b111; cyc_siz = 2'b00; cyc_rw = 1'b1; cyc_is_op = 1'b0;
        end else if (is_cas2_r1 | is_cas2_w1) begin
            cyc_addr  = eu_cas2_addr1; cyc_fc = eu_cas2_fc;
            cyc_siz   = eu_cas2_siz;   cyc_is_op = 1'b0;
            cyc_rw    = is_cas2_r1 ? 1'b1 : 1'b0;
            cyc_wdata = eu_cas2_wdata1;
        end else if (is_cas2_r2 | is_cas2_w2) begin
            cyc_addr  = eu_cas2_addr2; cyc_fc = eu_cas2_fc;
            cyc_siz   = eu_cas2_siz;   cyc_is_op = 1'b0;
            cyc_rw    = is_cas2_r2 ? 1'b1 : 1'b0;
            cyc_wdata = eu_cas2_wdata2;
        end else if (in_retry_r) begin
            cyc_addr  = retry_addr_r;  cyc_fc    = retry_fc_r;
            cyc_siz   = retry_siz_r;   cyc_rw    = retry_rw_r;
            cyc_is_op = retry_is_op_r; cyc_wdata = retry_wdata_r;
        end else if (grant_mmu) begin
            cyc_addr = mmu_addr; cyc_fc = mmu_fc;
        end else if (grant_eu) begin
            cyc_addr  = eu_addr;       cyc_fc    = eu_fc;
            cyc_siz   = eu_siz;        cyc_is_op = eu_is_operand;
            // RMW write phase: force rw=0 and use eu_wdata; EU keeps addr stable
            cyc_rw    = is_rmw_write ? 1'b0 : eu_rw;
            cyc_wdata = eu_wdata;
        end else if (grant_ifu) begin
            cyc_addr = ifu_addr; cyc_fc = 3'b110; cyc_siz = 2'b10;
        end
    end

    // BERR / retry / fault always_ff
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            berr_abort_r        <= 1'b0; berr_is_halt_retry_r <= 1'b0;
            fault_valid_r       <= 1'b0;
            fault_addr_r  <= 32'h0; fault_data_r <= 32'h0;
            fault_fc_r    <= 3'b0;  fault_rw_r   <= 1'b1; fault_siz_r <= 2'b0;
            fault_retry_r <= 1'b0;  fault_is_rmw_r <= 1'b0;
            retry_r       <= 1'b0;  in_retry_r   <= 1'b0;
            retry_addr_r  <= 32'h0; retry_wdata_r <= 32'h0;
            retry_fc_r    <= 3'b0;  retry_rw_r   <= 1'b1;
            retry_siz_r   <= 2'b0;  retry_is_op_r <= 1'b0;
        end else if (phase_r == 2'd3) begin
            if ((is_S4_or_S5 || is_S6) && berr_s) begin
                berr_abort_r <= 1'b1;
                if (!halt_s && !in_retry_r) begin
                    // BERR + HALT asserted: retry the cycle
                    berr_is_halt_retry_r <= 1'b1;
                    retry_r       <= 1'b1;
                    retry_addr_r  <= cyc_addr; retry_wdata_r <= cyc_wdata;
                    retry_fc_r    <= cyc_fc;   retry_rw_r    <= cyc_rw;
                    retry_siz_r   <= cyc_siz;  retry_is_op_r <= cyc_is_op;
                end else begin
                    // Plain BERR (no HALT) or BERR during retry → exception
                    berr_is_halt_retry_r <= 1'b0;
                    fault_valid_r  <= 1'b1;
                    fault_addr_r   <= cyc_addr; fault_data_r  <= ext_d_in;
                    fault_fc_r     <= cyc_fc;   fault_rw_r    <= cyc_rw;
                    fault_siz_r    <= cyc_siz;
                    fault_retry_r  <= in_retry_r;
                    fault_is_rmw_r <= is_rmw_write;
                end
            end
            // Clear berr_abort_r and berr_is_halt_retry_r at S7
            if (is_S7) begin
                berr_abort_r        <= 1'b0;
                berr_is_halt_retry_r <= 1'b0;
            end
            if (state == ST_IDLE && retry_r && !in_retry_r) in_retry_r <= 1'b1;
            if (in_retry_r && (state == ST_READ_S7 || state == ST_WRITE_S7)) begin
                in_retry_r <= 1'b0; retry_r <= 1'b0;
            end
            // fault_valid is latched and held per BIU-090; cleared only by reset
            // (the EU reads fault_addr/data/fc from the outputs and acknowledges separately)
        end
    end

    assign fault_addr    = fault_addr_r;
    assign fault_data    = fault_data_r;
    assign fault_fc      = fault_fc_r;
    assign fault_rw      = fault_rw_r;
    assign fault_siz     = fault_siz_r;
    assign fault_valid   = fault_valid_r;
    assign retry_pending = retry_r;
    assign fault_retry   = fault_retry_r;
    assign fault_is_rmw  = fault_is_rmw_r;

    // IACK vector capture
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin iack_vec_r <= 8'h00; iack_avec_r <= 1'b0; end
        else if (phase_r == 2'd3) begin
            if ((state == ST_IACK_S4 || state == ST_IACK_S5) && !berr_s) begin
                if (avec_s || vpa_terminate) begin
                    // AVEC# or VPA# (autovector): compute vector from interrupt level
                    iack_vec_r  <= 8'd24 + {5'b0, eu_iack_level};
                    iack_avec_r <= 1'b1;
                end else if (!dsack_wait) begin
                    // DSACK# with vector on D[7:0]: use peripheral-supplied vector
                    iack_vec_r  <= ext_d_in[7:0];
                    iack_avec_r <= 1'b0;
                end
            end
            if (state == ST_IDLE) iack_avec_r <= 1'b0;
        end
    end

    // RESET instruction counter
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) rstout_cnt_r <= 8'h0;
        else if (phase_r == 2'd3) begin
            if (state == ST_IDLE && eu_rst_req && init_done_r && !retry_r && !eu_iack_req)
                rstout_cnt_r <= RSTOUT_CLKS[7:0] - 8'd1;
            else if (state == ST_RESET_INST && rstout_cnt_r != 8'h0)
                rstout_cnt_r <= rstout_cnt_r - 8'h1;
        end
    end

    // Captured read data
    logic [31:0] captured_rdata;
    logic [1:0]  port_dsack_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            port_dsack_r    <= 2'b00;
            captured_rdata  <= 32'h0;
            cas2_rdata1_r   <= 32'h0;
            cas2_rdata2_r   <= 32'h0;
            coproc_addr_r   <= 32'h0; coproc_fc_r    <= 3'b0;
            coproc_siz_r    <= 2'b0;  coproc_rw_r    <= 1'b1;
            coproc_wdata_r  <= 32'h0; cyc_is_coproc_r <= 1'b0;
        end else if (phase_r == 2'd3) begin
            if (!dsack_wait) begin
                if (state == ST_READ_S4  || state == ST_READ_S5  ||
                    state == ST_WRITE_S4 || state == ST_WRITE_S5)
                    port_dsack_r <= {dsack1_s, dsack0_s};
            end
            if ((!dsack_wait || sterm_active || vpa_terminate) && !berr_s) begin
                if (state == ST_READ_S4     || state == ST_READ_S5     ||
                    state == ST_RMW_READ_S4 || state == ST_RMW_READ_S5)
                    captured_rdata <= ext_d_in;
                if (state == ST_CAS2_R1_S4 || state == ST_CAS2_R1_S5)
                    cas2_rdata1_r  <= ext_d_in;
                if (state == ST_CAS2_R2_S4 || state == ST_CAS2_R2_S5)
                    cas2_rdata2_r  <= ext_d_in;
            end
            // Latch coprocessor parameters and set discriminator at IDLE→coproc
            if (state == ST_IDLE && eu_coproc_req && init_done_r && !retry_r) begin
                coproc_addr_r   <= eu_coproc_addr;
                coproc_fc_r     <= eu_coproc_fc;
                coproc_siz_r    <= eu_coproc_siz;
                coproc_rw_r     <= eu_coproc_rw;
                coproc_wdata_r  <= eu_coproc_wdata;
                cyc_is_coproc_r <= 1'b1;
            end
            if (is_S7) cyc_is_coproc_r <= 1'b0;
        end
    end

    assign cyc_port_dsack = port_dsack_r;

    // S-phase abstraction
    localparam logic [3:0] SP_NONE = 4'd15;
    localparam logic [3:0] SP_S0   = 4'd0;
    localparam logic [3:0] SP_S1   = 4'd1;
    localparam logic [3:0] SP_S2   = 4'd2;
    localparam logic [3:0] SP_S3   = 4'd3;
    localparam logic [3:0] SP_S4   = 4'd4;
    localparam logic [3:0] SP_S5   = 4'd5;
    localparam logic [3:0] SP_S6   = 4'd6;
    localparam logic [3:0] SP_S7   = 4'd7;

    logic [3:0] sphase;
    always_comb begin
        case (state)
            ST_INIT_SSP_S0, ST_INIT_PC_S0, ST_READ_S0,  ST_WRITE_S0,  ST_IACK_S0,
            ST_RMW_READ_S0, ST_RMW_WRITE_S0,
            ST_CAS2_R1_S0, ST_CAS2_W1_S0, ST_CAS2_R2_S0, ST_CAS2_W2_S0,
            ST_BURST_S0, ST_BWRITE_S0: sphase = SP_S0;

            ST_INIT_SSP_S1, ST_INIT_PC_S1, ST_READ_S1,  ST_WRITE_S1,  ST_IACK_S1,
            ST_RMW_READ_S1, ST_RMW_WRITE_S1,
            ST_CAS2_R1_S1, ST_CAS2_W1_S1, ST_CAS2_R2_S1, ST_CAS2_W2_S1,
            ST_BURST_S1, ST_BWRITE_S1: sphase = SP_S1;

            ST_INIT_SSP_S2, ST_INIT_PC_S2, ST_READ_S2,  ST_WRITE_S2,  ST_IACK_S2,
            ST_RMW_READ_S2, ST_RMW_WRITE_S2,
            ST_CAS2_R1_S2, ST_CAS2_W1_S2, ST_CAS2_R2_S2, ST_CAS2_W2_S2,
            ST_BURST_S2, ST_BWRITE_S2: sphase = SP_S2;

            ST_INIT_SSP_S3, ST_INIT_PC_S3, ST_READ_S3,  ST_WRITE_S3,  ST_IACK_S3,
            ST_RMW_READ_S3, ST_RMW_WRITE_S3,
            ST_CAS2_R1_S3, ST_CAS2_W1_S3, ST_CAS2_R2_S3, ST_CAS2_W2_S3,
            ST_BURST_S3, ST_BURST_NEXT_S3, ST_BWRITE_S3, ST_BWRITE_NEXT_S3: sphase = SP_S3;

            ST_INIT_SSP_S4, ST_INIT_PC_S4, ST_READ_S4,  ST_WRITE_S4,  ST_IACK_S4,
            ST_RMW_READ_S4, ST_RMW_WRITE_S4,
            ST_CAS2_R1_S4, ST_CAS2_W1_S4, ST_CAS2_R2_S4, ST_CAS2_W2_S4,
            ST_BURST_S4, ST_BURST_NEXT_S4, ST_BWRITE_S4, ST_BWRITE_NEXT_S4: sphase = SP_S4;

            ST_INIT_SSP_S5, ST_INIT_PC_S5, ST_READ_S5,  ST_WRITE_S5,  ST_IACK_S5,
            ST_RMW_READ_S5, ST_RMW_WRITE_S5,
            ST_CAS2_R1_S5, ST_CAS2_W1_S5, ST_CAS2_R2_S5, ST_CAS2_W2_S5,
            ST_BURST_S5, ST_BURST_NEXT_S5, ST_BWRITE_S5, ST_BWRITE_NEXT_S5: sphase = SP_S5;

            ST_INIT_SSP_S6, ST_INIT_PC_S6, ST_READ_S6,  ST_WRITE_S6,  ST_IACK_S6,
            ST_RMW_READ_S6, ST_RMW_WRITE_S6,
            ST_CAS2_R1_S6, ST_CAS2_W1_S6, ST_CAS2_R2_S6, ST_CAS2_W2_S6,
            ST_BURST_S6, ST_BURST_NEXT_S6, ST_BWRITE_S6, ST_BWRITE_NEXT_S6: sphase = SP_S6;

            ST_INIT_SSP_S7, ST_INIT_PC_S7, ST_READ_S7,  ST_WRITE_S7,  ST_IACK_S7,
            ST_RMW_READ_S7, ST_RMW_WRITE_S7,
            ST_CAS2_R1_S7, ST_CAS2_W1_S7, ST_CAS2_R2_S7, ST_CAS2_W2_S7,
            ST_BURST_S7, ST_BURST_NEXT_S7, ST_BWRITE_S7, ST_BWRITE_NEXT_S7: sphase = SP_S7;

            default: sphase = SP_NONE;
        endcase
    end

    // Next-state logic
    always_comb begin
        state_nxt = state;
        unique case (state)
            ST_RESET: if (rst_s2) state_nxt = ST_IDLE;

            ST_IDLE: begin
                if (!init_done_r) begin
                    state_nxt = ST_INIT_SSP_S0;
                end else if (retry_r) begin
                    // Retry takes priority over HALT# — bus was already committed
                    if (retry_rw_r) state_nxt = ST_READ_S0;
                    else            state_nxt = ST_WRITE_S0;
                end else if (!halt_s) begin
                    // HALT# asserted (standalone, no BERR): suspend new bus cycles.
                    // Any in-progress cycle already ran to completion before reaching
                    // IDLE; here we simply hold IDLE until HALT# deasserts.
                end else if (eu_iack_req) begin
                    state_nxt = ST_IACK_S0;
                end else if (eu_rst_req) begin
                    state_nxt = ST_RESET_INST;
                end else if (eu_cas2_req) begin
                    state_nxt = ST_CAS2_R1_S0;
                end else if (eu_burst_req) begin
                    state_nxt = ST_BURST_S0;
                end else if (eu_m16_req) begin
                    state_nxt = ST_BWRITE_S0;
                end else if (eu_coproc_req) begin
                    if (eu_coproc_rw) state_nxt = ST_READ_S0;
                    else              state_nxt = ST_WRITE_S0;
                end else if (!dma_active) begin
                    if (grant_mmu && mmu_req) begin
                        state_nxt = ST_READ_S0;
                    end else if (grant_eu && eu_req) begin
                        if (eu_ae_cond)
                            ; // address error: reject, eu_addr_err asserted in output block
                        else if (eu_rmw)  state_nxt = ST_RMW_READ_S0;
                        else if (eu_rw)   state_nxt = ST_READ_S0;
                        else              state_nxt = ST_WRITE_S0;
                    end else if (grant_ifu && ifu_req) begin
                        if (ifu_ae_cond)
                            ; // address error: reject, ifu_addr_err asserted in output block
                        else
                            state_nxt = ST_READ_S0;
                    end
                end
            end

            ST_INIT_SSP_S0: state_nxt = ST_INIT_SSP_S1;
            ST_INIT_SSP_S1: state_nxt = ST_INIT_SSP_S2;
            ST_INIT_SSP_S2: state_nxt = ST_INIT_SSP_S3;
            ST_INIT_SSP_S3: state_nxt = ST_INIT_SSP_S4;
            ST_INIT_SSP_S4: begin
                if (dsack_wait) state_nxt = ST_INIT_SSP_S5; else state_nxt = ST_INIT_SSP_S6;
            end
            ST_INIT_SSP_S5: begin
                if (dsack_wait) state_nxt = ST_INIT_SSP_S5; else state_nxt = ST_INIT_SSP_S6;
            end
            ST_INIT_SSP_S6: state_nxt = ST_INIT_SSP_S7;
            ST_INIT_SSP_S7: state_nxt = ST_INIT_PC_S0;

            ST_INIT_PC_S0: state_nxt = ST_INIT_PC_S1;
            ST_INIT_PC_S1: state_nxt = ST_INIT_PC_S2;
            ST_INIT_PC_S2: state_nxt = ST_INIT_PC_S3;
            ST_INIT_PC_S3: state_nxt = ST_INIT_PC_S4;
            ST_INIT_PC_S4: begin
                if (dsack_wait) state_nxt = ST_INIT_PC_S5; else state_nxt = ST_INIT_PC_S6;
            end
            ST_INIT_PC_S5: begin
                if (dsack_wait) state_nxt = ST_INIT_PC_S5; else state_nxt = ST_INIT_PC_S6;
            end
            ST_INIT_PC_S6: state_nxt = ST_INIT_PC_S7;
            ST_INIT_PC_S7: state_nxt = ST_IDLE;

            ST_READ_S0: state_nxt = ST_READ_S1;
            ST_READ_S1: state_nxt = ST_READ_S2;
            ST_READ_S2: state_nxt = ST_READ_S3;
            ST_READ_S3: state_nxt = ST_READ_S4;
            ST_READ_S4: begin
                if      (berr_s)                         state_nxt = ST_READ_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_READ_S6;
                else if (vpa_terminate)                  state_nxt = ST_READ_S6;
                else                                     state_nxt = ST_READ_S5;
            end
            ST_READ_S5: begin
                if      (berr_s)                         state_nxt = ST_READ_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_READ_S6;
                else if (vpa_terminate)                  state_nxt = ST_READ_S6;
                else                                     state_nxt = ST_READ_S5;
            end
            ST_READ_S6: state_nxt = ST_READ_S7;
            ST_READ_S7: state_nxt = ST_IDLE;

            ST_WRITE_S0: state_nxt = ST_WRITE_S1;
            ST_WRITE_S1: state_nxt = ST_WRITE_S2;
            ST_WRITE_S2: state_nxt = ST_WRITE_S3;
            ST_WRITE_S3: state_nxt = ST_WRITE_S4;
            ST_WRITE_S4: begin
                if      (berr_s)                         state_nxt = ST_WRITE_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_WRITE_S6;
                else if (vpa_terminate)                  state_nxt = ST_WRITE_S6;
                else                                     state_nxt = ST_WRITE_S5;
            end
            ST_WRITE_S5: begin
                if      (berr_s)                         state_nxt = ST_WRITE_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_WRITE_S6;
                else if (vpa_terminate)                  state_nxt = ST_WRITE_S6;
                else                                     state_nxt = ST_WRITE_S5;
            end
            ST_WRITE_S6: state_nxt = ST_WRITE_S7;
            ST_WRITE_S7: state_nxt = ST_IDLE;

            ST_IACK_S0: state_nxt = ST_IACK_S1;
            ST_IACK_S1: state_nxt = ST_IACK_S2;
            ST_IACK_S2: state_nxt = ST_IACK_S3;
            ST_IACK_S3: state_nxt = ST_IACK_S4;
            ST_IACK_S4: begin
                if      (berr_s)                  state_nxt = ST_IACK_S6;
                else if (avec_s || !dsack_wait)   state_nxt = ST_IACK_S6;
                else if (vpa_terminate)            state_nxt = ST_IACK_S6;
                else                              state_nxt = ST_IACK_S5;
            end
            ST_IACK_S5: begin
                if      (berr_s)                  state_nxt = ST_IACK_S6;
                else if (avec_s || !dsack_wait)   state_nxt = ST_IACK_S6;
                else if (vpa_terminate)            state_nxt = ST_IACK_S6;
                else                              state_nxt = ST_IACK_S5;
            end
            ST_IACK_S6: state_nxt = ST_IACK_S7;
            ST_IACK_S7: state_nxt = ST_IDLE;

            ST_RESET_INST: begin
                if (rstout_cnt_r == 8'h0) state_nxt = ST_IDLE;
            end

            // RMW: read phase S0-S7, then write phase S0-S7, no bus release
            ST_RMW_READ_S0: state_nxt = ST_RMW_READ_S1;
            ST_RMW_READ_S1: state_nxt = ST_RMW_READ_S2;
            ST_RMW_READ_S2: state_nxt = ST_RMW_READ_S3;
            ST_RMW_READ_S3: state_nxt = ST_RMW_READ_S4;
            ST_RMW_READ_S4: begin
                if      (berr_s)                       state_nxt = ST_RMW_READ_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_RMW_READ_S6;
                else                                   state_nxt = ST_RMW_READ_S5;
            end
            ST_RMW_READ_S5: begin
                if      (berr_s)                       state_nxt = ST_RMW_READ_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_RMW_READ_S6;
                else                                   state_nxt = ST_RMW_READ_S5;
            end
            ST_RMW_READ_S6: state_nxt = ST_RMW_READ_S7;
            ST_RMW_READ_S7: state_nxt = ST_RMW_WRITE_S0; // no bus release!
            ST_RMW_WRITE_S0: state_nxt = ST_RMW_WRITE_S1;
            ST_RMW_WRITE_S1: state_nxt = ST_RMW_WRITE_S2;
            ST_RMW_WRITE_S2: state_nxt = ST_RMW_WRITE_S3;
            ST_RMW_WRITE_S3: state_nxt = ST_RMW_WRITE_S4;
            ST_RMW_WRITE_S4: begin
                if      (berr_s)      state_nxt = ST_RMW_WRITE_S6;
                else if (!dsack_wait) state_nxt = ST_RMW_WRITE_S6;
                else                  state_nxt = ST_RMW_WRITE_S5;
            end
            ST_RMW_WRITE_S5: begin
                if      (berr_s)      state_nxt = ST_RMW_WRITE_S6;
                else if (!dsack_wait) state_nxt = ST_RMW_WRITE_S6;
                else                  state_nxt = ST_RMW_WRITE_S5;
            end
            ST_RMW_WRITE_S6: state_nxt = ST_RMW_WRITE_S7;
            ST_RMW_WRITE_S7: state_nxt = ST_IDLE;

            // CAS2: R1→(W1 if do_write1)→R2→(W2 if do_write2)→IDLE
            ST_CAS2_R1_S0: state_nxt = ST_CAS2_R1_S1;
            ST_CAS2_R1_S1: state_nxt = ST_CAS2_R1_S2;
            ST_CAS2_R1_S2: state_nxt = ST_CAS2_R1_S3;
            ST_CAS2_R1_S3: state_nxt = ST_CAS2_R1_S4;
            ST_CAS2_R1_S4: begin
                if      (berr_s)                       state_nxt = ST_CAS2_R1_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_CAS2_R1_S6;
                else                                   state_nxt = ST_CAS2_R1_S5;
            end
            ST_CAS2_R1_S5: begin
                if      (berr_s)                       state_nxt = ST_CAS2_R1_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_CAS2_R1_S6;
                else                                   state_nxt = ST_CAS2_R1_S5;
            end
            ST_CAS2_R1_S6: state_nxt = ST_CAS2_R1_S7;
            ST_CAS2_R1_S7:
                if      (berr_abort_r)       state_nxt = ST_IDLE;
                else if (eu_cas2_do_write1)  state_nxt = ST_CAS2_W1_S0;
                else                         state_nxt = ST_CAS2_R2_S0;
            ST_CAS2_W1_S0: state_nxt = ST_CAS2_W1_S1;
            ST_CAS2_W1_S1: state_nxt = ST_CAS2_W1_S2;
            ST_CAS2_W1_S2: state_nxt = ST_CAS2_W1_S3;
            ST_CAS2_W1_S3: state_nxt = ST_CAS2_W1_S4;
            ST_CAS2_W1_S4: begin
                if      (berr_s)      state_nxt = ST_CAS2_W1_S6;
                else if (!dsack_wait) state_nxt = ST_CAS2_W1_S6;
                else                  state_nxt = ST_CAS2_W1_S5;
            end
            ST_CAS2_W1_S5: begin
                if      (berr_s)      state_nxt = ST_CAS2_W1_S6;
                else if (!dsack_wait) state_nxt = ST_CAS2_W1_S6;
                else                  state_nxt = ST_CAS2_W1_S5;
            end
            ST_CAS2_W1_S6: state_nxt = ST_CAS2_W1_S7;
            ST_CAS2_W1_S7:
                if (berr_abort_r) state_nxt = ST_IDLE;
                else              state_nxt = ST_CAS2_R2_S0;
            ST_CAS2_R2_S0: state_nxt = ST_CAS2_R2_S1;
            ST_CAS2_R2_S1: state_nxt = ST_CAS2_R2_S2;
            ST_CAS2_R2_S2: state_nxt = ST_CAS2_R2_S3;
            ST_CAS2_R2_S3: state_nxt = ST_CAS2_R2_S4;
            ST_CAS2_R2_S4: begin
                if      (berr_s)                       state_nxt = ST_CAS2_R2_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_CAS2_R2_S6;
                else                                   state_nxt = ST_CAS2_R2_S5;
            end
            ST_CAS2_R2_S5: begin
                if      (berr_s)                       state_nxt = ST_CAS2_R2_S6;
                else if (sterm_active || !dsack_wait)  state_nxt = ST_CAS2_R2_S6;
                else                                   state_nxt = ST_CAS2_R2_S5;
            end
            ST_CAS2_R2_S6: state_nxt = ST_CAS2_R2_S7;
            ST_CAS2_R2_S7:
                if      (berr_abort_r)      state_nxt = ST_IDLE;
                else if (eu_cas2_do_write2) state_nxt = ST_CAS2_W2_S0;
                else                        state_nxt = ST_IDLE;
            ST_CAS2_W2_S0: state_nxt = ST_CAS2_W2_S1;
            ST_CAS2_W2_S1: state_nxt = ST_CAS2_W2_S2;
            ST_CAS2_W2_S2: state_nxt = ST_CAS2_W2_S3;
            ST_CAS2_W2_S3: state_nxt = ST_CAS2_W2_S4;
            ST_CAS2_W2_S4: begin
                if      (berr_s)      state_nxt = ST_CAS2_W2_S6;
                else if (!dsack_wait) state_nxt = ST_CAS2_W2_S6;
                else                  state_nxt = ST_CAS2_W2_S5;
            end
            ST_CAS2_W2_S5: begin
                if      (berr_s)      state_nxt = ST_CAS2_W2_S6;
                else if (!dsack_wait) state_nxt = ST_CAS2_W2_S6;
                else                  state_nxt = ST_CAS2_W2_S5;
            end
            ST_CAS2_W2_S6: state_nxt = ST_CAS2_W2_S7;
            ST_CAS2_W2_S7: state_nxt = ST_IDLE;

            // Burst read: beat 0 (S0-S7) then beats 1-3 (NEXT_S3-S7 reused)
            ST_BURST_S0: state_nxt = ST_BURST_S1;
            ST_BURST_S1: state_nxt = ST_BURST_S2;
            ST_BURST_S2: state_nxt = ST_BURST_S3;
            ST_BURST_S3: state_nxt = ST_BURST_S4;
            ST_BURST_S4: begin
                if      (berr_s)                         state_nxt = ST_BURST_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_BURST_S6;
                else                                     state_nxt = ST_BURST_S5;
            end
            ST_BURST_S5: begin
                if      (berr_s)                         state_nxt = ST_BURST_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_BURST_S6;
                else                                     state_nxt = ST_BURST_S5;
            end
            ST_BURST_S6: state_nxt = ST_BURST_S7;
            ST_BURST_S7: begin
                if (!berr_abort_r && bc_cback_ok && bc_burst_beat < 2'd3)
                                                           state_nxt = ST_BURST_NEXT_S3;
                else                                       state_nxt = ST_IDLE;
            end
            ST_BURST_NEXT_S3: state_nxt = ST_BURST_NEXT_S4;
            ST_BURST_NEXT_S4: begin
                if      (berr_s)                         state_nxt = ST_BURST_NEXT_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_BURST_NEXT_S6;
                else                                     state_nxt = ST_BURST_NEXT_S5;
            end
            ST_BURST_NEXT_S5: begin
                if      (berr_s)                         state_nxt = ST_BURST_NEXT_S6;
                else if (sterm_active || !dsack_wait)    state_nxt = ST_BURST_NEXT_S6;
                else                                     state_nxt = ST_BURST_NEXT_S5;
            end
            ST_BURST_NEXT_S6: state_nxt = ST_BURST_NEXT_S7;
            ST_BURST_NEXT_S7: begin
                if (!berr_abort_r && bc_burst_beat < 2'd3) state_nxt = ST_BURST_NEXT_S3;
                else                                       state_nxt = ST_IDLE;
            end

            // MOVE16 burst write: same structure, RW=0
            ST_BWRITE_S0: state_nxt = ST_BWRITE_S1;
            ST_BWRITE_S1: state_nxt = ST_BWRITE_S2;
            ST_BWRITE_S2: state_nxt = ST_BWRITE_S3;
            ST_BWRITE_S3: state_nxt = ST_BWRITE_S4;
            ST_BWRITE_S4: begin
                if      (berr_s)                      state_nxt = ST_BWRITE_S6;
                else if (sterm_active || !dsack_wait) state_nxt = ST_BWRITE_S6;
                else                                  state_nxt = ST_BWRITE_S5;
            end
            ST_BWRITE_S5: begin
                if      (berr_s)                      state_nxt = ST_BWRITE_S6;
                else if (sterm_active || !dsack_wait) state_nxt = ST_BWRITE_S6;
                else                                  state_nxt = ST_BWRITE_S5;
            end
            ST_BWRITE_S6: state_nxt = ST_BWRITE_S7;
            ST_BWRITE_S7: begin
                if (!berr_abort_r && bc_cback_ok && bc_burst_beat < 2'd3)
                                                           state_nxt = ST_BWRITE_NEXT_S3;
                else                                       state_nxt = ST_IDLE;
            end
            ST_BWRITE_NEXT_S3: state_nxt = ST_BWRITE_NEXT_S4;
            ST_BWRITE_NEXT_S4: begin
                if      (berr_s)                      state_nxt = ST_BWRITE_NEXT_S6;
                else if (sterm_active || !dsack_wait) state_nxt = ST_BWRITE_NEXT_S6;
                else                                  state_nxt = ST_BWRITE_NEXT_S5;
            end
            ST_BWRITE_NEXT_S5: begin
                if      (berr_s)                      state_nxt = ST_BWRITE_NEXT_S6;
                else if (sterm_active || !dsack_wait) state_nxt = ST_BWRITE_NEXT_S6;
                else                                  state_nxt = ST_BWRITE_NEXT_S5;
            end
            ST_BWRITE_NEXT_S6: state_nxt = ST_BWRITE_NEXT_S7;
            ST_BWRITE_NEXT_S7: begin
                if (!berr_abort_r && bc_burst_beat < 2'd3) state_nxt = ST_BWRITE_NEXT_S3;
                else                                       state_nxt = ST_IDLE;
            end

            default: state_nxt = ST_IDLE;
        endcase
    end

    // Combinational bus output logic
    always_comb begin
        ext_a        = 32'h0; ext_as_n = 1'b1; ext_ds_n = 1'b1;
        ext_rw       = 1'b1;  ext_fc   = 3'b0; ext_siz  = 2'b0;
        ext_ecs_n    = 1'b1;  ext_ocs_n = 1'b1;
        ext_d_out    = 32'h0; ext_d_oe = 1'b0;
        ext_rstout_n = 1'b1;  ext_cbreq_n = 1'b1;
        eu_rdata     = 32'h0; eu_ack   = 1'b0; eu_berr = 1'b0; eu_retry = 1'b0;
        ifu_rdata    = 32'h0; ifu_ack  = 1'b0; ifu_berr = 1'b0;
        mmu_rdata    = 32'h0; mmu_ack  = 1'b0; mmu_berr = 1'b0;
        eu_iack_vec  = 8'h00; eu_iack_avec = 1'b0; eu_iack_ack = 1'b0;
        eu_coproc_rdata = 32'h0; eu_coproc_ack = 1'b0; eu_coproc_berr = 1'b0;
        eu_cas2_rdata1 = cas2_rdata1_r;
        eu_cas2_rdata2 = cas2_rdata2_r;
        eu_cas2_ack    = 1'b0;
        eu_burst_rdata0 = bc_burst_rdata0; eu_burst_rdata1 = bc_burst_rdata1;
        eu_burst_rdata2 = bc_burst_rdata2; eu_burst_rdata3 = bc_burst_rdata3;
        eu_burst_ack = bc_eu_burst_ack; eu_burst_berr = bc_eu_burst_berr;
        eu_m16_ack   = bc_eu_m16_ack;   eu_m16_berr   = bc_eu_m16_berr;
        eu_addr_err  = 1'b0; ifu_addr_err = 1'b0;

        if (state == ST_RESET_INST) ext_rstout_n = 1'b0;

        // Address error: combinationally reject at IDLE when request is misaligned.
        // The bus cycle does not start; the requesting unit must deassert its req.
        if (state == ST_IDLE && !dma_active) begin
            if (grant_eu && eu_req && eu_ae_cond)
                eu_addr_err = 1'b1;
            if (grant_ifu && ifu_req && ifu_ae_cond)
                ifu_addr_err = 1'b1;
        end

        if (!dma_active) begin
            case (sphase)
                SP_S0: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz;
                    ext_rw = cyc_rw;
                    // ECS# deasserted at S0; it asserts only in the 2nd half of S1
                    if (bc_cbreq_assert) ext_cbreq_n = 1'b0;
                end
                SP_S1: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz;
                    ext_rw = cyc_rw;
                    // ECS# asserts for the 2nd half of S1 (phases 2-3), giving
                    // exactly 1/2 CLK setup before AS# asserts at S2.
                    if (phase_r >= 2'd2) ext_ecs_n = 1'b0;
                    // OCS# deasserted here; it asserts coincident with AS# at S2.
                    if (bc_cbreq_assert) ext_cbreq_n = 1'b0;
                end
                SP_S2: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz;
                    ext_rw = cyc_rw; ext_ocs_n = !cyc_is_op; ext_as_n = 1'b0;
                end
                SP_S3: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz; ext_rw = cyc_rw;
                    ext_ocs_n = !cyc_is_op; ext_as_n = 1'b0;
                    ext_ds_n  = 1'b0;   // DS asserts for all cycles incl. IACK
                    ext_d_oe  = !cyc_rw;
                    ext_d_out = cyc_rw ? 32'h0 : blc_wdata;
                end
                SP_S4, SP_S5: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz; ext_rw = cyc_rw;
                    ext_ocs_n = !cyc_is_op; ext_as_n = 1'b0;
                    ext_ds_n  = 1'b0;
                    ext_d_oe  = !cyc_rw;
                    ext_d_out = cyc_rw ? 32'h0 : blc_wdata;
                end
                SP_S6: begin
                    ext_a = cyc_addr; ext_fc = cyc_fc; ext_siz = cyc_siz;
                    ext_rw = cyc_rw; ext_ocs_n = 1'b1;
                    // Burst: hold AS asserted until the final beat's S6
                    ext_as_n = (is_burst && bc_burst_beat != 2'd3) ? 1'b0 : 1'b1;
                    ext_ds_n = 1'b1;
                end
                SP_S7: begin
                    if (is_iack) begin
                        eu_iack_vec  = iack_vec_r;
                        eu_iack_avec = iack_avec_r;
                        if (!berr_abort_r) eu_iack_ack = 1'b1;
                        else               eu_berr     = 1'b1;
                    end else if (is_init_ssp | is_init_pc) begin
                        // init fetches complete internally
                    end else if (is_cas2) begin
                        if (berr_abort_r) begin
                            // BERR on any CAS2 sub-cycle aborts the entire atomic sequence.
                            // The state machine redirects to IDLE from the current sub-S7;
                            // fire eu_berr here so the EU knows the operation failed.
                            eu_berr = 1'b1;
                        end else if ((state == ST_CAS2_W2_S7) ||
                                     (state == ST_CAS2_R2_S7 && !eu_cas2_do_write2)) begin
                            eu_cas2_ack = 1'b1;
                        end
                        // eu_cas2_rdata1/2 already driven from captured registers above
                    end else if (cyc_is_coproc_r) begin
                        // Coprocessor CPU Space cycle complete (FC=111, A[19:16]=0010)
                        eu_coproc_rdata = captured_rdata;
                        if (berr_abort_r) eu_coproc_berr = 1'b1;
                        else              eu_coproc_ack  = 1'b1;
                    end else if (state == ST_RMW_READ_S7) begin
                        // RMW read done; pass data to EU so it can compute write value.
                        eu_rdata = captured_rdata;
                        eu_ack   = 1'b1;  // sub-ack so EU sees the read data
                    end else if (is_rmw_write) begin
                        // RMW write complete
                        if (!berr_abort_r) eu_ack  = 1'b1; else eu_berr = 1'b1;
                    end else if (grant_mmu) begin
                        mmu_rdata = captured_rdata;
                        if (!berr_abort_r) mmu_ack  = 1'b1; else mmu_berr = 1'b1;
                    end else if (grant_eu || in_retry_r) begin
                        eu_rdata = captured_rdata;
                        if (berr_abort_r) begin
                            if (berr_is_halt_retry_r) eu_retry = 1'b1;
                            else                      eu_berr  = 1'b1;
                        end else
                            eu_ack = 1'b1;
                    end else if (grant_ifu) begin
                        ifu_rdata = captured_rdata;
                        if (!berr_abort_r) ifu_ack  = 1'b1; else ifu_berr = 1'b1;
                    end
                end
                default: ; // SP_NONE
            endcase
            // RMW atomic lock: AS# must stay asserted continuously from read-S2
            // through write-S1; the case above deasserts it at SP_S6/S7 and
            // leaves it low at SP_S0/S1 only if it was already in a cycle.
            // Override here to keep it low during the read→write gap states.
            if (rmw_as_hold) ext_as_n = 1'b0;
        end
    end

    assign bus_idle       = (state == ST_IDLE);
    assign bus_reset_inst = (state == ST_RESET_INST);
    // bus_halted: HALT# is actively suspending bus cycles (not during init or retry)
    assign bus_halted     = (state == ST_IDLE) && init_done_r && !retry_r && !halt_s;

endmodule

`default_nettype wire
