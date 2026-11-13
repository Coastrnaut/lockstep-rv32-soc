# 🔬 lockstep-rv32-soc Verification & Testbench Specification Framework
**Standard Compliance:** ISO 26262 Part 5 (Hardware Level) & Part 6 (Software/HDL Quality)  
**Target Integrity Level:** ASIL D  
**Verification Frameworks:** OSVVM (Open Source VHDL Verification Methodology) & VUnit Test Runner  

---

## Status of this specification

Sections 1 to 5 state targets. Most are not met today, and none of them is
enforced by CI. This table says what exists, so that the targets are not read
as achieved. Per-run evidence is in `docs/verification/milestone_0_1.md`.

| Target | Today |
|--------|-------|
| 100% statement, branch, condition, MC/DC, toggle and FSM coverage (section 1) | Not measured. GHDL in this flow reports no structural coverage, and no licensed simulator job exists |
| Illegal FSM recovery by forcing (section 1) | Done for the comparator state register (`tb_lockstep_illegal_state`). `tb_fsm_illegal_recovery` exercises the CAN gate and traffic, not illegal states. CAN, UART and self-test FSMs use enumerated types and have no illegal-state tests |
| OSVVM functional coverage bins (section 2) | Bus access kind, target and spacing in `tb_soc_lockstep`. Address-space corners are directed tests in `tb_soc_bus_fabric` and `tb_soc_fabric`, not coverage bins |
| Stuck-at and transient fault injection (section 3) | A seeded campaign of single forced bits at 15 RTL sites, classified with denominators and latencies (`docs/verification/fault_campaign.md`). No netlist injection |
| 50 µs fault-to-safe-pin bound (section 3.C) | Checked from the ECC fault to `actuator_safe_o` in `tb_soc_ecc`. Other fault classes are checked in clocks from the comparator. No item FTTI exists |
| Comparator self-checking (section 4.A) | Startup self-test after each cold reset. No periodic heartbeat (roadmap R2.4) |
| Gate-level netlist simulation (section 4.B) | Not done. GHDL synthesis is used as a lint and smoke test only |
| CI blocks on coverage and FTTI (section 5) | CI blocks on lint, VSG, the regression, fixture drift and stale mutation patterns. It does not measure coverage |
| Mutation campaign | 430 mutants. Full campaign is manual, before a release |

The signal names `sys_outputs_valid_o` and `core_mismatch_detected` below come
from an early draft. The implemented equivalents are the comparator's
`bus_valid_o` and its trip.

---

## 📊 1. Quantitative Code Coverage Mandates

To satisfy an ASIL D audit for the `lockstep-rv32-soc` platform, verification cannot rely on arbitrary test durations. The simulation suite must achieve **100% Structural Code Coverage** across the entire RTL codebase. Any unexercised line of code will result in an immediate compliance failure.

The qualified simulator engine (e.g., Siemens Questa or Synopsys VCS) must generate artifacts validating the following metrics:

*   **Statement Coverage (100%):** Every individual line of executable VHDL code in the repository must be stepped through at least once.
*   **Branch / Decision Coverage (100%):** Every conditional path (`if/else`, `elsif`, and `case` alternatives) must be forced into both its true and false outcomes.
*   **Condition / Expression Coverage (100%):** Complex boolean expressions must be tested using all input combinations that can alter the outcome of the statement.
*   **Modified Condition/Decision Coverage (MC/DC) (100%):** Each condition within a decision must be shown to independently affect the outcome of that decision. This metric is strictly mandatory for ASIL D.
*   **Toggle Coverage (100%):** Every single node, wire, bus bit, and internal register bit across both CPU cores and the wrapper peripherals must execute a complete `0 -> 1` and `1 -> 0` transition sequence.
*   **FSM State & Transition Coverage (100%):** Every state in your Finite State Machines must be visited, and every valid transition arc must be triggered. 
*   **Illegal FSM Recovery Verification:** Testbenches must explicitly force the safety state machine into an out-of-bounds state using simulator forcing commands to validate that the `when others =>` default block safely steers the chip into `ST_FAULT_TRIPPED`.

