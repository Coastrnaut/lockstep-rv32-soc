# 🏎️ lockstep-rv32-soc: Open-Source Dual-Core Lockstep RISC-V SoC

**lockstep-rv32-soc** is an open-source, vendor-agnostic, dual-core lockstep System-on-Chip (SoC) reference architecture written in **VHDL-2008**.

It is built towards **ISO 26262** functional safety for critical control units (for example steer-by-wire, brake-by-wire and safety-gate monitors). Today it is a **research prototype with simulation evidence**: no ASIL has been assessed, and the hardware metrics in `docs/safety/` are illustrative. `docs/ROADMAP.md` sets out the path to a target-backed safety case, and `docs/verification/milestone_0_1.md` records what has been verified and how.

---

## 🏗️ Core Architecture & Safety Features

Two NEORV32 RISC-V cores run the same program, core B two clocks behind core A. Everything that leaves them is compared before it can have an effect:

- **Dual-Core Lockstep (DCLS) Engine:** The comparator checks address, data, byte enables, write enable and strobe of every bus cycle. A mismatch stops that cycle before any slave sees it, latches a fault, raises the hardware fault pin `nmi_fault_o` at the next edge and makes the actuators safe. Containment does not depend on any interrupt: the cores see the fault only as a maskable MEI. A startup self-test proves the comparator before the cores start, and an illegal value of its state register is itself a fault.
- **Redundant comparator:** Two comparators with their own state, reset, delay line and injection point check the same buses. The bus opens only while both pass a request and agree; a disagreement between them is a fault that holds until reset, so a comparator that fails after its startup test cannot let a divergence out (`docs/verification/diagnostics.md`).
- **Explicit bus responses:** Every accepted request gets exactly one response, ACK or ERR, from the slave it addressed. Unmapped addresses end in ERR and the core takes an access fault (HSI section 8.1).
- **SECDED ECC on the data RAM:** 256 KB of shared RAM in 72-bit words corrects single-bit errors and ends a load or store of an uncorrectable word with ERR, while tripping the comparator. The instruction memories have no ECC; an upset there shows up as a lockstep mismatch.
- **Windowed Hardware Watchdog:** Runs on its own clock input, with an inclusive kick window of 40,000 to 50,000 watchdog clocks, and resets the SoC through a reset network that asserts without a system clock.
- **Safe outputs:** A trip or a reset forces `actuator_safe_o` high, the CAN pin recessive and the UART pin to mark, and discards the frame or byte in progress (HSI section 8.3).
- **Two actuator channels with read-back:** `actuator_en_o`, of the opposite polarity, must be high as well before the actuator may be powered. `actuator_safe_o` is read back at the driver on `actuator_fb_i`, and a line that does not follow its command trips the comparators (TSR_ACTUATOR_001).
- **System clock monitor:** The independent watchdog clock checks the system clock's rate. A stopped or wrong clock raises the fault pin and holds the SoC in reset, without needing the system clock (TSR_CLOCK_001, `docs/verification/clocks.md`).

---

## 📂 Repository Directory Layout

```
├── .github/workflows/    # CI: lint, regression, formal, board and firmware checks, evidence, RISC-V ACT; PR checklist gate
├── docs/
│   ├── ROADMAP.md        # Evaluation and engineering roadmap, with the status of each item
│   ├── requirements/     # Technical Safety Requirements (TSR)
│   ├── safety/           # Item definition, HSI, safety case, FMEDA inputs, DFA, traceability, evidence index
│   └── verification/     # Toolchain, coverage, ISA compliance, clocks, bench hardware, formal, fault campaign, diagnostics
├── fpga/arty_a7_100t/    # Board wrapper, constraints, Vivado build and board image (no build has run yet)
├── rtl/
│   ├── pkg/              # Types, records, safe-state encodings and the generated register map
│   ├── soc/              # The SoC top level and the one NEORV32 configuration both cores use
│   ├── safety/           # Comparators, self-test, clock and actuator monitors, bus fabric, ECC RAM, watchdog, resets, telemetry
│   ├── peripherals/      # Safety-gated CAN controller and diagnostic UART
│   └── core/             # NEORV32 RISC-V processor (git submodule)
├── sim/
│   ├── run.py            # The regression: lint, VSG, every test on GHDL and xsim, compared; code coverage
│   ├── coverage_waivers.txt  # The lines left out of the coverage figure, each with its reason
│   ├── tb/               # Benches, plain VHDL-2008
│   │   └── lib/          # tb_pkg (runner and checks), tb_random_pkg (random and coverage), CAN and trace helpers
│   ├── formal/           # SymbiYosys properties and jobs
│   ├── campaign/         # Fault campaign manifests and results
│   ├── firmware/         # Generated test program for the cores
│   ├── generated/        # Generated CAN reference frames and register-map package
│   └── scripts/          # Firmware and CAN generators, mutation, fault campaign, formal runner
├── sw/
│   ├── common/           # Startup and trap code, linker script, helpers, shared by every program
│   ├── board/            # The board program: UART, ECC RAM, CAN and watchdog checks
│   ├── hello/            # Hello, world: the smallest program, with its bench
│   ├── include/          # Generated C register header
│   └── build.py          # Builds every program's IMEM image with the pinned RISC-V compiler
└── tools/                # Register map, VSG config, fixture, evidence, FMEDA and CI report scripts
```

---

## 🛠️ Toolchain

