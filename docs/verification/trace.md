# Retirement trace comparison (roadmap R2.2)

The XBus comparator sees only what reaches the bus. A fault in a core's
registers, program counter or control state stays hidden until it changes a
bus access, or for ever if it never does. Two comparisons of the cores'
retirements close that gap: one in the RTL, which trips the SoC, and one in the
benches, which is independent of it and reports where the cores parted.

## In the RTL: `retire_comparator` (TSR_LOCKSTEP_046)

Both cores' NEORV32 trace ports are always on. `rtl/soc/retire_comparator.vhd`
delays core A's retirement record by the two clocks core B runs behind, and
compares it with core B's in every clock: whether an instruction retired, and
for one that did, the instruction, both program counters, the trap and
interrupt flags, the destination register, its write data and the CSR write
data (HSI FLT-05).

- **It only detects.** A difference, registered, goes to the comparators'
  fatal input, which closes the bus, raises the fault pin and holds until a
  cold reset. Containment stays with the bus comparator, which still stops
  every access the cores disagree on before it has an effect. The ordering
  question that kept this out of the RTL before, a retirement compared after
  its store, does not arise: a store the cores disagree on never passes the bus
  comparator, whatever the retirement comparator does.
- **Memory fields are not compared.** Addresses and data reach the bus, where
  the bus comparator sees them first.
- **It compares while core B is out of reset.** Core B's reset is core A's,
  delayed with its other inputs, and the delay line has no reset of its own, so
  core A's last records before a reset are still there for core B to match.
- **Cost.** Two trace ports and 2 × 168 flip-flops of delay line, and NEORV32's
  64-bit instruction counter in each core. Not yet measured in a synthesis
  (R3.1).

## In the benches: `trace_compare`

- `sim/tb/lib/trace_compare.vhd` keeps each of core A's retirements in a
  short queue until core B, two clocks behind, retires the instruction with the
  same order number, then compares them field by field. It normalises the
  fields first: register write data counts only for a register other than x0,
  and memory data only in the byte lanes the access enabled.
- A reset starts a new epoch on both cores, with order numbers from 0. Core B's
  reset arrives two clocks after core A's, by which time it has retired
  everything core A had, so the queue is empty between epochs.

## Results

`sim/tb/tb_soc_trace.vhd`, GHDL 6.0, on the simulation firmware:

| Test | Result |
|------|--------|
| `core_b_retires_exactly_what_core_a_retired_all_through_the_program` | 5,052 retirements compared, none differ |
| `access_faults_and_their_handler_retire_the_same_on_both_cores` | The bus probes' 11 access faults: 11 trap-handler entries, 1,743 retirements compared, none differ |
| `a_register_only_divergence_is_caught_by_the_retirement_comparator` | Core A's write of 0 to s5 at order 4 is forced to `0xDEADBEEF` for one clock. The fault pin rises within six clocks of core A retiring it, the actuators go safe, and the bus stays closed: the program never sends its CAN frame |
| `without_the_retirement_comparator_the_bus_comparator_never_sees_it` | The same, with the RTL comparator's output held at 0, as the SoC was before it. The bench's comparison reports a mismatch in the register write at order 4, 40 ns (two clocks) after core A retired it. The program runs to the end and sends its CAN frame with `nmi_fault_o` low: s5 is read only on an access fault, so no bus access ever depended on it |

## What this is not

| Item | Status |
|------|--------|
| RVFI compatibility | Not claimed. The fields are NEORV32's own. The trap test checks that both cores report the same trap entries; it does not check them against an independent model |
| Comparison against Sail or Spike | Not done. There is no RISC-V simulator or compiler on the development machine |
| ACT4 pilot | Needs a compiler, a linker script and an ELF loader (roadmap R3.3) |
| A self-test of the retirement comparator | Not built. A comparator whose output sticks at "no difference" is a latent fault until the next proof test; the bus comparator still contains every effect (FMEDA FM-26) |
