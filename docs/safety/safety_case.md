# ============================================================================
# Safety Case Document — lockstep-rv32-soc
# ============================================================================
# ISO 26262 Part 4: Evidence of Compliance
# Document ID: SC-LRS-001
# Revision: 1.0
# ============================================================================

## 1. EXECUTIVE SUMMARY

The lockstep-rv32-soc dual-core lockstep SoC is a dual-core RISC-V platform designed for
automotive safety-critical applications. This safety case demonstrates
compliance with ISO 26262 ASIL-D through:

1. Hardware safety mechanisms (lockstep, ECC, watchdog, safety-gated I/O)
2. Comprehensive verification (7 testbenches, fault injection, formal assertions)
3. Quantitative metrics (SPFM 96.76%, LFM 98.92%, PMHF 1.53×10⁻⁹ /h)
4. Full bi-directional traceability from safety goals to test results

---

## 2. SAFETY GOALS & COMPLIANCE

| Safety Goal | Requirement | Evidence | Status |
|-------------|-------------|----------|--------|
| SG-01: Prevent unintended motion | Lockstep comparator isolates actuators | tb_lockstep_comparator, tb_lockstep_fault_inject | ✅ |
| SG-02: Detect computational divergence | Dual-core lockstep within 2 cycles | lockstep_comparator.vhd formal asserts | ✅ |
| SG-03: Detect memory corruption | SECDED ECC on all memory buses | tb_ecc, tb_ecc_fault_inject | ✅ |
| SG-04: Detect software lockup | Windowed watchdog on isolated clock | tb_watchdog | ✅ |
| SG-05: Ensure fault-free communication | Safety-gated CAN + parity UART | tb_can, tb_uart | ✅ |

---

## 3. VERIFICATION SUMMARY

### 3.1 Functional Testbenches
- `tb_lockstep_comparator` — Mismatch detection, NMI assertion, safe state latch
- `tb_ecc` — SBE correction, DBE detection, clean path validation
- `tb_watchdog` — Normal kick, early violation, late timeout
- `tb_can` — Frame TX, safety gate drop, mailbox load
- `tb_uart` — Parity-protected TX, error flagging

### 3.2 Fault Injection Testbenches
- `tb_lockstep_fault_inject` — Stuck-at and bit-flip on core bus
- `tb_ecc_fault_inject` — Single/double bit injection on data path

### 3.3 Formal Verification Assertions
- Lockstep comparator: NMI within 2 cycles, bus isolation, safe state latch
- ECC wrapper: SBE/DBE mutual exclusion, zero syndrome = no error
- Watchdog: Reset on timeout, early kick detection
- CAN: TX recessive on safety gate drop
- UART: Parity blocks TX, error flagged on mismatch

---

## 4. HARDWARE METRICS

| Metric | Value | ASIL-D Threshold | Compliance |
|--------|-------|------------------|------------|
| SPFM   | 96.76% | >= 90%           | ✅ PASS    |
| LFM    | 98.92% | >= 60%           | ✅ PASS    |
| PMHF   | 1.53×10⁻⁹ /h | < 10⁻⁸ /h | ✅ PASS    |
| DC     | 95.6%  | >= 60%           | ✅ PASS    |

See `docs/safety/fmeda_analysis.md` for detailed calculation.

---

## 5. TRACEABILITY

Full bi-directional traceability from safety goals → FSR → TSR → RTL → test
is maintained in `docs/safety/traceability_matrix.md`. All RTL files carry
VHDL traceability attributes (`requirement_id`).

---

## 6. RESIDUAL RISK ASSESSMENT

| Residual Risk | Mitigation                     | Remaining Severity |
|---------------|--------------------------------|--------------------|
| Common cause failure in lockstep | Independent ECC on memory path | Low |
| Watchdog oscillator failure      | Lockstep comparator as backup  | Low |
| Instruction fetch corruption     | Lockstep detects via divergence | Low |
| Power supply transient           | Watchdog on isolated RC clock  | Low |

---

## 7. CONCLUSION

The lockstep-rv32-soc satisfies ISO 26262 ASIL-D requirements through:
- **Redundancy**: Dual-core lockstep with independent ECC
- **Diagnostics**: Watchdog, safety-gated I/O, parity checks
- **Verification**: 7 testbenches with fault injection coverage
- **Metrics**: All quantitative thresholds exceeded by significant margins

The hardware is suitable for integration into ASIL-D automotive safety systems.
