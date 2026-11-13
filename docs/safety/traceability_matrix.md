# ============================================================================
# Bi-directional Traceability Matrix
# ============================================================================
# ISO 26262 Part 4: Traceability from Safety Goals to Verification
# Document ID: TRC-LRS-001
# Revision: 1.1
# ============================================================================

## LEGEND
- **SG** = Safety Goal
- **FSR** = Functional Safety Requirement
- **TSR** = Technical Safety Requirement, defined in `docs/requirements/tsr_safety_core.md`
- **RTL** = RTL Block
- **TEST** = Named bench in `sim/tb`, or bench.test
- **STATUS** = **Sim** for implemented and checked in RTL simulation by the named
  test, **Formal** for proved by k-induction on GHDL's synthesis of the RTL
  (`docs/verification/formal.md`), **Planned** for not implemented or not yet
  verified. No row claims gate-level, FPGA or bench evidence. Those are
  milestone 3 of `docs/ROADMAP.md`.

Revision 1.1 retires `TSR_LOCKSTEP_042`, which was an alias of
`TSR_LOCKSTEP_001`, and adds `TSR_BUS_001`, `TSR_TYPES_001`, `TSR_UART_001`,
`TSR_SAFETY_GATE_002` and `TSR_SAFETY_GATE_003`, which the RTL already cited
but no document defined.

---

## TRACEABILITY TABLE

