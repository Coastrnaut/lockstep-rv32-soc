# ============================================================================
# Safety Case Document — lockstep-rv32-soc
# ============================================================================
# ISO 26262 Part 4: Evidence of Compliance
# Document ID: SC-LRS-001
# Revision: 1.1
# ============================================================================

## 1. EXECUTIVE SUMMARY

The lockstep-rv32-soc dual-core lockstep SoC is a dual-core RISC-V research
platform built towards automotive safety-critical use. Revision 1.0 of this
document concluded that the hardware was suitable for integration into ASIL-D
systems. That claim is withdrawn. What exists today is:

1. Hardware safety mechanisms in RTL: lockstep with a startup self-test,
   temporal diversity, ECC on the shared data RAM, a windowed watchdog, an
   explicit bus response contract and safety-gated CAN and UART pins
2. Simulation evidence: 49 benches with 321 tests, each run on GHDL and
   on Vivado's xsim with identical output, directed fault
   injection by forcing named signals, clocked simulation assertions and a
   mutation harness
3. Illustrative hardware metrics, not derived from a target (section 4)
4. Traceability from safety goals through TSRs to named tests

A reference item, a torque-enable supervisor for an EV traction inverter,
is defined with its hazard analysis, safety goals, FTTI and assumptions of
use in `docs/safety/item_definition.md`; a real product replaces it with its
own. An ASIL claim needs a defined item, a selected target, an FMEDA and
dependent-failure analysis built from that target, formal and post-route
evidence, bench measurements and independent assessment. Section 7 lists what
is missing.

---

## 2. SAFETY GOALS & EVIDENCE

| Safety Goal | Requirement | Evidence (simulation) | Status |
|-------------|-------------|------------------------|--------|
| SG-01: Prevent unintended motion | The comparator closes the bus and makes the actuators safe, independent of interrupts; CAN goes recessive and UART to mark | tb_lockstep_comparator, tb_lockstep_fault_inject, tb_lockstep_illegal_state, tb_soc_lockstep, tb_uart_abort, tb_soc_reset_network | Sim |
| SG-02: Detect computational divergence | Dual-core lockstep, compared within 2 cycles of the comparator seeing it | tb_lockstep_comparator, tb_temporal_diversity, tb_soc_lockstep | Sim. Divergence that stays inside a core until a later access is caught by the trace comparison in verification builds (`docs/verification/trace.md`); in the product it is found only when it reaches the bus |
| SG-03: Detect memory corruption | SECDED ECC on the data RAM; an uncorrectable word ends the access with ERR and trips the comparator. The instruction memory has none: each core has its own copy, so the comparator catches an upset there once it reaches the bus | tb_ecc, tb_ecc_exhaustive, tb_ecc_fault_inject, tb_ecc_data_ram, tb_soc_bus_fabric, tb_soc_ecc, tb_telemetry_port. Stored single-bit errors are written back and patrolled, and the first fault is readable over a read-only port with the bus shut (`docs/verification/memory_protection.md`) | Sim |
| SG-04: Detect software lockup | Windowed watchdog on its own clock, inclusive window | tb_watchdog, tb_watchdog_window, tb_watchdog_supervisor, tb_soc_watchdog | Sim. Watchdog clock loss is an open board requirement (HSI WD-04) |
| SG-05: Ensure fault-free communication | Safety-gated CAN and parity UART | tb_can, tb_can_receive, tb_uart, tb_uart_abort | Sim. Supported subset in `docs/verification/can_support.md`; no bench interoperability yet (roadmap R4.2) |

---

## 3. VERIFICATION SUMMARY

