# ============================================================================
# Technical Safety Requirements — Core Processing Unit
# ============================================================================
# Each TSR defines a safety requirement, its ASIL allocation, mitigation
# strategy, and verification method. These IDs are embedded in VHDL source
# files via attribute tags for automated traceability.
#
# Revision 1.1. Every ID that a VHDL `requirement_id` attribute or `Traces to:`
# header names is defined here. "Verified by" names the tests that check it in
# simulation. ASIL allocations are design intent: no item, hazard analysis or
# assessor has confirmed them (docs/verification/milestone_0_1.md).
# ============================================================================

## TSR_LOCKSTEP_001
- **Description:** The system must detect a structural mismatch between Core A and Core B on the compared bus (address, data, byte enables, write enable and strobe) within 2 clock cycles of it reaching the comparator, and must stop the mismatched request before any slave sees it.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** Close the system bus in the cycle of the mismatch, drop `bus_valid_o` and raise `safe_state_o` at the next edge, and drive the external fault pin `nmi_fault_o` from the registered fault, independent of any interrupt mask (HSI section 8.2).
- **Verification Method:** Fault Injection Simulation
- **Implemented In:** `rtl/safety/lockstep_comparator.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_lockstep_comparator`, `tb_lockstep_fault_inject`, `tb_lockstep_fault_inject_permanent`, `tb_soc_lockstep`; formal proofs CMP-01 to CMP-11 and COM-03, COM-04 (`docs/verification/formal.md`)
- **Alias:** `TSR_LOCKSTEP_042` was the comparator's own tag for this requirement until revision 1.1. It is retired, and the comparator now carries `TSR_LOCKSTEP_001`.

## TSR_BUS_001
- **Description:** Every request that the comparator accepts must end with exactly one response in the next cycle, from the slave it addressed: ACK with that slave's data, or ERR with zero data for an unmapped address or an uncorrectable RAM word. A request the comparator stops must reach no slave. A warm reset must drop a response or a RAM write that it catches.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `soc_bus_fabric` registers the decoded target with the accepted request and drives one response record, which core B receives two clocks after core A (HSI section 8.1).
- **Verification Method:** Directed and seeded random simulation, firmware loads and stores
- **Implemented In:** `rtl/safety/soc_bus_fabric.vhd`, `rtl/safety/ecc_data_ram.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_soc_bus_fabric`, `tb_soc_fabric`, `tb_soc_ecc`; formal proofs BUS-P1 to BUS-P6 (`docs/verification/formal.md`)

## TSR_BUS_002
- **Description:** A fault in the read data on its way from the fabric to either core must be detected and must trip the comparator, so that a fault both cores would receive alike cannot pass unseen.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** Even parity taken from each slave's data before the selection, carried with the response and through core B's delay line, and checked at both cores' inputs in every clock; a mismatch is a fatal input to the comparators (HSI section 8.6).
- **Verification Method:** Directed simulation, formal proof, fault campaign
- **Implemented In:** `rtl/safety/soc_bus_fabric.vhd`, `rtl/soc/top_automotive_soc.vhd`, `rtl/pkg/package_soc_types.vhd`
- **Verified by:** `tb_soc_bus_fabric.parity_comes_from_each_slave_before_the_selection`, `tb_soc_fabric.a_stuck_read_data_bit_trips_the_soc_while_the_bus_is_idle`, `tb_soc_fabric.a_fault_in_core_b_copy_of_the_read_data_trips_the_soc`; formal proof BUS-P7; fault campaign sites 7 and 18 (`docs/verification/fault_campaign.md`)

## TSR_ECC_001
- **Description:** All memory bus transactions must be protected by SECDED Hamming code to correct single-bit errors and detect double-bit errors.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** Correct SBE transparently; flag DBE, end the access with ERR and trip the comparator.
- **Scope:** The shared data RAM only. The cores' instruction memories have no ECC (HSI section 5).
- **Verification Method:** Randomized Error Injection Testbench
- **Implemented In:** `rtl/safety/hamming_ecc_wrapper.vhd`, `rtl/safety/ecc_data_ram.vhd`
- **Verified by:** `tb_ecc`, `tb_ecc_exhaustive`, `tb_ecc_fault_inject`, `tb_ecc_seu_inject`, `tb_ecc_write_read`, `tb_ecc_data_ram`, `tb_soc_ecc`

