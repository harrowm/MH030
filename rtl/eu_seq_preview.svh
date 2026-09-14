    // -----------------------------------------------------------------------
    // eu_seq_preview.svh -- the Track 3 back-to-back bus-cycle dispatch-gap
    // preview mechanism (wobbly-honking-cascade.md), extracted from
    // eu_seq_execute.svh as a post-Track-3 cleanup pass (pure text
    // relocation, same `` `include `` technique Phase 226 already proved
    // safe for the original decode/execute split -- byte-identical
    // elaborated output, no behavior change). Contains: the shared
    // `reg_hazard` helper, every family's own `*_final_ack`/`*_hazard`
    // signal (Tracks 3 #1-#16, MOVEM through CAS2), and the two signals
    // that consume them, `preview_current_ready`/`preview_ok`. Everything
    // downstream of `preview_ok` (the `mem_req`/`mem_rw`/`mem_wdata`/
    // `mem_addr` dispatch mux, which predates Track 3 and serves every
    // special FSM's own bus-active flag, not just preview) deliberately
    // stays in `eu_seq_execute.svh` -- it is not Track-3-specific and is
    // not a clean, self-contained extraction candidate.
    // -----------------------------------------------------------------------
    //
    // reg_hazard: shared helper for the Track 3 hazard-signal shape that
    // recurs below -- "this family's own direct-port register write
    // (bypassing hazard_ex/hazard_wb entirely) is landing THIS cycle on
    // the exact register NEXT's own preview would read as src or dst."
    // Ten of the eleven Track 3 hazard checks were hand-copied instances
    // of this identical template with only the write-enable/target pair
    // substituted -- centralized here as a single function instead,
    // mirroring the project's own opcode_fields.sv precedent (Phase
    // 221-224) for the same hand-copied-field bug shape (a silently
    // dropped `dec_dst_reg` half of the OR would be a real, hard-to-catch
    // under-protection bug). Pure refactor: behaviorally identical to
    // every site it replaces.
    function automatic logic reg_hazard(logic wr_en, logic [3:0] target);
        return wr_en && (dec_src_reg == target || dec_dst_reg == target);
    endfunction

    // Track 3 #1 (MOVEM, wobbly-honking-cascade.md): MOVEM writes
    // registers via its own direct wr_en/movem_reg_sel port -- NOT
    // through ex_dest_reg/wb_dest_reg, so hazard_ex/hazard_wb's own
    // generic check never sees these writes at all (confirmed by direct
    // inspection: `assign wr_sel = movem_wr_en ? movem_reg_sel : ...`,
    // a completely separate path). Two hazard sources, both landing on
    // the exact cycle `movem_last` fires (one cycle before the write
    // itself commits -- the same "this cycle still reads the OLD value"
    // timing every synchronous write has): (1) `movem_wr_en` (load
    // mode): the register `movem_reg_sel` names is being loaded THIS
    // cycle; (2) `movem_an_wr_en` (predec/postinc): the base An register
    // is being updated THIS cycle regardless of load/store direction.
    // NEXT's own preview must not read either as its own An/Xn/write-
    // source -- checked against both `dec_src_reg` and `dec_dst_reg`
    // since either could be the field the active preview sub-case uses.
    logic movem_hazard;
    assign movem_hazard = reg_hazard(movem_wr_en, movem_reg_sel) ||
                          reg_hazard(movem_an_wr_en, {1'b1, movem_an_r});

    // Track 3 #2 (CMP2/CHK2, wobbly-honking-cascade.md): the second
    // (upper-bound) read's own ack, `cmp2_run_r && mem_ack`, is the
    // family's "genuinely final beat" signal (mirrors `movem_last`'s own
    // derivation -- `ex_mem_stall` includes the raw registered
    // `cmp2_run_r`, which only clears ONE CYCLE AFTER this same ack, per
    // Phase 257's universal finding, so `!ex_mem_stall` cannot be reused
    // as the trigger here either). No dedicated hazard signal is needed
    // the way MOVEM needed `movem_hazard`: CMP2/CHK2 never sets
    // `dec_writes_reg` (confirmed via direct inspection -- Rn is only
    // ever READ, via `dec_dst_reg`/`rd_b`, to be compared against the
    // bounds, never written), so `hazard_ex`/`hazard_wb`'s own generic
    // `ex_dest_reg`/`wb_dest_reg` check is trivially satisfied (nothing
    // to protect). The only real write this family makes is to CCR
    // (`cmp2_sr_wr_en`), which the EXISTING `hazard_ccr` term already
    // covers with zero changes: `ex_updates_ccr` latches at EX-dispatch
    // time (`dec_updates_ccr`) and stays 1 for the instruction's entire
    // EX residency, including this exact final-ack cycle, so
    // `hazard_ccr` already blocks any NEXT that reads CCR here.
    // **New exclusion needed, unlike MOVEM**: CHK2 (not CMP2) can
    // synchronously TRAP on this exact same cycle (`chk_trap`, gated on
    // `cmp2_run_r && mem_ack && cmp2_is_chk2_r && cmp2_c_w` -- see
    // `chk_trap_raw`'s own declaration). A trap redirects flow to the
    // exception vector; the ordinarily-decoded `dec_valid` instruction
    // this same cycle is never actually going to execute, so preview_ok
    // must not dispatch a phantom bus read for it (the same "unrequested
    // phantom cycle" bug class Phase 254's own investigation flagged as
    // a genuine correctness issue, not just a missed optimization).
    // `chk_trap` itself is already the correct one-shot/edge-triggered
    // form (`chk_trap_raw && !chk_trap_fired_r`, the same signal
    // `ex_will_except`/`ex_exc_dispatch_hazard` use to protect the
    // ORDINARY dispatch path) -- reused directly here.
    logic cmp2_final_ack;
    assign cmp2_final_ack = cmp2_run_r && mem_ack && !chk_trap;

    // Track 3 #3 (MOVEP, wobbly-honking-cascade.md): `movep_last`
    // (already declared/derived at line ~527 for MOVEP's own byte-
    // sequence termination) is the final-beat signal -- `ex_mem_stall`
    // includes the raw registered `movep_run_r`, which clears one cycle
    // after this same final ack, matching Phase 257's universal finding.
    // Like MOVEM (not CMP2/CHK2), MOVEP writes a register via its own
    // direct port (`wr_sel = ... : movep_wr_en ? movep_wr_sel`,
    // `movep_wr_sel = {1'b0, movep_dn_r}` -- always Dn, never An, since
    // MOVEP's own EA is fixed d16(An) with no auto-inc/dec) --
    // hazard_ex/hazard_wb never see this write, so a dedicated
    // `movep_hazard` is needed, mirroring `movem_hazard`'s own shape but
    // simpler: only ONE hazard source (no second `_an_wr_en`-style term,
    // since MOVEP never updates An). `movep_wr_en` is already 0 for the
    // store direction (`movep_wr_en = movep_last && movep_load_r`), so
    // this is naturally a no-op hazard for MOVEP stores. MOVEP never
    // traps or changes flow, so no CHK2-style exclusion is needed either.
    logic movep_hazard;
    assign movep_hazard = reg_hazard(movep_wr_en, movep_wr_sel);

    // Track 3 #4 (ADDX/SUBX-mem, wobbly-honking-cascade.md): unlike
    // MOVEM/MOVEP, ADDX/SUBX -(Ay),-(Ax)'s own decode arm
    // (`eu_seq_decode.svh`) never sets `dec_is_mem_rd`/`dec_is_mem_wr`
    // at all -- it dispatches entirely through its own dedicated 3-phase
    // FSM (`addx_mem_run_r`/`addx_mem_phase_r`: 0=read Ay, 1=read Ax,
    // 2=write the ALU result back to memory at Ax), so the ordinary
    // trigger's `ex_is_mem_rd` term structurally never fires for it,
    // regardless of `ex_mem_stall` timing -- a new dedicated OR-term is
    // still needed. Final beat = phase 2's own write ack.
    // **No dedicated hazard signal is needed here, unlike MOVEM/MOVEP**:
    // confirmed via direct inspection that (1) the ALU RESULT is written
    // to MEMORY, not a register, so there is no Dn/An VALUE hazard of
    // that shape at all; (2) Ay's own predecrement-pointer update
    // (`addx_ay_wr_en`) commits when PHASE 0 acks, and Ax's
    // (`addx_ax_wr_en`) when PHASE 1 acks -- both strictly BEFORE phase
    // 2 ever begins, so by the time phase 2's ack fires (this new
    // trigger), both address-register writes already committed at least
    // one full clock edge earlier -- no in-flight/same-cycle collision
    // the way MOVEM's own final beat coincides with its own register
    // write. `hazard_ex`/`hazard_wb` need no new coverage either: both
    // are gated on `ex_writes_reg`, which ADDX/SUBX-mem's own decode arm
    // never sets (confirmed -- no `dec_writes_reg` assignment in that
    // branch), so they're trivially satisfied (nothing to protect via
    // the generic path, consistent with the memory-only-result finding
    // above). The only real write this family makes is to CCR
    // (`addx_mem_sr_wr_en`), already covered by the pre-existing
    // `hazard_ccr` exactly as for CMP2/CHK2. ADDX/SUBX-mem never traps
    // or changes flow, so no CHK2-style exclusion is needed either.
    logic addx_mem_final_ack;
    assign addx_mem_final_ack = addx_mem_run_r && addx_mem_phase_r == 2'd2 && mem_ack;

    // Track 3 #5 (bitfield-mem, wobbly-honking-cascade.md): BFCHG/BFCLR/
    // BFSET/BFINS/BFEXTU/BFEXTS/BFFFO/BFTST's own memory-EA form
    // dispatches through a 2-phase FSM (0=read, 1=write -- write phase
    // skipped entirely for the 4 non-mutating ops, mirroring
    // `bf_mem_stall`'s own "done" sub-expression exactly, reused
    // directly here as the final-beat signal). Like MOVEM/MOVEP (not
    // ADDX/SUBX-mem), the non-mutating ops (BFEXTU/BFEXTS/BFFFO) DO
    // write a result to a Dn register via their own direct port
    // (`bf_dn_wr_en`/`bf_mem_dn_r`, confirmed in `wr_sel`'s own
    // `bf_dn_wr_en ? {1'b0, bf_mem_dn_r}` arm) -- bypassing
    // `hazard_ex`/`hazard_wb` entirely, and this write lands on the
    // EXACT SAME cycle as the final-beat trigger for that sub-case
    // (`bf_dn_wr_en`'s own condition, `!bf_mem_phase_r &&
    // !bf_mem_mutates_r`, is one of the two final-beat conditions
    // itself) -- a dedicated `bf_hazard` is needed, mirroring
    // `movem_hazard`/`movep_hazard`. For the 4 mutating ops (BFCHG/
    // BFCLR/BFSET/BFINS), `bf_dn_wr_en` requires `!bf_mem_mutates_r`, so
    // it is always 0 regardless of phase -- `bf_hazard` is naturally
    // inert there, the same "no-op for the write-only direction" shape
    // MOVEP's own hazard already established. Bitfield instructions
    // never use auto-inc/dec addressing (no An-update hazard source
    // exists to protect against, unlike MOVEM), never trap, and never
    // change flow.
    logic bf_mem_final_ack;
    assign bf_mem_final_ack = bf_mem_run_r && mem_ack &&
                              ((!bf_mem_phase_r && !bf_mem_mutates_r) || bf_mem_phase_r);
    logic bf_hazard;
    assign bf_hazard = reg_hazard(bf_dn_wr_en, {1'b0, bf_mem_dn_r});

    // Track 3 #6 (PACK/UNPK-mem, wobbly-honking-cascade.md): a 2-phase
    // FSM (0=read Ay, 1=write result to Ax), superficially like
    // ADDX/SUBX-mem's 3-phase shape, but with one critical difference
    // found via direct inspection: ADDX-mem's own Ax predecrement update
    // (`addx_ax_wr_en`) fires at PHASE 1's ack -- strictly BEFORE its
    // own final beat at phase 2 -- so by the time the final trigger
    // fires, Ax has already committed. PACK/UNPK-mem has only 2 phases
    // total, so `pack_ax_wr_en` (Ax's own predecrement update, via the
    // SAME dedicated `an_wr_en`/`an_wr_sel` port MOVEM's own
    // `movem_an_wr_en` uses -- confirmed bypassing `hazard_ex`/
    // `hazard_wb` entirely, same as every other direct-port write this
    // track has found) fires on the EXACT SAME condition as this
    // family's own final beat (`pack_mem_run_r && pack_mem_phase_r &&
    // mem_ack`) -- a genuine same-cycle hazard, the MOVEM shape, not the
    // ADDX-mem shape. A dedicated `pack_hazard` is therefore needed
    // (Ay's own update, at phase 0's ack, is NOT the final-beat cycle,
    // so it's already safely committed by then -- no protection needed
    // there, matching ADDX-mem's own Ay/Ax reasoning). PACK/UNPK-mem
    // never writes a data register via the generic `wr_en`/`wr_sel`
    // path (confirmed -- no `pack_*_wr_en` term in that OR-chain; the
    // packed/unpacked byte goes to MEMORY, not Dn) and affects no CCR
    // bits at all (a documented 68k ISA property), so no other hazard
    // source exists. PACK/UNPK-mem never traps or changes flow.
    logic pack_mem_final_ack;
    assign pack_mem_final_ack = pack_mem_run_r && pack_mem_phase_r && mem_ack;
    logic pack_hazard;
    assign pack_hazard = reg_hazard(pack_ax_wr_en, {1'b1, pack_mem_ax_reg_r});

    // Track 3 #7 (PMOVE64, wobbly-honking-cascade.md): PMOVE CRP/SRP's
    // own 2-phase FSM (phase 0: bus cycle at An; phase 1: bus cycle at
    // An+4). Final beat = phase 1's own ack, `pmove64_run_r &&
    // !pmove64_skip_r && mem_ack` (mirrors `pmove64_skip_r`'s own
    // declaration comment exactly -- `pmove64_skip_r` burns the one
    // stale mem_ack that fires the same clock `pmove64_run_r` transitions
    // 0->1, so `!pmove64_skip_r` is required to pick out the GENUINE
    // second-half ack, not that transitional one). **No dedicated hazard
    // signal is needed at all, unlike MOVEM/MOVEP/bitfield-mem/PACK**:
    // confirmed via direct inspection of the decode arm
    // (`eu_seq_decode.svh`) that PMOVE64's own EA is restricted to
    // `f_mode==3'b010` (plain `(An)`) ONLY -- no auto-inc/dec form is
    // even decoded, so there is no An-update hazard source at all (the
    // one structural difference from PACK/UNPK-mem, which shares this
    // family's "own dedicated 2-phase FSM" shape but DOES use
    // predecrement EAs). The 64-bit CRP/SRP value itself is internal MMU
    // state (`crp_out`/`srp_out`), never a Dn/An register, so
    // `hazard_ex`/`hazard_wb`/`hazard_ccr` have nothing to protect
    // regardless. **New consideration, shared with CMP2/CHK2's own
    // shape**: PMOVE CRP/SRP can synchronously trigger the MMU
    // Configuration Exception (vector 56) on this exact same final-ack
    // cycle (`mmu_config_trap`, already the correct one-shot/edge-
    // triggered signal, mirroring `chk_trap`'s own shape exactly) -- a
    // trap redirects flow to the exception vector, so `dec_valid`'s own
    // instruction this same cycle never actually executes and must not
    // receive a phantom preview bus access. Excluded directly via
    // `!mmu_config_trap`.
    logic pmove64_final_ack;
    assign pmove64_final_ack = pmove64_run_r && !pmove64_skip_r && mem_ack && !mmu_config_trap;

    // Track 3 #8 (cpSAVE/cpRESTORE, wobbly-honking-cascade.md): the
    // first family whose own "genuinely final beat" is NOT itself
    // always a memory-bus event. Its transfer loop alternates between a
    // memory access (`cpsr_xfer_mem_r`) and a coprocessor-interface
    // access (`cpsr_xfer_cir_r`, via the SEPARATE `eu_coproc_req`/
    // `eu_coproc_ack` port, confirmed independent of `mem_req`/
    // `mem_ack`), looping until `cpsr_xfer_cnt_r+4 >= cpsr_len_r`
    // (`cpsr_len_r` is a runtime, coprocessor/memory-supplied byte
    // length -- confirmed via direct inspection of the loop's own
    // termination arms). **cpSAVE's own last iteration ends on the
    // MEMORY write** (`cpsr_xfer_mem_r && mem_ack`, writing the final
    // longword to the destination -(An) address); **cpRESTORE's own
    // last iteration ends on the COPROCESSOR write instead**
    // (`cpsr_xfer_cir_r && eu_coproc_ack`, writing the final longword
    // to the Operand CIR) -- confirmed by direct inspection of both
    // branches' own "else: this was the last longword -- done" comments.
    // `ex_mem_stall` already includes both `cpsr_xfer_mem_r` and
    // `cpsr_xfer_cir_r` as raw, unconditional OR-terms (so it stays 1
    // through the WHOLE loop, clearing only the cycle AFTER whichever
    // ack is genuinely final -- the same universal one-cycle-late
    // pattern Phase 257 found for every other special FSM), so a
    // dedicated trigger is needed regardless of which port the final ack
    // arrives on. **No dedicated hazard signal is needed**: `cpsr_an_wr_en`
    // (the -(An)/(An)+ auto-update) fires at `cpsr_start_r`, the
    // instruction's own FIRST cycle -- committed many cycles before any
    // final-beat trigger below could possibly fire, the same "already
    // safely committed" reasoning ADDX-mem's own Ay/Ax updates rely on.
    // Neither cpSAVE nor cpRESTORE ever writes a Dn register (confirmed
    // -- no `cpsr_*_wr_en` term anywhere in the generic `wr_en` OR-chain;
    // `dec_unit=UNIT_NONE` for both). The format-error abort path
    // (`cpsr_abort_r`) is a structurally separate state, mutually
    // exclusive with `cpsr_xfer_mem_r`/`cpsr_xfer_cir_r` (a malformed
    // transfer never enters the loop at all), so no CHK2-style trap
    // exclusion is needed either. Confirmed via direct decode inspection
    // (the new standing checklist item from Phase 264/PMOVE64) that
    // neither `dec_is_cpsave` nor `dec_is_cprestore` ever sets
    // `dec_is_mem_rd`/`dec_is_mem_wr` (`dec_unit=UNIT_NONE`, only
    // `dec_src_reg`/`dec_reads_src` for An itself) -- safe from the
    // PMOVE64-shaped regression.
    logic cpsr_last_iter;
    assign cpsr_last_iter = !((cpsr_xfer_cnt_r + 8'd4) < cpsr_len_r);
    logic cpsr_final_ack;
    assign cpsr_final_ack = (cpsr_xfer_mem_r && mem_ack && !cpsr_is_restore_r && cpsr_last_iter) ||
                            (cpsr_xfer_cir_r && eu_coproc_ack && cpsr_is_restore_r && cpsr_last_iter);

    // Track 3 #9 (BCD-mem, ABCD/SBCD -(Ay),-(Ax), wobbly-honking-cascade.md):
    // structurally IDENTICAL to ADDX/SUBX-mem's own 3-phase shape (0=read
    // Ay, 1=read Ax, 2=write result) -- confirmed via direct inspection:
    // `bcds_ay_wr_en` fires at phase 0's ack, `bcds_ax_wr_en` at phase 1's
    // ack, BOTH strictly before phase 2 (this new trigger), so neither
    // address-register write is in-flight at the moment of preview, the
    // same reasoning ADDX-mem's own Ay/Ax updates already established.
    // The BCD result byte writes to MEMORY, not a register (confirmed --
    // no `bcds_*_wr_en` term in the generic `wr_en` chain); the only
    // other write is to CCR (`bcds_sr_wr_en`), already covered by the
    // pre-existing `hazard_ccr`. ABCD/SBCD-mem never traps or changes
    // flow, and its own decode arm (confirmed via the same Phase 264
    // checklist item) never sets `dec_is_mem_rd`/`dec_is_mem_wr` either
    // (dispatches entirely through its own dedicated FSM, same as
    // ADDX/SUBX-mem) -- safe from the PMOVE64-shaped regression. No
    // dedicated hazard signal needed at all.
    logic bcds_final_ack;
    assign bcds_final_ack = ex_valid && ex_is_abcd_sbcd_mem && bcds_run_r &&
                            bcds_phase_r == 2'd2 && mem_ack;

    // Track 3 #10 (MOVE mem-to-mem indexed-dst, wobbly-honking-cascade.md):
    // `ex_is_move_mm`'s own 2-phase FSM (read source, then
    // `move_mm_run_r`=write phase) is ALSO one of `dyn_bit_get_Dn`'s 5
    // consumer families -- but that swap fires at the SOURCE READ's own
    // ack (`ex_is_mem_rd && mem_ack`, explicitly excluding
    // `move_mm_run_r`/`move_mm_after_r` in its own formula), a
    // completely different cycle than this family's own final beat
    // (`move_mm_run_r && mem_ack`, the WRITE ack) -- no collision.
    // **Confirmed SAFE from the Phase 264/PMOVE64-shaped regression, but
    // for a different reason than every later family**: `dec_is_move_mm`
    // DOES set `dec_is_mem_rd=1` for its own source-read phase (matching
    // PMOVE64's own exposure shape) -- but `ex_mem_stall` ALREADY
    // includes `move_mm_read_ack` as its own dedicated OR-term (pre-
    // existing, not added by this track), so the ordinary trigger's own
    // `!ex_mem_stall` already correctly excludes the read-ack moment;
    // this family's own history already closed the exact gap PMOVE64
    // exposed, before Track 3 ever started. **New hazard signal needed**:
    // `move_mm_dst_an_wr_en` (the destination An auto-inc/dec update, for
    // non-indexed destination EA forms only -- indexed destinations never
    // set `move_mm_dst_an_upd_r`) fires on the EXACT SAME cycle as this
    // family's own final beat (`move_mm_run_r && mem_ack`), the PACK
    // shape, not the ADDX-mem shape. `move_mm_hazard` protects against
    // it; naturally 0 for the indexed-destination sub-case the plan's
    // own item name specifically flags (the higher-risk `dyn_bit_get_Dn`
    // consumer), since indexed EA never sets `move_mm_dst_an_upd_r` at
    // all. No Dn register write exists via the generic `wr_en` path
    // (confirmed -- no `move_mm_*_wr_en` term there); the only other
    // write is CCR (`move_mm_sr_wr_en`), already covered by
    // `hazard_ccr`. MOVE mem-to-mem never traps or changes flow.
    logic move_mm_final_ack;
    assign move_mm_final_ack = ex_is_move_mm && move_mm_run_r && mem_ack;
    logic move_mm_hazard;
    assign move_mm_hazard = reg_hazard(move_mm_dst_an_wr_en, {1'b1, move_mm_dst_an_reg_r});

    // Track 3 #11 (CMPM, wobbly-honking-cascade.md): CMPM (Ay)+,(Ax)+'s
    // own 2-phase FSM (phase 1: read Ay, postincrement; phase 2: read Ax,
    // postincrement + compare). Final beat = `cmpm_phase_r && mem_ack`
    // (mirrors `cmpm_stall`'s own complement exactly). **Confirmed SAFE
    // from the Phase 264/PMOVE64-shaped regression, the same reason as
    // MOVE mem-to-mem**: CMPM's own decode DOES set `dec_is_mem_rd=1`
    // (matching PMOVE64's exposure shape), but `cmpm_stall` (a
    // pre-existing signal, already in `ex_mem_stall`'s own OR-chain)
    // already correctly stays 1 through phase 1's own ack (its own
    // formula, `!(cmpm_phase_r && mem_ack)`, is 1 whenever
    // `cmpm_phase_r=0`, i.e. throughout phase 1) -- this family's own
    // history already closed the gap PMOVE64 exposed. **New hazard
    // signal needed, the PACK/move_mm shape**: `cmpm_ax_wr_en` (Ax's own
    // postincrement update, via the same dedicated `an_wr_en` port)
    // fires on the EXACT SAME cycle as this final beat (CMPM has only 2
    // phases total, so there's no earlier phase for it to commit at,
    // unlike ADDX-mem's own 3-phase Ay/Ax timing) -- `cmpm_hazard`
    // protects against it. `cmpm_ay_wr_en` (Ay's own postincrement),
    // fires at phase 1's ack, strictly BEFORE this final beat, so it's
    // already safely committed by then, needing no protection (the
    // ADDX-mem shape for Ay specifically). CMPM never writes a Dn
    // register (a pure compare); the only other effect is CCR, already
    // covered by `hazard_ccr`. CMPM never traps or changes flow.
    logic cmpm_final_ack;
    assign cmpm_final_ack = ex_valid && ex_is_cmpm && cmpm_phase_r && mem_ack;
    logic cmpm_hazard;
    assign cmpm_hazard = reg_hazard(cmpm_ax_wr_en, {1'b1, cmpm_ax_reg_r});

    // Track 3 #12 (memory-indirect, Group B, wobbly-honking-cascade.md):
    // the shared `memind_*` FSM used as a PREFIX by 9 other families
    // (MOVE, LEA, PEA, JMP, JSR, general ALU-EA, CMP2/CHK2, TAS, Scc,
    // MOVEM). Confirmed via direct inspection this is NOT one single
    // "final beat" shape -- it splits into two structurally different
    // completion points, and several of its own 9 consumers hand off to
    // an ENTIRELY SEPARATE dedicated FSM afterward (already covered by
    // their own final-beat triggers elsewhere in this track) rather than
    // completing via memind itself:
    //   - `memind_addr_only_r` (LEA/JMP/TAS/MOVEM): skips the outer
    //     phase entirely, completing/handing-off directly at
    //     `memind_inner_r && mem_ack`. Of these four, only LEA and JMP
    //     genuinely COMPLETE here -- TAS hands off to
    //     `tas_memind_pending_r`->`tas_run_r` (Task #14, not yet done)
    //     and MOVEM hands off to `movem_memind_pending_r`->`movem_run_r`
    //     (already closed, Task #1/Phase 258) -- excluded here via
    //     `!ex_is_tas && !ex_is_movem` so this new trigger never fires
    //     mid-hand-off for either.
    //   - The remaining 5 (MOVE, PEA, JSR, general ALU-EA, Scc) all run
    //     the outer phase (`memind_outer_r`) and genuinely complete at
    //     its own ack -- EXCEPT CMP2/CHK2, which ALSO runs the outer
    //     phase (to resolve its own LOWER bound) but then hands off to
    //     `cmp2_run_r` for the upper bound via `memind_outer_done_r`
    //     (already closed, Task #2/Phase 259) -- excluded via
    //     `!ex_is_cmp2chk2`.
    // **New hazard signals needed for two of these sub-cases, the
    // MOVEM/PACK shape (a direct-port register write landing on the
    // EXACT SAME cycle as the trigger)**: LEA's own resolved address
    // commits via `memind_addr_wr_en` (bypassing `hazard_ex`/
    // `hazard_wb`) at the SAME condition as the inner/addr-only trigger
    // -- confirmed via direct inspection this signal's own gating
    // (`memind_inner_r && mem_ack && memind_addr_only_r && !ex_is_tas &&
    // !ex_is_movem`) is IDENTICAL to the new trigger itself.
    // MOVE-via-memind's own resolved value commits via `memind_wr_en`
    // (also bypassing the generic path) at the SAME condition as the
    // outer trigger. Both write to the same captured field,
    // `memind_dest_r` (4-bit, already `{is_an,reg}`-encoded, captured at
    // `memind_start_r`'s own transition from `dec_dest_reg`). General
    // ALU-EA's own result write is NOT among these -- confirmed
    // `memind_wr_en` explicitly excludes it (`!ex_is_mem_src`), so ALU-EA
    // writes back via the ORDINARY `wb_valid && wb_writes_reg` generic
    // path instead, already protected by the existing `hazard_ex`/
    // `hazard_wb` mechanism with no new signal needed. PEA/JSR/Scc write
    // only to memory (or change flow, already covered by
    // `!ex_redirect_pending` via `branch_taken`'s own existing JMP/JSR
    // coverage -- confirmed the comment at `ex_redirect_pending`'s own
    // declaration explicitly states it covers JMP/JSR's redirect cycle
    // itself, not just the wait beforehand), so neither needs a new
    // hazard term. CCR updates from any of these are already covered
    // generically by `hazard_ccr`. Confirmed via the Phase 264 checklist
    // item that every memind-consuming decode arm explicitly clears
    // `dec_is_mem_rd` when setting `dec_is_memind` (the shared
    // `mode110_ea_src` decode template convention) -- safe from the
    // PMOVE64-shaped regression structurally, not just by coincidence.
    logic memind_inner_final_ack;
    assign memind_inner_final_ack = memind_inner_r && mem_ack && memind_addr_only_r &&
                                    !ex_is_tas && !ex_is_movem;
    logic memind_outer_final_ack;
    assign memind_outer_final_ack = memind_outer_r && mem_ack && !ex_is_cmp2chk2;
    logic memind_addr_hazard;
    assign memind_addr_hazard = reg_hazard(memind_addr_wr_en, memind_dest_r);
    logic memind_wr_hazard;
    assign memind_wr_hazard = reg_hazard(memind_wr_en, memind_dest_r);

    // Track 3 #13 (general RMW, `mem_rmw_run_r`, wobbly-honking-cascade.md,
    // first Group C family): confirmed via direct inspection this family
    // does NOT use the bus-LOCKED RMW protocol at all -- `mem_rmw`
    // (the signal driving `biu_cycle_gen.sv`'s own continuous-AS
    // `ST_RMW_READ_*`/`ST_RMW_WRITE_*` sequence) is asserted ONLY for
    // `ex_is_tas` (`assign mem_rmw = ex_valid && ex_is_tas && ...`) --
    // general RMW ops (ASL/BSET/etc. memory forms) are a plain 2-phase
    // read-then-write FSM using two ORDINARY, non-locked bus cycles via
    // the generic `mem_req`/`mem_ack` path. This matches the plan's own
    // framing of this family as "not bus-locked the way TAS/CAS/CAS2
    // are... a reasonable bridge into bus-lock territory" -- the
    // dedicated AS-continuity/arbiter re-read the plan's own Group C
    // methodology calls for is genuinely needed starting at TAS (Task
    // #14), not here. Final beat: `mem_rmw_run_r && mem_ack` (the write
    // phase's own ack). **Confirmed SAFE from the Phase 264/PMOVE64-
    // shaped regression, the same reason as move_mm/CMPM**: this
    // family's own decode DOES set `dec_is_mem_rd=1` for its read phase,
    // but `mem_rmw_read_ack` (pre-existing, already in `ex_mem_stall`'s
    // own OR-chain) already correctly stays 1 through that read-ack
    // moment. **New hazard signal needed**: `mem_rmw_an_wr_en` (the
    // memory operand's own auto-inc/dec An update, for -(An)/(An)+
    // forms) fires on the EXACT SAME cycle as this final beat -- and
    // critically, `hazard_ex`'s own generic "An-update hazard" clause
    // EXPLICITLY EXCLUDES this family (`!ex_is_mem_rmw`, confirmed via
    // direct inspection of that clause's own condition) because RMW's
    // own An update commits via the dedicated `an_wr_en` port at
    // write-ack, not the ordinary WB timing that generic clause assumes
    // -- so there is genuinely no existing protection at all here,
    // unlike every other family in this track. `mem_rmw_hazard` supplies
    // it directly, mirroring the excluded clause's own field but at the
    // correct (write-ack) cycle. No Dn register write exists via the
    // generic `wr_en` path (confirmed -- no `mem_rmw_*_wr_en` term
    // there); the only other write is CCR (`mem_rmw_sr_wr_en`), already
    // covered by `hazard_ccr`. General RMW never traps or changes flow.
    logic mem_rmw_final_ack;
    assign mem_rmw_final_ack = ex_valid && ex_is_mem_rmw && mem_rmw_run_r && mem_ack;
    logic mem_rmw_hazard;
    assign mem_rmw_hazard = reg_hazard(mem_rmw_an_wr_en, {1'b1, ex_an_upd_reg});

    // Track 3 #14 (TAS, wobbly-honking-cascade.md, first GENUINELY
    // bus-locked family): a dedicated re-read of the exact AS-
    // continuity/`bus_lock`/arbiter mechanics, per the plan's own
    // explicit Group C methodology, confirmed the following BEFORE any
    // RTL was touched. `bus_lock` (the REAL, structural continuous-lock
    // signal `biu_arbiter.sv` uses to suppress DMA grants) is derived
    // ENTIRELY from `biu_cycle_gen.sv`'s own INTERNAL FSM state
    // (`state==ST_RMW_READ_S0/S1`, `is_rmw_write`, etc.) -- NOT from
    // `mem_rmw`/`eu_rmw` staying asserted throughout the locked
    // sequence. `mem_rmw` (this project's own EU-side dispatch signal,
    // `assign mem_rmw = ex_valid && ex_is_tas && (ex_is_mem_rd ||
    // tas_memind_pending_r) && !tas_run_r && !tas_after_write_r`) is
    // used ONLY to TRIGGER the BIU's own transition INTO the RMW state
    // sequence (`if (eu_rmw) state_nxt = ST_RMW_READ_S0`); once inside,
    // `bus_lock` is governed purely by the BIU's own state register,
    // completely independent of what the EU side's `mem_addr`/`mem_req`
    // outputs show afterward. This means a preview mechanism that only
    // ever touches those EU-side OUTPUT signals -- and only at the exact
    // cycle TAS's own write genuinely ACKS (the same edge the BIU's own
    // state machine independently reacts to for its own natural
    // state transition, mirroring the already-proven `eu_continue_ok`
    // fast path Phase 253 built for ordinary reads/writes) -- cannot
    // structurally interfere with `bus_lock`'s own drop timing or the
    // arbiter's own grant continuity. TAS's own final beat:
    // `tas_run_r && mem_ack` (mirrors the pre-existing `tas_sr_wr_en`'s
    // own exact condition). **No hazard signal needed at all** (simpler
    // than every prior family): TAS writes NO Dn/An register through
    // any port -- only the memory byte itself (bit 7 set, the write
    // phase's own result) and CCR (`tas_sr_wr_en`, already covered
    // generically by `hazard_ccr`); TAS's own genuine memory-indirect EA
    // (`tas_memind_pending_r`) resolves and hands off to `tas_run_r`
    // BEFORE this trigger, already excluded from memind's own inner
    // trigger (`!ex_is_tas` in `memind_inner_final_ack`, Task #12).
    // **Confirmed safe from the Phase 264/PMOVE64-shaped regression**:
    // TAS's own decode DOES set `dec_is_mem_rd=1` for its read phase,
    // but `tas_read_ack` (pre-existing, already in `ex_mem_stall`'s own
    // OR-chain) already covers that moment. TAS never traps or changes
    // flow (unlike CAS, it always writes back regardless of the tested
    // value -- no conditional-write trap path to exclude).
    logic tas_final_ack;
    assign tas_final_ack = ex_valid && ex_is_tas && tas_run_r && mem_ack;

    // Track 3 #15 (CAS, wobbly-honking-cascade.md): a SECOND dedicated
    // re-read of the exact AS-continuity/`bus_lock`/arbiter mechanics
    // (Group C methodology), since this project's own history
    // (`silent-copper-latch.md`'s own 5 attempts) documents CAS's own
    // bus-lock as MORE delicate than TAS's. Key structural difference
    // from TAS: CAS has a genuine, registered "bus release" gap
    // (`cas_get_du_r`, between the read and write phases) where
    // `mem_req` really drops to 0 for one cycle -- `eu_cas_hold =
    // cas_active_r` is what keeps `bus_lock` asserted through that gap
    // regardless (confirmed via direct inspection: `bus_lock`'s own
    // formula includes `eu_cas_hold` alongside `is_rmw_write`/`is_cas2`),
    // so `cas_active_r`'s own exact clear timing is THE single most
    // safety-critical signal in this whole mechanism -- and critically,
    // my own new preview trigger does NOT touch `cas_active_r`,
    // `eu_cas_hold`, or any other CAS-internal register at all; it only
    // ever reads them combinationally to decide when `mem_addr`/
    // `mem_req` (the EU's own OUTPUT toward the BIU) may show NEXT's own
    // values -- so there is no risk of it altering `cas_active_r`'s own
    // timing, only of firing at the WRONG moment relative to it.
    // CAS has TWO structurally different completion paths, confirmed by
    // direct inspection of exactly when `cas_active_r` itself clears:
    //   - MISMATCH (`cas_z_r=0`): the FSM never reaches `cas_write_r` at
    //     all -- `cas_active_r <= 1'b0` fires DIRECTLY inside the
    //     `cas_get_du_r` branch itself, on the identical condition as
    //     the pre-existing `cas_dc_wr_en` (`cas_get_du_r && !cas_z_r`).
    //   - MATCH (`cas_z_r=1`): the FSM proceeds through `cas_write_r`
    //     (the real bus write) and only clears `cas_active_r` one cycle
    //     later, at `cas_after_r` (the write's own post-ack cooldown) --
    //     NOT at the write's own `mem_ack` cycle itself.
    // `cas_final_ack` reuses these two EXACT conditions verbatim (not a
    // new derivation), so it fires on precisely the same cycle
    // `cas_active_r` itself is captured transitioning to 0 -- at that
    // moment `cas_active_r`/`eu_cas_hold` are STILL 1 (the transition
    // takes effect on the NEXT edge), so `bus_lock` is still asserted
    // and the arbiter's own sticky grant is still held THIS cycle,
    // exactly mirroring the timing relationship every other family's
    // own final-beat trigger already relies on (fires the cycle the
    // family's own "busy" flag is ABOUT TO clear, never after). Must
    // NOT fire during `cas_get_du_r && cas_z_r` (match found, but the
    // write hasn't happened yet -- CAS is genuinely NOT done) -- the
    // explicit `!cas_z_r`/`cas_after_r` split guarantees this.
    // **New hazard signal needed**: `cas_dc_wr_en` (Dc's own mismatch-
    // path load, via the SEPARATE `wr2_en`/`wr2_sel`/`wr2_data` direct
    // port -- confirmed bypassing `hazard_ex`/`hazard_wb` entirely, a
    // second direct-write port beyond the `wr_en` one every earlier
    // family in this track used) fires on the EXACT SAME condition as
    // the mismatch arm of this new trigger. `cas_hazard` protects it.
    // No An-update hazard exists: confirmed via direct inspection this
    // project's own CAS decode is scoped to `CAS Dc,Du,(An)` only (no
    // auto-inc/dec forms, no `cas_an_wr_en` signal exists anywhere).
    // MATCH's own memory write needs no hazard (writes to MEMORY, not a
    // register); CCR (`cas_sr_wr_en`) is already covered by
    // `hazard_ccr`. **Confirmed safe from the Phase 264/PMOVE64-shaped
    // regression**: CAS's own decode DOES set `dec_is_mem_rd=1` for its
    // read phase, but `cas_read_ack` (pre-existing, already in
    // `ex_mem_stall`'s own OR-chain) already covers that moment -- the
    // same "already closed before Track 3" pattern as move_mm/CMPM/
    // general RMW/TAS.
    logic cas_final_ack;
    assign cas_final_ack = (cas_get_du_r && !cas_z_r) || cas_after_r;
    logic cas_hazard;
    assign cas_hazard = reg_hazard(cas_dc_wr_en, cas_dc_reg_r);

    // Track 3 #16 (CAS2, wobbly-honking-cascade.md, the LAST family in
    // this whole track): direct inspection of CAS2's own 6-8-phase FSM
    // (rd1-ack -> rd2_r -> [get_du1_r -> wr1_r -> get_du2_r -> wr2_r] on
    // MATCH, or [dc1_wr_r -> dc2_wr_r] on MISMATCH -> after_r either way)
    // found this family is structurally SIMPLER to close than single
    // CAS, not harder, despite chaining twice as many sub-cycles: BOTH
    // completion paths funnel through the SAME unified `cas2_after_r`
    // cooldown step before `cas2_active_r` itself clears --
    // `cas2_after_r <= (cas2_wr2_r && mem_ack) || cas2_dc2_wr_r`, and
    // `cas2_active_r <= 1'b0` fires only inside the `cas2_after_r`
    // branch, for MATCH and MISMATCH alike. This differs from single
    // CAS, whose mismatch path clears `cas_active_r` immediately with NO
    // cooldown step at all. New `cas2_final_ack = cas2_after_r` --
    // fires precisely when `cas2_active_r` itself is captured
    // transitioning to 0, the same timing relationship every other
    // family's own final-beat trigger relies on.
    // **No hazard signal needed at all**, confirmed by tracing exactly
    // when CAS2's own two register writes commit relative to this
    // trigger: `cas2_dc1_wr_en`/`cas2_dc2_wr_en` (Dc1/Dc2's own
    // mismatch-path loads, via the SAME shared `wr2_en`/`wr2_sel` second
    // direct port single CAS's own `cas_dc_wr_en` uses) fire at
    // `cas2_dc1_wr_r`/`cas2_dc2_wr_r` respectively -- ONE and TWO cycles
    // BEFORE `cas2_after_r` (this new trigger), not on the same cycle --
    // both are already safely committed to the register file well before
    // the trigger ever fires (the ADDX-mem/BCD-mem shape, not the
    // MOVEM/single-CAS shape). No An-update mechanism exists for CAS2 at
    // all (confirmed -- no `cas2_an_wr_en` signal anywhere; real CAS2
    // uses plain register-indirect Rn1/Rn2 addressing only, no
    // auto-inc/dec). CCR (`cas2_sr_wr_en`) is already covered generically
    // by `hazard_ccr`. **Confirmed safe from the Phase 264/PMOVE64-
    // shaped regression**: CAS2's own decode DOES set `dec_is_mem_rd=1`
    // for its first read phase, but `cas2_rd1_ack` (pre-existing,
    // already in `ex_mem_stall`'s own OR-chain) already covers that
    // moment -- the same "already closed before Track 3" pattern every
    // prior `dec_is_mem_rd`-setting family in this track has shown.
    logic cas2_final_ack;
    assign cas2_final_ack = cas2_after_r;

    // preview_current_ready: "CURRENT is genuinely handing off the bus
    // this cycle, safe to preview NEXT" -- the ordinary read case (its
    // own `ex_mem_stall` clears the same cycle as `mem_ack`, the
    // project's own established convention), OR `movem_last`/
    // `cmp2_final_ack`/`movep_last`/`addx_mem_final_ack` (each already a
    // combinational "final beat, acking this cycle" signal built for
    // that family's own FSM termination; `ex_mem_stall` does NOT clear
    // on this same cycle for MOVEM/CMP2/MOVEP -- confirmed via direct
    // inspection of every special-FSM `_run_r`-clearing block -- so it
    // cannot be reused as the trigger there the way it is for the
    // ordinary case; ADDX/SUBX-mem's own `ex_mem_stall` contribution
    // actually DOES already clear the same cycle, per its own
    // `addx_mem_stall` formula, but a dedicated OR-term is still needed
    // since `ex_is_mem_rd` is never set for this family at all).
    //
    // `!ex_is_pmove64` (Track 3 #7): PMOVE CRP/SRP's own LOAD direction
    // sets `dec_is_mem_rd=1` (unlike MOVEM/CMP2/MOVEP/ADDX/PACK), so its
    // own phase-0 ack (BEFORE `pmove64_run_r` transitions to 1) would
    // otherwise satisfy this ordinary clause by pure coincidence --
    // found via a genuine live regression: without this exclusion,
    // `preview_ok` fired one beat early (at phase 0's ack instead of the
    // real final beat), hijacking `mem_addr` mid-FSM-handoff and causing
    // a spurious MMU Configuration Exception downstream (the trap's own
    // check read stale phase-0 `mem_rdata` instead of the genuine
    // phase-1 response). A first fix attempt added a `pmove64_first_ack`
    // term to the shared `ex_mem_stall` signal (mirroring
    // `cmp2_first_ack`'s own shape) -- reverted after it caused a
    // genuine simulation hang: `ex_mem_stall` gates the pipeline's own
    // ordinary (non-preview) dispatch timing throughout the whole
    // module, and extending it changed when `ex_valid` drops after
    // PMOVE64's own phase-0 ack broadly enough to break something
    // downstream. Excluding `ex_is_pmove64` from ONLY this trigger's own
    // clause instead is fully equivalent for preview purposes (PMOVE64
    // already has its own dedicated `pmove64_final_ack` trigger below)
    // and touches nothing else.
    // Post-Track-3 gap closure (`wobbly-honking-cascade.md`, found while
    // building the Figure 7-25 read-write-write-read timing diagram):
    // the ordinary clause above only ever fired when CURRENT was a READ
    // (`ex_is_mem_rd`) -- an ordinary WRITE as CURRENT never triggered a
    // preview of NEXT at all, regardless of what NEXT was. Track 2 Stage
    // 2.2 only ever extended what NEXT is allowed to be (a plain write);
    // it never extended CURRENT-side eligibility to writes, and no later
    // Track 3 family closed this either, since all 16 of them are
    // read-final-beat families. Confirmed empirically before fixing (a
    // throwaway write-then-write test showed zero `preview_ok`
    // engagement on either transition, despite both writes acking
    // cleanly). Fixed by mirroring the read clause exactly, with the
    // SAME two exclusions and the same justification for each,
    // re-verified fresh for the write side rather than assumed:
    //   - `!ex_is_move_reg_idx_dst`: this family's own decode (confirmed
    //     via direct inspection) never sets `dec_is_mem_rd`, so it could
    //     never have collided with the read clause above -- but it DOES
    //     set `dec_is_mem_wr`, so it newly enters scope here. Kept
    //     excluded, matching the read clause's own conservative posture
    //     (its original Track 1-era rationale, rd_c port contention, is
    //     stale post-Track-2 -- preview no longer touches rd_c at all --
    //     but excluding it costs nothing: a narrow, rare indexed-MOVE-
    //     write form, not a new gap relative to today).
    //   - `!ex_is_pmove64`: confirmed via direct decode inspection that
    //     PMOVE64's own STORE direction (`dec_pmove_to_mem`) ALSO sets
    //     `dec_is_mem_wr=1'b1` for its own phase-0 write -- the exact
    //     same shape as the original Phase 264 read-side regression,
    //     confirmed via inspection before it could ship as a live bug
    //     this time, not found the hard way again.
    // **No new hazard signal needed**: confirmed via direct inspection
    // that `hazard_ex`'s own generic An-update clause already covers
    // every ordinary write with auto-inc/dec addressing (`ex_an_upd_en
    // && !ex_is_mem_rmw`, and ordinary writes are not `ex_is_mem_rmw`),
    // asserted for the instruction's entire EX residency including the
    // exact cycle this new trigger fires -- the same "generic path
    // already protects it" shape as ADDX-mem (Track 3 #4), not a new
    // direct-port write needing its own dedicated signal. CCR is already
    // covered by `hazard_ccr` generically, as always. Every OTHER
    // special-FSM family whose own write phase sets the generic
    // `dec_is_mem_wr` (confirmed via a full survey of all 26
    // `dec_is_mem_wr=1'b1` decode sites) turned out to be an ordinary,
    // non-multi-phase instruction (MOVE/PEA/JSR/ALU-to-memory/Scc
    // variants) except PMOVE64, already excluded above; every
    // memind-consuming write-shaped family (PEA/JSR/MOVE/Scc via
    // memind) already explicitly suppresses `dec_is_mem_wr` when
    // `dec_is_memind` is set (confirmed via direct inspection, mirroring
    // the identical `dec_is_mem_rd` suppression Track 3 #12 already
    // relied on) -- safe from this regression shape structurally, not
    // just by coincidence.
    logic preview_current_ready;
    assign preview_current_ready = (ex_valid && (ex_is_mem_rd || ex_is_mem_wr) && no_special_bus_op &&
                                     mem_ack && !ex_mem_stall && !ex_is_move_reg_idx_dst &&
                                     !ex_is_pmove64) ||
                                    movem_last || cmp2_final_ack || movep_last || addx_mem_final_ack ||
                                    bf_mem_final_ack || pack_mem_final_ack || pmove64_final_ack ||
                                    cpsr_final_ack || bcds_final_ack || move_mm_final_ack ||
                                    cmpm_final_ack || memind_inner_final_ack || memind_outer_final_ack ||
                                    mem_rmw_final_ack || tas_final_ack || cas_final_ack ||
                                    cas2_final_ack;

    assign preview_ok = preview_current_ready && !ex_redirect_pending &&
                        dec_valid &&
                        // Track 2 Stage 2.2: NEXT may now be an ordinary
                        // read OR a plain register-source write (never
                        // both -- dec_is_mem_rd/dec_is_mem_wr are mutually
                        // exclusive by decode convention throughout this
                        // file).
                        ((dec_is_mem_rd && !dec_is_mem_wr) || preview_is_write) &&
                        !dec_is_moves && preview_trivial_ea &&
                        (dec_mem_rd_siz == 2'b00) &&
                        // Track 1 Stage 4 originally needed an extra
                        // `!ex_is_idx` (CURRENT) guard here, since indexed
                        // preview reused the CURRENT instruction's own
                        // rd_b port for Xn. Track 2 Stage 2.1 gave the
                        // preview mechanism its own dedicated rd_prev_a/
                        // rd_prev_b ports (never touched by anything
                        // else), so that restriction no longer applies --
                        // indexed-EA preview is now unconditional on what
                        // CURRENT is doing with its own ports.
                        !hazard_ex && !hazard_wb && !hazard_ccr && !movem_hazard && !movep_hazard &&
                        !bf_hazard && !pack_hazard && !move_mm_hazard && !cmpm_hazard &&
                        !memind_addr_hazard && !memind_wr_hazard && !mem_rmw_hazard &&
                        !cas_hazard && !need_ext;
