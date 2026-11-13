# Memory protection, repair and telemetry (roadmap R4.1)

What protects each store of state in the SoC, what was added to the shared RAM
in R4.1, and how it was checked. The contract is HSI section 8.5, ECC-05 to
ECC-08.

## Protection map

| State | Where | Protection | Detection path | Gaps |
|-------|-------|------------|----------------|------|
| Shared data RAM, 256 KB | `ecc_data_ram` on the system bus | SECDED (72,64) on every word; writeback on load and store; idle patrol | Single-bit: corrected, counted, repaired. Double-bit: an access trips the comparator (`dbe_fatal_o`); the patrol flags it as latent | No address in the code (below); three or more flipped bits in one word can be miscorrected |
| Instruction memory, 16 KB in each core | NEORV32 IMEM, private | None | An upset in one core's copy makes the cores disagree, and the comparator trips at the next differing bus access | Latent until the instruction runs and reaches the bus; the same upset in both copies is not seen |
| CPU register files and pipeline | NEORV32, private | None | Lockstep: a difference reaches the comparator at the next bus access. The trace comparison (`docs/verification/trace.md`) sees it at the retirement, in verification only | Latent while the value is unused (fault campaign) |
| Request bus, each core to the comparator | XBus, private | Lockstep comparison of address, data, byte enables, write and strobe | Comparator, in the cycle the cores differ | |
| Response bus, the fabric to both cores | Shared | None of its own | The RAM's ECC covers the data while it is in the RAM. A fault on the shared path reaches both cores alike, so lockstep cannot see it | Integrity protection on the response is milestone 5 analysis |
| Peripheral and comparator registers | Flip-flops | Comparator and self-test result use 8-bit Hamming-distance encodings; others none | Comparator: illegal-state detection. Others: none | CAN, UART and watchdog registers |
| External program storage | None in this design | | | Not present |

## The RAM codec

`hamming_ecc_wrapper` is a (72,64) SECDED code. Its data width is now
constrained to 64 bits: the code has a fixed 8 check bits, and only 64 data
bits are used or tested, so any other width fails at elaboration instead of
building an untested code.

## Repair and patrol

| Rule | Implementation |
|------|----------------|
| Writeback (ECC-05) | A load that finds a single-bit error writes the corrected word back in its response cycle. A store already wrote back the corrected word it merged into |
| Patrol (ECC-06) | Each clock with no RAM strobe reads the next word. A single-bit error is written back corrected in the next clock. An uncorrectable word sets PATROL bit 0 and the first-fault record, and does not trip: nothing has used it yet |
| Arbitration (ECC-07) | A strobe always has the read port. The patrol never reads in a strobe clock, and a patrol check never falls in the cycle after a strobe, so it never meets a store's commit |
| Telemetry (ECC-08) | The first error since cold reset, with cause, word address, syndrome and time; registers 0x40000110 to 0x4000011C; and a read-only SPI port on its own pins |

### Patrol interval

| Load | Clocks for one pass over 32,768 words | At 50 MHz |
|------|-------------------------------------|-----------|
| Idle bus | 32,768 | 0.66 ms |
| Back-to-back core accesses, the worst case: a strobe every other clock | 65,538, measured in `tb_ecc_data_ram` | 1.31 ms |

A core cannot strobe in two clocks running, because it waits for the response
in the clock after its strobe. So the patrol has at least every other clock,
and a pass takes at most twice the number of words. That bound is checked, not
only measured: the test fails if a pass takes more than 2 × 32,768 + 8 clocks.
Its duty cycle is the core's; a DMA master that could strobe every clock would
need a different arbitration policy.

### Collision

A patrol write and a bus read of the same word can fall in the same clock. In
simulation the read sees the written word; a block RAM in read-first mode would
return the old one. Both are correctable words with the same corrected data,
so the access returns the right data either way, and at worst the same error
is counted twice.

## The diagnostic port