## TSR_WD_001
- **Description:** An independent watchdog must monitor CPU activity and assert a system reset if no valid check-in is received within the watchdog window. The window is inclusive: a kick sampled at a count from 40,000 to 50,000 is accepted (HSI WD-01).
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** Hardware reset to critical actuators via `sys_reset_o`.
- **Verification Method:** Timeout Simulation + Fault Injection
- **Implemented In:** `rtl/safety/hardware_watchdog.vhd`, `rtl/safety/watchdog_supervisor.vhd`
- **Verified by:** `tb_watchdog`, `tb_watchdog_window`, `tb_watchdog_timeout`, `tb_watchdog_kick_sequence`, `tb_watchdog_supervisor`, `tb_soc_watchdog`
- **Open:** containment of a lost watchdog clock needs an independent supervisor on the board (HSI WD-04).

## TSR_LOCKSTEP_043
- **Description:** Core B must run 2 clocks behind Core A, so that a transient fault on both cores cannot change them both the same way, and nothing may leave the cores before it has been compared.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** All of Core B's changing inputs, including the bus response, and Core A's bus pass through 2-clock delay lines, and the comparator stops a bad bus cycle in the cycle it finds it.
- **Verification Method:** Simultaneous Glitch Injection + Functional Coverage
- **Implemented In:** `rtl/safety/temporal_diversity.vhd`, `rtl/safety/lockstep_comparator.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_temporal_diversity`, `tb_soc_lockstep`

## TSR_LOCKSTEP_044
- **Description:** The cores must not start unless the lockstep comparator has proved, since the last cold reset, that it can detect a fault on every line it compares, latch it, report it on the registered output that drives the fault pin, and clear it. A test that does not finish within its time limit is a failure.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** A startup self-test trips the comparator through its real logic, and holds the cores in reset unless every step passes. A failure leaves `actuator_safe_o` and `nmi_fault_o` high.
- **Verification Method:** Comparator Fault Injection
- **Implemented In:** `rtl/safety/comparator_self_test.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_comparator_self_test`, `tb_soc_lockstep`, including the reporting path and a stuck sequencer (`docs/verification/diagnostics.md`)

## TSR_LOCKSTEP_045
- **Description:** A lockstep comparator that fails after its startup self-test must not let a divergent request reach a slave. Two comparators must check the same buses; the bus may carry a request only while both pass it and their decisions agree, either one's trip is a fault, and a disagreement between them is a fault that holds until a reset.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `dual_comparator` instantiates two `lockstep_comparator`s with their own state, compares their outputs every clock, latches a disagreement, and feeds it back to both as a fatal fault. The startup self-test sees a trip only when both comparators trip, so it tests each of them. Comparator B has its own reset synchroniser, its own delay line for core A's bus and its own self-test injection point for core B's; the two resets are compared, and the disagreement latch clears only when both comparators are in reset. The self-test holds both in reset through its settle time, so two synchronisers that release a clock apart still start the pair together.
- **Verification Method:** Comparator Fault Injection
- **Implemented In:** `rtl/safety/dual_comparator.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_dual_comparator`, `tb_dual_comparator_faults`, `tb_soc_lockstep.comparator_b_stuck_at_no_error_also_fails_the_self_test`, `tb_soc_lockstep.comparator_b_stuck_tripped_fails_the_self_test`, `tb_soc_lockstep.a_comparator_that_stops_comparing_after_startup_is_found_at_the_first_divergence`, `tb_soc_lockstep.a_reset_of_comparator_b_alone_is_found_and_held`, `tb_soc_lockstep.a_fault_on_comparator_b_copy_of_core_a_bus_is_found`, `tb_soc_lockstep.a_fault_on_comparator_b_copy_of_core_b_bus_is_found`, `tb_soc_lockstep.comparator_b_reset_released_a_clock_late_still_starts_the_pair_together`
- **Open:** both comparators still share the `rst_n_i` pin, the cores' buses before the copies split, and the clock, which TSR_CLOCK_001 monitors (DFA DF-15).

