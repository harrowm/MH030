# MC68030 Bus Interface Unit (BIU) — Complete Specification

Derived from the architectural discussion in `output.txt`, verified against the
MC68030 User's Manual, MC68030 datasheet, comp.sys.m68k FAQ, Linux m68k kernel
source, ManualsLib MC68030 manual scans, and the MiSTer/WinUAE community reference
implementations. See Appendix A for a summary of corrections made to the source
material during verification.

---

## Section 1 — External Signal Interface

### 1.1 Output Signals

**BIU-001** — Address Bus A[31:0]
The full 32-bit address is driven on the rising edge of S0 and must be stable before
AS asserts at S2. Address must not change while AS is asserted.

**BIU-002** — Data Bus D[31:0] (bidirectional)
For writes, data is driven by S3 and held until S6. For reads, the bus is tri-stated
and data is sampled at the falling edge of S6 when DS deasserts. When the external bus
is granted to a DMA controller, all data pins must tri-state within one internal clock
cycle of BG assertion.

**BIU-003** — AS (Address Strobe, active-low)
AS asserts at S2, after address and FC are stable. It deasserts at S6. AS is used by
external memory controllers to latch the address. During burst mode, AS asserts only
on the first longword; subsequent longwords use DS alone.

**BIU-004** — DS (Data Strobe, active-low)
A single DS pin asserts at S3 and deasserts at S6. External logic uses SIZ[1:0] and
A[1:0] to determine which byte lanes are active on the 32-bit data bus. The 68030 does
not have separate LDS and UDS pins; those belong to the 68000/68010.

**BIU-005** — RW (Read/Write)
RW=1 for reads, RW=0 for writes. Driven at S0 alongside the address. During RMW
cycles (TAS, CAS, CAS2), RW transitions from 1 to 0 within the locked cycle without
releasing AS.

**BIU-006** — FC[2:0] (Function Code)
Driven at S0 alongside the address and must remain valid for the entire bus cycle.
Transitions only at cycle boundaries. During pipelined cycles, FC must change at the
exact S-state boundary between the old cycle and the new one.

| FC[2:0] | Address Space |
|---------|---------------|
| 001 | User Data Space |
| 010 | User Program Space |
| 101 | Supervisor Data Space |
| 110 | Supervisor Program Space |
| 111 | CPU Space (IACK and coprocessor cycles) |

**BIU-007** — SIZ[1:0] (Transfer Size)
Output pins that indicate the size of the current transfer request. Updated on each
sub-cycle during dynamic bus sizing to reflect the remaining byte count.

| SIZ1 | SIZ0 | Transfer |
|------|------|----------|
| 0 | 0 | Longword (32-bit) |
| 0 | 1 | Byte (8-bit) |
| 1 | 0 | Word (16-bit) |
| 1 | 1 | 3 Bytes (remaining bytes in a dynamic sizing sequence) |

**BIU-008** — ECS (External Cycle Start)
ECS asserts one half-clock before AS on every bus cycle. External address decoders use
ECS for pipelined decode — they begin decoding the address before AS so DSACK can be
returned with zero wait states.

**BIU-009** — OCS (Operand Cycle Start)
OCS asserts on the first bus cycle that is part of an operand (data) access, as
distinct from an instruction prefetch. External logic uses OCS to distinguish
instruction-fetch traffic from data-access traffic. The 68030 has no CLKOUT pin; ECS
and OCS serve the external synchronisation role.

**BIU-010** — BG (Bus Grant, output)
Asserted by the CPU to grant the bus to an external DMA controller after receiving BR.
Remains asserted until BGACK deasserts.

**BIU-011** — CBREQ (Cache Burst Request, output)
Asserted by the BIU before a burst cache linefill to signal that it wishes to use
burst mode. The external memory controller responds with CBACK to confirm capability.

**BIU-012** — RSTOUT (Reset Output, active-low)
Driven low during execution of a software RESET instruction for exactly 124 clock
cycles, resetting external peripherals. This is an output distinct from the external
RESET input pin. For an external hardware reset, RESET + HALT must be asserted
together for at least 100 ms at power-on, or at least 10 clock cycles for a warm
reset.

**BIU-145** — E-Clock Generation for VPA Cycles
The 68030 generates an E clock output at CLK/10 frequency with a fixed 60/40 duty
cycle: 6 clock cycles low followed by 4 clock cycles high per E period. This is driven
on the external E pin and is required for 6800-family peripherals that use VPA. When
VPA is asserted, the BIU must synchronise the current bus cycle to complete on an
E-clock boundary. The cycle does not terminate via DSACK; it terminates when E
transitions, at which point the CPU latches the data. The BIU must maintain an
internal 4-bit counter (0–9) that generates E regardless of whether any VPA cycle is
in progress.

### 1.2 Input and Handshake Signals

**BIU-013** — DSACK0 / DSACK1 (Data Transfer and Size Acknowledge)
Two input pins that simultaneously signal cycle completion and the port width of the
responding device. Sampled at S4.

| DSACK1 | DSACK0 | Meaning |
|--------|--------|---------|
| 0 | 0 | 32-bit port; cycle complete |
| 0 | 1 | 16-bit port; cycle complete (BIU generates additional cycles) |
| 1 | 0 | 8-bit port; cycle complete (BIU generates additional cycles) |
| 1 | 1 | Insert wait state; device not yet ready |

When the reported port width is narrower than the requested transfer, the BIU
automatically generates additional bus cycles for the remaining bytes, updating SIZ
and the address each time.

**BIU-014** — STERM (Synchronous Termination, active-low)
Sampled at S2. When asserted at S2, the bus cycle terminates synchronously at S4 with
zero wait states. Used for high-speed synchronous SRAM that can guarantee data within
a fixed number of clock cycles. Each individual bus cycle can independently be
synchronous (STERM) or asynchronous (DSACK); there is no global mode selector.

**BIU-015** — BERR (Bus Error, active-low)
Asserted by external hardware to signal a bus fault. BERR alone initiates bus error
exception processing and generates one of the long exception stack frames (Format $9,
$A, or $B depending on context). See BIU-148 for the special case of BERR and HALT
asserted simultaneously.

**BIU-148** — BERR + HALT Simultaneous: Bus Cycle Retry
When BERR and HALT are asserted simultaneously (both sampled active in the same clock
cycle), the CPU does not generate a bus error exception. Instead it retries the failing
bus cycle: the BIU re-executes the identical cycle with the same address, FC[2:0],
SIZ[1:0], RW, and data (for writes). This mechanism is used by ECC memory controllers
that assert BERR briefly while performing single-bit correction, and by systems with
slow peripherals that miss the DSACK window. The BIU must distinguish simultaneous
BERR+HALT (retry) from BERR alone (exception) and from HALT alone (halt-and-wait) by
sampling both pins in the same synchronizer output stage and comparing in a single
combinational priority check before the S-state machine transitions out of S4/S5.

**BIU-016** — BR (Bus Request, active-low)
Asserted by an external DMA controller to request the bus. The BIU completes the
current bus cycle (or full RMW/burst sequence) before asserting BG.

**BIU-017** — BGACK (Bus Grant Acknowledge, active-low)
Asserted by the DMA controller to confirm it has taken the bus. The BIU keeps BG
asserted until BGACK deasserts, then re-enables its bus outputs within one clock cycle.

**BIU-018** — CBACK (Cache Burst Acknowledge, active-low)
Asserted by the external memory controller to confirm it can supply data in burst mode.
The BIU samples CBACK before driving DS for each subsequent longword of a burst. If
CBACK is not asserted, the burst terminates and individual cycles are used for the
remaining data.

**BIU-019** — AVEC (Autovector Enable, active-low)
During an IACK cycle, AVEC is asserted by external logic to signal that the CPU should
generate the interrupt vector internally (interrupt level + 24) rather than reading a
vector from the data bus.

**BIU-020** — VPA (Valid Peripheral Address, active-low)
When VPA is asserted during a bus cycle, the BIU synchronises the cycle to the
internally generated E clock (BIU-145) and generates a 6800-compatible bus cycle for
legacy peripherals. VPA is not the autovector mechanism; AVEC is.

**BIU-021** — IPL[2:0] (Interrupt Priority Level, active-low)
Three-bit encoded interrupt level sampled at the end of each instruction. IPL=111
(all low = NMI level 7) is non-maskable. The BIU reports the sampled level to the EU;
the EU accepts the interrupt if level > I-mask in SR.

**BIU-022** — HALT (active-low)
When HALT is asserted alone, the BIU completes the current bus cycle, then tri-states
all outputs and holds. When HALT is asserted simultaneously with BERR, the BIU retries
the failing bus cycle (BIU-148). When HALT deasserts, the BIU resumes after the
minimum hold time specified in the AC timing tables.