`telemetry_port` shifts out 160 bits, most significant first: FIRST_INFO,
FIRST_ADDR, FIRST_TIME, PATROL, then SBE_COUNT and DBE_COUNT. SPI mode 0; chip
select falling takes a snapshot; each falling edge of the clock moves to the
next bit, so a bit holds for the whole high phase. Both inputs go through
two-flop synchronisers, so the SPI clock is at most a tenth of `clk_i`. It is
reset only by the cold reset.

The port has no path to the system bus and no way to write anything, so a
supervisor can read why the SoC stopped while the comparator keeps the bus
shut. On the Arty board it is on Pmod JB1 to JB3.

## Tests

| Roadmap case | Test |
|--------------|------|
| Persistent stored single-bit error | `tb_ecc_data_ram.a_load_writes_back_a_stored_single_bit_error`: a second load finds nothing. `tb_ecc_data_ram.the_patrol_repairs_a_stored_error_that_nothing_reads`: repaired within one pass, recorded as the patrol's |
| Collision with foreground access | `tb_ecc_data_ram.the_patrol_covers_the_ram_under_back_to_back_accesses_and_delays_none`: every load answered in the clock after its strobe for a whole pass; two stored errors in neighbouring words both repaired under the load; pass time measured and bounded |
| Uncorrectable word in an idle region | `tb_ecc_data_ram.the_patrol_reports_an_uncorrectable_word_without_tripping`: latent flag and record, no trip, DBE_COUNT and STATUS untouched; a later load trips and the first record stays |
| Initialisation | `tb_ecc_data_ram.memory_starts_as_zeros_with_no_errors`, and the patrol passes over the zeroed RAM in every other test without an error |
| Warm and cold retention | `tb_ecc_data_ram.the_first_error_is_kept_through_a_warm_reset_and_cleared_cold` |
| Telemetry with the bus isolated | `tb_ecc_data_ram.telemetry_carries_the_registers`; `tb_soc_ecc.the_first_fault_reads_out_over_the_diagnostic_port_with_the_bus_shut`: the program stores an uncorrectable word, trips on it, and an SPI controller reads the record with the bus shut, twice, while the bus stays shut |
| The port | `tb_telemetry_port`: fastest and slow clocks, snapshot, a read cut short, idle output, reset |

Two older SoC tests changed their expectation, not their check: a bit stuck in
the RAM's read register is now also seen by every patrol read, so SBE_COUNT
grows past the three that the program's accesses alone gave. They now check
that the count is past three, and that it does not change across a watchdog
reset.

### Mutants

Twelve new mutants, all killed: writeback off for loads, off for the patrol,
the patrol never reading, the patrol advancing in strobe clocks (skipping
words), its uncorrectable word tripping the SoC or not flagged, the first record
replaced, lost in a warm reset, or holding the wrong word, and the port shifting
on the rising edge, driving its output unselected, or shifting the live record.
Two of them survived the first version of the tests and showed real gaps: the
port test now checks that a bit holds through the clock's high phase, and that
the port is quiet unselected even when it holds ones. Five older RAM mutants
were repointed at the changed lines, and every RAM, ECC and bus mutant was run
again against the new behaviour.

## Assumptions and limits

| Item | Status |
|------|--------|
| Address and control faults | Not covered by the code. The ECC is over the data only, so a wrong row decode returns a valid word from the wrong place. The lockstep comparison covers the request address up to the fabric, not the RAM's own decoder. Folding the address into the check bits would cover it; not done |
| Multi-bit upsets | Two flipped bits in a word are detected; three or more may be miscorrected. Physical interleaving of a word's bits across block RAM columns is a target-level choice, not made here |
| Patrol and DBE | A latent uncorrectable word does not trip the SoC until it is used. A target that needs it to should treat PATROL bit 0 as a fault in the supervisor |
| Time stamp | 32 bits of clocks since cold reset, wrapping after about 86 s at 50 MHz |
| Fault campaign | The seed-2026 campaign (`docs/verification/fault_campaign.md`) reruns with an identical report and results: its RAM faults are injected at an access, which the access corrects or trips on before the patrol reaches the word |
| Formal | The store-commit proof (`docs/verification/formal.md`) still holds: a repair is not a commit, and writes the same corrected data. No proof yet that a repair never changes a word's data |
