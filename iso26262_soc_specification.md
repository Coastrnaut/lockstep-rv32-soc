# 📋 ASIL-V: Exhaustive ISO 26262 ASIL-D Reference Hardware Platform Checklist & Specification

This specification document outlines the comprehensive roadmap, architectural constraints, and low-level VHDL implementation details required to design, verify, and certify the `lockstep-rv32-soc` repository under **ISO 26262 ASIL-D** functional safety requirements.

---

## 🏁 Section 1: The ISO 26262 Project Milestone Checklist

### 📋 Milestone 1: Functional Safety Management & System Concept (Parts 2, 3 & 4)
*Before writing VHDL code, the regulatory foundations must be locked in.*
* **1.1 Appoint Functional Safety Manager (FSM):** Assign a dedicated auditor independent of the active RTL engineering team.
* **1.2 Create the Safety Plan:** Document project milestones, safety life cycle hooks, and tailing procedures for programmable logic.
* **1.3 Define the Item Definition:** Author the system boundaries, environmental limitations (electrical, thermal, radiation profile), and assumptions.
* **1.4 Execute HARA (Hazard Analysis and Risk Assessment):** Analyze failure consequences (e.g., unintended acceleration, loss of braking), calculate Severity (S), Exposure (E), and Controllability (C) ratings, and mathematically lock in the ASIL-D rating assignment.
* **1.5 Define Functional Safety Requirements (FSR):** Author high-level mitigation strategies (e.g., *"If processor outputs diverge, the system must drop vehicle control authority immediately"*).
* **1.6 Create Technical Safety Requirements (TSR):** Translate FSR into explicit hardware engineering requirements (e.g., `TSR_LOCKSTEP_001`).

### 🛠️ Milestone 2: Technical Reference Documentation (Parts 5 & 6 Artifacts)
*The audit trail artifacts that must sit inside the `/docs/` repository workspace.*
* **2.1 Author Hardware-Software Interface (HSI) Specification:** Map out all registers, command structures, and interrupt channels. Formally define the exact system clock speeds, startup timing limitations, and memory allocation maps.
* **2.2 Establish the Bi-Directional Traceability Matrix:** Ensure every safety goal links dynamically to a requirement, an RTL block, and a validation test.
* **2.3 Create EDA Tool Qualification Plan (TQP):** Evaluate all software compilers, static code linters, and simulators to assign their Tool Confidence Level (TCL1, TCL2, or TCL3).
* **2.4 Publish Safety-Critical VHDL Coding Standard:** Formally document rules for the repository (e.g., strict application of MISRA VHDL / SafeVHDL constraints).

### 💻 Milestone 3: Hardened VHDL Core Implementation (Part 5 Engineering)
*The complete coding steps required to build the hardware core.*
* **3.1 Initialize Repository & Submodules:** Establish directory structural rules and attach the `neorv32` repository as a Git submodule inside `rtl/core/neorv32`.
* **3.2 Implement package_soc_types.vhd:** Set up system records and enforce high Hamming distance binary encodings for all state definitions.
* **3.3 Upgrade lockstep_comparator.vhd:** Build structural comparison loops tracking the dual core processing lines cycle-by-cycle. Implement an autonomous downstream isolation output validity gate (`sys_outputs_valid_o`).
* **3.4 Implement hamming_ecc_wrapper.vhd:** Code an active SECDED error correction module to defend register files, internal caches, and RAM buses against bit-flips.
* **3.5 Implement hardware_watchdog.vhd:** Build an independent windowed dead-man counter tracking primary clock failures using an isolated RC oscillator.
* **3.6 Finalize top_automotive_soc.vhd:** Instantiate the parallel NEORV32 compute blocks alongside your custom safety components on a single structural canvas.
* **3.7 Add Traceability Metadata Tags:** Add explicit `attribute requirement_id` parameters inside every VHDL file header for automated tool scanning.

### 🧪 Milestone 4: Code Quality & Static Analysis Gates (Part 6 Quality Gates)
*Proving the code is clean and deterministic before running physical simulations.*
* **4.1 Configure Language Server & Linters:** Sync `VHDL-LS` to catch structural syntax errors during active coding tasks.
* **4.2 Execute Static Code Linter Campaigns:** Pass the codebase through a strict static analyzer (e.g., Synopsys SpyGlass) to verify 0 unintended latches are inferred, 0 gated clock infrastructures exist, and 100% of processes have complete sensitivity lists.
* **4.3 Execute Clock Domain Crossing (CDC) Structural Audit:** Verify that all asynchronous signals crossing clock boundaries have synchronizer register chains to eliminate metastability risks.