### 3.1 Functional Testbenches
- `tb_lockstep_comparator` — Mismatch detection, NMI assertion, safe state latch
- `tb_ecc` — SBE correction, DBE detection, clean path validation
- `tb_ecc_exhaustive` — Every single and double bit flip in the 72-bit word
- `tb_ecc_data_ram` — RAM access, read-modify-write, error registers, flips on loads and stores
- `tb_soc_bus_fabric` — One response per accepted request, ACK or ERR, against a model with seeded random traffic
- `tb_soc_fabric` — The same through firmware loads and stores, and a warm reset between acceptance and commit
- `tb_soc_ecc` — Correction and lock-up on the running SoC, and ERR with an access fault on an uncorrectable load or store
- `tb_watchdog`, `tb_watchdog_window` — Kicks at MIN-1, MIN, MAX-1, MAX and the timeout
- `tb_watchdog_supervisor` — Register access, clock crossings and the window boundaries at four clock ratios
- `tb_soc_watchdog` — Firmware kicks, timeouts and early kicks on the running SoC
- `tb_can` — Frame TX, safety gate drop, mailbox load
- `tb_can_receive` — Reception from reference model frames, error flags, resynchronisation
- `tb_uart`, `tb_uart_abort` — Parity-protected TX, error flagging, abort to mark

### 3.2 Fault Injection Testbenches
- `tb_lockstep_fault_inject` — Stuck-at and bit-flip on core bus
- `tb_lockstep_illegal_state` — Every one-bit corruption of both comparator encodings
- `tb_soc_lockstep` — The same glitch on both cores at once, a store the cores disagree on, a trip in a UART byte and a CAN frame, a trip with MIE and MEIE masked, and every one-bit corruption of the comparator state through a watchdog and a cold reset
- `tb_comparator_self_test` — A comparator broken each way the startup test has to catch
- `tb_ecc_fault_inject` — Single/double bit injection on data path

All injection is by VHDL-2008 `force` on named RTL signals in simulation.

### 3.3 Simulation Assertions
The RTL carries clocked assertions, named "FORMAL" in their messages, which
the simulator checks on every run. They have not been run through a formal
tool. A first proof job is roadmap R2.1.
- Lockstep comparator: NMI within 2 cycles, bus isolation, safe state latch, illegal state handled as a fault
- Bus fabric: ACK and ERR exclusive, no response without a request, no data with ERR, one-hot target
- ECC wrapper: SBE/DBE mutual exclusion, zero syndrome = no error
- Watchdog: Reset on timeout, early kick detection
- CAN: TX recessive on safety gate drop
- UART: Parity blocks TX, error flagged on mismatch, mark with the gate closed

### 3.4 Mutation Testing
Coverage shows that a line ran, not that a test would notice it change.
`sim/scripts/mutate.py` breaks one rule in the RTL at a time and runs the
regression against each break. A mutant counts as caught only when at least
one test fails.

Historical result, kept for provenance: on 2026-11-07, against the RTL and
testbenches of commit `057c639`, the regression caught all 386 mutants then
defined. Milestone 1 changed the comparator, UART, watchdog, RAM and top level,
re-pointed the affected patterns so each keeps its original meaning, and added
mutants for the new rules, for 412 in all. The targeted sample run on those
changes is recorded in `docs/verification/milestone_0_1.md`. A full campaign is
not in CI, because it takes hours of CPU. Rerun it before a release.

On 2026-11-13, after the benches moved to `tb_pkg` and the redundant
comparator was built, there are 439 mutants. Every new one (seven `dual:`
and two `regmap:`) was run and killed, and a
one-tenth sample of all of them (`mutate.py --shard 1/10`, 44 mutants)
killed all 44.

Later on 2026-11-13, comparator B was given its own reset, delay line and
injection point, and the system clock a monitor (TSR_CLOCK_001): 451 mutants.
The twelve new ones (five `dual:` for the shared causes, seven `clock:`) and
the nine whose patterns had to follow the RTL were run, and all 21 killed.

After the actuator channels, the move to NEORV32 v1.13.7, the explicit UART
state encoding and the assertion tests, there are 458 mutants; every one
still applies, and the UART, CAN, self-test, watchdog and clock monitor
mutants, whose code changed, were all rerun and killed.

---

## 4. HARDWARE METRICS (ILLUSTRATIVE)

