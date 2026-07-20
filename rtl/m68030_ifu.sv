`default_nettype none

// MC68030 Instruction Fetch Unit
//
// 6-word × 16-bit prefetch queue.  The BIU always returns a 32-bit
// longword per fetch; the IFU splits it into two 16-bit words and pushes
// them to the queue tail.  The EU/sequencer drains up to 5 words per
// cycle (opcode + up to 4 extension words).
// 6 words supports MOVE.L #imm32, abs.L (5 total words: opcode+2+2).
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
    //   4 = opcode + 3 ext  5 = opcode + 4 ext
    input  logic [2:0]  drain,

    // Instruction stream outputs (combinational, valid the cycle after fill)
    output logic [15:0] instr_word,   // q[0] — opcode
    output logic [31:0] ext_data,     // {q[1], q[2]} — two extension words
    output logic [15:0] q3_word,      // q[3] — third extension word
    output logic [31:0] ext34_data,   // {q[3], q[4]} — words 3+4
    output logic        instr_valid,  // q_cnt >= 1
    output logic        ext_valid,    // q_cnt >= 3
    output logic        ext4_valid,   // q_cnt >= 4
    output logic        ext5_valid,   // q_cnt >= 5
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
    logic [15:0] q    [0:5];      // prefetch queue: q[0] = head (next opcode)
    logic [2:0]  q_cnt;           // valid word count: 0–6
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
    assign q3_word      = q[3];
    assign ext34_data   = {q[3], q[4]};
    assign instr_valid  = (q_cnt >= 3'd1);
    assign ext_valid    = (q_cnt >= 3'd3);
    assign ext4_valid   = (q_cnt >= 3'd4);
    assign ext5_valid   = (q_cnt >= 3'd5);
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
    logic [2:0] dn;
    assign dn = (drain > q_cnt) ? q_cnt : drain;

    // Queue shifted left by dn (drain from head); tail zeroed
    logic [15:0] qd [0:5];
    always_comb begin
        case (dn)
            3'd1: begin qd[0]=q[1]; qd[1]=q[2]; qd[2]=q[3]; qd[3]=q[4]; qd[4]=q[5]; qd[5]=16'h0; end
            3'd2: begin qd[0]=q[2]; qd[1]=q[3]; qd[2]=q[4]; qd[3]=q[5]; qd[4]=16'h0; qd[5]=16'h0; end
            3'd3: begin qd[0]=q[3]; qd[1]=q[4]; qd[2]=q[5]; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            3'd4: begin qd[0]=q[4]; qd[1]=q[5]; qd[2]=16'h0; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            3'd5: begin qd[0]=q[5]; qd[1]=16'h0; qd[2]=16'h0; qd[3]=16'h0; qd[4]=16'h0; qd[5]=16'h0; end
            default: begin qd[0]=q[0]; qd[1]=q[1]; qd[2]=q[2]; qd[3]=q[3]; qd[4]=q[4]; qd[5]=q[5]; end
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

    // Position in qd where fill starts = q_cnt_d (0–4 when ack fires,
    // because we only issue a fetch when q_cnt_d ≤ 4, and q_cnt_d ≤ q_cnt ≤ 4)
    logic [2:0] fill_at;
    assign fill_at = q_cnt_d[2:0];

    // -----------------------------------------------------------------------
    // Sequential queue update
    // -----------------------------------------------------------------------
    always_ff @(posedge clk_4x or negedge rst_n) begin : queue_seq

        if (!rst_n) begin
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0;
            q[3] <= 16'h0; q[4] <= 16'h0; q[5] <= 16'h0;
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
            q[0] <= 16'h0; q[1] <= 16'h0; q[2] <= 16'h0;
            q[3] <= 16'h0; q[4] <= 16'h0; q[5] <= 16'h0;
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
                q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                q_cnt <= q_cnt_d;

            end else if (ifu_ack && fetch_pend_r && !bus_err_r) begin
                // Fill: write new word(s) into qd at position fill_at
                fetch_addr_r <= fetch_addr_r + 32'd4;
                skip_first_r <= 1'b0;
                q_cnt        <= q_cnt_df;
                // Clear fetch_pend_r; drain-only branch re-asserts next cycle
                // with the updated fetch_addr_r, avoiding address-race with the BIU.
                fetch_pend_r <= 1'b0;

                // Write queue: cases on {skip_first_r, fill_at[2:0]}
                // skip_first=0: rdata[31:16] at fill_at, rdata[15:0] at fill_at+1
                // skip_first=1: rdata[15:0]  at fill_at only (first word discarded)
                case ({skip_first_r, fill_at})
                    4'b0_000: begin
                        q[0] <= ifu_rdata[31:16]; q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_001: begin
                        q[0] <= qd[0]; q[1] <= ifu_rdata[31:16];
                        q[2] <= ifu_rdata[15:0];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_010: begin
                        q[0] <= qd[0]; q[1] <= qd[1];
                        q[2] <= ifu_rdata[31:16]; q[3] <= ifu_rdata[15:0];
                        q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b0_011: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                        q[3] <= ifu_rdata[31:16]; q[4] <= ifu_rdata[15:0];
                        q[5] <= qd[5];
                    end
                    4'b0_100: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                        q[4] <= ifu_rdata[31:16]; q[5] <= ifu_rdata[15:0];
                    end
                    4'b1_000: begin
                        q[0] <= ifu_rdata[15:0];
                        q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_001: begin
                        q[0] <= qd[0]; q[1] <= ifu_rdata[15:0];
                        q[2] <= qd[2]; q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_010: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= ifu_rdata[15:0];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_011: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= ifu_rdata[15:0];
                        q[4] <= qd[4]; q[5] <= qd[5];
                    end
                    4'b1_100: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2]; q[3] <= qd[3];
                        q[4] <= ifu_rdata[15:0]; q[5] <= qd[5];
                    end
                    default: begin
                        q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                        q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                    end
                endcase

            end else begin
                // Drain only: just shift the queue
                q[0] <= qd[0]; q[1] <= qd[1]; q[2] <= qd[2];
                q[3] <= qd[3]; q[4] <= qd[4]; q[5] <= qd[5];
                q_cnt <= q_cnt_d;

                // Issue a new fetch if queue has room (≤ 4 words after drain).
                // Guard !ifu_ack: biu_cycle_gen holds ifu_ack high for all 4
                // ticks of S7.  Without this guard the drain-only path re-arms
                // fetch_pend_r on tick 1 of S7, causing a spurious second fill
                // (at tick 2) with stale captured_rdata and advancing
                // fetch_addr_r past the next real fetch address.
                if (!fetch_pend_r && !bus_err_r && initialized_r &&
                    (q_cnt_d <= 3'd4) && !ifu_ack) begin
                    fetch_pend_r <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