### 🔬 Milestone 5: Dynamic Simulation & Fault Validation (Parts 5 & 6 Testing)
*The rigorous verification suite required to back up the safety case data.*
* **5.1 Build the Verification Environment (sim/run.py):** Set up automated Python/VUnit regression matrix wrappers capable of switching between local GHDL tests and certified tools.
* **5.2 Write Functional Testbenches:** Create OSVVM/UVVM testing environments checking peripheral operations like CAN-Bus connectivity.
* **5.3 Code Formal Verification Assertions:** Write property assertions to mathematically prove your safety logic holds true under all conditions.
* **5.4 Record 100% Code Coverage Metrics:** Run tests through a qualified simulator to verify complete coverage across all statements, branches, conditions, and FSM states.
* **5.5 Execute Automated Fault Injection Campaigns:** Force random stuck-at bits, bit-flips, and shorted lines into your compiled netlist, and verify that your safety structures successfully detect and handle every fault.
* **5.6 Compile Final Safety Metrics (FMEDA Spreadsheet):** Calculate and document the final mathematical proof that your hardware achieves Single Point Fault Metric (SPFM) >99% and Latent Fault Metric (LFM) >90%.

### 🚀 Milestone 6: CI/CD & Safety Sign-off Execution
*Locking down the repository to prevent regression errors.*
* **6.1 Deploy GitHub Actions Automated Workflow:** Build a pipeline to verify pull requests, enforce safety checklists, and run compilation test matrices automatically.
* **6.2 Execute Peer Safety Code Reviews:** Run human code reviews backed by the Automotive VHDL Coding Standard Checklist.
* **6.3 Finalize the Safety Case Document:** Compile requirements, test verification summaries, coverage data, and safety metrics into a single package for review.
* **6.4 External TÜV Certification Audit:** Submit the repository and safety case documentation to an external safety organization (like TÜV SÜD) to receive final ASIL-D certification.

---

## 💻 Section 2: Detailed Architectural Design & VHDL Coding Tasks

Standard, textbook behavioral VHDL is insufficient for an ISO 26262 ASIL-D silicon audit. Hardware engineers must adhere to the low-level microarchitectural structures and patterns outlined below.

### 1. Global Safety Environment Configurations (`config/package_soc_types.vhd`)
This file establishes global structures, uniform interconnect definitions, and strict type scopes to eliminate implicit data conversions.
* **Bus Structural Bundling:** Define an internal master `t_rv_bus` record containing the processor lines: `addr` (32-bit `std_logic_vector`), `wdata` (32-bit `std_logic_vector`), `rdata` (32-bit `std_logic_vector`), `we` (`std_logic`), and `valid` (`std_logic`).
* **Peripheral Interface Standardization:** Define a peripheral interface record (`t_periph_bus`) to route data safely to memory-mapped devices.
* **State Space Hardening:** Enforce strict, high Hamming distance state variables. Rather than a standard enumeration, define states as 8-bit constants (`subtype t_safe_state is std_logic_vector(7 downto 0);`) with a minimum mutual Hamming distance of 4 bits:
  * `constant ST_SYSTEM_OK     : t_safe_state := "01011010";`
  * `constant ST_FAULT_TRIPPED : t_safe_state := "10100101";`
* **Auditable Traceability Headers:** Use custom VHDL user attributes (`attribute requirement_id : string;`) to allow third-party requirements parsing software to map components automatically.

### 2. Cycle-by-Cycle Dual-Core Lockstep Comparator (`rtl/safety_blocks/lockstep_comparator.vhd`)
Monitors the master and checker CPUs cycle-by-cycle. It locks down downstream vehicle actuators instantly if a computational divergence is detected.
* **Combinational Mismatch Vector Array:** Create an internal combinational process with an explicit, exhaustive sensitivity list tracking all core output ports. Avoid VHDL-2008 `process(all)` to remain compatible with strict formal verification engines.
* **Strict Process Defaults:** Ensure the comparison process initializes `w_mismatch_detected <= '0';` on line 1 of the block to eliminate any chance of synthesis tool latch inference.
* **ASIL-D Latch-Up State Loop:** The FSM synchronous process must be completely decoupled from the next-state logic. Once the state engine reaches `ST_FAULT_TRIPPED`, it must remain locked in that loop until a hard cold-reset occurs.
* **Active Isolation Gating:** The output assignment stage must be heavily guarded. If the state machine drops out of `ST_SYSTEM_OK`, drive an active validity gate (`sys_outputs_valid_o <= '0';`) and force all outgoing address, data, and write-enable lines to a hard flat `'0'` state to prevent downstream actuators from floating or executing corrupted data.

