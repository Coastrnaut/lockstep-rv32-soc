# 🏎️ ASIL-V: Open-Source ISO 26262 ASIL-D Reference Hardware Platform

**ASIL-V** is a fully open-source, vendor-agnostic, dual-core lockstep System-on-Chip (SoC) reference architecture written in pure, deterministic **VHDL-2008**.

Designed specifically to address **ISO 26262 ASIL-D** functional safety requirements, this project provides automotive OEMs, Tier-1 suppliers, and researchers with an auditable, hardware-hardened computational core for critical control units (e.g., steer-by-wire, brake-by-wire, and autonomous safety-gate monitors).

---

## 🏗️ Core Architecture & Safety Features

The processor platform wraps twin open-source 32-bit RISC-V cores in a high-integrity hardware layer featuring three independent, hardware-level diagnostic and mitigation mechanisms:

- **Dual-Core Lockstep (DCLS) Engine:** A cycle-by-cycle VHDL comparator tracks internal processing lines. It isolates faults and trips a Non-Maskable Interrupt (NMI) within **2 clock cycles** of a computational divergence.
- **Memory Bus SECDED ECC:** Wraps RAM and Flash channels with a strict Hamming matrix to dynamically patch Single-Bit Errors (SBE) and flag Double-Bit Errors (DBE).
- **Windowed Hardware Watchdog:** Runs on a dedicated, independent internal RC oscillator to capture infinite software loops or primary clock network failures.
- **Sealed State Machines:** Every Finite State Machine (FSM) features explicit, high-Hamming-distance safe binary encodings to resist radiation-induced Single Event Upsets (SEU).

---

## 📂 Repository Directory Layout

```
├── .github/workflows/    # CI/CD pipelines (Auto-linting & regression testing)
├── config/               # Global types, records, and safe state definitions
├── docs/
│   ├── safety/           # Safety Case, HSI, and FMEDA analysis
│   └── requirements/     # Functional & Technical Safety Requirements (FSR/TSR)
├── rtl/                  # Hand-coded VHDL-2008 source files
│   ├── core/             # NEORV32 RISC-V processor (git submodule)
│   ├── safety_blocks/    # Lockstep comparators, ECC wrappers, watchdogs
│   └── peripherals/      # Fault-hardened CAN-Bus and diagnostic UART interfaces
└── sim/                  # Verification environment (VUnit)
    ├── testbenches/      # Functional and fault-injection test suites
    └── scripts/          # Automation tool and coverage collection wrappers
```

---

## 🛠️ Hybrid Toolchain & Compliance Strategy

To deliver an agile open-source development pipeline while meeting strict **ISO 26262 Part 8 Tool Qualification** requirements, this project utilizes a dual-simulator strategy:

### 1. Local Development & CI (GHDL + VUnit)
For daily coding, local refinement, and automated GitHub actions, the pipeline uses **GHDL** (LLVM backend) paired with the **VUnit** Python test runner. This layer rapidly intercepts syntax anomalies, typing mismatches, and regression errors.

### 2. Regulatory Certification Gate (Siemens Questa One Sim)
For official safety sign-off, the exact same standard-compliant VHDL files are processed through a pre-certified commercial simulator. This layer runs the **OSVVM functional coverage matrix** and executes formal **Fault Injection Campaigns** to calculate the mandatory **SPFM (>99%)** and **LFM (>90%)** metrics required for ASIL-D.

---

## 🚀 Quick Start: Running Local Verification

### Prerequisites
```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y ghdl python3 python3-pip
pip install vunit_hdl
```

### Compiling and Executing Tests
```bash
git clone https://github.com/Coastrnaut/lockstep-rv32-soc.git
cd lockstep-rv32-soc
git submodule update --init --recursive
python3 sim/run.py --compile
python3 sim/run.py
```

---

## 📋 Contribution Guidelines & Pull Request Policy

All Pull Requests must meet the following entry criteria:

1. **Zero Linting Failures:** Code must compile cleanly under VHDL-2008 strict rules.
2. **100% Coverage:** New blocks must achieve 100% statement, branch, and state coverage.
3. **Traceability:** Every new architecture file must embed a `requirement_id` attribute linking it to a TSR in `docs/requirements/`.
4. **Mandatory Checklist:** The PR description must contain a completed copy of the [Automotive VHDL Coding Standard Checklist](docs/safety/PR_CHECKLIST.md).

---

## 📄 License
This project is licensed under the **BSD 3-Clause License** — see the [LICENSE.md](LICENSE.md) file for details.