---

## 🎯 2. Functional Coverage & Requirements Mapping

Structural code coverage only proves that code executes; it does not prove that code behaves correctly under environmental operational extremes. We use **OSVVM coverage bins** to map test execution metrics directly back to our Technical Safety Requirements (TSR).

### Mandatory Coverage Bins for the `lockstep-rv32-soc` Platform:
1.  **Address & Data Boundaries:** Testbenches must exercise transaction sequences at absolute minimum (`0x00000000`), absolute maximum (`0xFFFFFFFF`), and overlapping page boundary lines across the processor interconnect.
2.  **Bus Transaction Concurrency:** Functional coverage matrices must track back-to-back write operations, concurrent read/write contentions, and maximum bus stall/timeout latency limits on the safety fabric.
3.  **Reset De-assertion Timing:** Verify system behavior when the master reset (`rst_n_i`) is de-asserted precisely synchronous to the rising edge of the system clock. Asynchronous assertions must be verified to clear all pipelines cleanly without generating metastable hazards.
4.  **Temporal Diversity Delay Realignment:** OSVVM cross-coverage bins must verify that the 2-cycle delayed inputs to Core B match the outputs of Core A exactly 2 clock cycles prior, validating the lockstep pipeline realignment logic under back-to-back branch hazards and stall cycles.

---

## ⚡ 3. Fault Injection Testing Framework (ASIL-D Core Requirement)

To validate the **Single Point Fault Metric (SPFM ≥99%)** and **Latent Fault Metric (LFM ≥90%)** for the `lockstep-rv32-soc`, we write automated test scripts that deliberately break the hardware mid-simulation. The safety mechanisms must isolate these anomalies automatically within the system's critical timing bounds.

### A. Permanent (Stuck-At) Fault Campaigns
*   **Injection Execution:** The test runner must intercept physical netlist lines (e.g., `core_b_bus_i.addr(0)`) and lock them permanently to a hard `'1'` (Stuck-At-1) or `'0'` (Stuck-At-0) state.
*   **Compliance Pass Metric:** The testbench must verify that as soon as the CPU attempts to address memory via the compromised bit line, the `lockstep_comparator` catches the mismatch, drops `sys_outputs_valid_o` to `'0'`, and drives `actuator_safe_o` high within **exactly 2 clock cycles** of the error reaching the comparator boundaries.

### B. Transient Faults (Single Event Upsets / Bit-Flips)
*   **Injection Execution:** The simulation wrapper must wait until the processor enters a deep calculation routine, then use a simulator force macro to flip a single flip-flop register bit inside the CPU or safety blocks for exactly one clock cycle.
*   **Compliance Pass Metric (Memory / RegFile):** When a bit-flip is introduced into the RAM data bus or internal register file, the testbench must verify that the `hamming_ecc_wrapper` catches the single-bit corruption, applies corrections on the fly, logs an internal single-bit error counter, and allows the CPU to continue processing without hitching.
*   **Compliance Pass Metric (Fatal Multi-Bit Faults):** If a double bit-flip is injected simultaneously, the testbench must verify that the ECC core catches the uncorrectable anomaly and asserts `dbe_fatal_o` to force an immediate system lock.
*   **Compliance Pass Metric (Core Lockstep Mismatch):** When a transient bit-flip is forced into Core A, the testbench must verify that Core B remains unaffected due to physical/spatial isolation, and that the `lockstep_comparator` trips the critical fault output.

### C. FTTI Determinism & Global System Trip Boundaries
*   **Maximum Trip Latency Mandate:** From the precise timestamp ($T_{inject}$) an uncorrectable fault or core mismatch is introduced via the test runner, the top-level safety signals (`sys_outputs_valid_o` dropping to `'0'` and `actuator_safe_o` rising to `'1'`) **must complete their transitions within a maximum window of 50µs**.
*   **Assertion-Based Monitoring:** Every automated fault injection scenario must bind a concurrent VHDL/PSL timing assertion to monitor the output ports:
    ```vhdl
    -- Strict ASIL D 50µs FTTI Verification Boundary Assertion
    assert property (
        @(posedge clk_i) disable iff (rst_n_i = '0')
        (core_mismatch_detected | fatal_ecc_error) -> within_time(actuator_safe_o = '1', 50 us)
    ) report "Functional Safety Violation: FTTI exceeded 50 microseconds!" severity failure;
    ```