### 1.3 Asynchronous Input Synchronization

**BIU-023**
All asynchronous inputs — DSACK0, DSACK1, BERR, BR, IPL[2:0], HALT, AVEC, STERM,
CBACK, VPA — must pass through two-stage flip-flop synchronizers before being consumed
by any BIU logic. This is mandatory on FPGAs to prevent metastability. Clock the first
stage on posedge clk_4x and the second stage one cycle later.

---

## Section 2 — S-State Machine and Bus Cycle Timing

**BIU-024** — Standard Read Cycle S-State Sequence
A standard asynchronous read cycle uses 8 states S0–S7, spanning a minimum of 4
external clock cycles.

| S-State | Action |
|---------|--------|
| S0 | Address, FC[2:0], SIZ[1:0], RW driven; ECS asserts |
| S1 | Address, FC, SIZ stable; OCS asserts on operand cycles |
| S2 | AS asserts; STERM sampled; data bus goes high-Z |
| S3 | DS asserts |
| S4 | DSACK sampled (first opportunity); if DSACK=11, loop to S5 |
| S5 | Wait state; DSACK sampled again |
| S6 | Data sampled from bus; AS and DS deassert |
| S7 | Bus cleanup; bus_ack issued to pipeline |

**BIU-025** — Standard Write Cycle
Same S0–S7 sequence. RW is driven low at S0. Data is driven onto the bus by S3 and
held through S7. The data bus is never tri-stated during a write cycle.

**BIU-026** — Wait State Insertion
If DSACK1=1 and DSACK0=1 at the S4 sample point, the BIU inserts one wait state
(holds S4/S5 for one clock) and resamples. This repeats until DSACK signals completion
or BERR asserts. The wait-state count must be reported to the internal pipeline for
cycle-accurate instruction timing.

**BIU-027** — Pipelined / Overlapped Bus Cycles
The 68030 supports bus pipelining: the address phase of bus cycle N+1 (driving A,
FC, SIZ) can be asserted while bus cycle N is still in its data phase waiting for
DSACK. The BIU must implement this overlap to match real 68030 execution speed.

**BIU-028** — Setup and Hold Time Enforcement
With a 4× internal clock (BIU-110), the BIU must enforce:
- Address, FC, SIZ valid at least one internal clock phase before AS asserts (S2)
- AS stable for at least one internal clock phase before DS asserts (S3)
- Data valid for write cycles by S3 at the latest
- DSACK0/DSACK1 stable before the S4 sample point

**BIU-029** — Back-to-Back Inter-Cycle Gap
Between consecutive non-pipelined bus cycles there may be a 0 or 1 clock-cycle gap
where the address bus floats, depending on pipeline state. RMW and burst cycles have
zero gap between their constituent sub-cycles.

**BIU-030** — Data Sample Timing (Read)
The BIU samples data at the falling edge of the S6 clock when DS deasserts. External
memory must drive valid data before this point, satisfying the setup time in the
MC68030 AC timing tables.

**BIU-031** — Data Drive Timing (Write)
The BIU drives data by S3 and holds it through S7. The external device captures data
on the rising edge of the clock coincident with DSACK assertion.

---

## Section 3 — Bus Cycle Type Catalogue

### 3.1 Normal Read and Write

**BIU-032**
Normal read and write cycles follow the S0–S7 sequence defined in BIU-024 and
BIU-025. Any transfer size (byte, word, longword) uses the same S-state sequence;
byte-lane selection is conveyed by SIZ[1:0] and A[1:0] for external logic.

### 3.2 Dynamic Bus Sizing

**BIU-033** — Automatic Multi-Cycle Sizing
When DSACK indicates a port narrower than the requested transfer, the BIU automatically
continues the transfer across multiple bus cycles:
- Longword to 16-bit port: 2 cycles
- Longword to 8-bit port: 4 cycles
- Word to 8-bit port: 2 cycles

The BIU tracks remaining bytes internally and adjusts SIZ and address for each cycle.
The EU pipeline stalls with a single bus_req until the final bus_ack.

**BIU-146** — Dynamic Bus Sizing State Machine
The BIU must implement a dedicated sizing FSM for transfers to narrow ports. The FSM
proceeds as follows:

*Longword (SIZ=00) to a 16-bit port (DSACK=01):*
1. Cycle 1: Drive A[31:0], SIZ=00. Receive D[31:16]. DSACK=01 signals 16-bit
   completion. Latch upper 16 bits. Increment address by 2.
2. Cycle 2: Drive A+2, SIZ=10 (2 bytes remaining). Receive D[31:16]. Merge lower
   16 bits. Transfer complete.

*Longword (SIZ=00) to an 8-bit port (DSACK=10):*
1. Cycle 1: SIZ=00. Latch D[31:24]. Address+1. SIZ→11 (3 remaining).
2. Cycle 2: SIZ=11. Latch D[31:24]. Address+1. SIZ→10 (2 remaining).
3. Cycle 3: SIZ=10. Latch D[31:24]. Address+1. SIZ→01 (1 remaining).
4. Cycle 4: SIZ=01. Latch D[31:24]. Transfer complete.

SIZ[1:0] on each subsequent cycle reflects the remaining byte count using the encoding
in BIU-007. The internal data assembly register shifts received bytes into the correct
lane positions.

### 3.3 Unaligned Access Splitting

**BIU-034**
If the EU requests a word or longword read from a non-aligned address, the BIU splits
the access into two or more bus cycles, adjusting address and SIZ for each. The
pipeline stalls until all sub-cycles complete.

> Address Error: If the processor is configured to require alignment, an Address Error
> exception is generated before any bus cycle starts rather than splitting the access.

### 3.4 Read-Modify-Write (RMW) Cycles

**BIU-035** — RMW Atomic Lock
For TAS, CAS, and CAS2, the BIU executes a read phase and a write phase back-to-back
without releasing AS or granting the bus to DMA between them. RW transitions from 1 to
0 within the locked sequence.

**BIU-036** — CAS2 Dual-Address Atomic Lock
CAS2 performs an atomic compare-and-swap on two separate memory locations. The BIU
must lock the bus across all four constituent cycles (read location 1, read location 2,
conditional write location 1, conditional write location 2) without any bus release.
This is the most complex bus cycle in the 68030 instruction set.

**BIU-037** — DMA Deferral During RMW / Burst
If BR asserts during any locked sequence (RMW, CAS2, or burst), the BIU must complete
the entire atomic sequence before asserting BG.

### 3.5 Burst Mode

**BIU-038** — Burst Read Protocol
A cache linefill burst transfers 16 bytes (4 longwords):
1. BIU asserts CBREQ to request burst mode
2. External memory controller asserts CBACK to confirm capability
3. BIU asserts AS + DS for the first longword (SIZ=00, address = line base)
4. For longwords 2, 3, 4: BIU asserts DS only; AS remains deasserted; address
   increments by 4 bytes after DSACK for each longword

Burst mode is read-only; there is no burst write mode on the 68030.

**BIU-039** — Burst Address Increment Timing
The address increments after each longword's DSACK is asserted and before DS asserts
for the next longword. The exact timing within the S-state sequence must match the
timing diagrams in Chapter 5 of the MC68030 User Manual.

**BIU-040** — Burst Wait States
If DSACK is not asserted during a burst longword, the BIU inserts wait states at the
inter-longword boundary (not mid-longword). CBACK must remain asserted between
longwords; if the memory controller deasserts CBACK mid-burst, the burst terminates
and the remaining bytes are fetched with individual cycles.

**BIU-147** — CBACK Sampling Window Within Burst
CBACK must be asserted and stable before DS asserts for each subsequent burst longword.
CBACK is sampled at S2 of each longword's sub-cycle, the same phase as STERM. If
CBACK is not asserted by S2 of a given longword, the BIU must:
1. Complete the current longword normally (wait for DSACK)
2. Deassert CBREQ and terminate the burst after that longword
3. Issue remaining cache-line longwords as individual bus cycles with AS asserting
   for each

**BIU-041** — Burst Abort on BERR
If BERR asserts during a burst, the BIU aborts the entire burst, captures the fault
data, and initiates bus error exception processing. The cache line being filled must
not be marked valid.

**BIU-042** — Burst Width Scaling
Burst behaviour scales with the DSACK-reported port width:
- 32-bit port: 4 bus cycles × 32-bit = 16 bytes
- 16-bit port: 8 bus cycles × 16-bit = 16 bytes
- 8-bit port: 16 bus cycles × 8-bit = 16 bytes

### 3.6 Interrupt Acknowledge (IACK)

