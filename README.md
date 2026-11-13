# 🏎️ lockstep-rv32-soc: Open-Source Dual-Core Lockstep RISC-V SoC

**lockstep-rv32-soc** is an open-source, vendor-agnostic, dual-core lockstep System-on-Chip (SoC) reference architecture written in **VHDL-2008**.

It is built towards **ISO 26262** functional safety for critical control units (for example steer-by-wire, brake-by-wire and safety-gate monitors). Today it is a **research prototype with simulation evidence**: no ASIL has been assessed, and the hardware metrics in `docs/safety/` are illustrative. `docs/ROADMAP.md` sets out the path to a target-backed safety case, and `docs/verification/milestone_0_1.md` records what has been verified and how.

---

## 🏗️ Core Architecture & Safety Features

Two NEORV32 RISC-V cores run the same program, core B two clocks behind core A. Everything that leaves them is compared before it can have an effect:

- **Dual-Core Lockstep (DCLS) Engine:** The comparator checks address, data, byte enables, write enable and strobe of every bus cycle. A mismatch stops that cycle before any slave sees it, latches a fault, raises the hardware fault pin `nmi_fault_o` at the next edge and makes the actuators safe. Containment does not depend on any interrupt: the cores see the fault only as a maskable MEI. A startup self-test proves the comparator before the cores start, and an illegal value of its state register is itself a fault.
- **Explicit bus responses:** Every accepted request gets exactly one response, ACK or ERR, from the slave it addressed. Unmapped addresses end in ERR and the core takes an access fault (HSI section 8.1).
- **SECDED ECC on the data RAM:** 256 KB of shared RAM in 72-bit words corrects single-bit errors and ends a load or store of an uncorrectable word with ERR, while tripping the comparator. The instruction memories have no ECC; an upset there shows up as a lockstep mismatch.
- **Windowed Hardware Watchdog:** Runs on its own clock input, with an inclusive kick window of 40,000 to 50,000 watchdog clocks, and resets the SoC through a reset network that asserts without a system clock.
- **Safe outputs:** A trip or a reset forces `actuator_safe_o` high, the CAN pin recessive and the UART pin to mark, and discards the frame or byte in progress (HSI section 8.3).

---

## 📂 Repository Directory Layout

```
├── .github/workflows/    # CI: lint, regression, evidence; PR checklist gate
├── config/               # Global types, records, and safe state definitions
├── docs/
│   ├── ROADMAP.md        # Evaluation and engineering roadmap
│   ├── safety/           # HSI, safety case, FMEDA, traceability, coding standard
│   ├── requirements/     # Technical Safety Requirements (TSR)
│   └── verification/     # Evidence records for each milestone
├── fpga/arty_a7_100t/    # Board wrapper, constraints and Vivado build (no build has run yet)
├── rtl/                  # Hand-coded VHDL-2008 source files
│   ├── top_automotive_soc.vhd  # The SoC
│   ├── lockstep_core.vhd # The one NEORV32 configuration both cores use
│   ├── core/             # NEORV32 RISC-V processor (git submodule)
│   ├── safety_blocks/    # Lockstep comparator, bus fabric, ECC RAM, watchdog, resets
│   └── peripherals/      # Safety-gated CAN controller and diagnostic UART
├── sw/include/           # Generated C register header
└── sim/                  # Verification environment (VUnit)
    ├── testbenches/      # Functional and fault-injection test suites
    ├── formal/           # SymbiYosys properties and jobs
    ├── campaign/         # Fault campaign manifests and results
    ├── firmware/         # Generated test program for the cores
    ├── generated/        # Generated CAN reference frames
    └── scripts/          # Generators, mutation harness, CI evidence scripts
```

---

## 🛠️ Toolchain

### What runs today: GHDL + VUnit
Local development and CI use **GHDL** with the **mcode** backend and the **VUnit** test runner, with the Python tools pinned in `sim/requirements.txt` (VUnit 4.7.1, VSG 3.35.0). VUnit compiles its own bundled OSVVM; the `sim/OsvvmLibraries` submodule is pinned but not compiled by the runner. CI uses Ubuntu 24.04's GHDL 4.1; the evidence in this repository was also produced with GHDL 6.0 on Windows.

### Formal, fault campaign and board checks
A separate CI job proves properties of the comparator, the bus fabric and the RAM's store commit with YoWASP Yosys and SymbiYosys (`docs/verification/formal.md`). `sim/scripts/fault_campaign.py` runs a seeded fault campaign (`docs/verification/fault_campaign.md`). `fpga/arty_a7_100t/check_board.py` checks the board wrapper and image with GHDL in CI.

### Planned: licensed simulator
Structural coverage and gate-level simulation are not part of the flow yet.

---

## 🚀 Quick Start: Running Local Verification

### Prerequisites
```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y ghdl python3 python3-pip
pip install -r sim/requirements.txt
```

`sim/run.py` uses `VUNIT_GHDL_PATH` if it is set, then `C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin` on Windows, then `ghdl` on `PATH`.

### Compiling and Executing Tests
```bash
git clone https://github.com/Coastrnaut/lockstep-rv32-soc.git
cd lockstep-rv32-soc
git submodule update --init --recursive
cd sim
python3 run.py --lint      # ghdl -Wall analysis and ghdl --synth of every block
python3 run.py --vsg       # style
python3 run.py -p 4 --xunit-xml vunit_out/regression.xml
python3 run.py "sim_lib.tb_soc_ecc.*"    # one bench
```

### Evidence checks
```bash
python3 sim/scripts/check_fixtures.py                 # generated files match their generators
python3 sim/scripts/register_map.py                   # regenerate the register constants, C header and table
python3 sim/scripts/ci_report.py manifest manifest.json
python3 sim/scripts/ci_report.py summary sim/vunit_out/regression.xml
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
2. **Tests:** New behaviour needs a test that fails without it, and new safety rules need a mutant in `sim/scripts/mutate.py`. Structural coverage is a goal that the flow cannot measure yet.
3. **Traceability:** Every new architecture file must embed a `requirement_id` attribute linking it to a TSR defined in `docs/requirements/`.
4. **Mandatory Checklist:** The PR description must contain a completed copy of the [Automotive VHDL Coding Standard Checklist](docs/safety/PR_CHECKLIST.md). The PR workflow checks that it is there, not what it says.

---

## 📄 License
This project is licensed under the **BSD 3-Clause License** — see the [LICENSE.md](LICENSE.md) file for details.
