`default_nettype none

// MC68030 Exception Controller (Phase 44)
//
// Handles all exception types, pushes the appropriate stack frame format,
// fetches the handler vector, and loads the new PC/SR into the EU.
//
// Priority (highest first):
//   Bus error / address error > Interrupt > Instruction faults > Traps
//
// Frame push uses longword (32-bit) BIU writes.  Each push step covers 4
// bytes; the step counter counts down from (total_LW_writes - 1) to 0 so
// address = new_ssp + step_rem * 4.  Format $0 needs 2 writes; format $B
// needs 23 writes.
//
// Formats $0/$2/$3 are fully populated.
// Formats $9/$A/$B: steps 0-3 carry the core fault snapshot; step 4 carries
// the Data Output Buffer (DOB) captured from the BIU at fault time; steps 5+
// are zero (internal pipeline state — stubbed until Phase 52 FPU).
// The bus-error frame format code ($9/$A/$B) is determined by biu_exc_capture
// and passed in via bus_err_fmt; the EU/EXC module just consumes it.
//
// SR after exception: T1=0, T0=0, S=1, M=0, I=preserved (or updated for
// interrupt); CCR preserved.  Interrupt updates I[2:0] to the level taken.

module m68030_exc (
    input  logic        clk_4x,
    input  logic        rst_n,

    // ── Exception source inputs ───────────────────────────────────────────
    input  logic        bus_err_req,
    input  logic        addr_err_req,
    input  logic [2:0]  ipl_sync,       // synchronized IPL[2:0]
    input  logic [2:0]  ipl_mask,       // SR[10:8] current interrupt mask
    input  logic        illegal_req,
    input  logic        priv_req,
    input  logic        trace_req,
    input  logic        linea_req,
    input  logic        linef_req,
    input  logic        fmt_err_req,
    input  logic        div_zero_req,
    input  logic        chk_req,
    input  logic        trapv_req,
    input  logic        trap_req,
    input  logic [3:0]  trap_num,       // TRAP #0–#15

    // ── Fault snapshot (from BIU biu_exc_capture and EU) ─────────────────
    input  logic [31:0] fault_pc,       // EU PC at exception entry
    input  logic [15:0] fault_sr,       // SR at exception entry
    input  logic [31:0] fault_addr,     // faulting bus address (bus/addr err)
    input  logic [15:0] fault_ssw,      // Special Status Word (biu_exc_capture)
    input  logic [3:0]  bus_err_fmt,    // frame format from biu_exc_capture ($9/$A/$B)
    input  logic [31:0] fault_data,     // Data Output Buffer at fault time (for $9/$A/$B step 4)

    // ── Supervisor stack pointer (EU regfile ISP or MSP) ──────────────────
    input  logic [31:0] ssp_in,
    output logic [31:0] ssp_out,        // decremented SSP to write back
    output logic        ssp_wr_en,      // pulse when last frame word pushed

    // ── Vector Base Register ──────────────────────────────────────────────
    input  logic [31:0] vbr_in,

    // ── BIU longword read/write interface ────────────────────────────────
    output logic [31:0] exc_addr,       // bus address
    output logic [31:0] exc_wdata,      // write data
    output logic        exc_rw,         // 0=write (push), 1=read (vector fetch)
    output logic [1:0]  exc_siz,        // 00=longword always
    output logic        exc_req,        // request strobe
    input  logic        exc_ack,        // cycle complete
    input  logic [31:0] exc_rdata,      // read data from vector fetch

    // ── Outputs to EU ─────────────────────────────────────────────────────
    output logic [31:0] new_pc,
    output logic        new_pc_wr,
    output logic [15:0] new_sr,
    output logic        new_sr_wr,
    output logic        exc_active,
    output logic [7:0]  exc_vector_num  // for logging / IACK cycle
);

    // -----------------------------------------------------------------------
    // Exception vector numbers (MC68030)
    // -----------------------------------------------------------------------
    localparam [7:0] VEC_BUS_ERR  = 8'd2;
    localparam [7:0] VEC_ADDR_ERR = 8'd3;
    localparam [7:0] VEC_ILLEGAL  = 8'd4;
    localparam [7:0] VEC_DIV_ZERO = 8'd5;
    localparam [7:0] VEC_CHK      = 8'd6;
    localparam [7:0] VEC_TRAPV    = 8'd7;
    localparam [7:0] VEC_PRIV     = 8'd8;
    localparam [7:0] VEC_TRACE    = 8'd9;
    localparam [7:0] VEC_LINE_A   = 8'd10;
    localparam [7:0] VEC_LINE_F   = 8'd11;
    localparam [7:0] VEC_FMT_ERR  = 8'd14;
    localparam [7:0] VEC_AV1      = 8'd25;  // auto-vector level 1
    localparam [7:0] VEC_TRAP0    = 8'd32;  // TRAP #0 (TRAP #n = 32+n)

    // Frame format codes
    localparam [3:0] FMT_SHORT   = 4'h0;  //  4 words  (2 LW writes)
    localparam [3:0] FMT_INST    = 4'h2;  //  6 words  (3 LW writes)
    localparam [3:0] FMT_ADDR    = 4'h3;  //  8 words  (4 LW writes)
    localparam [3:0] FMT_FPU_PI  = 4'h4;  //  8 words  (4 LW writes)
    localparam [3:0] FMT_FPU_PR  = 4'h8;  // 29 words (15 LW + 1 word — stub)
    localparam [3:0] FMT_MMU     = 4'h9;  // 12 words  (6 LW writes)
    localparam [3:0] FMT_BUS_INS = 4'hA;  // 16 words  (8 LW writes)
    localparam [3:0] FMT_BUS_DAT = 4'hB;  // 46 words (23 LW writes)

    // -----------------------------------------------------------------------
    // Interrupt pending
    // -----------------------------------------------------------------------
    logic       int_pending;
    logic [7:0] int_vec;
    logic [2:0] ipl_sync_l;
    logic [2:0] ipl_mask_l;
    assign ipl_sync_l  = ipl_sync;
    assign ipl_mask_l  = ipl_mask;
    assign int_pending = (ipl_sync_l != 3'b000) && (ipl_sync_l > ipl_mask_l);
    assign int_vec     = VEC_AV1 - 8'd1 + {5'd0, ipl_sync_l};

    // -----------------------------------------------------------------------
    // Priority encoder (combinational)
    // -----------------------------------------------------------------------
    logic       exc_pending;
    logic [7:0] pend_vec;
    logic [3:0] pend_fmt;

    always_comb begin
        exc_pending = 1'b0;
        pend_vec    = 8'h0;
        pend_fmt    = FMT_SHORT;
        if (bus_err_req) begin
            exc_pending = 1'b1; pend_vec = VEC_BUS_ERR;  pend_fmt = bus_err_fmt;
        end else if (addr_err_req) begin
            exc_pending = 1'b1; pend_vec = VEC_ADDR_ERR; pend_fmt = FMT_ADDR;
        end else if (int_pending) begin
            exc_pending = 1'b1; pend_vec = int_vec;       pend_fmt = FMT_SHORT;
        end else if (illegal_req) begin
            exc_pending = 1'b1; pend_vec = VEC_ILLEGAL;   pend_fmt = FMT_SHORT;
        end else if (priv_req) begin
            exc_pending = 1'b1; pend_vec = VEC_PRIV;      pend_fmt = FMT_SHORT;
        end else if (trace_req) begin
            exc_pending = 1'b1; pend_vec = VEC_TRACE;     pend_fmt = FMT_SHORT;
        end else if (linea_req) begin
            exc_pending = 1'b1; pend_vec = VEC_LINE_A;    pend_fmt = FMT_SHORT;
        end else if (linef_req) begin
            exc_pending = 1'b1; pend_vec = VEC_LINE_F;    pend_fmt = FMT_SHORT;
        end else if (fmt_err_req) begin
            exc_pending = 1'b1; pend_vec = VEC_FMT_ERR;   pend_fmt = FMT_SHORT;
        end else if (div_zero_req) begin
            exc_pending = 1'b1; pend_vec = VEC_DIV_ZERO;  pend_fmt = FMT_SHORT;
        end else if (chk_req) begin
            exc_pending = 1'b1; pend_vec = VEC_CHK;       pend_fmt = FMT_INST;
        end else if (trapv_req) begin
            exc_pending = 1'b1; pend_vec = VEC_TRAPV;     pend_fmt = FMT_INST;
        end else if (trap_req) begin
            exc_pending = 1'b1;
            pend_vec    = VEC_TRAP0 + {4'd0, trap_num};
            pend_fmt    = FMT_SHORT;
        end
    end

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        EXC_IDLE  = 2'd0,
        EXC_PUSH  = 2'd1,
        EXC_FETCH = 2'd2,
        EXC_LOAD  = 2'd3
    } exc_state_t;

    exc_state_t state_r;

    logic [31:0] snap_ssp_r;
    logic [7:0]  snap_vec_r;
    logic [3:0]  snap_fmt_r;
    logic [31:0] snap_pc_r;
    logic [15:0] snap_sr_r;
    logic [2:0]  snap_ipl_r;    // captured IPL for interrupt SR update
    logic [31:0] snap_dob_r;    // Data Output Buffer snapshot (fault_data at entry)
    logic [4:0]  push_step_r;
    logic [31:0] vec_data_r;

    // -----------------------------------------------------------------------
    // Per-format: total longword write count and SSP decrement
    // -----------------------------------------------------------------------
    logic [4:0] total_steps;
    logic [7:0] ssp_delta;

    always_comb begin
        case (snap_fmt_r)
            FMT_SHORT:   begin total_steps = 5'd2;  ssp_delta = 8'd8;  end
            FMT_INST:    begin total_steps = 5'd3;  ssp_delta = 8'd12; end
            FMT_ADDR:    begin total_steps = 5'd4;  ssp_delta = 8'd16; end
            FMT_FPU_PI:  begin total_steps = 5'd4;  ssp_delta = 8'd16; end
            FMT_FPU_PR:  begin total_steps = 5'd15; ssp_delta = 8'd58; end  // 29 words → 14 LW + 1 word; use 15 LW (round up)
            FMT_MMU:     begin total_steps = 5'd6;  ssp_delta = 8'd24; end
            FMT_BUS_INS: begin total_steps = 5'd8;  ssp_delta = 8'd32; end
            FMT_BUS_DAT: begin total_steps = 5'd23; ssp_delta = 8'd92; end
            default:     begin total_steps = 5'd2;  ssp_delta = 8'd8;  end
        endcase
    end

    // -----------------------------------------------------------------------
    // Frame/offset word
    //   [15:12] = frame format
    //   [11:2]  = vector_number (= vector_offset >> 2; range 0-255 fits 8b)
    //   [1:0]   = 00
    // -----------------------------------------------------------------------
    logic [15:0] fmtvec;
    assign fmtvec = {snap_fmt_r, 2'b00, snap_vec_r, 2'b00};

    // -----------------------------------------------------------------------
    // New SSP and push address
    //   new_ssp   = snap_ssp_r - ssp_delta
    //   push_addr = new_ssp + step_rem * 4   (step_rem counts down: first push
    //               is at highest address = snap_ssp_r - 4)
    // -----------------------------------------------------------------------
    logic [31:0] new_ssp;
    logic [4:0]  step_rem;
    logic [31:0] push_addr;

    assign new_ssp  = snap_ssp_r - {24'd0, ssp_delta};
    assign step_rem = total_steps - 5'd1 - push_step_r;
    assign push_addr = new_ssp + {25'd0, step_rem, 2'b00};

    // -----------------------------------------------------------------------
    // Push data for each step:
    //   step 0: fault_pc  (PC; highest address = snap_ssp_r - 4)
    //   step 1: {fmtvec, fault_sr}  (format/SR pair just below PC)
    //   step 2: fault_addr  (instruction address for $2/$3; fault addr for others)
    //   step 3: {fault_ssw, 16'h0}  (SSW + reserved; used by $3/$A/$B)
    //   step 4: snap_dob_r (Data Output Buffer; formats $9/$A/$B only)
    //   step 5+: zeros (internal pipeline state; stubbed until Phase 52)
    // -----------------------------------------------------------------------
    logic [31:0] push_data;
    logic        fmt_is_fault;
    assign fmt_is_fault = (snap_fmt_r == FMT_MMU) ||
                          (snap_fmt_r == FMT_BUS_INS) ||
                          (snap_fmt_r == FMT_BUS_DAT);

    always_comb begin
        case (push_step_r)
            5'd0:    push_data = snap_pc_r;
            5'd1:    push_data = {fmtvec, snap_sr_r};
            5'd2:    push_data = fault_addr;
            5'd3:    push_data = {fault_ssw, 16'h0};
            5'd4:    push_data = fmt_is_fault ? snap_dob_r : 32'h0;
            default: push_data = 32'h0;
        endcase
    end

    // -----------------------------------------------------------------------
    // Vector address: VBR + vector_number × 4
    // -----------------------------------------------------------------------
    logic [31:0] vec_addr;
    assign vec_addr = vbr_in + {22'd0, snap_vec_r, 2'b00};

    // -----------------------------------------------------------------------
    // New SR: T1=0, T0=0, S=1, M=0, I=preserved (updated for interrupt)
    // -----------------------------------------------------------------------
    logic [15:0] new_sr_comb;
    logic [2:0]  new_ipl;
    assign new_ipl     = snap_ipl_r;            // non-zero only for interrupts
    assign new_sr_comb = {2'b00, 1'b1, 1'b0, 1'b0, new_ipl, snap_sr_r[7:0]};
    // [15:14]=T=00, [13]=S=1, [12]=M=0, [11]=0, [10:8]=new_ipl, [7:0]=CCR

    // -----------------------------------------------------------------------
    // FSM sequential
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state_r     <= EXC_IDLE;
            snap_ssp_r  <= 32'h0;
            snap_vec_r  <= 8'h0;
            snap_fmt_r  <= FMT_SHORT;
            snap_pc_r   <= 32'h0;
            snap_sr_r   <= 16'h0;
            snap_ipl_r  <= 3'b0;
            snap_dob_r  <= 32'h0;
            push_step_r <= 5'd0;
            vec_data_r  <= 32'h0;
        end else begin
            case (state_r)
                EXC_IDLE: begin
                    if (exc_pending) begin
                        snap_ssp_r  <= ssp_in;
                        snap_vec_r  <= pend_vec;
                        snap_fmt_r  <= pend_fmt;
                        snap_pc_r   <= fault_pc;
                        snap_sr_r   <= fault_sr;
                        snap_ipl_r  <= int_pending ? ipl_sync_l : fault_sr[10:8];
                        snap_dob_r  <= fault_data;
                        push_step_r <= 5'd0;
                        state_r     <= EXC_PUSH;
                    end
                end

                EXC_PUSH: begin
                    if (exc_ack) begin
                        if (push_step_r == total_steps - 5'd1) begin
                            push_step_r <= 5'd0;
                            state_r     <= EXC_FETCH;
                        end else begin
                            push_step_r <= push_step_r + 5'd1;
                        end
                    end
                end

                EXC_FETCH: begin
                    if (exc_ack) begin
                        vec_data_r <= exc_rdata;
                        state_r    <= EXC_LOAD;
                    end
                end

                EXC_LOAD: begin
                    state_r <= EXC_IDLE;
                end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // BIU request outputs
    // -----------------------------------------------------------------------
    always_comb begin
        exc_req   = 1'b0;
        exc_rw    = 1'b0;
        exc_siz   = 2'b00;   // always longword
        exc_addr  = 32'h0;
        exc_wdata = 32'h0;

        case (state_r)
            EXC_PUSH: begin
                exc_req   = 1'b1;
                exc_rw    = 1'b0;       // write
                exc_addr  = push_addr;
                exc_wdata = push_data;
            end
            EXC_FETCH: begin
                exc_req  = 1'b1;
                exc_rw   = 1'b1;        // read
                exc_addr = vec_addr;
            end
            default: ;
        endcase
    end

    // SSP write: fire when last frame word is acked
    always_comb begin
        ssp_wr_en = 1'b0;
        ssp_out   = new_ssp;
        if (state_r == EXC_PUSH && exc_ack && (push_step_r == total_steps - 5'd1)) begin
            ssp_wr_en = 1'b1;
        end
    end

    // PC/SR write: fire in LOAD state (combinational; EU latches on next posedge)
    assign new_pc     = vec_data_r;
    assign new_sr     = new_sr_comb;
    assign new_pc_wr  = (state_r == EXC_LOAD);
    assign new_sr_wr  = (state_r == EXC_LOAD);

    assign exc_active     = (state_r != EXC_IDLE);
    assign exc_vector_num = snap_vec_r;

endmodule

`default_nettype wire
