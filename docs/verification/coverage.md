# RTL code coverage

Statement and branch coverage of every first-party RTL file (`rtl/pkg`,
`rtl/safety`, `rtl/peripherals`, `rtl/soc`) over the whole regression,
2026-11-13: 298 tests on Vivado 2026.1's xsim, all passing.

    python sim/run.py --coverage          # every test, then the summary
    python sim/run.py --coverage-report   # the summary again, from the last run's databases

`docs/verification/toolchain.md` says how it is measured: one coverage
database per snapshot, reported per database by `xcrg`, and merged line by
line by `run.py`, since `xcrg`'s own merge of databases with different
hierarchies keeps one instance per file. A statement line counts as covered
if any test ran it; a branch outcome (true, false, or a missing else) if any
test took it.

## Result

| File | Statement lines | Branch outcomes |
|------|------:|------:|
| `rtl/peripherals/automotive_can_controller.vhd` | 315 of 315 (100.0 %) | 261 of 261 (100.0 %) |
| `rtl/peripherals/can_receiver.vhd` | 148 of 148 (100.0 %) | 107 of 107 (100.0 %) |
| `rtl/peripherals/safe_uart.vhd` | 85 of 85 (100.0 %) | 58 of 58 (100.0 %) |
| `rtl/pkg/package_soc_types.vhd` | - | - |
| `rtl/safety/actuator_monitor.vhd` | 19 of 19 (100.0 %) | 15 of 15 (100.0 %) |
| `rtl/safety/clock_monitor.vhd` | 24 of 24 (100.0 %) | 18 of 18 (100.0 %) |
| `rtl/safety/comparator_self_test.vhd` | 58 of 58 (100.0 %) | 51 of 51 (100.0 %) |
| `rtl/safety/dual_comparator.vhd` | 22 of 22 (100.0 %) | 14 of 14 (100.0 %) |
| `rtl/safety/ecc_data_ram.vhd` | 115 of 115 (100.0 %) | 83 of 83 (100.0 %) |
| `rtl/safety/hamming_ecc_wrapper.vhd` | 71 of 71 (100.0 %) | 50 of 50 (100.0 %) |
| `rtl/safety/hardware_watchdog.vhd` | 33 of 33 (100.0 %) | 27 of 27 (100.0 %) |
| `rtl/safety/lockstep_comparator.vhd` | 54 of 54 (100.0 %) | 49 of 49 (100.0 %) |
| `rtl/safety/reset_synchronizer.vhd` | 10 of 10 (100.0 %) | 8 of 8 (100.0 %) |
| `rtl/safety/soc_bus_fabric.vhd` | 49 of 49 (100.0 %) | 40 of 40 (100.0 %) |
| `rtl/safety/telemetry_port.vhd` | 16 of 16 (100.0 %) | 14 of 14 (100.0 %) |
| `rtl/safety/temporal_diversity.vhd` | 9 of 9 (100.0 %) | 3 of 3 (100.0 %) |
| `rtl/safety/watchdog_supervisor.vhd` | 71 of 71 (100.0 %) | 52 of 52 (100.0 %) |
| `rtl/soc/lockstep_core.vhd` | - | - |
| `rtl/soc/top_automotive_soc.vhd` | 32 of 32 (100.0 %) | - |
| **All** | 1131 of 1131 (100.0 %) | 850 of 850 (100.0 %) |

`package_soc_types.vhd` holds types and constants only, and `lockstep_core.vhd`
only instantiates NEORV32, so neither has a statement of its own. The top
level's statements are concurrent assignments, with no branches.

## Waived lines

`sim/coverage_waivers.txt` leaves 82 lines out of the statement figure, each
with its reason, and only while no test runs them:

| Lines | Kind | Why no passing test runs them |
|------:|------|-------------------------------|
| 68 | The `report` and `severity` lines of 34 assertions | They run only when the assertion fails; a failing assertion fails the test |
| 13 | Two functions evaluated at elaboration: the clock monitor's divider width, the ECC code's bit-position table | xsim counts simulation, not elaboration |
| 1 | The UART state machine's `when others` arm | Every value of its enumerated state has an arm of its own, so no simulation reaches it; it stays as the coding standard's fail-safe default |

Reaching full coverage took one RTL change: the UART state machine had two
states, `uart_parity` and `uart_stop`, that it could never enter (the data
state shifts the parity and stop bits out of the same register), and a
branch in its start state that could never be taken. They were removed, with
no change in behaviour: the UART benches give the same output on GHDL and
xsim, and every mutant still applies.

## What this does and does not show

It shows that every statement and every branch outcome of the first-party
RTL is exercised by some test whose checks pass. It does not show that each
of those tests checks the effect of that line: the mutation harness
(`sim/scripts/mutate.py`, 457 mutants) is the measure of that.

Not measured here: condition coverage (MC/DC), FSM state and transition
coverage, and toggle coverage of the whole SoC, which
`docs/verification/specification.md` sets as targets for a qualified flow.
xsim collects condition and toggle data too (`-cc_type sbct`); the full
`xcrg` reports are in `sim/out/coverage/xcrg/`, but they are not merged
across snapshots. NEORV32 is not in the figures: its own tests and the
RISC-V ACT (`docs/verification/isa_compliance.md`) cover it.
