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
- **Implemented In:** `rtl/safety_blocks/hamming_ecc_wrapper.vhd`

## TSR_WD_001
- **Description:** An independent watchdog must monitor CPU activity and assert a system reset if no valid check-in is received within the watchdog timeout window.
- **ASIL Allocation:** ASIL-D
- **Mitigation:** Hardware reset to critical actuators via `sys_reset_o`.
- **Verification Method:** Timeout Simulation + Fault Injection
- **Implemented In:** `rtl/safety_blocks/hardware_watchdog.vhd`

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
