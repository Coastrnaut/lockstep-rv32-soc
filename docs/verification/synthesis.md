# Synthesis and the safe-state encodings (roadmap R3.1)

The comparator's state register (`0x5A` healthy, `0xA5` tripped) and the
self-test's result register use 8-bit encodings with a Hamming distance of 8,
so that no single upset turns one value into the other, and any other value
can be recognised as illegal (TSR_SAFETY_GATE_001, HSI FLT-03). That only
holds if synthesis keeps the eight flip-flops as written. A default 7-series
flow does not.

## What a default flow does

GHDL 6.0 netlists, mapped by Yosys 0.71 `synth_xilinx -family xc7` (YoWASP,
`yowasp-yosys` 0.71.0.0.post1285):

| Flow | Comparator flip-flops | What happened |
|------|-----------------------|---------------|
| Default | 3 | `fsm_detect` found the state register, and `fsm_recode` re-encoded `0x5A` and `0xA5` as a 2-bit one-hot code. The self-test's result register was re-encoded the same way |
| FSM extraction off | 3 | Every bit of `0xA5` is the complement of the same bit of `0x5A`, so the eight bits fall into two groups with identical next-state logic, and register merging keeps one flip-flop per group |
| As written | 9 | 8 state bits and the fault latch |

In both mapped versions one upset is enough to turn the healthy state into the
tripped one, or the reverse. The illegal-state check has nothing left to
check, because every combination of the remaining flip-flops is a legal state.
The formal proofs in `docs/verification/formal.md` are of GHDL's netlist
before this optimisation, so they do not show it. Vivado performs the same
optimisations by default: FSM extraction (`-fsm_extraction auto`) and
equivalent-register removal.

## What the design does about it

- The RTL marks the protected registers for Vivado:
  `fsm_encoding = "none"` and `dont_touch = "true"` on each comparator's
  `r_current_state`, `dont_touch` on its `r_fault_latched`, and both on the
  self-test's `r_result`. `dont_touch` stops the merging, and `fsm_encoding`
  the re-encoding.
- The FPGA build (`fpga/arty_a7_100t/build.tcl`) also turns FSM extraction off
  for the whole design. It then counts the flip-flops after synthesis and again
  after routing: 8 for each comparator's state, 1 for each one's latch, 1 for
  the disagreement latch, 8 for the self-test result. A smaller count stops
  the build.
- The two comparators in `dual_comparator` are identical logic on the same
  inputs, which equivalent-register removal would merge into one. Their
  instances carry `keep_hierarchy` and `dont_touch`, and the build checks that
  both still have their own state after routing (16 flip-flops).

## Status and limits

| Item | Status |
|------|--------|
| Vivado honours the attributes and the build's checks pass | **Not yet run.** Vivado 2026.1 is installed on the development machine with the Artix-7 devices, but it reports an Alveo licence and `get_parts` then lists no parts, so no Vivado synthesis has run. Its simulator runs (`docs/verification/toolchain.md`). The checks run on the first build |
| The Yosys flow keeps the encodings | No. GHDL puts the VHDL attributes on the named wire rather than on the flip-flop, so Yosys does not see them. The figures above come from this flow, as evidence of the hazard, not of the fix |
| Other targets | An ASIC or another FPGA flow needs the same protection under its own names, and the same post-synthesis check |
| CAN, UART and self-test sequencers | Enumerated types with no claimed state distance; a tool may re-encode them |

## Resource estimates

The same Yosys flow, with FSM extraction off, for the blocks of milestone 1.
These are estimates for comparing options, not a fit report.

| Block | LUTs | Flip-flops | Other |
|-------|------|------------|-------|
| `lockstep_comparator` | 135 | 3 (9 as written) | |
| `comparator_self_test` | 149 | 23 (29 as written) | 5 CARRY4 |
| `soc_bus_fabric` | 86 | 7 | |
