# Toolchain: GHDL, Vivado's xsim and VSG

How the regression runs, on which simulators, how style is checked, and what
became of each idea in the September 2026 development notes.

## Running the regression

```bash
cd sim
python run.py               # GHDL lint, VSG, then every test on every simulator found
python run.py --sim ghdl    # GHDL only (what CI runs)
python run.py --sim xsim    # Vivado's xsim only
python run.py --sim both    # both, and fail if Vivado is missing
python run.py --list        # every bench.test, without running anything
python run.py "tb_soc_ecc.*"            # one bench; patterns take * and ?
python run.py --lint        # GHDL lint only, then exit
python run.py --vsg         # VSG only, then exit
python run.py --vsg-fix     # let VSG fix what it can, then exit
python run.py --compile     # analyse and elaborate only
python run.py --coverage    # xsim only: code coverage of the RTL, in sim/out/coverage
python run.py -p 4 -x out/regression.xml   # four jobs, with an xUnit report
```

`--sim auto`, the default, runs GHDL and, when Vivado is found, xsim as well.
`LOCKSTEP_NO_LINT=1` skips the lint gates, as the mutation and fault campaigns
do. Every bench `sim/tb/tb_*.vhd` runs without being named: `run.py` reads
each bench's tests from its `run("...")` calls.

GHDL is found from `GHDL_BIN` (the folder holding `ghdl`), then on Windows
`C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin` or `C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64\bin`,
then `ghdl` on PATH, which is how CI finds it on Linux. Vivado is found from
`VIVADO_BIN` (its bin folder), `XILINX_VIVADO`, `xvhdl` on PATH, then the
default install folders (`C:\AMDDesignTools\*\Vivado\bin`, `C:\Xilinx\...`,
`/tools/Xilinx/...`, `/opt/Xilinx/...`).

## The test framework

The benches use no VUnit or OSVVM. They are plain VHDL-2008 on two packages
in `sim/tb/lib`, which both GHDL and xsim compile:

