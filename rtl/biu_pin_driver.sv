`default_nettype none

// MC68030 BIU — Pin Driver (Phase 9)
//
// Manages the output enable for the bidirectional D[31:0] bus.
// In real hardware D[31:0] is truly bidirectional; in simulation we model
// this with separate ext_d_out / ext_d_in ports and an explicit OE signal.
//
// Two conditions must both be true for the BIU to drive D[31:0]:
//   1. biu_cycle_gen asserts d_oe (write cycle, S3–S5)
//   2. biu_config has asserted pins_released (at least one clock after reset)
//
// When either condition fails, ext_d_oe is 0 and the data bus is tri-stated.
// ext_d_out passes through unconditionally so that any upstream register can
// be inspected in simulation even when OE is gated off.

module biu_pin_driver (
    // From biu_cycle_gen
    input  logic [31:0] d_out,         // write data to place on D[31:0]
    input  logic        d_oe,          // 1 = biu_cycle_gen wants to drive bus

    // From biu_config
    input  logic        pins_released, // 0 during reset; 1 after first clock

    // To external bus
    output logic [31:0] ext_d_out,     // data to drive (valid when ext_d_oe=1)
    output logic        ext_d_oe       // 1 = drive ext_d_out onto D[31:0]
);

    assign ext_d_oe  = d_oe & pins_released;
    assign ext_d_out = d_out;

endmodule

`default_nettype wire
