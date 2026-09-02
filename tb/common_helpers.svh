// Shared full-chip-testbench check/wait helpers, `include`d by any tb/*.sv
// harness that instantiates `m68030_top #(.POWERON_RSTO_CLKS(40)) u_top`
// with the project's own established internal register-file access path
// (`u_top.u_eu.u_rf.d_reg[...]`) and a `logic clk_4x` clock. Before this
// file existed, `tb/stall_fsm_tb.sv` and `tb/cache_tb.sv` each
// independently declared byte-for-byte identical copies of `check`/
// `check32`/`run_and_check` (and `fail_count`) -- the same "two places
// must stay in sync" shape the ext_count de-duplication effort
// (rtl/opcode_fields.sv, plan.md's ext_count de-duplication plan) already
// fixed once for the RTL side; this closes the analogous gap on the
// testbench side. `` `include `` requires `-I tb` in IVFLAGS (already
// added by that same effort, for tb/ext_count_overlap_flags.svh).
//
// Deliberately NOT centralized here: each file's own check8/
// wait_cleared_then_set/claim_park/run_berr_mid_test/run_int_mid_test/
// emit_set_cacr/emit_set_caar/emit_set_sfc/run_dberr_mid_test -- none of
// these are actual duplicates (each file's own version differs in real,
// file-specific ways), so sharing them would be forcing an abstraction
// where none is warranted, not eliminating a real "must stay in sync"
// risk. Only genuinely byte-for-byte-identical helpers belong here.

int fail_count = 0;

task automatic check(input string name, input logic cond);
    if (cond) $display("PASS  %s", name);
    else begin $display("FAIL  %s", name); fail_count++; end
endtask

task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
    if (got === exp) $display("PASS  %s (got %08h)", name, got);
    else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
endtask

// Jumps PC to base_addr by forcibly patching the EU's PC register (there
// is no direct pc_wr_en port at the m68030_top level -- the real chip
// only ever moves PC via reset/exception/branch -- so each test case is
// instead reached by falling through from the previous one in program
// order), then polls up to `budget` cycles for the dependent register to
// reach its expected value.
task automatic run_and_check(
    input string       name,
    input int          reg_idx,
    input logic [31:0] exp_val,
    input int          budget
);
    int t;
    logic saw_ack;
    saw_ack = 0;
    for (t = 0; t < budget; t++) begin
        @(posedge clk_4x); #1;
        if (u_top.u_eu.u_rf.d_reg[reg_idx] === exp_val) begin saw_ack = 1'b1; break; end
    end
    check(name, saw_ack);
endtask
