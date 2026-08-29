# 📋 ISO 26262 ASIL-D / SafeVHDL Design Review Checklist

**Project Name:** Open-Source Fault-Tolerant Automotive SoC
**VHDL Component/Entity:** `[Insert Entity Name, e.g., lockstep_comparator.vhd]`
**Author:** `[Name/GitHub Handle]`
**Reviewer:** `[Name/Reviewer Handle]`
**Date:** `[Insert Date]`

---

### 1. Clocking & Reset Domain Integrity (Preventing Metastability)
- [ ] **1.1 No Gated Clocks:** Are all clocks driven exclusively by global clock buffers? Inferring clock logic via combinational gates is strictly banned.
- [ ] **1.2 Single Clock Edge:** Do all synchronous elements trigger strictly on a single edge type (preferably `rising_edge(clk)`)? Mixed edges are prohibited within the same block.
- [ ] **1.3 Explicit CDC Synchronization:** Are all Clock Domain Crossings (CDC) protected by a documented synchronization mechanism (e.g., multi-stage flip-flop register chains or asynchronous FIFOs)?
- [ ] **1.4 Synchronous Reset Release:** Are all asynchronous resets asserted asynchronously but de-asserted synchronously to avoid partial-state initialization?

### 2. Combinational Logic & Latches (Preventing Race Conditions)
- [ ] **2.1 Zero Unintended Latches:** Do all combinational `process` blocks assign a default value to every output signal at the top of the process to ensure no memory elements are inferred?
- [ ] **2.2 Complete Sensitivity Lists:** Do all combinational processes list *every* read signal in their sensitivity list (or use VHDL-2008 `process(all)`)?
- [ ] **2.3 No Combinational Loops:** Is the code free of direct or indirect combinational feedback loops (where an output loops back to an input without a flip-flop)?

### 3. Finite State Machine (FSM) Hardening
- [ ] **3.1 Safe State Playback:** Does every `case` statement handling FSM states contain a `when others =>` clause that forces the FSM into a designated "Safe Reset State"?
- [ ] **3.2 Architecture Separation:** Is the state register completely decoupled from next-state combinational logic (two-process or three-process FSM style preferred for auditability)?
- [ ] **3.3 Illegal State Recovery:** If an illegal state transition occurs due to a hardware fault, does the FSM assert a diagnostic fault signal to the system supervisor?

### 4. Type Safety & Arithmetic
- [ ] **4.1 Standard Packages Only:** Is math limited strictly to IEEE standard packages (`ieee.numeric_std.all`)? The legacy, non-standard `std_logic_arith` and `std_logic_unsigned` packages are completely banned.
- [ ] **4.2 Explicit Type Casting:** Are all conversions between types (e.g., `std_logic_vector` to `unsigned` or `integer`) handled explicitly without relying on tool-specific implicit conversions?
- [ ] **4.3 Array Bound Protection:** Are all array index pointers dynamically checked or statically constrained to guarantee that index-out-of-bounds execution is mathematically impossible?

### 5. Traceability, Readability, & Maintainability
- [ ] **5.1 Requirements Mapping:** Does the entity header contain a commented tag explicitly linking the file to a Technical Safety Requirement ID (e.g., `-- Traces to: TSR_LOCKSTEP_042`)?
- [ ] **5.2 No Don't Care Assignments:** Is the use of `'X'`, `'-'`, or `'Z'` assignments avoided in internal synthesis code unless explicitly required for tri-state I/O buffers?
- [ ] **5.3 Generics Constraints:** Are all structural design configurations passed via strictly bounded VHDL `generics` to ensure synthesis predictability across different FPGA/ASIC targets?

---

### 📝 Review Summary Notes & Action Items
*Use this space to document any failed items and the exact modification required before code check-in.*

1. **`[Issue 1]`**:

---

### 🔐 Sign-off Signatures
**Design Engineer:** `_______________________`
**Safety Reviewer:** `_______________________`
