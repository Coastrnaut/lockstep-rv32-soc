# ============================================================================
# Technical Safety Requirements — Core Processing Unit
# ============================================================================
# Each TSR defines a safety requirement, its ASIL allocation, mitigation
# strategy, and verification method. These IDs are embedded in VHDL source
# files via attribute tags for automated traceability.
# ============================================================================

## TSR_LOCKSTEP_001
- **Description:** The system must detect a structural mismatch between Core A and Core B on critical buses within 2 clock cycles.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** Assert an un-maskable `nmi_fault_o` and lower `sys_outputs_valid_o` to '0'.
- **Verification Method:** Fault Injection Simulation
- **Implemented In:** `rtl/safety_blocks/lockstep_comparator.vhd`

## TSR_ECC_001
- **Description:** All memory bus transactions must be protected by SECDED Hamming code to correct single-bit errors and detect double-bit errors.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** Correct SBE transparently; flag DBE and trip NMI.
- **Verification Method:** Randomized Error Injection Testbench
- **Implemented In:** `rtl/safety_blocks/hamming_ecc_wrapper.vhd`, `rtl/safety_blocks/ecc_data_ram.vhd`

## TSR_WD_001
- **Description:** An independent watchdog must monitor CPU activity and assert a system reset if no valid check-in is received within the watchdog timeout window.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** Hardware reset to critical actuators via `sys_reset_o`.
- **Verification Method:** Timeout Simulation + Fault Injection
- **Implemented In:** `rtl/safety_blocks/hardware_watchdog.vhd`, `rtl/safety_blocks/watchdog_supervisor.vhd`

## TSR_LOCKSTEP_043
- **Description:** Core B must run 2 clocks behind Core A, so that a transient fault on both cores cannot change them both the same way, and nothing may leave the cores before it has been compared.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** All of Core B's changing inputs and Core A's bus pass through 2-clock delay lines, and the comparator stops a bad bus cycle in the cycle it finds it.
- **Verification Method:** Simultaneous Glitch Injection + Functional Coverage
- **Implemented In:** `rtl/safety_blocks/temporal_diversity.vhd`, `rtl/safety_blocks/lockstep_comparator.vhd`, `rtl/top_automotive_soc.vhd`

## TSR_LOCKSTEP_044
- **Description:** The cores must not start unless the lockstep comparator has proved, since the last cold reset, that it can detect a fault on every line it compares, latch it, and clear it.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** A startup self-test trips the comparator through its real logic, and holds the cores in reset unless every step passes. A failure leaves `actuator_safe_o` and `nmi_fault_o` high.
- **Verification Method:** Comparator Fault Injection
- **Implemented In:** `rtl/safety_blocks/comparator_self_test.vhd`, `rtl/top_automotive_soc.vhd`

## TSR_RESET_001
- **Description:** A reset must take effect at once, with or without a clock, and be released on a clock edge, with both cores released on the same edge. Actuators must be held safe during a reset.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** One synchroniser drives both cores, the comparator and the peripherals, and `actuator_safe_o` is high whenever its output is low.
- **Verification Method:** Functional Testbench + Reset Pulse Injection
- **Implemented In:** `rtl/safety_blocks/reset_synchronizer.vhd`, `rtl/top_automotive_soc.vhd`

## TSR_SAFETY_GATE_001
- **Description:** The lockstep comparator must use high-Hamming-distance safe state encoding to resist single-event upsets on internal FSM registers.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** 8-bit encoded states (0x5A / 0xA5) with minimum Hamming distance of 8.
- **Verification Method:** Formal Verification + Bit-Flip Injection
- **Implemented In:** `config/package_soc_types.vhd`, `rtl/safety_blocks/lockstep_comparator.vhd`

## TSR_CAN_001
- **Description:** The CAN-Bus controller must only process transactions validated by the lockstep safety gate.
- **ASIL Allocation:** ASIL-B
- **Mitigation:** `bus_ok_i` input blocks all CAN traffic when `bus_valid_o` is low.
- **Verification Method:** Functional Testbench
- **Implemented In:** `rtl/peripherals/automotive_can_controller.vhd`
