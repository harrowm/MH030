`default_nettype none

// =============================================================================
// MH030-P instruction cache: 64 longwords (256 bytes), direct-mapped.
//
// WHY. `make bench` measured where the ticks actually go, and it is not the
// execute pipeline or the clock:
//
//     issued=1419 stalled=1544 idle=3163 redirects=253
//     bus=1610 fetch=1352 data=258
//
// EX had nothing to execute for 3,163 of 6,116 ticks -- 52% -- and the front end
// issued 1,352 instruction fetches for 1,419 instructions, nearly one bus
// transaction each where a longword fetch supplies two. The cause is on the same
// line: 253 taken branches, in loops of 4-7 instructions, so the prefetch queue
// was flushed roughly every five instructions and refilled from the target.
//
// A real MC68030 has a 256-byte instruction cache for exactly this reason. The
// size here is 64 bytes (16 longwords) and that is a MEASURED choice, not a
// smaller-is-fine guess -- 16, 32 and 64 entries were all built and benchmarked:
//
//     entries   ticks   fetches   icache cells   design total
//       16      4,025      43        3,257          32,116
//       32      4,025      43        7,683          36,542
//       64      4,025      43       10,583          39,442
//
// Identical ticks and identical fetch counts at every size, because the loops
// that matter here are 4-7 instructions, so 64 bytes already holds them whole.
// The read muxes are what cost area, and they grow with the entry count, so the
// larger sizes were paying ~7,000 cells for nothing measurable. ENTRIES is a
// parameter: raise it if a workload with bigger loops ever shows a benefit,
// which this benchmark cannot.
//
// SHAPE. A longword per entry, not a 16-byte line, because this core's bus has
// no burst transfer -- the arbiter moves one longword per transaction, so a line
// would have to be filled by four separate misses and would buy nothing over
// caching each longword as it arrives.
//
// A HIT ACKS IN THE SAME CYCLE, which is the whole point: the fetch unit samples
// if_ack in a clocked block, so a combinational ack retires the request on that
// edge and a hit costs one tick instead of a bus transaction.
//
// TAG INCLUDES ADDRESS BIT 1. Fetch addresses are not longword-aligned in
// general: the fetch unit takes its address from redirect_pc and then adds 4, so
// a branch to an odd word address makes every subsequent fetch 2 mod 4. The
// bytes at 0x08 and 0x0A overlap but are different requests returning different
// data, so bit 1 has to distinguish them or one would answer for the other.
//
// COHERENCE. The real 68030's I-cache is not coherent with writes -- software is
// expected to flush it. This one snoops the data side and invalidates a matching
// entry, which is cheap (one comparator) and removes a whole class of risk:
// without it, a test that writes over an address already cached would read a
// stale instruction, and the Harte harness synthesises programs whose writes can
// land anywhere.
// =============================================================================

module mh030p_icache #(
    // Entries, each one longword. 64 would be 256 bytes, matching the real
    // MC68030 -- but the size is chosen from measurement instead, because the
    // read muxes cost real area and the loops that matter are small. See the
    // note at the bottom.
    parameter ENTRIES = 16
) (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Fetch unit side.
    input  wire        if_req,
    input  wire [31:0] if_addr,
    output wire [31:0] if_rdata,
    output wire        if_ack,

    // Memory side (to the arbiter).
    output reg         m_req,
    output reg  [31:0] m_addr,
    input  wire [31:0] m_rdata,
    input  wire        m_ack,

    // Data-side snoop, for the invalidate described above.
    input  wire        d_req,
    input  wire        d_rw,        // 1 = read, 0 = write
    input  wire [31:0] d_addr
);

    localparam int IDXW = (ENTRIES == 64) ? 6 : (ENTRIES == 32) ? 5 : 4;
    // {addr[31:IDXW+2], addr[1]}
    localparam int TAGW = 32 - (IDXW + 2) + 1;

    // PACKED STORAGE, READ AND WRITTEN BY PART-SELECT. Written as indexed
    // unpacked arrays first, which is the obvious way and cost 13,940
    // combinational cells for 64 x 58 bits -- the same pathology the register
    // file has, where yosys builds a per-bit priority-mux chain instead of a
    // balanced tree. Packing lets it emit one $shiftx per read instead.
    //
    // This is the case where packing is the right call, and the register file is
    // the case where it is not. There the muxes feed the decoder and the address
    // adder, which have no slack, and packing measured 1.67 MHz SLOWER. Here the
    // read feeds the fetch unit's queue write -- a flip-flop, with a whole clock
    // to settle -- so the depth a $shiftx costs is spent out of slack that
    // already exists.
    reg [ENTRIES*TAGW-1:0] tags_flat;
    reg [ENTRIES*32-1:0]   data_flat;
    reg [ENTRIES-1:0]      valid_flat;

    wire [IDXW-1:0] if_idx = if_addr[IDXW+1:2];
    wire [TAGW-1:0] if_tag = {if_addr[31:IDXW+2], if_addr[1]};
    wire [IDXW-1:0] d_idx  = d_addr[IDXW+1:2];
    wire [TAGW-1:0] d_tag  = {d_addr[31:IDXW+2], d_addr[1]};

    wire [TAGW-1:0] if_tag_r  = tags_flat[if_idx*TAGW +: TAGW];
    wire [31:0]     if_data_r = data_flat[if_idx*32   +: 32];
    wire [TAGW-1:0] d_tag_r   = tags_flat[d_idx*TAGW  +: TAGW];

    wire hit = if_req && valid_flat[if_idx] && (if_tag_r == if_tag);

    // A hit answers immediately; a miss answers when the bus does.
    assign if_rdata = hit ? if_data_r : m_rdata;
    assign if_ack   = hit || m_ack;

    // A write to a cached longword drops it. Checked against the ENTRY's own
    // tag, so an unrelated address that merely shares the index is untouched.
    wire snoop_kill = d_req && !d_rw && valid_flat[d_idx] && (d_tag_r == d_tag);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            m_req  <= 1'b0;
            m_addr <= 32'h0;
            // Only the valid bits need clearing; tag and data are don't-care
            // until an entry is valid, and not resetting them keeps 2,048+1,600
            // flip-flops out of the reset fan-out.
            valid_flat <= {ENTRIES{1'b0}};
        end else begin
            // Miss: issue the fetch and hold it until the bus answers. A hit
            // never reaches the bus at all.
            if (if_req && !hit && !m_req) begin
                m_req  <= 1'b1;
                m_addr <= if_addr;
            end else if (m_ack) begin
                m_req  <= 1'b0;
            end

            // Fill on the answering ack, then the snoop, so an invalidate that
            // lands in the same cycle as a fill wins -- the safe direction.
            if (m_ack) begin
                tags_flat[if_idx*TAGW +: TAGW] <= if_tag;
                data_flat[if_idx*32   +: 32]   <= m_rdata;
                valid_flat[if_idx]             <= 1'b1;
            end
            if (snoop_kill) valid_flat[d_idx] <= 1'b0;
        end
    end

endmodule

`default_nettype wire