**BIU-043** — IACK Cycle Protocol
When an interrupt is accepted, the BIU executes an IACK cycle. FC[2:0] is set to 111
(CPU Space). Both AS and DS assert as in a normal read cycle. The interrupt controller
drives the 8-bit vector number on D[7:0] and asserts DSACK, or asserts AVEC for an
autovectored interrupt.

**BIU-044** — IACK Function Code
FC[2:0] = 111 (CPU Space) during all IACK cycles.

**BIU-045** — IACK Address Bus Encoding
During IACK the address bus carries a CPU Space access address:
- A1–A3: interrupt level being acknowledged (binary value of IPL2–IPL0)
- A4–A15: all driven high
- A16–A19: 1111 (identifies this CPU Space cycle as Interrupt Acknowledge)
- A20–A31: all driven high

Example: acknowledging level 5 → A1=1, A2=0, A3=1, A4–A31 all 1s.

**BIU-046** — Autovector (AVEC) During IACK
If AVEC is asserted instead of DSACK during an IACK cycle, the CPU ignores D[7:0] and
generates the vector internally as (interrupt level + 24). No data is latched from
the bus.

**BIU-047** — Spurious Interrupt
If neither DSACK, AVEC, nor BERR is asserted during an IACK cycle, the BIU internally
generates vector $18 (decimal 24) — the spurious interrupt exception.

**BIU-048** — Interrupt Level Sampling Point
IPL[2:0] is sampled at the end of each instruction, synchronised to the clock. The
latched level is compared to the I-mask in SR. If level > I-mask (or level = 7, NMI),
the IACK cycle is initiated after the current instruction completes.

### 3.7 Synchronous Termination (STERM)

**BIU-049** — STERM Protocol
STERM is sampled at S2. When asserted at S2, the bus cycle terminates at S4 with zero
wait states and no DSACK sampling. Used for high-speed synchronous SRAM.

**BIU-150** — STERM and DSACK Simultaneous Assertion
If both STERM and DSACK are asserted at the S2 sample point, STERM takes precedence
and the cycle terminates synchronously. If STERM arrives after S2 (too late for
synchronous termination), the BIU ignores the late STERM and continues with
asynchronous termination via DSACK. Late STERM must never shorten a cycle that has
already advanced past S2, to prevent race conditions from board propagation delay.

**BIU-050** — Write Cycle in Synchronous Mode
In synchronous mode (STERM), data must be driven by S2 and the cycle completes at S4.

### 3.8 Reset and Initialization

**BIU-051** — Power-On Reset Sequence
At power-on:
1. RESET + HALT must both be asserted together for at least 100 ms
2. All BIU output pins are tri-stated during reset assertion
3. On reset release, the BIU waits for the internal clock to stabilize
4. No bus width configuration is sampled at reset — bus width is discovered
   dynamically via DSACK on the first bus cycle
5. The BIU then executes the SSP and PC fetches described in BIU-052

**BIU-052** — Initial SSP and PC Fetch
On reset release the BIU generates two read bus cycles:
- Address $00000000, FC=110 (Supervisor Program Space) → loads SSP
- Address $00000004, FC=110 (Supervisor Program Space) → loads PC

Instruction execution begins at the fetched PC.

**BIU-053** — BERR During Initial Fetch
If BERR asserts during either the SSP or PC fetch, the processor enters a catastrophic
double-fault halt. Only an external RESET can recover. The BIU drives HALT low to
signal the halt condition.

### 3.9 Instruction-Specific Bus Cycles

**BIU-054** — MOVEP (Move Peripheral)
MOVEP transfers a data register to/from peripheral memory in a byte-interleaved
pattern:
- MOVEP.L D0,(d16,A0): four individual byte bus cycles to addresses base, base+2,
  base+4, base+6 — each byte is a separate DS assertion
- MOVEP.W D0,(d16,A0): two byte cycles to base and base+2

All bytes go to/from the same half of the data bus (high or low), determined by
whether the base address is even or odd.

**BIU-055** — MOVEM (Move Multiple Registers)
MOVEM generates one longword bus cycle per register in the register mask. Cycles are
contiguous with no gaps and no CBREQ burst handshake. Cycle count equals
popcount(register_mask).

**BIU-057** — CAS2 (Compare and Swap, Dual Operand)
CAS2 atomically tests and conditionally updates two memory locations. The bus is locked
across all four constituent sub-cycles (BIU-036). This is the most complex bus cycle
in the 68030 instruction set and requires dedicated FSM states in the BIU.

**BIU-058** — CPUSH / CINVA / CINVL (Cache Maintenance)
Since the D-cache is write-through, there is no modified data to write back. Cache
maintenance instructions operate as follows:
- CPUSH: invalidates specified cache lines (no write-back bus cycles needed)
- CINVA: invalidates all I-cache and D-cache entries (no external bus cycles)
- CINVL: invalidates a single cache line; the CAAR register holds the target address

**BIU-059** — PFLUSH / PFLUSHA Family (MMU TLB Flush)
PFLUSH flushes TLB entries matching address/FC criteria. PFLUSHA flushes all TLB
entries. These are internal MMU operations that may generate write bus cycles to
update Accessed/Modified bits in page table entries before invalidating TLB entries.

**BIU-060** — PTEST (MMU Probe)
PTEST performs a software-controlled TLB probe for a given address and access type.
The BIU may generate read bus cycles if the TLB misses and a table walk is required.
Results are written to the MMUSR.

**BIU-061** — PLOAD / PVALID / PFREE
- PLOAD: explicitly loads a TLB entry (generates up to 3 read bus cycles for the walk)
- PVALID: checks TLB validity against current page tables (may generate read cycles)
- PFREE: invalidates a single TLB entry; may generate write cycles for M/U bit updates

**BIU-062** — STOP Instruction
STOP loads an immediate value into SR and halts instruction execution. The BIU enters
a low-activity state and ceases instruction prefetch. Execution resumes when an
unmasked interrupt is presented, a trace exception fires, or external RESET is
asserted.

**BIU-063** — RESET Instruction
RESET asserts RSTOUT for exactly 124 clock cycles to reset external peripherals (see
BIU-012). No other bus cycles occur during this time. In user mode, RESET is a
privileged instruction that generates a Privilege Violation exception.

**BIU-064** — RTE (Return from Exception)
RTE reads the exception stack frame from the supervisor stack. The BIU generates read
bus cycles for the format/vector offset word and all additional words. The total bus
cycles depend on the frame type (4 to 46 words — see Section 7).

**BIU-065** — CHK / CHK2
If a memory addressing mode is used, CHK reads bounds from memory (one or two read bus
cycles), then the EU performs the comparison. If out-of-bounds, the CHK exception is
generated after the memory reads complete.

**BIU-066** — LINK / UNLK
LINK writes the old frame pointer to the stack (one 32-bit write bus cycle) then
updates SP. UNLK reads the old frame pointer from the stack (one 32-bit read bus
cycle) then updates SP.

**BIU-067** — A-Line and F-Line Trap Vector Fetch
A-Line ($Axxx) and F-Line ($Fxxx) opcodes generate trap exceptions. The BIU fetches
the exception vector from the vector table using FC=110 (Supervisor Program Space).

**BIU-068** — Division Overflow / Divide-by-Zero
If DIVS or DIVU overflows or divides by zero, the exception fires after the operand
fetch bus cycles complete. No additional bus cycles are generated for exception
detection itself.

**BIU-069** — Privilege Violation
Privilege checks occur during instruction decode. For most privileged instructions the
exception fires before any bus cycles for that instruction are generated.

**BIU-070** — Trace Exception
When the T bit in SR is set, the BIU executes one instruction's bus cycles normally,
then generates a Trace exception before the next instruction begins. The Trace
exception uses a Format $2 stack frame.

---

## Section 4 — Byte Lane and Data Bus Routing

**BIU-071** — Single DS Pin
The 68030 asserts a single DS pin for all transfer sizes. Byte lane selection for
sub-longword transfers is the responsibility of external board logic, which examines
SIZ[1:0] and A[1:0] to generate byte enables for the memory array. The BIU must
output correct SIZ and A values for all transfer sizes and dynamic bus sizing
sub-cycles.

**BIU-072** — Internal Data Alignment
The 68030 internally aligns data from the 32-bit D[31:0] bus to the correct byte
position in the destination register or write buffer, based on SIZ[1:0] and A[1:0].
For an 8-bit port, the BIU must implement internal barrel-shift / alignment logic to
place received bytes in the correct lane positions within the assembly register.

---

## Section 5 — Cache Controller Interface

### 5.1 Cache Organization

**BIU-073** — I-Cache and D-Cache Specification
Both caches have identical organization:
- Size: 256 bytes each
- Organization: direct-mapped
- Line size: 16 bytes (4 longwords per line)
- Number of lines: 16
- Tag: physical address bits [31:8] (24-bit tag)
- Index: address bits [7:4] (4-bit index selects one of 16 lines)
- Word offset within line: address bits [3:2]