## TSR_CLOCK_001
- **Description:** A system clock that stops, or runs more than the configured tolerance (25 % by default) away from its nominal rate as measured against the independent watchdog clock, must be detected within two monitor windows, must raise the fault pin, and must hold the SoC in reset until a cold reset, without depending on the system clock.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `clock_monitor` divides the system clock, counts the divider's changes in the watchdog clock domain over each window of 256 watchdog clocks, and latches a fault outside the accepted range. The first window after a reset is not judged. The fault drives `nmi_fault_o` directly and the SoC reset request, whose synchroniser asserts without a clock, so the actuators go safe, the CAN pin recessive and the UART to mark.
- **Verification Method:** Clock Fault Injection
- **Implemented In:** `rtl/safety/clock_monitor.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_clock_monitor`, `tb_soc_watchdog.a_stopped_system_clock_is_reported_within_two_monitor_windows`
- **Open:** the nominal frequencies and the tolerance are generics the integrator sets; on the Arty board the watchdog clock is CFGMCLK, whose own tolerance is wide (`fpga/arty_a7_100t/arty_a7_top.vhd`). A watchdog clock that stops leaves the monitor unable to judge (HSI WD-04).

## TSR_ACTUATOR_001
- **Description:** The actuator must be removable by two channels of opposite polarity, `actuator_safe_o` (high: safe) and `actuator_en_o` (high: may be powered), so that one stuck pin cannot permit it alone. `actuator_safe_o`, read back at the actuator's driver on `actuator_fb_i`, must follow its command: a difference lasting longer than the driver's delay (8 clocks by default) must trip the comparators and hold until a cold reset. `actuator_en_o` must drop at once on such a fault, and on any SoC reset without a clock. The reset holds the command at safe, so the line is checked at every start.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `actuator_monitor` synchronises the read-back, compares it with the command delayed as long, filters, and latches; its fault trips both comparators through their fatal input. The second channel is a register of its own, from the comparators' bus permission rather than their safe-state output.
- **Verification Method:** Output Fault Injection
- **Implemented In:** `rtl/safety/actuator_monitor.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_actuator_monitor`, `tb_soc_lockstep.an_actuator_line_stuck_at_permit_is_found_and_the_second_channel_cuts_power`, `tb_soc_lockstep.an_actuator_line_stuck_at_safe_is_found_when_the_cores_start`, `tb_soc_lockstep.an_actuator_line_stuck_at_permit_is_found_before_the_cores_start`
- **Open:** a line stuck at "permit" while the command is "permit" stays latent until the next demand or start; the second channel covers that demand. The driver must feed back its own input (AoU-01, `docs/safety/item_definition.md`).

## TSR_RESET_001
- **Description:** A reset must take effect at once, with or without a clock, and be released on a clock edge, with both cores released on the same edge. Actuators must be held safe, the CAN pin recessive and the UART pin at mark during a reset.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** One synchroniser drives both cores, the comparator and the peripherals, and `actuator_safe_o` is high whenever its output is low.
- **Verification Method:** Functional Testbench + Reset Pulse Injection
- **Implemented In:** `rtl/safety/reset_synchronizer.vhd`, `rtl/soc/top_automotive_soc.vhd`
- **Verified by:** `tb_reset_synchronizer`, `tb_soc_reset_network`, `tb_soc_reset_timing`

## TSR_SAFETY_GATE_001
- **Description:** The lockstep comparator must use high-Hamming-distance safe state encoding to resist single-event upsets on internal FSM registers, and must treat any other value of its state register as a fault.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** 8-bit encoded states (0x5A / 0xA5) with a Hamming distance of 8. Any other value closes the bus, latches and reports a fault, and holds the safe state (HSI FLT-03). The fault latch and the state register each report a fault on their own, so an upset of either cannot hide one.
- **Verification Method:** Bit-Flip Injection in simulation, and a k-induction proof from arbitrary register values.
- **Implemented In:** `rtl/pkg/package_soc_types.vhd`, `rtl/safety/lockstep_comparator.vhd`
- **Verified by:** `tb_lockstep_illegal_state`, `tb_soc_lockstep`; formal proofs CMP-04, CMP-05, CMP-09 (`docs/verification/formal.md`)

