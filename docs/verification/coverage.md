# RTL code coverage

Statement and branch coverage of every first-party RTL file (`rtl/pkg`,
`rtl/safety`, `rtl/peripherals`, `rtl/soc`) over the whole regression,
2026-11-13: 333 tests on Vivado 2026.1's xsim, all passing, on NEORV32 v1.13.7.

    python sim/run.py --coverage          # every test, then the summary
    python sim/run.py --coverage-report   # the summary again, from the last run's databases

## Result

**Every statement line and every branch outcome is covered, with nothing waived.**

| File | Statement lines | Branch outcomes |
|------|------:|------:|
| `rtl/peripherals/automotive_can_controller.vhd` | 326 of 326 (100.0 %) | 263 of 263 (100.0 %) |
| `rtl/peripherals/can_receiver.vhd` | 152 of 152 (100.0 %) | 107 of 107 (100.0 %) |
| `rtl/peripherals/safe_uart.vhd` | 92 of 92 (100.0 %) | 59 of 59 (100.0 %) |
| `rtl/pkg/package_soc_types.vhd` | - | - |
| `rtl/safety/actuator_monitor.vhd` | 19 of 19 (100.0 %) | 15 of 15 (100.0 %) |
| `rtl/safety/clock_monitor.vhd` | 26 of 26 (100.0 %) | 18 of 18 (100.0 %) |
| `rtl/safety/comparator_self_test.vhd` | 65 of 65 (100.0 %) | 53 of 53 (100.0 %) |
| `rtl/safety/dual_comparator.vhd` | 24 of 24 (100.0 %) | 14 of 14 (100.0 %) |
| `rtl/safety/ecc_data_ram.vhd` | 119 of 119 (100.0 %) | 83 of 83 (100.0 %) |
| `rtl/safety/hamming_ecc_wrapper.vhd` | 84 of 84 (100.0 %) | 50 of 50 (100.0 %) |
| `rtl/safety/hardware_watchdog.vhd` | 38 of 38 (100.0 %) | 27 of 27 (100.0 %) |
| `rtl/safety/lockstep_comparator.vhd` | 66 of 66 (100.0 %) | 49 of 49 (100.0 %) |
| `rtl/safety/reset_synchronizer.vhd` | 12 of 12 (100.0 %) | 8 of 8 (100.0 %) |
| `rtl/safety/soc_bus_fabric.vhd` | 57 of 57 (100.0 %) | 40 of 40 (100.0 %) |
| `rtl/safety/telemetry_port.vhd` | 16 of 16 (100.0 %) | 14 of 14 (100.0 %) |
| `rtl/safety/temporal_diversity.vhd` | 9 of 9 (100.0 %) | 3 of 3 (100.0 %) |
| `rtl/safety/watchdog_supervisor.vhd` | 75 of 75 (100.0 %) | 52 of 52 (100.0 %) |
| `rtl/soc/lockstep_core.vhd` | - | - |
| `rtl/soc/top_automotive_soc.vhd` | 32 of 32 (100.0 %) | - |
| **All** | 1212 of 1212 (100.0 %) | 855 of 855 (100.0 %) |
| `rtl/safety/hamming_ecc_wrapper.vhd` | 70 | `v_position   := 3;` |

`package_soc_types.vhd` holds types and constants only, and `lockstep_core.vhd`
only instantiates NEORV32, so neither has a statement of its own. The top
level's statements are concurrent assignments, with no branches.

## How it is measured

`xelab -cc_type sbct` gives each snapshot (a bench, or a bench and a
configuration) its own coverage database, which every run of that snapshot
adds to; `run.py` runs a snapshot's tests one after another, and different
snapshots side by side. `xcrg` reports each database on its own, and
`run.py` merges them line by line: a statement line is covered if any test
ran it, and a branch outcome (true, false, or a missing else) if any test
took it. (`xcrg` can merge databases itself, but for databases with
different hierarchies it keeps one instance per file, and loses the rest.)

Three kinds of line needed more than ordinary tests:

| Lines | Kind | How they are covered |
|------:|------|----------------------|
| 68 | The `report` and `severity` lines of the RTL's 34 assertions, which run only when an assertion fails | 32 `assertion_` tests, one for each assertion or group, force the inconsistency the assertion guards against and expect exactly its message. `sim/run.py` passes such a test only if every expected message appears as an assertion error and no other error does (`expect_assertion` in `tb_pkg`). So the tests also show that every check in the RTL works |
| 9 | The ECC wrapper's bit-position table, a function that runs only while the design is elaborated, which xsim does not count | `run.py --coverage` elaborates the wrapper with GHDL's GCC backend and gcov, and counts the lines that elaboration ran. Elaboration needs neither of that backend's two defects (below). If no GHDL GCC backend is found, these lines are listed as waived, with their reason, from `sim/coverage_waivers.txt` |
| 2 | The UART state machine's `when others` arm | The state is now an explicit 2-bit encoding instead of an enumerated type: an upset into its unused value reaches the arm, and `tb_uart_parity_fault.an_upset_into_the_unused_state_goes_back_to_idle_at_mark` shows it returns to idle with the pin at mark |

The clock monitor's divider width was a function too; it is now one
constant expression, so it has no lines to cover.

Three small RTL changes made assertions on output ports testable, with no
change in behaviour: the watchdog's reset (`w_sys_reset`), the CAN pin's
gate (`w_tx_gate`) and the self-test's running flag (`w_running`) are named
signals, and the assertions check them. Before, each assertion compared a
port with the very signals it was computed from, so no fault could make
it fire, and no test could show it works.

Earlier, two UART states, `uart_parity` and `uart_stop`, could never be
entered: the data state shifts the parity and stop bits out of the same
register. They were removed with no change in behaviour.

## GHDL's GCC backend

GHDL's mcode backend, which the regression uses, has no coverage. Its GCC
backend writes gcov data, but runs 117 of the tests wrongly: it dereferences
NULL when a `force` targets an external name, and when an external name in a
process is resolved before the instance it reaches is elaborated; and it
aborts without a message in the CAN receiver bench. Most fault-injection
tests need both forces and external names, so the backend is used only for
elaboration, which it does correctly. The defects are GHDL's; mcode and xsim
run every test.

## What this does and does not show

It shows that every statement and branch outcome of the first-party RTL is
run by some passing test, and that every assertion in it fires when its
property is broken. It does not show that each test checks the effect of
every line it runs: the mutation harness (`sim/scripts/mutate.py`, 463
mutants) is the measure of that.

Not measured: condition coverage (MC/DC), FSM state and transition coverage,
and toggle coverage of the whole SoC, which `docs/verification/specification.md`
sets as targets for a qualified flow. xsim collects condition and toggle data
too; its reports are in sim/out/coverage/xcrg after a run, but they are not
merged across snapshots. NEORV32 is not in the figures: its own tests and
the RISC-V ACT (`docs/verification/isa_compliance.md`) cover it.