**BIU-074** — I-Cache Allocation Policy
On I-cache miss: the BIU allocates a new cache line and fills it with a 16-byte burst
read (4 longword cycles using CBREQ/CBACK). The fetched line replaces the existing
direct-mapped entry for that index.

**BIU-075** — D-Cache Write-Through Policy
The D-cache is write-through only. Every store instruction generates an external write
bus cycle simultaneously with the cache update. There is no write-back and no dirty
bit.

**BIU-076** — D-Cache Allocation Policy
On D-cache read miss: the BIU allocates a new cache line and fetches the required
longword (a single bus cycle, not burst). On D-cache write miss with WA=0 (CACR bit
13 clear, the default): no cache line is allocated; only external memory is updated.
With WA=1: a new cache line is allocated on write miss (see BIU-153).

**BIU-153** — Write-Allocate Bus Cycle Sequence (CACR.WA=1)
When CACR bit 13 (WA) is set and a D-cache write miss occurs, the BIU must execute
this sequence before unblocking the EU:
1. Burst read phase: issue a 16-byte burst read to fill the cache line at the target
   address (CBREQ, 4 longword cycles), populating the D-cache line.
2. Write phase: execute a normal write bus cycle updating both external memory and
   the now-populated cache line.
3. Signal bus_ack to the EU. The store is complete.

The cache line is not marked valid until both the burst read and write complete. If
BERR asserts during the burst-read phase, the BIU must abort the burst, not allocate
the cache line, still execute the external write cycle (write-through must always reach
memory), and then signal the BERR exception.

**BIU-077** — Cache Tag Comparison
A cache hit occurs when address[31:8] matches the stored tag for the indexed line and
the valid bit is set. On mismatch or invalid bit, the access is a miss.

### 5.2 CACR Register

**BIU-078** — Cache Control Register (CACR) Bit Layout
CACR is a 32-bit register. Bits 15–31 are reserved. The I-cache fields are agreed
across all sources; the D-cache field positions differ by one bit between the User
Manual register diagram (ManualsLib p.144) and at least one secondary source. The
layout below follows the User Manual diagram, which is the more authoritative source.
Verify against the physical manual before committing D-cache bit positions to Verilog.

| Bit | Name | Function |
|-----|------|----------|
| 0 | EI | Enable Instruction Cache |
| 1 | FI | Freeze Instruction Cache (inhibit replacement on miss) |
| 2 | CEI | Clear Entry in I-Cache (clears entry at address in CAAR) |
| 3 | CI | Clear Instruction Cache (clears all 16 I-cache lines) |
| 4 | IBE | Instruction Burst Enable |
| 5–8 | — | Reserved |
| 9 | ED | Enable Data Cache |
| 10 | FD | Freeze Data Cache |
| 11 | CED | Clear Entry in D-Cache (clears entry at address in CAAR) |
| 12 | CD | Clear Data Cache (clears all 16 D-cache lines) |
| 13 | DBE | Data Burst Enable |
| 14 | WA | Write Allocate (allocate D-cache line on write miss when set) |
| 15–31 | — | Reserved |

> **Implementation note:** one secondary source (huininga.nl) places ED at bit 8,
> shifting all D-cache fields down by one (ED=8…WA=13). If behaviour is unexpected
> during cache testing, try the alternative layout.

---

## Section 6 — MMU Interface

**BIU-079** — 3-Level Page Table Walk
The 68030 MMU uses a software-configurable 3-level hierarchical page table:
Root → Pointer → Page. The bit-field widths at each level are defined by the
Translation Control (TC) register. A TLB miss triggers up to 3 read bus cycles.

**BIU-154** — ATC (Address Translation Cache) Organisation
The 68030's internal TLB is called the ATC (Address Translation Cache):
- Entries: 22, fully associative
- Tag: logical address + FC[2:0] (both are part of the lookup key)
- Replacement policy: pseudo-LRU
- Hit penalty: 0 additional bus cycles — the ATC supplies the physical address before
  the bus cycle begins; translation is transparent to cycle timing
- Miss penalty: the MMU immediately hijacks the bus (BIU-082) and executes up to 3
  read cycles (one per table level), plus any DSACK wait states
- Entry contents: physical page address, protection bits, U (Accessed) bit, M
  (Modified) bit, CI (Cache Inhibit) flag

When the CI flag is set in an ATC entry (derived from the page descriptor), the BIU
must not allocate a cache line for accesses to that page — all accesses go directly to
external memory even when the cache is enabled. This is used for memory-mapped I/O.

**BIU-080** — TT0 and TT1 Transparent Translation Registers
TT0 and TT1 allow address ranges to bypass MMU translation entirely. When an access
address matches the TT register criteria (logical address base + mask, optionally
gated by FC), the BIU generates a normal bus cycle with the FC specified in the TT
register — no TLB lookup or table walk occurs.

**BIU-081** — CRP and SRP Root Pointers
- CRP (Current Root Pointer): base address of the user-mode page table root
- SRP (Supervisor Root Pointer): used for supervisor translations when TC.SRP=1

The 68030 integrated MMU has CRP and SRP only. The DRP (Default Root Pointer) belongs
to the external 68851 PMMU coprocessor and is not present in the 68030.

**BIU-082** — MMU Bus Hijack for Table Walk
When a TLB miss occurs, the MMU asserts the highest-priority request on the internal
bus arbiter (above EU and IFU). The EU pipeline stalls. The MMU drives the bus for up
to 3 read cycles (one per table level). After the walk completes, the TLB is loaded
and the original access proceeds.

**BIU-083** — Table Walk Bus Cycle Details
Walk cycle sequence (assuming a 3-level TC configuration):

| Level | Address | FC |
|-------|---------|-----|
| Root | CRP.base + (VA[tia] × entry_size) | Supervisor Data (101) |
| Pointer | root_entry.base + (VA[tib] × entry_size) | Supervisor Data (101) |
| Page | pointer_entry.base + (VA[tic] × entry_size) | Supervisor Data (101) |

Index field widths (tia, tib, tic) are defined by TC[TIA], TC[TIB], TC[TIC].

**BIU-084** — Wait States During Table Walk
Each walk read cycle can receive DSACK wait states exactly like any other read cycle.
The MMU state machine tracks which table level is active when a wait state occurs.

**BIU-085** — BERR During Table Walk
If BERR asserts during any table walk read cycle, the BIU aborts the walk, captures
the fault address and table level, and generates an MMU exception (Format $9 for a
short bus fault or Format $B for a long bus fault).

**BIU-086** — Accessed / Modified Bit Updates
When a page is accessed for the first time, the MMU sets the Accessed (U) bit in the
page table entry via a write bus cycle to the entry in physical memory. When a page is
written, the MMU sets the Modified (M) bit in the same way. Both write cycles use
FC=101 (Supervisor Data Space).

**BIU-087** — MMUSR (MMU Status Register)

| Bit | Name | Meaning |
|-----|------|---------|
| 13 | T | Translation Fault |
| 12 | WP | Write Protect violation |
| 11 | I | Invalid descriptor |
| 10 | M | Modified bit (current state of page M bit) |
| 9 | 0 | Reserved |
| 8 | U | Accessed bit (current state of page U bit) |
| 7 | S | Supervisor violation |
| 6–3 | Level | Table level at which fault or hit occurred |
| 2 | ATC | ATC hit indicator |
| 1–0 | N | Number of levels searched |

MMUSR is updated during PTEST and after every table walk.

**BIU-088** — TLB Management Instructions
- PLOAD: explicitly loads a TLB entry (generates up to 3 read bus cycles for the walk)
- PVALID: checks TLB validity against current page tables (may generate read cycles)
- PFREE: invalidates a single TLB entry; may generate write cycles for U/M bit updates

**BIU-152** — Instruction Re-execution After MMU Fault Recovery
When the OS resolves an MMU access fault and re-starts the faulting instruction via
RTE from a Format $B exception frame:
1. The BIU must re-drive the original failing bus cycle (same address, FC, SIZ, RW,
   and data for writes).
2. For Format $B frames (fault during a data cycle after instruction fetch cycles had
   already completed): the BIU re-executes only the faulting data cycle, not the
   instruction fetch cycles that preceded it. The internal pipeline state, prefetch
   queue contents, and already-fetched instruction words are restored from the
   Format $B frame before the re-drive.