## TSR_SAFETY_GATE_002
- **Description:** The data RAM must accept an access only while the comparator gate is open, and must commit a store only at its commit edge while the gate is still open, the word is correctable and no reset has arrived.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `bus_ok_i` gates selection and the write-commit strobe `w_commit` (HSI BUS-05).
- **Verification Method:** Functional Testbench + Gate Drop and Reset Injection
- **Implemented In:** `rtl/safety/ecc_data_ram.vhd`
- **Verified by:** `tb_ecc_data_ram`, `tb_soc_bus_fabric`, `tb_soc_fabric`; formal proofs COM-01 to COM-04 (`docs/verification/formal.md`)

## TSR_SAFETY_GATE_003
- **Description:** The watchdog's bus side must accept a kick and serve its registers only while the comparator gate is open, and its reset must reach the SoC whatever the system clock does.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `bus_ok_i` gates kicks and reads. The reset pulse comes from a flip-flop on `wd_clk_i` and asserts the reset network asynchronously.
- **Verification Method:** Functional Testbench + Clock Stop
- **Implemented In:** `rtl/safety/hardware_watchdog.vhd`, `rtl/safety/watchdog_supervisor.vhd`
- **Verified by:** `tb_watchdog_supervisor`, `tb_soc_watchdog`

## TSR_TYPES_001
- **Description:** Records, safe-state encodings, watchdog constants and register addresses shared by the RTL must be defined once.
- **ASIL Allocation:** ASIL-D (intent)
- **Mitigation:** `package_soc_types`. Testbenches that check addresses write them out from the HSI rather than reading this package, so a wrong address here fails them.
- **Verification Method:** Address decode testbenches and mutation of the constants
- **Implemented In:** `rtl/pkg/package_soc_types.vhd`
- **Verified by:** `tb_soc_periph_decode`, `tb_soc_fabric`

## TSR_UART_001
- **Description:** The diagnostic UART must send only bytes whose held parity checks, must flag a parity mismatch, and must go to mark and discard the byte in progress and any pending byte when the safety gate closes or a reset asserts.
- **ASIL Allocation:** QM (diagnostic output; intent)
- **Mitigation:** Parity gate before the serializer; `w_abort` forces mark combinationally and clears the serializer (HSI section 8.3).
- **Verification Method:** Functional Testbench + Parity Fault Injection + Gate Drop
- **Implemented In:** `rtl/peripherals/safe_uart.vhd`
- **Verified by:** `tb_uart`, `tb_uart_parity_fault`, `tb_uart_tx_error`, `tb_uart_abort`, `tb_soc_uart_error`, `tb_soc_lockstep`, `tb_soc_reset_network`

## TSR_CAN_001
- **Description:** The CAN-Bus controller must only process transactions validated by the lockstep safety gate.
- **ASIL Allocation:** ASIL-B (intent)
- **Mitigation:** `bus_ok_i` input blocks all CAN traffic when `bus_valid_o` is low, forces the pin recessive and clears the mailbox.
- **Verification Method:** Functional Testbench
- **Implemented In:** `rtl/peripherals/automotive_can_controller.vhd`
- **Verified by:** `tb_can`, `tb_fsm_illegal_recovery`, `tb_soc_periph_decode`, `tb_soc_lockstep`

## TSR_CAN_002
- **Description:** The CAN-Bus controller must receive and acknowledge frames from other nodes, reject any that fail a stuff, CRC or form check, and signal those with an error flag, following ISO 11898-1.
- **ASIL Allocation:** ASIL-B (intent)
- **Mitigation:** A bus-off node or a dropped `bus_ok_i` keeps it off the bus. A received frame is held until software releases it, and a later one cannot overwrite it.
- **Verification Method:** Reference Model Frames + Error Injection
- **Implemented In:** `rtl/peripherals/can_receiver.vhd`, `rtl/peripherals/automotive_can_controller.vhd`
- **Verified by:** `tb_can_receive`, `tb_can_rx_data`, `tb_soc_firmware`