### Simulation: GHDL and Vivado's xsim
The benches are plain VHDL-2008 with no VUnit or OSVVM: `sim/tb/lib/tb_pkg.vhd` gives them a test runner and checks, and `sim/tb/lib/tb_random_pkg.vhd` constrained-random stimulus and functional coverage, both of which GHDL and Vivado's xsim compile. `sim/run.py` runs each test in its own simulation, on GHDL (mcode) and, when Vivado is installed, on xsim too, and then checks that every test run on both gave the same verdict and printed the same lines. xsim cannot simulate VHDL-2008 `force`, so for xsim `run.py` turns each force into a Tcl `add_force`, applied while the bench pauses. CI uses Ubuntu 24.04's GHDL 4.1; the evidence here was also produced with GHDL 6.0 and Vivado 2026.1 on Windows. `docs/verification/toolchain.md` has the details.

| Simulator | Tests (2026-11-13) |
|-----------|--------------------|
| GHDL | 298 passed of 298: 289 in 48 benches, 7 testing the framework itself, the board image and hello world |
| xsim | 298 passed of 298, forces included (applied through Tcl). All 291 tests outside the framework check gave the same output as on GHDL |
| Code coverage (xsim) | 100 % of the first-party RTL's 1,131 statement lines and 850 branch outcomes, with 82 lines waived for stated reasons (`docs/verification/coverage.md`) |
| ISA (RISC-V ACT) | 346 of 347 on the pinned NEORV32; the one failure is a counter-CSR bug the SoC's cores cannot reach (`docs/verification/isa_compliance.md`) |

### Formal, fault campaign, mutation and board checks
A clock monitor on the independent watchdog clock holds the SoC safe if the system clock stops or strays (TSR_CLOCK_001). A separate CI job proves properties of the comparator, the bus fabric and the RAM's store commit with YoWASP Yosys and SymbiYosys (`docs/verification/formal.md`). `sim/scripts/fault_campaign.py` runs a seeded fault campaign (`docs/verification/fault_campaign.md`). `sim/scripts/mutate.py` holds 439 RTL mutants. `fpga/arty_a7_100t/check_board.py` checks the board wrapper and image with GHDL in CI.

### Style
VSG 3.35.0 with every one of its 972 rules defined, 941 on (`sim/vsg_config.yaml`, generated by `tools/vsg_config.py`).

### Not yet in the flow
MC/DC, FSM and toggle coverage, gate-level simulation, and a Vivado build: the installed Vivado is the Enterprise edition with only an Alveo licence (`docs/verification/bench_hardware.md` says how to fix it).

---

## 🚀 Quick Start: Running Local Verification

### Prerequisites
```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y ghdl python3 python3-pip
pip install -r sim/requirements.txt
```

`sim/run.py` finds GHDL from `GHDL_BIN`, then `C:\GIT\ghdl-mcode-6.0.0-ucrt64in` or `C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64in` on Windows, then `ghdl` on `PATH`. It finds Vivado from `VIVADO_BIN`, `XILINX_VIVADO`, `xvhdl` on `PATH` or the default install folders.

### Compiling and Executing Tests
```bash
git clone https://github.com/Coastrnaut/lockstep-rv32-soc.git
cd lockstep-rv32-soc
git submodule update --init --recursive
cd sim
python3 run.py                 # lint, VSG, every test on GHDL and (if installed) xsim, compared
python3 run.py --sim ghdl -p 4 -x out/regression.xml   # GHDL only, as CI runs it
python3 run.py --sim both      # both simulators; fails if Vivado is missing
python3 run.py "tb_soc_ecc.*"  # one bench
python3 run.py --list          # every bench.test
python3 run.py --lint          # ghdl -Wall analysis and ghdl --synth of every block
python3 run.py --vsg           # style, every VSG rule
python3 run.py --vsg-fix       # let VSG fix what it can
python3 run.py --coverage      # xsim: statement and branch coverage of the RTL, in sim/out/coverage
```

Each test's log is in `sim/out/<simulator>/<build>/<bench>.<test>/output.txt`.

### Evidence checks
```bash
python3 tools/check_fixtures.py                 # generated files match their generators
python3 tools/register_map.py                   # regenerate the register constants, C header and table
python3 tools/vsg_config.py                     # regenerate the VSG configuration from the installed VSG
python3 tools/check_evidence.py                 # every bench, test, property and file the documents cite exists
python3 tools/fmeda.py                          # check the FMEDA input table; metrics once it has rates
python3 sw/build.py --check                     # the program images are builds of sw/ (xPack GCC 15.2.0-1)
python3 tools/ci_report.py manifest manifest.json
python3 tools/ci_report.py summary sim/out/regression.xml
```

### Checking Test Strength
`sim/scripts/mutate.py` breaks one rule in the RTL at a time and checks that the regression fails. It works on a temporary copy and leaves your checkout alone. A full campaign takes hours of CPU, so CI only checks that every mutant still applies.
```bash
python3 sim/scripts/mutate.py --check      # every mutant still applies to the RTL
python3 sim/scripts/mutate.py ecc: ram:    # only the ECC and data RAM mutants
python3 sim/scripts/mutate.py              # all of them
```

---

## 📋 Contribution Guidelines & Pull Request Policy

All Pull Requests must meet the following entry criteria:

1. **Zero Linting Failures:** Code must pass `run.py --lint` and `run.py --vsg`.
2. **Tests:** New behaviour needs a test that fails without it, and new safety rules need a mutant in `sim/scripts/mutate.py`. Statement and branch coverage of the RTL must stay at 100 % (`python sim/run.py --coverage`), or the new line needs a waiver with its reason.
3. **Traceability:** Every new architecture file must embed a `requirement_id` attribute linking it to a TSR defined in `docs/requirements/`.
4. **Mandatory Checklist:** The PR description must contain a completed copy of the [Automotive VHDL Coding Standard Checklist](docs/safety/PR_CHECKLIST.md). The PR workflow checks that it is there, not what it says.

---

## 📄 License
This project is licensed under the **BSD 3-Clause License** — see the [LICENSE.md](LICENSE.md) file for details.