### 3. SECDED Hamming Error-Correcting Code Wrapper (`rtl/safety_blocks/hamming_ecc_wrapper.vhd`)
Intercepts RAM and Flash read/write cycles. It calculates parity bits to dynamically patch single-bit errors caused by electrical or thermal noise.
* **Parity Generation Logic:** For a 32-bit wide data bus, implement a 6-bit parity bit generator matrix to calculate check bits during every write cycle.
* **Syndrome Decoding Network:** On read cycles, compute the internal 6-bit syndrome vector using XOR logic across the incoming data lines and parity bits: `w_syndrome(0) <= data_i(0) xor data_i(1) xor data_i(3) xor ... xor parity_i(0);`
* **Dynamic Bit-Flip Inversion:** Route the computed syndrome index to an explicit decoder matrix. If the syndrome matches a single-point fault, use an active bitwise negation line to flip that corrupted register bit back to its correct state on the fly.
* **Fatal Crash Mitigation:** If the syndrome detects a double-bit error (which cannot be corrected by a 6-bit Hamming matrix), assert a high-priority, hardware-level `dbe_fatal_o` exception flag directly into the system's global reset and clock monitor block.

### 4. Windowed Independent Hardware Watchdog (`rtl/safety_blocks/hardware_watchdog.vhd`)
Acts as the independent system controller running on an internal clock to trap infinite software loops or frozen clock lines.
* **Isolated Clock Mapping:** The watchdog entity must completely bypass the main system clock line (`clk_i`). It must lock onto a slow, independent, internal low-frequency clock input generated by an on-chip RC oscillator.
* **Windowed Timing Threshold Logic:** Implement a synchronous process tracking a 16-bit unsigned counter. Define a strict operational "window" (e.g., between count value 40,000 and 50,000).
* **Early/Late Check-In Isolation:** If the CPU tries to reset the counter before it reaches the minimum threshold (early stroke) or fails to reset it before it exceeds the maximum threshold (late stroke), flag an immediate violation.
* **Hardwire Supervisor Override:** Route the output line (`sys_reset_o`) directly to the hardware supervisor reset network, guaranteeing the watchdog can physically force a full chip initialization without relying on software intervention.

### 5. Structural Core Integration Fabric (`rtl/top_automotive_soc.vhd`)
The master integration structural canvas. It takes your clock strings, instantiates two parallel instances of the RISC-V CPU Core, passes their buses into the Lockstep Comparator, and exposes the validated pins outward.
* **Library Context Mapping:** Declare the external compiled submodule library namespace at the absolute top of the file layout structure: `library neorv32;`.
* **Identical Generic Constraining:** Instantiate `i_cpu_master` and `i_cpu_checker` side-by-side. You must explicitly configure their internal parameters (such as `CLOCK_FREQUENCY`, cache allocations, and instruction set options) identically via direct VHDL `generic map` parameters to ensure cycle-accurate execution.
* **Record Bus Extraction:** Capture the flat individual port strings coming out of both CPU cores (like `wb_adr_o`, `wb_dat_o`, and `wb_we_o`) and map them directly into your internal `w_core_a_bus` and `w_core_b_bus` record structures.
* **Clock and Reset Distribution:** Distribute the global clock input (`clk_i`) and raw hardware reset (`rst_n_i`) in parallel to both CPU instances and all internal safety monitoring sub-blocks.

### 6. Hardened Automotive Peripheral Controllers (`rtl/peripherals/`)
Provides safety-hardened communication blocks to handle external data transmission safely without risking system stability.
* **`automotive_can_controller.vhd` Implementation:** Build a complete Controller Area Network (CAN-Bus) logic engine managing data frame serialization, bit stuffing, and CRC-15 error calculation. Connect the input lines of the CAN controller directly to the safety-filtered output of the lockstep comparator module (`w_safe_sys_bus`). Embed an explicit hardware verification gate inside the controller's main write-enable validation loop: if `bus_ok_i` drops to `'0'`, the CAN controller must completely isolate its internal transmission shift registers, cutting off the external `can_tx_o` pin to prevent corrupt data from flooding the vehicle's network infrastructure.
* **`safe_uart.vhd` Implementation:** Build a hardware Universal Asynchronous Receiver-Transmitter block to provide real-time diagnostic output streams. Isolate the transceiver registers behind internal parity-check loops to protect transmitted debugging telemetry against local bit corruption.
