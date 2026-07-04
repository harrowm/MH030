`default_nettype none

// MC68030 BIU — Multi-Operation FSM (Phase 5)
//
// Sits between the EU and biu_sizing_fsm.  Issues N sequential single-operand
// bus cycles to the sizing_fsm for MOVEM and MOVEP instructions.
//
// MOVEM: N longword (SIZ=00) cycles at consecutive 4-byte-aligned addresses.
// MOVEP: N byte (SIZ=01) cycles at addresses spaced `stride` bytes apart.
//
// The EU provides:
//   eu_mo_req        — start sequence
//   eu_mo_start_addr — byte address of first sub-cycle
//   eu_mo_fc         — FC[2:0] for all sub-cycles
//   eu_mo_siz        — transfer size for each sub-cycle (01=byte, 00=LW)
//   eu_mo_rw         — 1=read, 0=write
//   eu_mo_count      — number of sub-cycles (1–4; value 0 treated as 1)
//   eu_mo_stride     — byte address increment per sub-cycle (typically 2 or 4)
//   eu_mo_wdata[0-3] — write data for each sub-cycle (used when rw=0)
//
// On completion, eu_mo_ack pulses high for one clk_4x cycle.
// eu_mo_rdata[0-3] hold the assembled read data.

module biu_multiop_fsm (
    input  logic        clk_4x,
    input  logic        rst_n,

    // EU multi-op interface
    input  logic        eu_mo_req,
    input  logic [31:0] eu_mo_start_addr,
    input  logic [2:0]  eu_mo_fc,
    input  logic [1:0]  eu_mo_siz,
    input  logic        eu_mo_rw,
    input  logic [2:0]  eu_mo_count,
    input  logic [2:0]  eu_mo_stride,
    input  logic [31:0] eu_mo_wdata0,
    input  logic [31:0] eu_mo_wdata1,
    input  logic [31:0] eu_mo_wdata2,
    input  logic [31:0] eu_mo_wdata3,
    output logic [31:0] eu_mo_rdata0,
    output logic [31:0] eu_mo_rdata1,
    output logic [31:0] eu_mo_rdata2,
    output logic [31:0] eu_mo_rdata3,
    output logic        eu_mo_ack,
    output logic        eu_mo_berr,

    // Sizing-FSM EU port (driven by this module)
    output logic [31:0] sf_eu_addr,
    output logic [2:0]  sf_eu_fc,
    output logic [1:0]  sf_eu_siz,
    output logic        sf_eu_rw,
    output logic [31:0] sf_eu_wdata,
    output logic        sf_eu_is_op,
    output logic        sf_eu_req,
    input  logic [31:0] sf_eu_rdata,
    input  logic        sf_eu_ack,
    input  logic        sf_eu_berr
);

    typedef enum logic [1:0] {
        MO_IDLE   = 2'd0,
        MO_CYCING = 2'd1,
        MO_DONE   = 2'd2
    } mo_state_t;

    mo_state_t mo_state;

    logic [2:0]  mo_idx;       // current sub-cycle index (0-3)
    logic [31:0] cur_addr;
    logic [2:0]  count_r;      // latched on start (eu_mo_count)
    logic [2:0]  stride_r;
    logic [31:0] rdata_r [0:3];

    // Write data mux
    logic [31:0] wdata_mux;
    always_comb begin
        case (mo_idx[1:0])
            2'd0: wdata_mux = eu_mo_wdata0;
            2'd1: wdata_mux = eu_mo_wdata1;
            2'd2: wdata_mux = eu_mo_wdata2;
            2'd3: wdata_mux = eu_mo_wdata3;
        endcase
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mo_state  <= MO_IDLE;
            mo_idx    <= 3'd0;
            cur_addr  <= 32'h0;
            count_r   <= 3'd1;
            stride_r  <= 3'd4;
            rdata_r[0] <= 32'h0; rdata_r[1] <= 32'h0;
            rdata_r[2] <= 32'h0; rdata_r[3] <= 32'h0;
        end else begin
            case (mo_state)
                MO_IDLE: begin
                    if (eu_mo_req) begin
                        mo_state <= MO_CYCING;
                        mo_idx   <= 3'd0;
                        cur_addr <= eu_mo_start_addr;
                        count_r  <= (eu_mo_count == 3'd0) ? 3'd1 : eu_mo_count;
                        stride_r <= eu_mo_stride;
                    end
                end
                MO_CYCING: begin
                    if (sf_eu_ack) begin
                        if (eu_mo_rw) rdata_r[mo_idx[1:0]] <= sf_eu_rdata;
                        if (mo_idx == (count_r - 3'd1)) begin
                            mo_state <= MO_DONE;
                        end else begin
                            mo_idx   <= mo_idx + 3'd1;
                            cur_addr <= cur_addr + {29'h0, stride_r};
                        end
                    end
                end
                MO_DONE: begin
                    mo_state <= MO_IDLE;
                end
                default: mo_state <= MO_IDLE;
            endcase
        end
    end

    assign sf_eu_addr   = cur_addr;
    assign sf_eu_fc     = eu_mo_fc;
    assign sf_eu_siz    = eu_mo_siz;
    assign sf_eu_rw     = eu_mo_rw;
    assign sf_eu_wdata  = wdata_mux;
    assign sf_eu_is_op  = 1'b1;
    assign sf_eu_req    = (mo_state == MO_CYCING);

    assign eu_mo_rdata0 = rdata_r[0];
    assign eu_mo_rdata1 = rdata_r[1];
    assign eu_mo_rdata2 = rdata_r[2];
    assign eu_mo_rdata3 = rdata_r[3];
    assign eu_mo_ack    = (mo_state == MO_DONE);
    assign eu_mo_berr   = sf_eu_berr && (mo_state == MO_CYCING);

endmodule

`default_nettype wire
