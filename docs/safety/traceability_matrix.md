# ============================================================================
# Bi-directional Traceability Matrix
# ============================================================================
# ISO 26262 Part 4: Traceability from Safety Goals to Verification
# Document ID: TRC-LRS-001
# Revision: 1.0
# ============================================================================

## LEGEND
- **SG** = Safety Goal
- **FSR** = Functional Safety Requirement
- **TSR** = Technical Safety Requirement
- **RTL** = RTL Block
- **TEST** = Verification Testbench
- **STATUS** = Implementation status

---

## TRACEABILITY TABLE

| SG    | FSR              | TSR                | RTL Block                    | Testbench                      | Status |
|-------|------------------|--------------------|------------------------------|--------------------------------|--------|
| SG-01 | FSR_MOTION_001   | TSR_LOCKSTEP_042   | lockstep_comparator          | tb_lockstep_comparator         | ✅     |
| SG-01 | FSR_MOTION_001   | TSR_SAFETY_GATE_001| lockstep_comparator          | tb_lockstep_fault_inject       | ✅     |
| SG-01 | FSR_MOTION_002   | TSR_WD_001         | hardware_watchdog            | tb_watchdog                    | ✅     |
| SG-02 | FSR_DIV_001      | TSR_LOCKSTEP_042   | lockstep_comparator          | tb_lockstep_comparator         | ✅     |
| SG-02 | FSR_DIV_001      | TSR_LOCKSTEP_042   | lockstep_comparator          | tb_lockstep_fault_inject       | ✅     |
| SG-02 | FSR_DIV_002      | TSR_ECC_001        | hamming_ecc_wrapper          | tb_ecc                         | ✅     |
| SG-02 | FSR_DIV_002      | TSR_ECC_001        | hamming_ecc_wrapper          | tb_ecc_fault_inject            | ✅     |
| SG-03 | FSR_MEM_001      | TSR_ECC_001        | hamming_ecc_wrapper          | tb_ecc                         | ✅     |
| SG-03 | FSR_MEM_001      | TSR_ECC_001        | hamming_ecc_wrapper          | tb_ecc_fault_inject            | ✅     |
| SG-03 | FSR_MEM_002      | TSR_SAFETY_GATE_002| hamming_ecc_wrapper          | tb_ecc                         | ✅     |
| SG-04 | FSR_LOCK_001     | TSR_WD_001         | hardware_watchdog            | tb_watchdog                    | ✅     |
| SG-04 | FSR_LOCK_001     | TSR_SAFETY_GATE_003| hardware_watchdog            | tb_watchdog                    | ✅     |
| SG-05 | FSR_COMM_001     | TSR_CAN_001        | automotive_can_controller    | tb_can                         | ✅     |
| SG-05 | FSR_COMM_001     | TSR_CAN_001        | automotive_can_controller    | tb_can                         | ✅     |
| SG-05 | FSR_COMM_002     | TSR_UART_001       | safe_uart                    | tb_uart                        | ✅     |
| SG-05 | FSR_COMM_002     | TSR_UART_001       | safe_uart                    | tb_uart                        | ✅     |

---

## COVERAGE SUMMARY

| Coverage Type       | Target | Achieved | Notes                              |
|---------------------|--------|----------|------------------------------------|
| RTL Implementation  | 100%   | 100%     | All 5 safety blocks implemented    |
| Testbench Coverage  | 100%   | 100%     | 7 testbenches (5 functional + 2 fault inject) |
| Fault Injection     | 100%   | 100%     | Stuck-at + bit-flip on lockstep + ECC |
| Formal Assertions   | 100%   | 100%     | Clocked assertions in all 5 blocks |
| Traceability Tags   | 100%   | 100%     | VHDL attributes in all RTL files   |

---

## REQUIREMENT IDs

### Safety Goals
- **SG-01**: Prevent unintended vehicle motion
- **SG-02**: Detect computational divergence
- **SG-03**: Detect memory corruption
- **SG-04**: Detect software lockup
- **SG-05**: Ensure fault-free communication

### Functional Safety Requirements
- **FSR_MOTION_001**: System shall isolate actuators on fault
- **FSR_MOTION_002**: System shall reset on watchdog timeout
- **FSR_DIV_001**: System shall detect core divergence within 2 cycles
- **FSR_DIV_002**: System shall detect and correct memory bit errors
- **FSR_MEM_001**: Memory buses shall use SECDED ECC
- **FSR_MEM_002**: Double-bit errors shall be flagged as fatal
- **FSR_LOCK_001**: Watchdog shall run on independent clock
- **FSR_COMM_001**: CAN TX shall be safety-gated
- **FSR_COMM_002**: UART TX shall verify parity

### Technical Safety Requirements
- **TSR_LOCKSTEP_042**: Lockstep comparator implementation
- **TSR_SAFETY_GATE_001**: Safety gate on system bus
- **TSR_SAFETY_GATE_002**: Safety gate on ECC bus
- **TSR_SAFETY_GATE_003**: Safety gate on watchdog
- **TSR_ECC_001**: SECDED Hamming ECC wrapper
- **TSR_WD_001**: Windowed hardware watchdog
- **TSR_CAN_001**: Fault-hardened CAN controller
- **TSR_UART_001**: Parity-protected UART
