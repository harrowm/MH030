`default_nettype none

// =============================================================================
// MH030-P bus arbiter: one external port shared by instruction fetch and data.
//
// The core and the fetch unit were given separate ports while the pipeline was
// being built, because contention would have obscured what was being measured.
// Real 68030 silicon has one bus, and rtl/biu_arbiter.sv arbitrates it, so
// this closes that simplification.
//
// PRIORITY: data beats instruction fetch. The EU is executing work the program
// actually asked for and stalls when it cannot proceed, whereas a fetch is
// speculative -- the queue exists precisely to absorb the delay. Serving the
// IFU first would stall the EU behind prefetch for instructions a branch may
// be about to discard. rtl/biu_arbiter.sv uses the same ordering.
//
// A grant is HELD for the whole transaction. Once a request is forwarded it
// keeps the bus until its acknowledgement returns, and the address is taken
// from the winner latched at grant time rather than read live. Letting the
// address follow whoever currently wins would change it mid-transaction --
// that is a real bug this project already paid for once
// (feedback_live_address_during_held_grant.md).
// =============================================================================

module mh030p_arb (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Instruction side.
    input  wire        if_req,
    input  wire [31:0] if_addr,
    output wire [31:0] if_rdata,
    output wire        if_ack,

    // Data side.
    input  wire        d_req,
    input  wire [31:0] d_addr,
    input  wire        d_rw,
    input  wire [1:0]  d_siz,
    input  wire [31:0] d_wdata,
    output wire [31:0] d_rdata,
    output wire        d_ack,

    // The one external port.
    output reg         bus_req,
    output reg  [31:0] bus_addr,
    output reg         bus_rw,
    output reg  [1:0]  bus_siz,
    output reg  [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ack
);

    // Who owns the bus: 0 = nobody, 1 = data, 2 = instruction fetch.
    localparam [1:0] OWN_NONE = 2'd0, OWN_DATA = 2'd1, OWN_IFU = 2'd2;
    reg [1:0] owner;

    wire idle = (owner == OWN_NONE);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            owner     <= OWN_NONE;
            bus_req   <= 1'b0;
            bus_addr  <= 32'h0;
            bus_rw    <= 1'b1;
            bus_siz   <= 2'b00;
            bus_wdata <= 32'h0;
        end else if (idle) begin
            // Data first; see the header.
            if (d_req) begin
                owner     <= OWN_DATA;
                bus_req   <= 1'b1;
                bus_addr  <= d_addr;
                bus_rw    <= d_rw;
                bus_siz   <= d_siz;
                bus_wdata <= d_wdata;
            end else if (if_req) begin
                owner     <= OWN_IFU;
                bus_req   <= 1'b1;
                bus_addr  <= if_addr;
                bus_rw    <= 1'b1;
                bus_siz   <= 2'b00;      // instruction fetch is longword
                bus_wdata <= 32'h0;
            end
        end else if (bus_ack) begin
            // Transaction complete; release. The address above is never
            // re-driven while owner != NONE, so it cannot move mid-cycle.
            owner   <= OWN_NONE;
            bus_req <= 1'b0;
        end
    end

    // Acknowledgement goes only to the owner.
    assign d_ack    = bus_ack && (owner == OWN_DATA);
    assign if_ack   = bus_ack && (owner == OWN_IFU);
    assign d_rdata  = bus_rdata;
    assign if_rdata = bus_rdata;

endmodule

`default_nettype wire