*   **Worst-Case Latency Coverage:** Testbenches must intentionally inject faults during maximum bus stall durations, multi-cycle division operations, and back-to-back memory waits to prove that the 50µs boundary is never breached under worst-case operational congestion.

---

## 🛡️ 4. Lockstep-Specific & Target-Specific Verification Requirements

### A. Dual-Core Lockstep (DCLS) Comparator Common-Cause Analysis
Because the comparison logic represents a single point of failure (SPF), the test suite must prove its resilience against Common Cause Failures (CCF):
*   **Self-Checking Verification:** Testbenches must simulate a permanent failure *inside* the comparator itself (e.g., forcing a comparator output permanently to "No Error"). The surrounding system safety monitor must detect that the comparator has failed its startup self-test or periodic heartbeat check.
*   **Simultaneous Glitch Testing:** The fault-injection engine must inject a multi-cycle voltage/timing glitch into both cores simultaneously. The testbench must verify that the **2-cycle temporal diversity delay** prevents the glitch from causing an identical, simultaneous state transition in both Core A and Core B, thereby forcing a detectable mismatch at the comparator.

### B. FPGA-to-ASIC Environmental Co-Verification
To ensure safety integrity holds firm when migrating hand-written VHDL from an FPGA fabric to custom silicon, the test suite must execute against two distinct targets:
*   **Phase 1: RTL-Level (Technology Agnostic):** Verification run against the purely behavioral, hand-written VHDL code to validate architectural safety loops, OSVVM functional coverage, and MC/DC targets.
*   **Phase 2: Post-Synthesis Gate-Level Netlist (GLN):** The test runner must execute the exact same test suite and fault-injection matrix against the synthesized gate-level netlist generated for the target FPGA (using vendor tools) and the target ASIC cell library (using an EDA compiler). This step is mandatory to prove that optimization algorithms did not eliminate redundant safety components, register replications, or timing-delay pipelines.

---

## ⚙️ 5. Test Suite Execution Architecture

To support a mixed open-source and commercial compliance path, the `sim/run.py` verification engine orchestrates tests for the `lockstep-rv32-soc` repository using a multi-phase configuration loop:

```text
               +-------------------------------------------+

               |           VUnit Python Runner             |
               +-------------------------------------------+
                                     |
                  +------------------+------------------+

                  |                                     |
                  v                                     v
     [Local Dev / Commit CI]              [Compliance Milestone Gate]
         Engine: GHDL                          Engine: Siemens Questa / Synopsys VCS
     Focus: Rapid Regression                Focus: 100% Code Coverage (MC/DC), GLN,
     Syntax & Basic Assertions                 Automated Fault Injection Campaigns,
                                               and 50µs FTTI Assertion Validation
```

### Automated Code Quality Regression Gates:
Every pull request triggers our CI runner to execute the validation test framework. If structural code coverage (including MC/DC and toggle) falls below 100%, or if a fault-injection simulation fails to flag a hardware safety trip within **exactly 50µs**, the build will automatically fail, preventing a code merge into the master lifecycle line.

### Mutation Campaign (Test Strength):
Coverage proves that code executed; it does not prove that a test would fail if the code were wrong. `sim/scripts/mutate.py` holds hand-written mutants, each breaking one safety rule in the RTL, and runs the regression against every one on a temporary copy of the tree. Every mutant must make at least one test fail, and a survivor is a missing test, to be written before release. A full campaign takes hours of CPU, so it runs before each release and after RTL changes rather than on every push. The latest result is in the safety case (SC-LRS-001, section 3.4).
