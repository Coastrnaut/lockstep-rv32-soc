# Retirement trace comparison (roadmap R2.2)

The XBus comparator sees only what reaches the bus. A fault in a core's
registers, program counter or control state stays hidden until it changes a
bus access, or for ever if it never does. This pilot compares the two cores'
retirements instead, instruction by instruction, as a verification
diagnostic. The bus comparator stays the authority for side effects.

## How it works

- `top_automotive_soc` has a generic `g_trace_en`, false by default, that
  turns on NEORV32's execution trace port in both cores. Nothing else changes,
  and the synthesised design is unchanged with it off.
- `sim/testbenches/trace_compare.vhd` keeps each of core A's retirements in a
  short queue until core B, two clocks behind, retires the instruction with the
  same order number, then compares them field by field. It normalises the
  fields first: register write data counts only for a register other than x0,
  and memory data only in the byte lanes the access enabled.
- A reset starts a new epoch on both cores, with order numbers from 0. Core B's
  reset arrives two clocks after core A's, by which time it has retired
  everything core A had, so the queue is empty between epochs.

## Results

`sim/testbenches/tb_soc_trace.vhd`, GHDL 6.0, on the simulation firmware:

| Test | Result |
|------|--------|
| `core_b_retires_exactly_what_core_a_retired_all_through_the_program` | 5,052 retirements compared, none differ |
| `access_faults_and_their_handler_retire_the_same_on_both_cores` | The bus probes' 11 access faults: 11 trap-handler entries, 1,743 retirements compared, none differ |
| `a_register_only_divergence_is_caught_by_the_trace_and_not_by_the_bus` | Core A's write of 0 to s5 at order 4 is forced to `0xDEADBEEF` for one clock. The trace comparison reports a mismatch in the register write at order 4, 40 ns (two clocks) after core A retired it. The program then runs to the end and sends its CAN frame, with `nmi_fault_o` low through 3,951 retirements: s5 is read only on an access fault, so no bus access ever depended on it, and the bus comparator never saw it |

## What this is not

| Item | Status |
|------|--------|
| RVFI compatibility | Not claimed. The fields are NEORV32's own. The trap test checks that both cores report the same trap entries; it does not check them against an independent model |
| Comparison against Sail or Spike | Not done. There is no RISC-V simulator or compiler on the development machine |
| ACT4 pilot | Needs a compiler, a linker script and an ELF loader (roadmap R3.3) |
| A hardware trace comparator | Not planned until there is an explicit retirement-to-store ordering contract. This remains a simulation diagnostic |