| SG    | FSR            | TSR                 | RTL Block                 | Test | Status |
|-------|----------------|---------------------|---------------------------|------|--------|
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_001    | lockstep_comparator       | tb_lockstep_comparator, tb_lockstep_fault_inject, tb_lockstep_fault_inject_permanent | Sim |
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_001    | top_automotive_soc        | tb_soc_lockstep.store_the_cores_disagree_on_never_reaches_a_peripheral, tb_soc_lockstep.lockstep_trip_with_mie_and_meie_masked_is_contained_without_an_interrupt | Sim |
| SG-01 | FSR_MOTION_001 | TSR_SAFETY_GATE_001 | lockstep_comparator       | tb_lockstep_illegal_state, tb_soc_lockstep.illegal_comparator_state_is_reported_kept_by_a_watchdog_reset_and_cleared_cold | Sim |
| SG-01 | FSR_MOTION_001 | TSR_RESET_001       | reset_synchronizer        | tb_reset_synchronizer | Sim |
| SG-01 | FSR_MOTION_001 | TSR_RESET_001       | top_automotive_soc        | tb_soc_reset_network, tb_soc_reset_timing | Sim |
| SG-01 | FSR_MOTION_001 | TSR_UART_001        | safe_uart                 | tb_uart_abort, tb_soc_lockstep.lockstep_trip_in_a_uart_byte_goes_to_mark_and_drops_the_byte, tb_soc_reset_network.reset_puts_the_uart_at_mark_without_a_clock | Sim |
| SG-01 | FSR_MOTION_002 | TSR_WD_001          | hardware_watchdog         | tb_watchdog, tb_watchdog_window, tb_watchdog_timeout, tb_watchdog_kick_sequence | Sim |
| SG-01 | FSR_MOTION_002 | TSR_WD_001          | watchdog_supervisor       | Watchdog clock loss with an independent board supervisor (HSI WD-04) | Planned |
| SG-02 | FSR_DIV_001    | TSR_LOCKSTEP_001    | lockstep_comparator       | tb_lockstep_comparator, tb_lockstep_fault_inject | Sim |
| SG-02 | FSR_DIV_001    | TSR_LOCKSTEP_044    | comparator_self_test      | tb_comparator_self_test | Sim |
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_045    | dual_comparator           | tb_dual_comparator, tb_dual_comparator_faults | Sim |
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_045    | top_automotive_soc        | tb_soc_lockstep.comparator_b_stuck_at_no_error_also_fails_the_self_test, tb_soc_lockstep.a_comparator_that_stops_comparing_after_startup_is_found_at_the_first_divergence | Sim |
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_045    | top_automotive_soc        | tb_soc_lockstep.a_reset_of_comparator_b_alone_is_found_and_held, tb_soc_lockstep.a_fault_on_comparator_b_copy_of_core_a_bus_is_found, tb_soc_lockstep.a_fault_on_comparator_b_copy_of_core_b_bus_is_found, tb_soc_lockstep.comparator_b_reset_released_a_clock_late_still_starts_the_pair_together | Sim |
| SG-01 | FSR_MOTION_002 | TSR_CLOCK_001       | clock_monitor             | tb_clock_monitor | Sim |
| SG-01 | FSR_MOTION_001 | TSR_ACTUATOR_001    | actuator_monitor          | tb_actuator_monitor | Sim |
| SG-01 | FSR_MOTION_001 | TSR_ACTUATOR_001    | top_automotive_soc        | tb_soc_lockstep.an_actuator_line_stuck_at_permit_is_found_and_the_second_channel_cuts_power, tb_soc_lockstep.an_actuator_line_stuck_at_safe_is_found_when_the_cores_start, tb_soc_lockstep.an_actuator_line_stuck_at_permit_is_found_before_the_cores_start | Sim |
| SG-01 | FSR_MOTION_002 | TSR_CLOCK_001       | top_automotive_soc        | tb_soc_watchdog.a_stopped_system_clock_is_reported_within_two_monitor_windows | Sim |
| SG-02 | FSR_DIV_001    | TSR_LOCKSTEP_043    | temporal_diversity        | tb_temporal_diversity | Sim |
| SG-02 | FSR_DIV_001    | TSR_LOCKSTEP_043    | top_automotive_soc        | tb_soc_lockstep | Sim |
| SG-02 | FSR_DIV_001    | TSR_LOCKSTEP_001    | top_automotive_soc        | tb_soc_trace.a_register_only_divergence_is_caught_by_the_trace_and_not_by_the_bus (diagnostic, verification build only) | Sim |
| SG-02 | FSR_DIV_002    | TSR_ECC_001         | hamming_ecc_wrapper       | tb_ecc, tb_ecc_fault_inject, tb_ecc_exhaustive | Sim |
| SG-03 | FSR_MEM_001    | TSR_ECC_001         | hamming_ecc_wrapper       | tb_ecc, tb_ecc_exhaustive, tb_ecc_seu_inject, tb_ecc_write_read | Sim |
| SG-03 | FSR_MEM_001    | TSR_ECC_001         | ecc_data_ram              | tb_ecc_data_ram | Sim |
| SG-03 | FSR_MEM_001    | TSR_ECC_001         | ecc_data_ram              | HSI ECC-05 to ECC-07, writeback and patrol: tb_ecc_data_ram.a_load_writes_back_a_stored_single_bit_error, tb_ecc_data_ram.the_patrol_repairs_a_stored_error_that_nothing_reads, tb_ecc_data_ram.the_patrol_reports_an_uncorrectable_word_without_tripping, tb_ecc_data_ram.the_patrol_covers_the_ram_under_back_to_back_accesses_and_delays_none | Sim |
| SG-03 | FSR_MEM_001    | TSR_ECC_001         | telemetry_port            | HSI ECC-08, first-fault telemetry: tb_telemetry_port, tb_ecc_data_ram.the_first_error_is_kept_through_a_warm_reset_and_cleared_cold, tb_soc_ecc.the_first_fault_reads_out_over_the_diagnostic_port_with_the_bus_shut | Sim |
| SG-03 | FSR_MEM_001    | TSR_ECC_001         | NEORV32 IMEM              | Instruction memory ECC and Flash | Planned |
| SG-03 | FSR_MEM_002    | TSR_SAFETY_GATE_002 | ecc_data_ram              | tb_ecc_data_ram, tb_soc_bus_fabric | Sim |
| SG-03 | FSR_MEM_002    | TSR_BUS_001         | soc_bus_fabric            | tb_soc_bus_fabric, tb_soc_ecc.double_bit_error_on_a_load_answers_err_and_traps_without_writeback, tb_soc_ecc.double_bit_error_on_a_byte_store_answers_err_and_leaves_the_word | Sim |
| SG-03 | FSR_MEM_002    | TSR_SAFETY_GATE_002 | top_automotive_soc        | tb_soc_ecc.two_stuck_bits_lock_the_soc_within_the_ftti | Sim |
| SG-02 | FSR_DIV_001    | TSR_BUS_001         | soc_bus_fabric            | tb_soc_fabric, tb_soc_bus_fabric | Sim |
| SG-03 | FSR_MEM_002    | TSR_BUS_002         | soc_bus_fabric            | HSI PAR-01: tb_soc_bus_fabric.parity_comes_from_each_slave_before_the_selection | Sim |
| SG-03 | FSR_MEM_002    | TSR_BUS_002         | top_automotive_soc        | HSI PAR-02: tb_soc_fabric.a_stuck_read_data_bit_trips_the_soc_while_the_bus_is_idle, tb_soc_fabric.a_fault_in_core_b_copy_of_the_read_data_trips_the_soc | Sim |
| SG-04 | FSR_LOCK_001   | TSR_WD_001          | hardware_watchdog         | tb_watchdog, tb_watchdog_window | Sim |
| SG-04 | FSR_LOCK_001   | TSR_WD_001          | watchdog_supervisor       | tb_watchdog_supervisor | Sim |
| SG-04 | FSR_LOCK_001   | TSR_WD_001          | top_automotive_soc        | tb_soc_watchdog | Sim |
| SG-04 | FSR_LOCK_001   | TSR_SAFETY_GATE_003 | watchdog_supervisor       | tb_watchdog_supervisor, tb_soc_watchdog | Sim |
| SG-05 | FSR_COMM_001   | TSR_CAN_001         | automotive_can_controller | tb_can, tb_fsm_illegal_recovery, tb_soc_periph_decode | Sim |
| SG-05 | FSR_COMM_001   | TSR_CAN_001         | top_automotive_soc        | tb_soc_lockstep.lockstep_trip_in_a_can_frame_goes_recessive_and_drops_the_frame | Sim |
| SG-05 | FSR_COMM_001   | TSR_CAN_002         | can_receiver              | tb_can_receive, tb_can_rx_data | Sim |
| SG-05 | FSR_COMM_001   | TSR_CAN_002         | automotive_can_controller | Interoperability with an independent controller on a bench (roadmap R4.2) | Planned |
| SG-05 | FSR_COMM_002   | TSR_UART_001        | safe_uart                 | tb_uart, tb_uart_parity_fault, tb_uart_tx_error, tb_soc_uart_error | Sim |
| all   | all            | TSR_TYPES_001       | package_soc_types         | tb_soc_periph_decode, tb_soc_fabric | Sim |
| SG-01 | FSR_MOTION_001 | TSR_LOCKSTEP_001    | lockstep_comparator       | fv_lockstep_comparator: CMP-01, CMP-02, CMP-03, CMP-07 | Formal |
| SG-01 | FSR_MOTION_001 | TSR_SAFETY_GATE_001 | lockstep_comparator       | fv_lockstep_comparator: CMP-04, CMP-05, CMP-06, CMP-08 to CMP-11 | Formal |
| SG-03 | FSR_MEM_002    | TSR_SAFETY_GATE_002 | ecc_data_ram              | fv_store_commit: COM-01 to COM-04 | Formal |
| SG-03 | FSR_MEM_002    | TSR_BUS_001         | soc_bus_fabric            | fv_soc_bus_fabric: BUS-P1 to BUS-P6 | Formal |
| SG-03 | FSR_MEM_002    | TSR_BUS_002         | soc_bus_fabric            | fv_soc_bus_fabric: BUS-P7 | Formal |
| SG-04 | FSR_LOCK_001   | TSR_WD_001          | watchdog_supervisor       | fv_watchdog_cdc: CDC-01 to CDC-06 | Formal |

