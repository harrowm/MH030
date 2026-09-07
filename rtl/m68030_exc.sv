`timescale 1ns/1ps
`default_nettype none

// MC68030 Exception Controller 
//
// Handles all exception types, pushes the appropriate stack frame format,
// fetches the handler vector, and loads the new PC/SR into the EU.
//
// Priority (highest first, MC68030UM.pdf Table 8-5 -- docs/*.md review,
// Phase 250 F7; the always_comb chain below is ordered to match exactly):
//   Address error > Bus error > Illegal/Priv/Line-A/Line-F/Format-error >
//   Zero-Divide/CHK/MMU-Config/TRAPV/TRAP#n > Interrupt (lowest of all)
//
// Frame push uses longword (32-bit) BIU writes.  Each push step covers 4
// bytes; the step counter counts down from (total_LW_writes - 1) to 0 so
// address = new_ssp + step_rem * 4.  Format $0 needs 2 writes; format $B
// needs 23 writes.
//
// Formats $0/$2/$3 are fully populated.
// Formats $9/$A/$B: steps 0-3 carry the core fault snapshot; step 4 carries
// the Data Output Buffer (DOB) captured from the BIU at fault time; steps 5+
// are zero (internal pipeline state — FPU not implemented).
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
    output logic        int_pending_out,// combinational int_pending, exported so
                                         // eu_seq.sv can hold a ready instruction
                                         // in DECODE for exactly one cycle rather
                                         // than let it launch the same edge this
                                         // module would otherwise recognize the
                                         // interrupt on (see int_ready below)
    input  logic        int_ready,      // pulses from eu_seq.sv (via m68030_eu)
                                         // the one cycle a ready-to-dispatch
                                         // instruction is being deliberately held
                                         // in DECODE instead of launching — real
                                         // 68030 silicon only samples IPL at
                                         // instruction boundaries; bus/address
                                         // error remain asynchronous (the fault
                                         // IS the in-flight bus cycle failing, so
                                         // there is no boundary to wait for)
    input  logic        illegal_req,
    input  logic        priv_req,
    input  logic        trace_req,
    input  logic        linea_req,
    input  logic        linef_req,
    input  logic        fmt_err_req,
    input  logic        div_zero_req,
    input  logic        chk_req,
    input  logic        mmu_config_req, // PMOVE TC/CRP/SRP config error (vector 56)
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

    // ── Raw ISP, always (docs/*.md review: Format $1 throwaway interrupt
    // frame, MC68030UM.pdf §8.1.9) — distinct from ssp_in/ssp_out above,
    // which already resolve to MSP-or-ISP depending on the CURRENT M bit.
    // When an interrupt is taken while M=1 (SSP==MSP), a second, throwaway
    // frame must ALSO land on the interrupt stack specifically, regardless
    // of M -- this needs direct, unconditional ISP access the ssp_in/out
    // pair can't provide.
    input  logic [31:0] isp_in,
    output logic [31:0] isp_out,        // decremented ISP to write back (throwaway frame only)
    output logic        isp_wr_en,      // pulse when throwaway frame's last word is pushed

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

    // ── CPU-space IACK interface (docs/*.md review: real vectored interrupt
    // acknowledge, replacing the previous always-autovector shortcut) ─────
    output logic        iack_req,       // request a real IACK bus cycle
    output logic [2:0]  iack_level,     // interrupt level for A[3:1] encoding
    input  logic        iack_ack,       // cycle complete (AVEC or DSACK'd vector)
    input  logic [7:0]  iack_vec,       // resolved vector number (autovector
                                         // already folded in by biu_cycle_gen
                                         // when AVEC/VPA terminated the cycle)
    input  logic        iack_berr,      // BERR during IACK -> Spurious Interrupt

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
    localparam [7:0] VEC_MMU_CONFIG = 8'd56;
    localparam [7:0] VEC_SPURIOUS = 8'd24;  // Spurious Interrupt (IACK BERR/timeout)
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
    logic [2:0] ipl_sync_l;
    logic [2:0] ipl_mask_l;
    assign ipl_sync_l  = ipl_sync;
    assign ipl_mask_l  = ipl_mask;
    assign int_pending = (ipl_sync_l != 3'b000) && (ipl_sync_l > ipl_mask_l);
    assign int_pending_out = int_pending;

    // -----------------------------------------------------------------------
    // Priority encoder (combinational)
    // -----------------------------------------------------------------------
    // docs/*.md review fix (Chapter 8 audit): pend_vec for the interrupt
    // case used to be `24+level` (i.e. always autovector) computed
    // right here -- this project's own real CPU-space IACK bus cycle
    // (biu_cycle_gen.sv's ST_IACK_* states, fully built and unit-tested in
    // isolation) was never actually wired into the dispatch path, so every
    // interrupt silently autovectored regardless of whether a real
    // peripheral would have supplied its own vector byte via DSACK, or
    // failed to respond at all (Spurious Interrupt, vector 24). pend_is_int
    // now routes the interrupt case through a new EXC_IACK state (below)
    // that issues the real IACK cycle and lets its own response determine
    // the vector -- pend_vec for this branch is now just a placeholder,
    // overwritten in EXC_IACK before the frame is ever pushed.
    logic       exc_pending;
    logic [7:0] pend_vec;
    logic [3:0] pend_fmt;
    logic       pend_is_int;

    // docs/*.md review (Phase 250 F7): reordered to match MC68030UM.pdf
    // Table 8-5's own priority groups (0.0 highest .. 4.2 lowest; Reset is
    // handled entirely outside this FSM). Previously: bus_err_req was
    // checked before addr_err_req (Table 8-5 ranks Address Error 1.0
    // strictly above Bus Error 1.1 -- swapped below), and int_pending was
    // checked 3rd -- ahead of illegal/priv/trace/chk/div_zero/trapv/trap,
    // every one of which Table 8-5 ranks strictly higher priority than
    // Interrupt (4.2, the single LOWEST priority of every exception in the
    // whole table) -- moved to last. Reachability of the int_pending case
    // specifically (can int_ready and, say, illegal_req/chk_req genuinely
    // be combinationally true in the same cycle given this project's own
    // pipeline staging) was not proven either way; this reorder is correct
    // regardless of whether that race is currently reachable, and removes
    // the risk at zero cost if it ever becomes reachable via a future
    // change.
    always_comb begin
        exc_pending = 1'b0;
        pend_vec    = 8'h0;
        pend_fmt    = FMT_SHORT;
        pend_is_int = 1'b0;
        if (addr_err_req) begin
            exc_pending = 1'b1; pend_vec = VEC_ADDR_ERR; pend_fmt = FMT_ADDR;
        end else if (bus_err_req) begin
            exc_pending = 1'b1; pend_vec = VEC_BUS_ERR;  pend_fmt = bus_err_fmt;
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
            // MC68030UM.pdf Table 8-6: Zero Divide shares the SIX WORD
            // STACK FRAME - FORMAT $2 with CHK/CHK2/TRAPcc/TRAPV/Trace/MMU
            // Configuration (docs/*.md review fix -- this previously used
            // FMT_SHORT, a real compliance bug: real silicon always pushes
            // the extra instruction-address word for this exception).
            exc_pending = 1'b1; pend_vec = VEC_DIV_ZERO;  pend_fmt = FMT_INST;
        end else if (chk_req) begin
            exc_pending = 1'b1; pend_vec = VEC_CHK;       pend_fmt = FMT_INST;
        end else if (mmu_config_req) begin
            exc_pending = 1'b1; pend_vec = VEC_MMU_CONFIG; pend_fmt = FMT_INST;
        end else if (trapv_req) begin
            exc_pending = 1'b1; pend_vec = VEC_TRAPV;     pend_fmt = FMT_INST;
        end else if (trap_req) begin
            exc_pending = 1'b1;
            pend_vec    = VEC_TRAP0 + {4'd0, trap_num};
            pend_fmt    = FMT_SHORT;
        end else if (int_pending && int_ready) begin
            exc_pending = 1'b1; pend_vec = 8'h0; pend_fmt = FMT_SHORT; pend_is_int = 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    typedef enum logic [2:0] {
        EXC_IDLE  = 3'd0,
        EXC_IACK  = 3'd1,   // real CPU-space IACK cycle, interrupts only
        EXC_PUSH  = 3'd2,
        EXC_FETCH = 3'd3,
        EXC_PUSH2 = 3'd5,   // throwaway Format $1 frame on ISP, M=1 interrupts only
        EXC_LOAD  = 3'd4
    } exc_state_t;

    exc_state_t state_r;

    logic [31:0] snap_ssp_r;
    logic [7:0]  snap_vec_r;
    logic [3:0]  snap_fmt_r;
    logic [31:0] snap_pc_r;
    logic [15:0] snap_sr_r;
    logic [2:0]  snap_ipl_r;    // captured IPL for interrupt SR update
    logic [31:0] snap_dob_r;    // Data Output Buffer snapshot (fault_data at entry)
    logic        snap_is_int_r; // captured pend_is_int (docs/*.md review fix)
    logic [4:0]  push_step_r;
    logic [31:0] vec_data_r;
    logic [4:0]  push2_step_r;  // throwaway frame's own 2-step push counter

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
    //   step 5+: zeros (internal pipeline state; FPU not implemented)
    // -----------------------------------------------------------------------
    logic [31:0] push_data;
    logic        fmt_is_fault;
    assign fmt_is_fault = (snap_fmt_r == FMT_MMU) ||
                          (snap_fmt_r == FMT_BUS_INS) ||
                          (snap_fmt_r == FMT_BUS_DAT);

    // push_data is indexed by step_rem (= distance from lowest stack address).
    // step_rem=0 → lowest address (first word read by RTE), step_rem=N-1 → highest.
    // This is format-agnostic: each slot always carries the same semantic field
    // regardless of total frame length, so FMT_SHORT/FMT_INST/FMT_ADDR all work.
    always_comb begin
        case (step_rem)
            5'd0:    push_data = {fmtvec, snap_sr_r};          // {format/vec, SR} — RTE phase 1
            5'd1:    push_data = snap_pc_r;                    // return PC         — RTE phase 2
            5'd2:    push_data = fault_addr;                   // instr/fault addr  — frame slot 2
            5'd3:    push_data = {fault_ssw, 16'h0};           // fault SSW         — frame slot 3
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
    // Throwaway Format $1 interrupt-stack frame (docs/*.md review fix,
    // MC68030UM.pdf §8.1.9): pushed onto ISP directly (not the "active" SSP
    // ssp_in/ssp_out above) only when an interrupt is taken while M=1.
    // Always exactly 2 longword writes (4-word frame) regardless of what
    // format the real frame used (interrupts always use FMT_SHORT for the
    // real frame anyway) -- hardcoded rather than reusing
    // total_steps/ssp_delta, which are keyed off snap_fmt_r, to keep this
    // frame's own fixed size self-evident and independent of that field.
    // "Same PC/vector offset as the master-stack frame... SR the same
    // except S is forced set" (manual's own exact wording).
    // -----------------------------------------------------------------------
    logic [31:0] new_isp_calc;
    logic [31:0] push2_addr;
    logic [31:0] push2_data;
    logic [15:0] fmtvec1;
    logic [15:0] throwaway_sr;
    assign new_isp_calc = isp_in - 32'd8;
    assign fmtvec1       = {4'h1, 2'b00, snap_vec_r, 2'b00};
    assign throwaway_sr  = snap_sr_r | 16'h2000;  // force S bit (bit 13) set
    assign push2_addr    = (push2_step_r == 5'd0) ? (new_isp_calc + 32'd4) : new_isp_calc;
    assign push2_data    = (push2_step_r == 5'd0) ? snap_pc_r : {fmtvec1, throwaway_sr};

    // -----------------------------------------------------------------------
    // New SR: T1=0, T0=0, S=1, I=preserved (updated for interrupt). M is
    // cleared ONLY for interrupt exceptions (docs/*.md review fix,
    // MC68030UM.pdf §8.1.9: "when the exception being processed is an
    // INTERRUPT and the M bit is set, the M bit is cleared" -- every other
    // exception type must leave M exactly as it was). Previously cleared
    // unconditionally for every exception, invisible to Harte (68000 has
    // no M bit at all).
    // -----------------------------------------------------------------------
    logic [15:0] new_sr_comb;
    logic [2:0]  new_ipl;
    logic        new_m;
    assign new_ipl     = snap_ipl_r;            // non-zero only for interrupts
    assign new_m       = snap_is_int_r ? 1'b0 : snap_sr_r[12];
    assign new_sr_comb = {2'b00, 1'b1, new_m, 1'b0, new_ipl, snap_sr_r[7:0]};
    // [15:14]=T=00, [13]=S=1, [12]=M(interrupt-only clear), [11]=0, [10:8]=new_ipl, [7:0]=CCR

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
            snap_ipl_r    <= 3'b0;
            snap_dob_r    <= 32'h0;
            snap_is_int_r <= 1'b0;
            push_step_r   <= 5'd0;
            push2_step_r  <= 5'd0;
            vec_data_r    <= 32'h0;
        end else begin
            case (state_r)
                EXC_IDLE: begin
                    if (exc_pending) begin
                        snap_ssp_r    <= ssp_in;
                        snap_vec_r    <= pend_vec;   // interrupt case: placeholder,
                                                       // overwritten in EXC_IACK below
                        snap_fmt_r    <= pend_fmt;
                        snap_pc_r     <= fault_pc;
                        snap_sr_r     <= fault_sr;
                        snap_ipl_r    <= int_pending ? ipl_sync_l : fault_sr[10:8];
                        snap_dob_r    <= fault_data;
                        snap_is_int_r <= pend_is_int;
                        push_step_r   <= 5'd0;
                        if (pend_is_int) state_r <= EXC_IACK;
                        else             state_r <= EXC_PUSH;
                    end
                end

                // Real CPU-space IACK cycle (docs/*.md review fix): drives
                // iack_req/iack_level (below) and waits for the BIU's own
                // response. iack_ack's own iack_vec already has the
                // autovector formula folded in by biu_cycle_gen when AVEC#/
                // VPA# terminated the cycle, so no further distinction is
                // needed here -- either way it's just "the resolved vector
                // number." A BERR (peripheral never responds) is Spurious
                // Interrupt, vector 24, per MC68030UM.pdf §8.1.9 -- always
                // vector 24 regardless of level, not derived from it.
                EXC_IACK: begin
                    if (iack_ack) begin
                        snap_vec_r <= iack_vec;
                        state_r    <= EXC_PUSH;
                    end else if (iack_berr) begin
                        snap_vec_r <= VEC_SPURIOUS;
                        state_r    <= EXC_PUSH;
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
                        vec_data_r   <= exc_rdata;
                        push2_step_r <= 5'd0;
                        // docs/*.md review fix: throwaway Format $1 frame
                        // (MC68030UM.pdf §8.1.9) only when this dispatch is
                        // an interrupt AND M was set before it -- snap_sr_r
                        // still holds the pre-exception SR at this point
                        // (new_sr_comb/new_m, above, is what changes it).
                        if (snap_is_int_r && snap_sr_r[12]) state_r <= EXC_PUSH2;
                        else                                state_r <= EXC_LOAD;
                    end
                end

                // Throwaway Format $1 frame onto ISP (docs/*.md review fix).
                // Purely additional bookkeeping -- vec_data_r/new_pc/new_sr
                // (the real, observable outcome of this exception) are
                // already fully resolved by this point; this state only
                // exists to also leave the interrupt-stack side effect real
                // 68030 silicon produces here, for software that inspects
                // ISP or expects to RTE through it later.
                EXC_PUSH2: begin
                    if (exc_ack) begin
                        if (push2_step_r == 5'd1) begin
                            push2_step_r <= 5'd0;
                            state_r      <= EXC_LOAD;
                        end else begin
                            push2_step_r <= push2_step_r + 5'd1;
                        end
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
            EXC_PUSH2: begin
                exc_req   = 1'b1;
                exc_rw    = 1'b0;       // write
                exc_addr  = push2_addr;
                exc_wdata = push2_data;
            end
            default: ;
        endcase
    end

    // IACK request outputs: level is held from snap_ipl_r (captured at
    // EXC_IDLE dispatch, same field the interrupt SR update already uses).
    assign iack_req   = (state_r == EXC_IACK);
    assign iack_level = snap_ipl_r;

    // SSP write: fire when last frame word is acked
    always_comb begin
        ssp_wr_en = 1'b0;
        ssp_out   = new_ssp;
        if (state_r == EXC_PUSH && exc_ack && (push_step_r == total_steps - 5'd1)) begin
            ssp_wr_en = 1'b1;
        end
    end

    // ISP write (throwaway Format $1 frame only): fires when its own last
    // word is acked. Independent of ssp_wr_en/ssp_out above -- when M=1
    // those write MSP (ssp_in/ssp_out resolve to MSP in that case), this
    // writes ISP directly regardless.
    always_comb begin
        isp_wr_en = 1'b0;
        isp_out   = new_isp_calc;
        if (state_r == EXC_PUSH2 && exc_ack && (push2_step_r == 5'd1)) begin
            isp_wr_en = 1'b1;
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