These values are not evidence of compliance. They came from revision 1.0 of
this document and of `docs/safety/fmeda_analysis.md`, which disagree with each
other, and neither derives from a selected target, a mission profile or a
classified failure-mode list.

| Metric | This document, rev 1.0 | FMEDA summary table, rev 1.0 | Reference ASIL-D target |
|--------|------------------------|------------------------------|-------------------------|
| SPFM   | 96.76%                 | 99.2%                        | ≥ 99%                   |
| LFM    | 98.92%                 | 97.8%                        | ≥ 90%                   |
| PMHF   | 1.53×10⁻⁹ /h          | 3.2×10⁻⁹ /h                 | < 10⁻⁸ /h (10 FIT)      |
| DC     | 95.6%                  | 92%                          | —                       |

Revision 1.0 printed 90% and 60% as the ASIL-D SPFM and LFM targets, which are
the ASIL-B values. The FMEDA's own formulas do not reproduce its inputs either,
as `docs/ROADMAP.md` records: its LFM ratio evaluates to 99.86%, and its PMHF
expression to 1.525×10⁻¹¹/h. Section 7 lists what a real calculation needs.

The replacement is `docs/safety/fmeda_inputs.csv`: 25 classified failure modes,
each with its mechanism, diagnostic interval and evidence, checked by
`tools/fmeda.py`. Its failure rates and coverages stay TBD until a target
and a failure-rate source are chosen, and until then it computes no metric.

---

## 5. TRACEABILITY

Bi-directional traceability from safety goals → FSR → TSR → RTL → test is
maintained in `docs/safety/traceability_matrix.md`, and from each requirement
of the implemented contract to its test and result in
`docs/safety/evidence_index.md`. CI checks that every test, property and file
these documents cite exists (`tools/check_evidence.py`). All RTL files carry VHDL
traceability attributes (`requirement_id`), and every ID they name is defined
in `docs/requirements/tsr_safety_core.md`.

---

## 6. RESIDUAL RISK ASSESSMENT

| Residual Risk | Mitigation in RTL | Remaining work |
|---------------|-------------------|----------------|
| Common cause failure in lockstep | Core B 2 clocks behind core A; ECC on the shared RAM | Shared read data from peripherals, decode, clock, power and reset have no independent check. Each is listed in `docs/safety/dependent_failure_analysis.md` |
| Watchdog oscillator failure | None in the SoC | Independent board supervisor (HSI WD-04) |
| Instruction fetch corruption | Lockstep detects it once it changes a bus access | No IMEM ECC; private CPU state stays latent until used (trace comparison sees it in verification builds only) |
| Latent comparator fault after startup | Two comparators cross-checked every clock, each proved by the startup self-test (TSR_LOCKSTEP_045) | Both comparators share clock, reset and inputs (DF-15) |
| Power supply transient | Watchdog on its own clock | Target-specific analysis |
| Faults after the comparator | Actuator: read-back and a second channel (TSR_ACTUATOR_001); CAN: bit monitoring and CRC | A line stuck at "permit" is latent until the next demand or start, when the second channel acts; the UART is diagnostic only; FMEDA FM-19, FM-20, FM-22 |

---

## 7. CONCLUSION

The lockstep-rv32-soc is a research prototype. Its RTL implements the
fault-containment contract of HSI section 8, and simulation checks each part of
that contract with named tests. It is not shown to satisfy ISO 26262 at any
ASIL. That needs, at least:

- a defined item, assumptions of use and hazard-derived FTTI and diagnostic intervals
- a selected target, with post-route timing, preserved redundancy and bench measurements of fault-to-pin times
- an FMEDA built from that target's failure rates, with classified failure modes and diagnostic coverage traced to analysis or campaigns
- dependent-failure analysis of clocks, power, reset, configuration memory and synthesis
- formal results for the comparator, bus response and safety gate
- tool-confidence evidence for the simulator, synthesis and the scripts relied on
- independent review
