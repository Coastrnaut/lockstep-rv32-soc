# ISA compliance: the RISC-V Architectural Certification Tests (roadmap R2.2)

## What runs

`.github/workflows/riscv-act.yml` runs the RISC-V Architectural Certification
Tests (riscv-arch-test, ACT4) through `stnolting/neorv32-riscv-act`, the
NEORV32 project's own port of them, pinned to a commit, with its NEORV32
replaced by the one this repository pins in `rtl/core/neorv32`:

| Part | What | Version |
|------|------|---------|
| Test port | `stnolting/neorv32-riscv-act` | commit `18660530588f9f7c5751c53325d6568543cc604a` |
| Tests | `riscv/riscv-arch-test`, the port's submodule | as the port pins it |
| Compiler | xPack GNU RISC-V Embedded GCC | 15.2.0-1 (the same as `sw/build.py`) |
| Reference model | Sail RISC-V | 0.16 |
| Simulator | GHDL, mcode | nightly, as the port uses |
| Device under test | NEORV32, this repository's submodule | `rtl/core/neorv32`, v1.13.7 |

The tests are generated, with their expected results, from the reference
model; each is built, run on the port's NEORV32 testbench, and passes only if
its self-check passes. The workflow runs on a change to the NEORV32 submodule,
weekly, and by hand, and keeps the summary as an artifact.

## Why this test, and what it shows

Options considered:

| Option | Verdict |
|--------|---------|
| riscv-arch-test through the NEORV32 port, with Sail (this) | **Chosen.** The official compliance suite, a reference model, and a port the NEORV32 maintainers keep working with each NEORV32 release; the same compiler as this repository |
| riscv-tests (`rv32ui-p-*`) on the lockstep SoC | Self-checking, but not the compliance suite, and not checked against a model |
| Porting ACT to run inside the lockstep SoC | Would test the SoC's configuration through the comparator, but needs a harness of its own (signature dump through the RAM, larger IMEM images) for little extra: the comparator does not change what an instruction does |
| A Spike co-simulation | Needs a trace bridge; the trace comparison of `docs/verification/trace.md` already checks the two cores against each other |

What it shows: the NEORV32 RTL at the revision both lockstep cores use
executes the ISA as the specification and the Sail model say. The port's
testbench configures NEORV32 with many more extensions (M, C, U, the B and
K extensions, PMP, counters) than the SoC's cores have
(`rv32i_zicsr_zifencei`, `rtl/soc/lockstep_core.vhd`). The RTL is the same,
and the base ISA, Zicsr and Zifencei the SoC uses are among the tests.

What it does not show: that the SoC's own configuration, its bus fabric or
its comparator are compliant. Those are this repository's own benches,
formal proofs and trace comparison.

## Result

| Run | NEORV32 | Tests | Passed | Failed |
|-----|---------|------:|-------:|-------:|
| 2026-11-13, Actions run 43512072076 | v1.13.7 (`b1f30724`), the submodule's pin now | 347 | **347** | 0 |
| 2026-11-13, Actions run 43494618381 | `4d6eaf3f` (v1.13.5), the pin then | 347 | 346 | 1 |

On v1.13.5 the one failure was `Sm_mcsr_cntr-00`; the history follows.

The one failure is `Sm_mcsr_cntr-00`, a machine-mode counter CSR test: at
this revision NEORV32's counter CSRs increment during a CSR write to them.
Upstream fixed it after our pin, in `stnolting/neorv32` commit `90a4c867`
("[counter CSRs] do not increment during CSR-write", #1654). **It cannot
reach the SoC:** its cores are built without the counter extension
(`RISCV_ISA_Zicntr` is off in `rtl/soc/lockstep_core.vhd`), so they have no
counter CSRs.

The workflow therefore passes only when every failure is listed, with its
reason, in `.github/act_known_failures.txt`, and fails on any other failure,
and on a listed test that passes again, so the list cannot go stale. Moving
the NEORV32 submodule to a revision with the fix (the ACT port's own pin,
`b1f30724`, is 209 commits on) would empty the list; it is a change of its
own, with the whole regression to rerun. It was done: the submodule is now
at v1.13.7, the regression, coverage and mutation checks were rerun on it,
all 347 tests pass, and the list of known failures is empty.