---

## COVERAGE SUMMARY

Revision 1.0 listed 100% here for every kind of coverage. These are the measured
or countable facts instead.

| Evidence | Status | Notes |
|----------|--------|-------|
| RTL implementation | 18 first-party RTL files: 16 blocks, the core wrapper and the top level | Boot ROM ECC, Flash and the comparator register block are not built (HSI section 5) |
| Testbenches | 49 benches, 324 tests, all passing on GHDL and on Vivado's xsim, with the same output | Plain VHDL-2008 on `sim/tb/lib/tb_pkg.vhd`. Tools and counts: `docs/verification/toolchain.md` |
| Fault injection | Directed forces in the benches, and a seeded campaign at 20 RTL sites, with bursts and common-cause disturbances | `docs/verification/fault_campaign.md`. No netlist-level injection |
| Structural coverage | 100 % of statement lines (1,212) and branch outcomes (855) of the first-party RTL, nothing waived; every assertion shown to fire | xsim code coverage over every test (`docs/verification/coverage.md`); MC/DC, FSM and toggle not measured |
| Mutation | 463 hand-written RTL mutants | Historical: all 386 then present killed at `057c639` (2026-11-07). This milestone's sample is in the evidence file |
| Assertions | Clocked simulation assertions in the RTL | Checked in simulation |
| Formal | 4 SymbiYosys jobs, 28 properties, all proved by k-induction, every cover reached, each job rejects a deliberately broken RTL | Comparator, bus fabric with read data parity, compare before the RAM commit, and the watchdog clock-domain crossings. The self-test and the CPUs are not covered (`docs/verification/formal.md`) |
| Traceability tags | Every first-party RTL file carries a `requirement_id` that this matrix resolves | |