| Package | What it gives a bench |
|---------|-----------------------|
| `tb_pkg` | The runner: `test_runner_setup(g_test)`, `while test_suite loop`, `if run("name")`, `test_runner_cleanup`, `test_runner_watchdog(t)`; checks `check`, `check_equal` (std_logic, vectors, integers, booleans), `fail`; `info` for log lines |
| `tb_random_pkg` | `t_random`, a Park-Miller generator (Schrage's method) that draws the same numbers on every simulator, seeded from a string; and a coverage store: bins, crosses, `sample`, `is_covered`, `rand_uncovered` for coverage-driven stimulus |

Each simulation runs one test. `run.py` names it with the generic `g_test`
(on xsim through an option file, since the `.bat` wrapper splits `k=v` at the
`=`), and the bench also reads `tb_select.txt` in its working folder. A bench
prints one line per event:

```
TB INFO <time> <message>
TB PASS <test>
TB FAIL <time> <message>
TB SKIP <test>: <reason>
```

A test passes only on its `TB PASS` line. Any `TB FAIL`, any assertion of
severity error (GHDL runs with `--assert-level=error`; on xsim `run.py`
looks for `Error:` lines), or no result line at all (a watchdog timeout or a
crash) fails it.

A test named `assertion_*` makes an RTL assertion fire on purpose, and says
which with `expect_assertion("<message>")` (printed as `TB EXPECT`). `run.py`
runs it with assertion errors allowed, and passes it only if each expected
message appears as an assertion error and no other error does. There is one
for each of the RTL's 34 assertions, so each is shown to work
(`docs/verification/coverage.md`).

`sim/tb/lib/tb_pkg_check.vhd` tests the framework itself: a test that passes,
a failed `check_equal`, a failed `check`, an assertion of severity error, a
test that never finishes, a test name the bench does not have, and a force
that must hold until its release. Each test's name says what the runner must
make of it (`expect_pass_`, `expect_fail_`), and the runner counts it as
passed only when that is what happened, on each simulator.

### Forces on xsim

xsim cannot elaborate a VHDL-2008 `force` or `release`, but its Tcl
`add_force` and `remove_forces` can force a signal. For xsim, `run.py`
compiles a copy of each bench that forces (under `sim/out/xsim/<build>/lib/
tcl_force/`) in which each `target <= force value;` becomes
`tb_force("<path>", target, value);` and each release `tb_release("<path>");`:

- The path is the target's xsim object path. `run.py` reads it from the
  external-name alias the target names (the latest one declared above the
  statement): instances joined by `/`, a generate scope as an extended
  identifier (`\core_complex_gen(0)\`), a record field after `.`, and an index
  or slice in parentheses with `:` for a range, which the bench evaluates.
  A target that is not an alias is a signal of the bench itself.
- `tb_force` (in `tb_pkg`, one overload per type, chosen by the target) writes
  the path, the radix and the value to `tb_force.txt` with the time, and calls
  `std.env.stop`. The run's Tcl script applies it with `add_force` (or
  `remove_forces`), and runs on to the stop time.
- A bench that forces is elaborated with `--debug typical`, which `add_force`
  needs; the rest keep `--debug off`. The run has no `--onfinish quit`,
  which would end it at the first `std.env.stop`.

One difference remains: when the bench resumes after `std.env.stop`, the rest
of the design has already run the time step's remaining delta cycles. A test
that samples a signal in the same delta as a force, rather than on a clock
edge, can read it a cycle late on xsim; `tb_soc_trace` records what it needs
from a separate process for that reason. The comparison between the
simulators finds any such test.

## Two simulators, one verdict

When both simulators run, `run.py` compares them test by test. Every test run
on both must end with the same verdict and print the same `TB` lines (times
included). A difference fails the run, and `--no-compare` turns the check
off. The framework check build is left out of the comparison, since its tests
fail on purpose.

Output goes to `sim/out/<simulator>/<build>/<bench>.<test>/output.txt`. The
three builds are `check` (the framework), `sim` (every bench in `sim/tb`,
with the simulation firmware image) and `board` (`tb_board_firmware` with the
Arty board image).

### What xsim cannot do

Found with Vivado 2026.1:

| Limit | What the repository does about it |
|-------|-----------------------------------|
| VHDL-2008 `force` and `release` are "not supported yet for simulation" | Carried out through Tcl, as above |
| An aggregate with `others` as a force value has no width once the force is a `tb_force` call | Benches force a named constant of the target's width instead |
| Now and then, under load, xsim loads the snapshot and stops at its prompt without sourcing `-tclbatch run.tcl`, so nothing is simulated | `run.py` runs the test once more on exactly that sign (no `source run.tcl` in the output), and says so in the test's log; a test that ran and failed is never retried |
| `time'image` gives fs on GHDL and ps on xsim | `tb_pkg` prints times as whole ns (`time_image`), and benches do the same |
| A 64-bit record field read through an external name in a process comes out wrong (NEORV32's trace `order`, at twice its value) | `tb_soc_trace` copies the record with a concurrent assignment, which xsim reads correctly |
| External names cannot reach the ports of an instance | The benches reach internal signals instead (`w_core_a_in.ack` for a core's bus input, the register file's `rf_we` for its write port) |
| An external name inline in a statement is not found | Every external name is an alias declared at the top of its process |
| An external name through NEORV32's control record fails with the trace port on ("Cross Language external name") | No bench reaches through it |
| VUnit does not run on xsim, in 4.7.1 or 5.0 up to 5.0.0.dev15; its pointer package stops `xelab` (`VRFC 10-3457`) | The reason the benches left VUnit |

xsim also needs its `xsim.dir` in the working folder: each test's folder gets
a junction to the build's one.

### Results, 2026-11-13

| Run | GHDL 6.0 (Windows) | xsim, Vivado 2026.1 |
|-----|--------------------|---------------------|
| Tests | 340 passed of 340 | 340 passed of 340 |
| Comparison | | All 333 tests outside the framework check gave the same verdict and the same `TB` lines |

The 340 tests are 331 in the 50 benches in `sim/tb`, 7 in the framework check
and the board test. CI runs the GHDL half with GHDL 4.1 on Ubuntu 24.04.

## Code coverage

`python run.py --coverage` runs the tests on xsim with Vivado's code
coverage on: `xelab -cc_type sbct` counts statements, branches, conditions
and toggles, into one database per snapshot (a bench, or a bench and a
configuration). Every run of a snapshot adds to its database, so a
snapshot's tests run one after another; different snapshots still run side
by side. `xcrg` then reports each database on its own, and `run.py` merges
them line by line: a statement line is covered if any test ran it, and a
branch outcome (true, false, or a missing else) if any test took it. `xcrg`
can merge databases itself, but for databases with different hierarchies it
keeps one instance per file, and a line one bench covered showed as never
run. The summary (summary.md in sim/out/coverage, beside the `xcrg`
reports) gives the two figures for each first-party RTL file (`rtl/pkg`,
`rtl/safety`, `rtl/peripherals`, `rtl/soc`), every statement no test ran and
every branch outcome no test took. `python run.py --coverage-report` builds
it again from the last run's databases.

`sim/coverage_waivers.txt` leaves out lines no passing test can run, each
with its reason: an assertion's message and severity, which run only when
it fails, and code that runs at elaboration, which xsim does not count. The
summary lists the waived lines apart.

GHDL's mcode backend has no coverage. Its GCC backend can write gcov data,
but it failed 117 of the 290 tests here: it aborts in the CAN receiver bench
and dereferences NULL on external names declared before the instance they
reach, which most SoC benches use. xsim runs every test.

The figures are in `docs/verification/coverage.md`.

## Synthesis

`fpga/arty_a7_100t/build.py` still cannot build here: this Vivado reports "A
valid Vivado Design Suite ALVEO license has been detected", and `get_parts`
then returns no parts at all, although `data/installed.devices` lists the
xc7a100t. The licence is the user's to change. `build.py` says so, instead of
reporting the Tcl source as check results.

## Style: every VSG rule

`sim/vsg_config.yaml` lists all 972 rules of VSG 3.35.0 with all of their
options, generated by `tools/vsg_config.py` from the installed VSG
(`vsg -oc`), not from the documentation. 941 rules are on at severity Error;
`tools/check_fixtures.py` regenerates the file in CI, so a rule cannot be
turned off by hand.

The 31 rules that stay off, each with its reason in the YAML:

| Rules | Reason |
|-------|--------|
| `after_001`, `after_003` | They add `after 1 ns` to every assignment: a simulation-only delay that moves every register's update and the benches' sampling |
| 29 naming rules | Each is the other half of a prefix/suffix pair for the same kind of name (`constant_015` prefix `c_` against `constant_600` suffix `_c`, and so on). No name can carry both; the repository's convention is the prefix, or for ports the direction suffix |

Turned on and configured to the repository's conventions: `c_`/`st_`
constants, `w_`/`r_` signals, `v_` variables, `t_` types, `g_` generics,
`p_` processes, `i_` instances, `a_` aliases, `_i`/`_o` ports, `loop_`
labels and `lv_` loop variables, entity instantiation, `rising_edge` clocks
and the architecture names in use. NEORV32's own generic names in
`rtl/soc/lockstep_core.vhd` sit between `vsg_off generic_map_601` and
`vsg_on`.

`sim/vsg_testbench.yaml` turns three more rules off for the benches in
`sim/tb` and `sim/tb/lib` only: alias prefixes (an alias carries the name of
the RTL signal it reaches), signal prefixes (a bench signal carries the name
of the port it drives) and process length (every test of a bench runs from
one process).

## The comparator bench

The September notes suggested an OSVVM constrained-random comparator bench.
It was already in the repository as `tb_lockstep_comparator`, and checking it
turned up a real fault: its checks were OSVVM `AffirmIfEqual` calls whose
errors never reached the test result, so with its expectation inverted it
still passed. It now:

- checks with `tb_pkg`'s `check_equal`, and fails when an expectation is
  wrong (inverted on purpose, it failed at once on lane 69);
- flips one random lane of the 70 compared bits, chosen by `tb_random_pkg`'s
  coverage model among the lanes not yet hit;
- runs until every lane has been flipped and every combination of read or
  write with a matched or mismatched copy has run;
- checks, for every vector, the system bus and the fault output in the same
  cycle, the latched safe state and closed bus after the edge, and recovery
  after a cold reset;
- runs on both simulators with the same random stream and the same output.

## The September notes

| Note | Outcome |
|------|---------|
| GHDL path on Windows, then Linux | Done: `GHDL_BIN`, both Windows folders, then PATH |
| CI passing `--test` | Not present: CI calls `run.py --sim ghdl` with patterns and `-x` |
| Run every bench by wildcard | Done: every `sim/tb/tb_*.vhd` |
| `--lint` and `--vsg` that run one gate and exit, in CI | Done; `--vsg-fix`, `--list` and `--compile` the same way |
| `vunit_vivado` in place of `vunit.vivado`, xsim when Vivado is found | xsim runs every bench when Vivado is found, with no VUnit: `vunit_vivado` needs VUnit 5, imports IP and does not run xsim |
| VUnit on xsim | Not possible, so the benches left VUnit for `tb_pkg` |
| VSG: every rule group and every rule | Done: every rule defined, 941 on, the rest off for the reasons above |
| OSVVM constrained-random comparator bench | Already present; its checks now count, it covers every lane, and it runs on both simulators |
| XDC for the Arty LEDs and UART | Already present: `fpga/arty_a7_100t/arty_a7_100t.xdc`, now also with the diagnostic port on Pmod JB |
| IP Integrator for memory | Not used: the RAM is inferred from RTL, so the same source simulates and synthesises without generated IP |
| Questa Tcl flow for sign-off | Not written; untested here, with no Questa licence. `run.py`'s `Ghdl` and `Xsim` classes show the three steps (compile, elaborate, run) a third simulator would need |
| `hermes setup --portal` | Unrelated to this repository; not acted on |
