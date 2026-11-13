# Comparator diagnostics (roadmap R2.4)

How the lockstep comparator's own faults are found, how long one can stay
hidden, and what it would cost to shorten that.

## What the startup self-test covers

`comparator_self_test` runs after every cold reset, with both cores in reset,
before they may start. For each of the 70 compared bus bits and the fatal
input it flips that one input through the real comparator logic, and checks
four things: the comparator trips in that cycle, the trip holds after the
cause has gone, a reset clears it, and the outputs are clean afterwards. The
outputs it checks are:

| Output | Path it covers | Since |
|--------|----------------|-------|
| `nmi_fault_o` | The compare and trip logic | Revision 1.0 |
| `safe_state_o`, `bus_valid_o` | The state register and the gate | Revision 1.0 |
| `fault_o` | The registered fault that drives the `nmi_fault_o` pin and MEI | **R2.4**. Before this, a fault in the reporting path was latent |

**Also R2.4: a time limit.** A healthy test takes 288 clocks. One still running
8 clocks after that ends as a failure, so a sequencer stuck busy is reported
on the pin instead of holding the SoC in reset without saying why.

A failed or unfinished test never grants bus permission: the cores stay in
reset, `actuator_safe_o` stays high, and `nmi_fault_o` rises once the test has
failed or run out of time.

| Demonstration | Test |
|---------------|------|
| A latent compare failure is caught at startup | `tb_comparator_self_test.stuck_at_no_error_stops_the_cores`, `tb_soc_lockstep.comparator_stuck_at_no_error_keeps_the_soc_safe` |
| A failure in the error-reporting path is caught at startup | `tb_comparator_self_test.a_registered_fault_stuck_either_way_stops_the_cores` (new; it needs the new `fault_i` input, so has no earlier equivalent) |
| A stuck sequencer is reported | `tb_comparator_self_test.a_sequencer_that_never_finishes_reports_a_failure`, `tb_soc_lockstep.a_self_test_that_never_finishes_keeps_the_soc_safe_and_reports_it`. Both failed before the time limit: `failed_o` and the pin stayed 0 |

Two mutants keep these in force: `test: registered fault not checked` and
`test: no time limit`.

## Maximum diagnostic interval

The comparator is tested only after a cold reset. A fault that appears later
stays hidden until the next one, and it matters only if a second fault, a real
divergence, then needs the comparator. So the latent-fault interval is the
time between cold resets.

That depends on the item. If the ECU is cold-reset at every key-on, the
interval is one drive cycle, the usual assumption for a multiple-point fault
detection interval. If the item runs for long periods without a power cycle,
the interval grows with it. The integrator has to state the duty cycle
(roadmap milestone 5). Until then, this record assumes a cold reset at least
once per drive cycle.

## Shortening it: options

Resource figures are Yosys `synth_xilinx` estimates for 7-series, with FSM
extraction off, from GHDL's netlist. Vivado has no devices installed here, so
these are not Vivado numbers. They are close enough to compare the options.

| Block | LUTs | Flip-flops |
|-------|------|------------|
| `lockstep_comparator` | about 135 | 9 as written (Yosys merges them to 3, see `docs/verification/synthesis.md`) |
| `comparator_self_test` | about 150, plus 5 CARRY4 | about 29 |
| `soc_bus_fabric` | about 86 | 7 |

| | A. Periodic proof test | B. Redundant comparator |
|-|------------------------|-------------------------|
| What it is | Rerun the startup test while the system is held in a safe state | A second comparator on the same buses, with independent state. The bus opens only if both open, either one's trip is a fault, and a disagreement between their decisions is a fault too |
| Diagnostic interval | The proof-test period, chosen by the integrator | Continuous for a comparator that has failed tripped. A comparator stuck at "no error" is found when the other one trips on a real divergence, which is still a safe outcome, so a dangerous failure needs both to fail |
| Area | Small: a request path and a little sequencing | About 135 LUTs and 9 flip-flops more, plus a few LUTs to cross-check |
| Latency | None in normal operation | None: both compare in the same cycle |
| Cost to the application | The cores restart for each test. The self-test needs both cores in reset, so a proof test is a planned warm restart, about 300 clocks (6 µs at 50 MHz) plus the boot, with the actuators safe throughout | None |
| Needs from the item | A quiescent window, and a reason to accept a restart | Nothing |

**Recommendation:** B, keeping the startup test for both comparators. It
removes the dependence on the duty cycle at a cost of under 1% of a 100T
device's LUTs, and does not interrupt the application. A suits an item that
already restarts on a schedule. Neither is built yet. B changes the top level,
the self-test and the formal harnesses, so it is the next step once the
target's area budget is known.

## Not covered

| Item | Status |
|------|--------|
| The self-test's injection path (`w_core_b_compared` XOR) | An injection stuck on after the test makes the comparator trip, which is safe. One stuck off is caught by the next startup test |
| Pin drivers and the board | Outside the RTL (roadmap R3.2) |
| Self-test sequencer state distance | `r_step` is an enumerated type; its encoding in the mapped design is not checked |