---

## REQUIREMENT IDs

### Safety Goals
Their hazards, ASIL, safe state and FTTI come from the reference item,
`docs/safety/item_definition.md` (a torque-enable supervisor for an EV
traction inverter): all ASIL D, safe state no torque, FTTI 100 ms.

- **SG-01**: Prevent unintended vehicle motion
- **SG-02**: Detect computational divergence
- **SG-03**: Detect memory corruption
- **SG-04**: Detect software lockup, or a supervisor running at the wrong rate
- **SG-05**: Ensure fault-free communication

### Functional Safety Requirements
- **FSR_MOTION_001**: System shall isolate actuators on fault
- **FSR_MOTION_002**: System shall reset on watchdog timeout
- **FSR_DIV_001**: System shall detect core divergence within 2 cycles of it reaching the comparator
- **FSR_DIV_002**: System shall detect and correct memory bit errors
- **FSR_MEM_001**: Memory buses shall use SECDED ECC
- **FSR_MEM_002**: Double-bit errors shall be flagged as fatal
- **FSR_LOCK_001**: Watchdog shall run on independent clock
- **FSR_COMM_001**: CAN TX shall be safety-gated
- **FSR_COMM_002**: UART TX shall verify parity

### Technical Safety Requirements
Defined in `docs/requirements/tsr_safety_core.md`:
`TSR_LOCKSTEP_001` (alias `TSR_LOCKSTEP_042`, retired), `TSR_LOCKSTEP_043`,
`TSR_LOCKSTEP_044`, `TSR_LOCKSTEP_045`, `TSR_CLOCK_001`, `TSR_ACTUATOR_001`, `TSR_BUS_001`, `TSR_BUS_002`, `TSR_ECC_001`, `TSR_WD_001`,
`TSR_RESET_001`, `TSR_SAFETY_GATE_001`, `TSR_SAFETY_GATE_002`,
`TSR_SAFETY_GATE_003`, `TSR_TYPES_001`, `TSR_UART_001`, `TSR_CAN_001`,
`TSR_CAN_002`.