3. For Format $9 frames (fault during the instruction's first bus cycle): the BIU
   re-executes from the beginning of the instruction.
4. If the re-driven cycle also faults, a double bus fault occurs and the processor
   halts (BIU-094).

---

## Section 7 — Exception Frame Generation

**BIU-089** — All Stack Frame Formats
The BIU must supply the EU with all data required to push the correct frame format.
The format is encoded in the high nibble of the format/vector offset word.

| Format | Total Size | Trigger |
|--------|-----------|---------|
| $0 | 4 words | Interrupts, TRAP, illegal instruction, privilege violation, most exceptions |
| $2 | 6 words | CHK, CHK2, TRAPV |
| $3 | 8 words | Address Error |
| $4 | 8 words | FPU post-instruction exception |
| $8 | 29 words | FPU pre-instruction exception |
| $9 | 12 words | Short bus fault (MMU fault during instruction) |
| $A | 16 words | Medium bus fault (bus error during instruction cycle) |
| $B | 46 words | Long bus fault (bus error during data cycle) |

**BIU-090** — Fault Data Capture
At the moment of any bus error or MMU fault, the BIU must latch and hold:
- Fault address A[31:0]
- Fault data D[31:0] (or partial data for reads)
- FC[2:0] at the time of fault
- RW (read=1, write=0)
- SIZ[1:0] at the time of fault
- Current S-state and cycle type
- Whether the faulted cycle was pipelined (determines Format $A vs $B)

These values populate the long exception stack frames ($9, $A, $B).

**BIU-091** — Synchronous vs Asynchronous Fault Classification
- Synchronous fault: BERR asserted during the current instruction's own bus cycle →
  Format $9 or $A stack frame
- Asynchronous fault: BERR asserted during a pipelined cycle initiated for a prior
  instruction → Format $B stack frame

The BIU must track whether any active cycle is pipelined to make this classification.

**BIU-092** — Prefetch Queue Capture for Exception Frames
When an exception occurs, the current contents of the instruction prefetch queue (the
"instruction input buffer" — words already fetched but not yet decoded) must be
captured. Formats $A and $B include the instruction input buffer in the stack frame.

**BIU-093** — Bus Cycle Abort
The BIU must be able to abort a bus cycle mid-flight upon BERR assertion or MMU access
violation during the address phase. This requires tri-stating the bus and transitioning
immediately to the exception processing path.

**BIU-094** — Double Bus Fault → Halt
If a second bus error occurs during exception processing (while building a stack frame
for the first fault), the processor halts immediately. HALT is driven low to signal the
catastrophic state. Only an external RESET can restart.

**BIU-095** — Multiple Simultaneous Exceptions
When multiple exceptions occur simultaneously, the 68030 processes them in priority
order: reset > address error > bus error > trace > interrupt > illegal instruction /
privilege violation > instruction traps. The BIU services the highest-priority
exception first.

**BIU-096** — Pipeline Flush on Exception
When an exception is taken, the instruction pipeline must be flushed. The BIU reports
the drain cycle count to the EU so it can account for these cycles in timing-critical
code.

---

## Section 8 — Bus Arbitration and Internal Priority

**BIU-097** — Internal Bus Priority Scheme
When IFU, EU, and MMU simultaneously request the external bus:

| Priority | Requester | Reason |
|----------|-----------|--------|
| 1 (highest) | MMU table walk | Must complete to resolve address translation |
| 2 | EU data access | Instruction stalled waiting for data |
| 3 | IFU prefetch | Prefetch queue may have slack |
| 4 (lowest) | Background prefetch | Only when bus otherwise idle |

**BIU-098** — IFU / EU / MMU Handshake
Each internal unit asserts bus_req. The BIU grants via bus_ack. Requests from
lower-priority units are queued. The pipeline is not stalled unless the required data
is strictly needed for the next pipeline stage.

**BIU-099** — Prefetch Abort on Branch / Exception
When a branch target or exception vector is computed, the BIU immediately aborts any
in-flight instruction prefetch for the old PC and begins fetching from the new target
within 1–2 internal clock cycles of the branch being resolved.

**BIU-100** — Pipeline Bubbles on DMA Grant
When the bus is granted to an external DMA controller (BG asserted / BGACK confirmed),
the BIU inserts pipeline bubbles equal to the number of cycles the bus was unavailable
and reports this count to the EU.

**BIU-101** — Control Signal Conflict Resolution

| Conflict | Resolution |
|----------|------------|
| HALT + BR | HALT takes precedence; bus tri-stated |
| BERR + DSACK | BERR takes precedence |
| AVEC + DSACK | AVEC wins during IACK cycles; DSACK otherwise |
| BR + BERR | BERR takes precedence; error handled before bus grant |
| BERR + HALT (simultaneous) | Bus cycle retry (BIU-148) |

---

## Section 9 — FPU Interface (68881 / 68882)

**BIU-102** — FPU Coprocessor Bus Cycles
The 68030 communicates with the 68881/68882 FPU via the MC68000 coprocessor interface
protocol. F-Line opcodes ($Fxxx) cause the BIU to generate CPU Space cycles (FC=111)
with specific address encodings identifying the coprocessor ID and the command type.

**BIU-151** — Coprocessor CPU Space Address Encoding
All coprocessor bus cycles use FC=111 (CPU Space). The CPU Space cycle type is encoded
in A16–A19:

| A19–A16 | CPU Space Type |
|---------|----------------|
| 0000 | Coprocessor interface |
| 0001 | Module operations |
| 1111 | Interrupt Acknowledge |

For coprocessor interface cycles (A19–A16 = 0000):

| Bits | Field | Meaning |
|------|-------|---------|
| A13–A15 | DR[2:0] | Operation type (response, control, save, restore, operand…) |
| A9–A11 | CID[2:0] | Coprocessor ID (68881/68882 FPU = 001) |
| A0–A8 | — | Driven high |

The BIU must generate the correct address encoding for each phase of the coprocessor
protocol: General Command, Condition Evaluate, Operand Transfer, Save State, and
Restore State. Each phase has a distinct DR[2:0] encoding and may generate one or more
bus cycles.

**BIU-103** — FPU Exception Stack Frames
FPU exceptions require Format $4 (FPU post-instruction, 8 words) or Format $8
(FPU pre-instruction, 29 words) stack frames. The BIU must supply the EU with FPU
internal state, the instruction PC, and the F-Line opcode to populate these frames.

---

## Section 10 — Special Instruction Timing

**BIU-104** — MULS / MULU Variable Timing
MULU (16×16 unsigned) timing = 38 + 2n clock cycles, where n = the number of 1-bits
in the 16-bit source operand. Minimum: 38 cycles (source = 0). Maximum: approximately
70 cycles (source = $FFFF). MULS timing depends on the number of 01/10 bit-pair
transitions in a 17-bit sign-extended representation of the source. The EU handles the
variable cycle count internally; no additional bus cycles are generated during
multiplication.

**BIU-105** — DIVS / DIVU Variable Timing
Division timing varies with the magnitudes of dividend and divisor. Exact cycle counts
are in the Instruction Execution Times table of the MC68030 User Manual. No additional
bus cycles are generated during division.

**BIU-106** — Shift / Rotate Variable Timing
ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR: timing increases by 2 clock cycles per bit
position shifted.

**BIU-107** — Division Overflow
If DIVS or DIVU results in overflow or divide-by-zero, the exception fires after the
operand-fetch bus cycles complete. No extra bus cycles are generated for exception
detection.

---

## Section 11 — Pipeline and Addressing Modes

**BIU-108** — Addressing Mode Bus Cycle Count

| Mode | Bus Cycles for EA |
|------|------------------|
| Register direct | 0 |
| Address register indirect | 1 |
| Address indirect + displacement | 1 (displacement calculation is internal) |
| Address indirect + index | 1 (complex EA; may add internal stall cycles) |
| Absolute short | 1 |
| Absolute long | 1 |
| PC-relative | 1 |
| Immediate (in opcode stream) | 0–2 (included in instruction prefetch) |

**BIU-109** — Pipeline Stall Cycles

| Hazard | BIU Action |
|--------|-----------|
| Data hazard (EU waiting for read data) | Stall EU until bus_ack; report wait cycles |
| Control hazard (branch) | Flush prefetch queue; restart from branch target |
| Structural hazard (MMU + EU contend) | Queue lower-priority; insert bubbles |
| MMU TLB miss | Stall EU; MMU hijacks bus for table walk |

---

## Section 12 — Electrical and FPGA Implementation

**BIU-110** — 4× Internal Clock Strategy
Run all BIU logic at 4× the external bus frequency. For a 25 MHz external bus, use a
100 MHz internal clock. This provides four internal ticks per external clock period,
allowing each S-state boundary to be modelled with explicit flip-flop stages without
combining posedge and negedge triggers.

```
External 25 MHz period = 40 ns
Internal 100 MHz period = 10 ns

Phase 0 (0°)   → start of external rising edge
Phase 1 (90°)  → quarter cycle
Phase 2 (180°) → external falling edge
Phase 3 (270°) → three-quarter cycle
```

**BIU-111** — PLL / Phase Alignment
An FPGA PLL must lock to the external CLK input and generate the 4× internal clock
with stable phase. A phase counter (0–3) resets on the external rising edge to maintain
alignment. Phase misalignment causes the S-state machine to assert signals at the wrong
external-clock fractions, breaking timing.

**BIU-112** — Output Drive Strength
FPGA output drive strength and slew rate for all BIU output pins (A, D, AS, DS, RW,
FC, SIZ, ECS, OCS, BG, CBREQ, RSTOUT) should be tuned to match the MC68030 AC
timing characteristics. Excessive slew rate causes overshoot; insufficient drive causes
setup time violations at the memory controller.

**BIU-113** — Input Setup and Hold Times
All DSACK, BERR, STERM, AVEC, BR, BGACK, IPL, HALT, CBACK, VPA inputs must meet the
setup and hold times specified in the MC68030 AC timing tables relative to the external
clock edge. The 2-stage synchronizer (BIU-023) ensures metastable inputs are resolved
before the S-state machine samples them.

---

## Section 13 — Variant Support

**BIU-114** — 68EC030 (No-MMU Variant)
The 68EC030 is identical to the 68030 with the integrated PMMU removed:
- No TLB or ATC hardware
- No TC, TT0, TT1, CRP, SRP, MMUSR registers
- All PMMU instructions (PFLUSH, PLOAD, PMOVE, PTEST, PFREE, PVALID, PFLUSHA)
  generate F-Line exceptions
- All bus cycles are otherwise identical (same S-states, same DSACK/STERM protocol)

Support both variants via a top-level parameter:
`parameter HAS_MMU = 1; // set 0 for 68EC030`

**BIU-115** — Test / Manufacturing Mode
The 68030 includes a manufacturing test mode. Exact pin behaviour in test mode is not
publicly documented. The 68030 predates IEEE 1149.1 (JTAG); no boundary scan is
supported.

---

## Section 14 — Silicon Errata

**BIU-116–130** — Documented Silicon Errata
Motorola published an errata document for the MC68030 covering at least 15 documented
bugs. Confirmed examples from community sources:

- At least one CAS / CAS2 variant fails to maintain the atomic bus lock under specific
  timing conditions (manifests during Macintosh Classic II boot)
- Certain cache invalidation sequences (CINVA followed immediately by a
  cache-touching instruction) can fail to invalidate under specific pipeline conditions
- Some instruction sequences cause pipeline state corruption under specific cache
  miss/hit interaction patterns

Implementation decision required: either replicate each erratum exactly (required for
software that works around the bug) or implement the correct behaviour (breaks software
workarounds for that bug). The Motorola errata document is available via archive.org —
search for "MC68030 errata".

---

## Section 15 — Operand-Dependent Timing Variations

**BIU-131–139**
The following instructions have cycle counts that vary with operand values. The EU
handles the variable timing internally; the BIU need not generate extra external bus
cycles during the operation itself.

| Instruction | Variable Factor |
|-------------|----------------|
| MULS / MULU | Bit count / transition count in source operand |
| DIVS / DIVU | Magnitude of dividend and divisor |
| ASL / ASR / LSL / LSR / ROL / ROR / ROXL / ROXR | Shift count |
| BFFFO (Bit Field Find First One) | Bit position of first set bit |
| MOVEM | Register count (popcount of mask) |
| DBcc | Branch taken vs not taken; loop iteration count |

---

## Section 16 — System-Specific Behaviours

**BIU-140–143** — Chipset-Specific DMA Timing
The 68030 was used in systems with unique DMA arbitration requirements. These are
board-level concerns that affect BR/BG/BGACK timing:

| System | Notes |
|--------|-------|
| Amiga 3000 | Agnus/Paula DMA uses tightly-timed BR/BG cycles; BERR timeout ≈ 8 bus clocks |
| Macintosh IIx/IIcx | NuBus arbitration requires specific BG deassertion timing |
| Atari TT030 / Falcon | Blitter DMA shares bus with 68030; specific BGACK hold times |
| VME systems | VMEbus BERR timeout and arbitration latency constraints |

Implement only if targeting a specific platform.

**BIU-144** — Address Space FC Encoding
The 68030 fully supports the M68000 separated address space model. Separate I-cache
(FC=010 or 110) and D-cache (FC=001 or 101) mean instruction and data spaces do not
alias in cache even if they share physical addresses. ECS and OCS further disambiguate
instruction-fetch cycles from data-access cycles for external hardware.

---

## Appendix A — Corrections to Source Material

The following factual errors were found in `output.txt` during verification. All
requirements in this document already reflect the correct values.

| # | Original Claim | Correction |
|---|---------------|------------|
| C-01 | DTACK is the bus acknowledgement signal | 68030 uses DSACK0/DSACK1, which simultaneously encode port width and cycle completion. DTACK exists on 68000/68010 only. |
| C-02 | 68030 uses LDS and UDS (Lower/Upper Data Strobes) | 68030 has a single DS pin. LDS/UDS are 68000/68010 signals. Byte-lane selection is external via SIZ + A. |
| C-03 | FC: 100=User Data, 101=User Program, 110=Sup Data, 111=Sup Program, 010=IACK | 001=User Data, 010=User Program, 101=Sup Data, 110=Sup Program, 111=CPU Space (IACK). |
| C-04 | SIZ=11 means "16-byte line (burst)" | SIZ=11 means 3-byte transfer (3 remaining bytes in a dynamic sizing sequence). |
| C-05 | DS does NOT assert during IACK | DS DOES assert during IACK — it is a standard read cycle. |
| C-06 | IACK address: Level 1=$00000002, Level 7=$0000000E | CPU Space encoding: A16–A19=1111, A1–A3=interrupt level, all other bits=1. |
| C-07 | RSTOUT asserts for 2 clock cycles | RESET instruction: RSTOUT asserts for 124 clock cycles. Hardware reset: ≥100 ms at power-on. |
| C-08 | SIZE0/SIZE1 are input pins sampled at reset to configure bus width | SIZ0/SIZ1 are output pins. Bus width is discovered dynamically per-cycle via DSACK. |
| C-09 | 68030 has a CLKOUT pin | No CLKOUT pin exists on the 68030. ECS and OCS serve the external synchronisation role. |
| C-10 | MOVE16 is a 68030 instruction (4 address variants) | MOVE16 is a 68040 instruction. It does not exist on the 68030. |
| C-11 | 68030 MMU has CRP, SRP, and DRP | 68030 integrated MMU has CRP and SRP only. DRP belongs to the external 68851 PMMU coprocessor. |
| C-12 | VPA is the autovector signal during IACK | AVEC is the autovector signal. VPA triggers legacy 6800-style E-clock cycles only. |
| C-13 | CACR: 5 bits (0–4) with D-cache in bits 1–3 | CACR is a 32-bit register. I-cache in bits 0–4 (confirmed). D-cache in bits 9–14 per the User Manual register diagram (bit 8 reserved, WA at bit 14). A secondary source places D-cache at bits 8–13; verify against the physical manual before committing to Verilog. |
| C-14 | FC=010 is used for IACK cycles | FC=010 is User Program Space. IACK uses FC=111 (CPU Space). |
| C-15 | Reset vector fetch uses FC=111 | Reset vector fetch uses FC=110 (Supervisor Program Space). FC=111 is CPU Space (IACK). |

---

## Appendix B — Verilog Implementation Plan

This appendix describes the recommended file structure, module hierarchy, port
interfaces, implementation order, and testing strategy for the BIU Verilog
implementation.

`output.txt` proposed a module hierarchy and testbench code that was based on the
unverified source material. This plan supersedes that proposal with a corrected
structure reflecting the verified spec: DSACK0/DSACK1 (not DTACK), single DS (not
LDS/UDS), correct FC encodings, E-clock generation, and STERM/AVEC handling.

---

### C.1 — Repository Layout

```
MH030/
├── rtl/
│   ├── m68030_biu.sv          Top-level wrapper and port map
│   ├── biu_arbiter.sv         Internal bus priority arbiter
│   ├── biu_cycle_gen.sv       Core S-state machine (all cycle types)
│   ├── biu_pin_driver.sv      External pin timing and tri-state control
│   ├── biu_sizing_fsm.sv      DSACK dynamic bus-sizing sequencer
│   ├── biu_burst_ctrl.sv      Burst mode (CBREQ/CBACK linefill)
│   ├── biu_error_handler.sv   BERR classification and fault-data capture
│   ├── biu_eclk_gen.sv        E-clock generator (CLK/10, 60/40 duty)
│   ├── biu_cache_if.sv        I-cache / D-cache hit/miss signalling
│   └── biu_mmu_if.sv          MMU table-walk bus hijack
├── tb/
│   ├── biu_tb.sv              Top-level testbench (iverilog-compatible)
│   ├── mem_model.sv           Parameterised memory model (DSACK, STERM modes)
│   └── biu_monitor.sv         Bus-activity monitor / VCD annotation
├── sim/
│   ├── run_tests.sh           Batch test runner (iverilog + Verilator)
│   ├── generate_tests.py      68030 test-binary generator
│   └── compare_traces.py      Cycle-accurate trace comparison vs Musashi
├── ref/
│   └── musashi/               Instrumented Musashi reference (see C.5)
├── biu_spec.md                This document
├── CLAUDE.md                  Project guidance for Claude Code
└── output.txt                 Source architectural discussion (read-only)
```

---

### C.2 — Module Hierarchy and Estimated Size

```
m68030_biu          top-level wrapper                  ~200 lines
├── biu_arbiter     internal bus priority               ~400 lines
├── biu_cycle_gen   S0–S7 state machine                ~2500 lines
├── biu_pin_driver  external pin control                ~600 lines
├── biu_sizing_fsm  DSACK multi-cycle sequencer         ~600 lines
├── biu_burst_ctrl  CBREQ/CBACK burst                  ~500 lines
├── biu_error_handler  BERR / fault capture             ~600 lines
├── biu_eclk_gen    E-clock, CLK/10                    ~200 lines
├── biu_cache_if    cache miss/hit signalling           ~600 lines
└── biu_mmu_if      MMU table-walk hijack              ~800 lines
                    ─────────────────────────────────────
                    Estimated total                    ~7000 lines
```

The original `output.txt` proposal included `biu_byte_lane_ctrl` for LDS/UDS
generation. That module is eliminated: the 68030 has a single DS pin and byte-lane
selection is entirely external logic (SIZ[1:0] + A[1:0]). Internal data alignment
(shifting received bytes into the correct register lane positions) lives in
`biu_sizing_fsm`.

---

### C.3 — Top-Level Port Interface (`m68030_biu.sv`)

```systemverilog
module m68030_biu #(
  parameter HAS_MMU = 1      // set 0 for 68EC030 (no MMU, no TLB)
) (
  //--- System ---------------------------------------------------------------
  input  logic        clk_4x,        // 4x bus clock (100 MHz for 25 MHz bus)
  input  logic        rst_n,         // Async assert / sync deassert

  //--- External address/control outputs -------------------------------------
  output logic [31:0] ext_a,         // Address bus A[31:0]
  output logic        ext_as_n,      // Address Strobe
  output logic        ext_ds_n,      // Data Strobe (single pin — not LDS/UDS)
  output logic        ext_rw,        // Read=1, Write=0
  output logic [2:0]  ext_fc,        // Function Code FC[2:0]
  output logic [1:0]  ext_siz,       // Transfer Size SIZ[1:0]
  output logic        ext_ecs_n,     // External Cycle Start
  output logic        ext_ocs_n,     // Operand Cycle Start
  output logic        ext_rstout_n,  // Reset Output (124 clk for RESET instr)
  output logic        ext_e,         // E-clock (CLK/10, 60/40 duty)
  output logic        ext_bg_n,      // Bus Grant
  output logic        ext_cbreq_n,   // Cache Burst Request

  //--- External data bus (split to avoid Verilog inout) --------------------
  input  logic [31:0] ext_d_in,      // Data in (sampled at S6 on reads)
  output logic [31:0] ext_d_out,     // Data out (driven S3-S7 on writes)
  output logic        ext_d_oe,      // Output-enable (high = drive bus)

  //--- Handshake inputs (all synchronised internally) ----------------------
  input  logic        ext_dsack0_n,  // DSACK0
  input  logic        ext_dsack1_n,  // DSACK1
  input  logic        ext_sterm_n,   // Synchronous Termination
  input  logic        ext_berr_n,    // Bus Error
  input  logic        ext_halt_n,    // Halt / Bus-Retry (BIU-148)
  input  logic        ext_avec_n,    // Autovector Enable
  input  logic        ext_vpa_n,     // Valid Peripheral Address
  input  logic [2:0]  ext_ipl_n,     // Interrupt Priority Level (active-low)
  input  logic        ext_br_n,      // Bus Request
  input  logic        ext_bgack_n,   // Bus Grant Acknowledge
  input  logic        ext_cback_n,   // Cache Burst Acknowledge

  //--- Internal interface — Execution Unit ----------------------------------
  input  logic [31:0] eu_addr,
  input  logic [31:0] eu_wdata,
  output logic [31:0] eu_rdata,
  input  logic [2:0]  eu_fc,
  input  logic        eu_rw,
  input  logic [1:0]  eu_siz,
  input  logic        eu_is_operand, // 1 = data access (asserts OCS)
  input  logic        eu_req,
  output logic        eu_ack,
  output logic        eu_berr,
  output logic        eu_retry,      // BERR+HALT retry in progress

  //--- Internal interface — Instruction Fetch Unit --------------------------
  input  logic [31:0] ifu_addr,
  input  logic        ifu_req,
  output logic [31:0] ifu_rdata,
  output logic        ifu_ack,
  output logic        ifu_berr,

  //--- Internal interface — MMU table walk ----------------------------------
  input  logic [31:0] mmu_addr,
  input  logic [2:0]  mmu_fc,        // Always 3'b101 (Supervisor Data)
  input  logic        mmu_req,
  output logic [31:0] mmu_rdata,
  output logic        mmu_ack,
  output logic        mmu_berr,

  //--- IACK cycle interface -------------------------------------------------
  input  logic        eu_iack_req,
  input  logic [2:0]  eu_iack_level,
  output logic [7:0]  eu_iack_vec,   // Vector or autovector
  output logic        eu_iack_avec,  // AVEC was asserted
  output logic        eu_iack_ack
);
```

The data bus is split into `ext_d_in`, `ext_d_out`, and `ext_d_oe` rather than using
a Verilog `inout`. FPGA top-level wrappers connect these three signals to the physical
bidirectional pin using `IOBUF` (Xilinx) or `GPIO` (Intel/Altera) primitives, keeping
all internal logic single-directional and simulation-friendly.

---

### C.4 — Implementation Phases and Order

Dependencies flow downward: each phase requires the previous phases to be functionally
correct before integration testing is possible.

#### Phase 1 — Foundation (2 weeks)
Target: clock, reset, E-clock

| Module | Requirements | Verify |
|--------|-------------|--------|
| `biu_eclk_gen.sv` | BIU-145 | E pin at CLK/10, 60/40 duty; internal counter 0–9 |
| 4× phase counter in `biu_cycle_gen.sv` | BIU-110, BIU-111 | phase[1:0] resets to 0 on first posedge after rst_n |
| Reset sequencer | BIU-051, BIU-052 | All outputs hi-Z during rst_n; SSP+PC fetch on release |

`biu_eclk_gen` has no internal dependencies and is the best starting point.

#### Phase 2 — Core Read/Write Cycles (3 weeks)
Target: single-longword read and write from a 32-bit port

| Module | Requirements | Verify |
|--------|-------------|--------|
| `biu_cycle_gen.sv` read path | BIU-024 to BIU-031 | AS/DS timing; data sampled at S6 |
| `biu_cycle_gen.sv` write path | BIU-025 | Data driven S3, held through S7 |
| `biu_pin_driver.sv` | BIU-001 to BIU-012 | ECS one half-clock before AS; OCS on operand cycles |
| `biu_arbiter.sv` | BIU-097 to BIU-101 | MMU > EU > IFU priority; BG/BGACK handshake |

Phase 2 is complete when a single-longword read from a 32-bit DSACK=00 model produces
the correct 8-S-state waveform and data is returned to `eu_rdata` with `eu_ack`.

#### Phase 3 — Dynamic Sizing and Burst (3 weeks)

| Module | Requirements | Verify |
|--------|-------------|--------|
| `biu_sizing_fsm.sv` — 32→16 bit | BIU-033, BIU-146 | 2 cycles; SIZ updated 00→10 |
| `biu_sizing_fsm.sv` — 32→8 bit | BIU-033, BIU-146 | 4 cycles; SIZ sequence 00→11→10→01 |
| `biu_sizing_fsm.sv` — alignment | BIU-072 | Bytes assembled into correct eu_rdata lanes |
| `biu_burst_ctrl.sv` | BIU-038 to BIU-042, BIU-147 | 4-longword burst; mid-burst CBACK deassert terminates cleanly |
| Wait states | BIU-026 | DSACK=11 loops; wait count exposed to EU |

#### Phase 4 — Error Handling and Special Cycles (3 weeks)

| Module | Requirements | Verify |
|--------|-------------|--------|
| `biu_error_handler.sv` | BIU-015, BIU-090–096 | Fault addr/data/FC/RW/SIZ latched on BERR |
| BERR + HALT retry | BIU-148 | Simultaneous sampling → re-drive, not exception |
| Double fault halt | BIU-094 | Second BERR during exception processing → HALT low |
| STERM path | BIU-049, BIU-050, BIU-150 | Cycle ends at S4; late STERM ignored |
| IACK cycles | BIU-043 to BIU-048 | FC=111, CPU Space address encoding, AVEC, spurious |
| VPA / E-clock sync | BIU-020, BIU-145 | VPA cycle waits for E boundary; no DSACK termination |
| RESET instruction | BIU-063, BIU-012 | RSTOUT exactly 124 clocks; bus otherwise idle |

#### Phase 5 — RMW, MOVEP, MOVEM (2 weeks)

| Module | Requirements |
|--------|-------------|
| RMW atomic lock in `biu_cycle_gen.sv` | BIU-035, BIU-036 |
| CAS2 four-cycle atomic lock | BIU-057 |
| MOVEP byte-interleave cycles | BIU-054 |
| MOVEM multi-longword cycles | BIU-055 |

#### Phase 6 — Cache and MMU Integration (4 weeks)

| Module | Requirements |
|--------|-------------|
| `biu_cache_if.sv` | BIU-073 to BIU-078, BIU-153, BIU-154 |
| `biu_mmu_if.sv` table walk | BIU-079 to BIU-088, BIU-082, BIU-083 |
| Write-allocate sequence | BIU-153 |
| Format $B re-execution | BIU-152 |

#### Phase 7 — FPU Coprocessor Interface (2 weeks)

| Module | Requirements |
|--------|-------------|
| CPU Space address encoding | BIU-151 |
| FPU exception frames | BIU-102, BIU-103 |

#### Phase 8 — Variant and Errata (1 week)

| Topic | Requirements |
|-------|-------------|
| 68EC030 MMU gating via `HAS_MMU` parameter | BIU-114 |
| Silicon errata implementation decisions | BIU-116 to BIU-130 |

---

### C.5 — Testing Strategy

#### Golden Reference: Musashi

Use the **Musashi** 68k C emulator as the golden reference. It is far easier to
instrument than WinUAE (a large GUI application). Add trace output to the memory
access callbacks in your Musashi harness:

```c
void trace_bus(uint32_t addr, uint32_t data, int fc, int rw, int siz) {
    static uint64_t cyc = 0;
    fprintf(trace_f, "%08X %08X %d %d %d %llu\n",
            addr, data, fc, rw, siz, cyc++);
}
// Register as m68k_read/write callbacks in your test harness
```

Musashi source: `https://github.com/kstenerud/Musashi`

#### Simulator: iverilog for Development, Verilator for Regression

During active development use **iverilog** (`iverilog` + `vvp`):
- Fast compile; waveforms via `$dumpvars` → GTKWave
- Single command: `iverilog -g2012 -o sim.vvp rtl/*.sv tb/biu_tb.sv && vvp sim.vvp`

Switch to **Verilator** for regression once the design is stable:
- 10–100× faster; critical for 250+ test cases
- `verilator --cc --exe --build -Wno-fatal biu_tb.cpp rtl/*.sv`

#### Memory Model (`mem_model.sv`)

**Important correction from `output.txt`:** the testbench code in the source
discussion uses DTACK and LDS/UDS, which are 68000/68010 signals. The 68030 memory
model must use DSACK0/DSACK1 and a single DS. Three parameterisable response modes:

```
ASYNC_32  DSACK1=0, DSACK0=0  — 32-bit port, cycle complete
ASYNC_16  DSACK1=0, DSACK0=1  — 16-bit port (triggers sizing FSM)
ASYNC_8   DSACK1=1, DSACK0=0  —  8-bit port (triggers sizing FSM)
SYNC      assert STERM at S2  — zero-wait synchronous
SLOW_N    DSACK=11 for N clocks, then DSACK=00
```

#### Trace Format

Both Musashi and the iverilog testbench emit the same line format:

```
# ADDR     DATA     FC RW SIZ CYCLE
00001000   00000064  6  1   0   0
00000000   00008000  6  1   2   4
```

`sim/compare_traces.py` reads both files and reports the first cycle where address, FC,
RW, or data diverges. A cycle-count divergence (same operations but different timing)
is also a failure.

#### Test Case Categories

| Category | Count | Key requirements |
|----------|-------|-----------------|
| Basic read/write, all sizes, 32/16/8-bit ports | ~50 | BIU-024 to BIU-034 |
| Dynamic bus sizing sequences | ~30 | BIU-033, BIU-146 |
| Burst linefill (with and without mid-burst CBACK abort) | ~20 | BIU-038 to BIU-042, BIU-147 |
| Wait state insertion (0, 1, 2, 4 wait states) | ~20 | BIU-026 |
| STERM zero-wait cycles | ~10 | BIU-049, BIU-150 |
| BERR exception (read, write, during MMU walk) | ~20 | BIU-015, BIU-085, BIU-090 |
| BERR + HALT retry | ~10 | BIU-148 |
| IACK (vectored, AVEC, spurious) | ~15 | BIU-043 to BIU-048 |
| RMW / TAS / CAS / CAS2 | ~15 | BIU-035 to BIU-037, BIU-057 |
| MOVEP / MOVEM | ~10 | BIU-054, BIU-055 |
| Reset sequence (SSP + PC fetch) | ~5 | BIU-051 to BIU-053 |
| E-clock / VPA cycles | ~10 | BIU-145, BIU-020 |
| RESET instruction RSTOUT timing | ~5 | BIU-063 |
| Exception frame generation | ~15 | BIU-089 to BIU-096 |
| **Total** | **~235** | |

#### Automation Script (iverilog path)

```bash
#!/bin/bash
# sim/run_tests.sh
PASS=0; FAIL=0
for bin in tests/*.bin; do
    name=$(basename "$bin" .bin)
    ./ref/musashi/run "$bin" > "traces/${name}_ref.txt"
    iverilog -g2012 -o sim.vvp rtl/*.sv tb/biu_tb.sv \
        -DTEST_BIN="\"$bin\"" && vvp sim.vvp
    if python3 sim/compare_traces.py "traces/${name}_ref.txt" biu_trace.txt; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); cp biu_trace.txt "traces/${name}_fail.txt"
    fi
done
echo "Passed $PASS / $((PASS+FAIL))"
```

---

### C.6 — Key Design Parameters

```systemverilog
parameter int CLK_MULT     = 4;    // Internal clock = CLK_MULT x external bus clock
parameter int BUS_FREQ_MHZ = 25;   // Target external bus frequency
parameter int HAS_MMU      = 1;    // 0 = 68EC030 (no MMU logic)
parameter int HAS_FPU_IF   = 1;    // 0 = no coprocessor CPU Space cycles
parameter int ECLK_LO      = 6;    // E-clock low phase (in ext clocks)
parameter int ECLK_HI      = 4;    // E-clock high phase (in ext clocks)
parameter int RSTOUT_CLKS  = 124;  // RESET instruction RSTOUT assertion count
```

---

### C.7 — Critical RTL Implementation Notes

1. **Two-stage synchroniser on all async inputs** (BIU-023). First flop clocks on
   `posedge clk_4x`; second flop one cycle later. Do not use synchronised outputs
   from separate paths for BERR and HALT — they must share one synchroniser pair so
   the simultaneous-assertion case is not split across different clock edges (BIU-148).

2. **STERM sampled at S2** — the rising `clk_4x` edge that closes S1. If STERM
   arrives after S2 it is silently ignored for this cycle (BIU-150).

3. **DSACK sampled at S4** — first opportunity after DS asserts (S3). DSACK=11 means
   insert a wait state and resample; any other encoding terminates the cycle (BIU-013).

4. **ECS asserts one half-clock before AS** — in 4× terms, ECS asserts at the
   `phase=2` tick of the external clock that precedes AS at `phase=0`. The state
   machine must look one 4× period ahead of the AS assertion (BIU-008).

5. **`ext_d_oe` must deassert within one `clk_4x` of BGACK asserting** (BIU-002).
   Register the output-enable signal; do not gate it combinationally.

6. **Phase counter** `phase[1:0]` resets to 0 on the first `posedge clk_4x` after
   `rst_n` deasserts. The PLL must be locked and stable before `rst_n` is released
   by the top-level reset synchroniser (BIU-111).

7. **Bus data turnaround**: `ext_d_oe` deasserts at S6 (read data sampled), not S7.
   On back-to-back read-then-write, the external memory controller needs at least one
   `clk_4x` gap between the read bus release and the write drive to avoid contention.
   The state machine must enforce this gap (BIU-029).
