`default_nettype none

// MC68030 Instruction Fetch Unit
//
// 4-word × 16-bit prefetch queue.  The BIU always returns a 32-bit
// longword per fetch; the IFU splits it into two 16-bit words and pushes
// them to the queue tail.  The EU/sequencer drains up to 3 words per
// cycle (opcode + up to 2 extension words).
//
// ext_data format: {q[1], q[2]} — first extension word in bits[31:16],
// second extension word in bits[15:0].  This is the hardware-accurate
// layout (MSW first, matching 68030 big-endian memory).
// eu_seq currently uses ext_data[31:0] as a full 32-bit immediate
// (zero-extended by testbench convention); Phase 32 integration aligns
// the two conventions.
//
// BIU request protocol: ifu_req = fetch_pend_r.  Assert ifu_req and hold
// ifu_addr stable; deassert ifu_req one cycle after ifu_ack (fetch_pend_r
// cleared at ack posedge, so ifu_req goes low the same cycle as ack if no
// immediate re-fetch, else stays high with the new address).
//
// PC alignment: if pc_wr_data[1]=1 (word-aligned but not long-aligned),
// skip_first_r causes the IFU to discard rdata[31:16] (the word at
// fetch_addr, which is one word before the actual PC) on the first fill.

module m68030_ifu (
    input  logic        clk_4x,
    input  logic        rst_n,

    // PC override (branch, exception, boot — from IFU perspective)
    input  logic        pc_wr_en,
    input  logic [31:0] pc_wr_data,

    // Drain: 16-bit words consumed by EU/sequencer this cycle
    //   0 = nothing  1 = opcode only  2 = opcode + 1 ext  3 = opcode + 2 ext
    input  logic [1:0]  drain,

    // Instruction stream outputs (combinational, valid the cycle after fill)
    output logic [15:0] instr_word,   // q[0] — opcode
    output logic [31:0] ext_data,     // {q[1], q[2]} — two extension words
    output logic        instr_valid,  // q_cnt >= 1
    output logic        ext_valid,    // q_cnt >= 3
    output logic [31:0] decode_pc,    // PC of instr_word

    // BIU longword-read interface
    output logic [31:0] ifu_addr,     // longword-aligned fetch address
    output logic        ifu_req,      // request held until ifu_ack
    input  logic [31:0] ifu_rdata,    // [31:16]=word@addr, [15:0]=word@addr+2
    input  logic        ifu_ack,      // data valid this cycle
    input  logic        ifu_berr,     // bus error this cycle

    // Supervisor mode → function code selection
    input  logic        supervisor,
    output logic [2:0]  fc_out,       // 110=SV prog, 010=user prog

    // Fault outputs
    output logic        bus_err,
    output logic [31:0] bus_err_addr,
    output logic        addr_err      // decode_pc[0]: odd address error
);

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    logic [15:0] q    [0:3];      // prefetch queue: q[0] = head (next opcode)
    logic [2:0]  q_cnt;           // valid word count: 0–4
    logic [31:0] fetch_addr_r;    // next longword address to request
    logic [31:0] decode_pc_r;     // PC of q[0]
    logic        fetch_pend_r;    // outstanding BIU fetch (ifu_req held high)
    logic        skip_first_r;    // discard rdata[31:16] on next fill
    logic        initialized_r;   // set on first pc_wr_en; gate auto-fetch
    logic        bus_err_r;
    logic [31:0] bus_err_addr_r;

    // -----------------------------------------------------------------------
    // Combinational outputs
    // -----------------------------------------------------------------------
    assign instr_word   = q[0];
    assign ext_data     = {q[1], q[2]};
    assign instr_valid  = (q_cnt >= 3'd1);
    assign ext_valid    = (q_cnt >= 3'd3);
    assign decode_pc    = decode_pc_r;
    assign ifu_addr     = fetch_addr_r;
    assign ifu_req      = fetch_pend_r;
    assign fc_out       = supervisor ? 3'b110 : 3'b010;
    assign bus_err      = bus_err_r;
    assign bus_err_addr = bus_err_addr_r;
    assign addr_err     = decode_pc_r[0];

    // -----------------------------------------------------------------------
    // Combinational drain helpers (all via assign — Icarus always_comb safe)
    // -----------------------------------------------------------------------

    // Cap drain to available words so we never underflow q_cnt
    logic [1:0] dn;
    assign dn = ({1'b0, drain} > q_cnt) ? q_cnt[1:0] : drain;

    // Queue shifted left by dn (drain from head); tail zeroed
    logic [15:0] qd [0:3];
    always_comb begin
        case (dn)
            2'd1: begin qd[0]=q[1]; qd[1]=q[2]; qd[2]=q[3]; qd[3]=16'h0; end
            2'd2: begin qd[0]=q[2]; qd[1]=q[3]; qd[2]=16'h0; qd[3]=16'h0; end
            2'd3: begin qd[0]=q[3]; qd[1]=16'h0; qd[2]=16'h0; qd[3]=16'h0; end
            default: begin qd[0]=q[0]; qd[1]=q[1]; qd[2]=q[2]; qd[3]=q[3]; end
        endcase
    end

    // q_cnt after drain (before fill)
    logic [2:0] q_cnt_d;
    assign q_cnt_d = q_cnt - {1'b0, dn};

    // Words added by this ack (0 if no ack; 1 if skip_first; 2 normally)
    logic [2:0] fill_cnt;
    assign fill_cnt = (ifu_ack && fetch_pend_r && !bus_err_r && !ifu_berr)
                      ? (skip_first_r ? 3'd1 : 3'd2)
                      : 3'd0;

    // q_cnt after drain + fill
    logic [2:0] q_cnt_df;
    assign q_cnt_df = q_cnt_d + fill_cnt;

    // Position in qd where fill starts = q_cnt_d (guaranteed 0–2 when ack fires,
    // because we only issue a fetch when q_cnt ≤ 2, and q_cnt_d ≤ q_cnt ≤ 2)
    logic [1:0] fill_at;
    assign fill_at = q_cnt_d[1:0];

    // -----------------------------------------------------------------------
    // Sequential queue update
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin : queue_seq

        if (!rst_n) begin
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0; q[3] <= 16'h0;
            q_cnt          <= 3'd0;
            fetch_addr_r   <= 32'h0;
            decode_pc_r    <= 32'h0;
            fetch_pend_r   <= 1'b0;
            skip_first_r   <= 1'b0;
            initialized_r  <= 1'b0;
            bus_err_r      <= 1'b0;
            bus_err_addr_r <= 32'h0;

        end else if (pc_wr_en) begin
            // Flush queue and restart from new PC.
            // fetch_pend_r cleared to 0 so any in-flight fetch is abandoned;
            // ifu_ack guarded by fetch_pend_r, so stale data is ignored.
            // The drain-only branch on the next cycle will set fetch_pend_r=1.
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0; q[3] <= 16'h0;
            q_cnt          <= 3'd0;
            decode_pc_r    <= pc_wr_data;
            fetch_addr_r   <= {pc_wr_data[31:2], 2'b00};  // longword-align
            skip_first_r   <= pc_wr_data[1];               // 1: PC = long_base + 2
            fetch_pend_r   <= 1'b0;
            initialized_r  <= 1'b1;
            bus_err_r      <= 1'b0;
            bus_err_addr_r <= 32'h0;

        end else begin
            // Always advance decode_pc for consumed words (2 bytes each)
            decode_pc_r <= decode_pc_r + {29'h0, dn, 1'b0};

            if (ifu_berr && fetch_pend_r && !bus_err_r) begin
                // Bus error: latch fault address, stop fetching
                bus_err_r      <= 1'b1;
                bus_err_addr_r <= fetch_addr_r;
                fetch_pend_r   <= 1'b0;
                q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                q_cnt <= q_cnt_d;

            end else if (ifu_ack && fetch_pend_r && !bus_err_r) begin
                // Fill: write new word(s) into qd at position fill_at
                fetch_addr_r <= fetch_addr_r + 32'd4;
                skip_first_r <= 1'b0;
                q_cnt        <= q_cnt_df;
                // Clear fetch_pend_r; drain-only branch re-asserts next cycle
                // with the updated fetch_addr_r, avoiding address-race with the BIU.
                fetch_pend_r <= 1'b0;

                // Write queue: cases on {skip_first_r, fill_at[1:0]}
                // skip_first=0: rdata[31:16] at fill_at, rdata[15:0] at fill_at+1
                // skip_first=1: rdata[15:0]  at fill_at only (first word discarded)
                case ({skip_first_r, fill_at})
                    3'b0_00: begin
                        q[0] <= ifu_rdata[31:16]; q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2];            q[3] <= qd[3];
                    end
                    3'b0_01: begin
                        q[0] <= qd[0];            q[1] <= ifu_rdata[31:16];
                        q[2] <= ifu_rdata[15:0];  q[3] <= qd[3];
                    end
                    3'b0_10: begin
                        q[0] <= qd[0];            q[1] <= qd[1];
                        q[2] <= ifu_rdata[31:16]; q[3] <= ifu_rdata[15:0];
                    end
                    3'b1_00: begin
                        q[0] <= ifu_rdata[15:0];  q[1] <= qd[1];
                        q[2] <= qd[2];            q[3] <= qd[3];
                    end
                    3'b1_01: begin
                        q[0] <= qd[0];            q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2];            q[3] <= qd[3];
                    end
                    3'b1_10: begin
                        q[0] <= qd[0];            q[1] <= qd[1];
                        q[2] <= ifu_rdata[15:0];  q[3] <= qd[3];
                    end
                    default: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                    end
                endcase

            end else begin
                // Drain only: just shift the queue
                q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                q_cnt <= q_cnt_d;

                // Issue a new fetch if queue has room (≤ 2 words after drain)
                if (!fetch_pend_r && !bus_err_r && initialized_r && (q_cnt_d <= 3'd2)) begin
                    fetch_pend_r <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
