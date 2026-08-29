# 🔬 lockstep-rv32-soc Verification & Testbench Specification Framework
**Standard Compliance:** ISO 26262 Part 5 (Hardware Level) & Part 6 (Software/HDL Quality)  
**Target Integrity Level:** ASIL-D  
**Verification Frameworks:** OSVVM (Open Source VHDL Verification Methodology) & VUnit Test Runner  

---

## 📊 1. Quantitative Code Coverage Mandates

To satisfy an ASIL-D audit for the `lockstep-rv32-soc` platform, verification cannot rely on arbitrary test durations. The simulation suite must achieve **100% Structural Code Coverage** across the entire RTL codebase. Any unexercised line of code will result in an immediate compliance failure.

The qualified simulator engine (e.g., Siemens Questa or Synopsys VCS) must generate artifacts validating the following metrics:

*   **Statement Coverage (100%):** Every individual line of executable VHDL code in the repository must be stepped through at least once.
*   **Branch / Decision Coverage (100%):** Every conditional path (`if/else`, `elsif`, and `case` alternatives) must be forced into both its true and false outcomes.
*   **Condition / Expression Coverage (100%):** Complex boolean expressions (e.g., `if (A or B) and C then`) must be tested using all input combinations that can alter the outcome of the statement.
*   **FSM State & Transition Coverage (100%):** Every state in your Finite State Machines must be visited, and every valid transition arc must be triggered. 
*   **Illegal FSM Recovery Verification:** Testbenches must explicitly force the safety state machine into an out-of-bounds state using simulator forcing commands to validate that the `when others =>` default block safely steers the chip into `ST_FAULT_TRIPPED`.

---

## 🎯 2. Functional Coverage & Requirements Mapping

Structural code coverage only proves that code executes; it does not prove that code behaves correctly under environmental operational extremes. We use **OSVVM coverage bins** to map test execution metrics directly back to our Technical Safety Requirements (TSR).

### Mandatory Coverage Bins for the `lockstep-rv32-soc` Platform:
1.  **Address & Data Boundaries:** Testbenches must exercise transaction sequences at absolute minimum (`0x00000000`), absolute maximum (`0xFFFFFFFF`), and overlapping page boundary lines across the processor interconnect.
2.  **Bus Transaction Concurrency:** Functional coverage matrices must track back-to-back write operations, concurrent read/write contentions, and maximum bus stall/timeout latency limits on the safety fabric.
3.  **Reset De-assertion Timing:** Verify system behavior when the master reset (`rst_n_i`) is de-asserted precisely synchronous and asynchronous to the rising edge of the system clock.

---

## ⚡ 3. Fault Injection Testing Framework (ASIL-D Core Requirement)

To validate the **Single Point Fault Metric (SPFM >99%)** and **Latent Fault Metric (LFM >90%)** for the `lockstep-rv32-soc`, we write automated test scripts that deliberately break the hardware mid-simulation. The safety mechanisms must isolate these anomalies automatically.

### A. Permanent (Stuck-At) Fault Campaigns
*   **Injection Execution:** The test runner must intercept physical netlist lines (e.g., `core_b_bus_i.addr(0)`) and lock them permanently to a hard `'1'` (Stuck-At-1) or `'0'` (Stuck-At-0) state.
*   **Compliance Pass Metric:** The testbench must verify that as soon as the CPU attempts to address memory via the compromised bit line, the `lockstep_comparator` catches the mismatch, drops `sys_outputs_valid_o` to `'0'`, and drives `actuator_safe_o` high within **exactly 2 clock cycles**.

### B. Transient Faults (Single Event Upsets / Bit-Flips)
*   **Injection Execution:** The simulation wrapper must wait until the processor enters a deep calculation routine, then use a simulator force macro to flip a single flip-flop register bit inside the CPU or safety blocks for exactly one clock cycle.
*   **Compliance Pass Metric (Memory):** When a bit-flip is introduced into the RAM data bus, the testbench must verify that the `hamming_ecc_wrapper` catches the single bit corruption, applies corrections on the fly, logs an internal single-bit error counter, and allows the CPU to continue processing without hitching.
*   **Compliance Pass Metric (Fatal Multi-Bit Faults):** If a double bit-flip is injected simultaneously, the testbench must verify that the ECC core catches the uncorrectable anomaly and asserts `dbe_fatal_o` to force an immediate system lock.

---

## ⚙️ 4. Test Suite Execution Architecture

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
         Engine: GHDL                          Engine: Siemens Questa
     Focus: Rapid Regression                Focus: 100% Code Coverage &
     Syntax & Basic Assertions                 Fault Injection Campaigns
```

### Automated Code Quality Regression Gates:
Every pull request triggers our CI runner to execute the validation test framework. If structural code coverage falls below 100%, or if a fault-injection simulation fails to flag a hardware safety trip within its mandated timing window, the build will automatically fail, preventing a code merge into the master lifecycle line.
