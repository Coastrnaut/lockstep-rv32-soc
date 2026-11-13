# Evidence index

Document ID: EVI-LRS-001, revision 0.1 (roadmap milestone 5, item 4).

From each requirement of the implemented contract (HSI-LRS-001 revision 1.2,
section 8) to where it is implemented, the test or property that checks it,
and what was measured. `sim/scripts/check_evidence.py` runs in CI and fails if
any bench, test, property or file named here or in the other safety and
verification documents stops existing.

**This is a research release.** Every result below is from RTL simulation or
formal proof on this repository's models. No row has FPGA, bench, gate-level
or assessor evidence, and no ASIL is claimed (`docs/safety/safety_case.md`).

Status: **Sim** checked in simulation. **Formal** proved by k-induction.
**Pending** not yet evidenced. **Waived** deliberately not done, with the
reason. **Out of scope** outside the profile this release covers.

## Bus, response and commit (HSI 8.1)

| Req | Implementation | Test or property | Result | Status |
|-----|----------------|------------------|--------|--------|
| BUS-01 Acceptance edge | `rtl/safety_blocks/lockstep_comparator.vhd` | CMP-01; `tb_soc_lockstep.store_the_cores_disagree_on_never_reaches_a_peripheral` | Proved; passes | Formal, Sim |
| BUS-02 Selected slave | `rtl/safety_blocks/soc_bus_fabric.vhd` | BUS-P5, BUS-P6; `tb_soc_bus_fabric.each_mapped_target_answers_once_with_its_own_data` | Proved; passes | Formal, Sim |
| BUS-03 Response edge | `soc_bus_fabric` | BUS-P4; `tb_soc_fabric.ram_256k.probes_get_one_response_each_and_unmapped_ones_change_nothing` | Proved; one response per request through the cores | Formal, Sim |
| BUS-04 ACK/ERR exclusive | `soc_bus_fabric` | BUS-P1, BUS-P3, BUS-P4 | Proved | Formal |
| BUS-05 Write commit | `rtl/safety_blocks/ecc_data_ram.vhd` | COM-01 to COM-04 | Proved with the real comparator in front of the RAM | Formal |
| BUS-06 Byte lanes | `ecc_data_ram` | `tb_ecc_data_ram.byte_enables_merge_into_either_half`; `tb_soc_bus_fabric.back_to_back_requests_to_both_halves_of_a_word_each_land_once` | Passes | Sim |
| BUS-07 Register directions | Peripherals, `ecc_data_ram` | BUS-P6; `tb_ecc_data_ram.registers_read_only_at_their_own_address_and_ignore_writes` | Proved; passes | Formal, Sim |
| BUS-08 Address holes answer ERR | `soc_bus_fabric` | BUS-P5; `tb_soc_bus_fabric.unmapped_addresses_answer_one_err_with_no_data_and_no_store`; `tb_soc_fabric.ram_32k.probes_get_one_response_each_and_unmapped_ones_change_nothing` | Proved; 11 ERRs on 256 KB, 13 on 32 KB | Formal, Sim |
| BUS-09 Fatal RAM response | `soc_bus_fabric`, `ecc_data_ram` | BUS-P5; `tb_soc_ecc.double_bit_error_on_a_load_answers_err_and_traps_without_writeback`; `tb_soc_ecc.double_bit_error_on_a_byte_store_answers_err_and_leaves_the_word` | Proved; passes | Formal, Sim |
| BUS-10 Denied requests | `lockstep_comparator` | `tb_soc_bus_fabric.double_bit_error_answers_err_and_the_next_request_is_denied` | Passes | Sim |
| BUS-11 Warm reset | `soc_bus_fabric`, `ecc_data_ram` | BUS-P2; `tb_soc_fabric.warm_reset_drops_a_store_caught_between_acceptance_and_commit` | Proved; passes | Formal, Sim |
| BUS-12 CYC, CTI and TAG unused | `rtl/lockstep_core.vhd` leaves them open | Review | | Waived: unused by design; the comparator does not compare them |

## Fault indication (HSI 8.2)

| Req | Implementation | Test or property | Result | Status |
|-----|----------------|------------------|--------|--------|
| FLT-01 Registered fault pin | `rtl/top_automotive_soc.vhd`, `lockstep_comparator` | CMP-06, CMP-11; `tb_soc_ecc.two_stuck_bits_lock_the_soc_within_the_ftti` | Proved; pin at the edge after detection | Formal, Sim |
| FLT-02 MEI maskable only | Top level | `tb_soc_lockstep.lockstep_trip_with_mie_and_meie_masked_is_contained_without_an_interrupt` | Contained with interrupts masked | Sim |
| FLT-03 Illegal comparator state | `lockstep_comparator` | CMP-04, CMP-05, CMP-09; `tb_lockstep_illegal_state.every_one_bit_corruption_of_the_healthy_state_is_a_held_fault` | Proved; every one-bit upset of 0x5A reported at once | Formal, Sim |
| FLT-04 Sticky until cold reset | `lockstep_comparator` | CMP-08; `tb_soc_watchdog.watchdog_reset_leaves_a_lockstep_fault_latched` | Proved; passes | Formal, Sim |

## Safe outputs (HSI 8.3)

| Condition | Test | Result | Status |
|-----------|------|--------|--------|
| Cold reset, no clock | `tb_soc_reset_network.reset_makes_the_outputs_safe_without_a_clock`, `tb_soc_reset_network.reset_puts_the_uart_at_mark_without_a_clock` | Safe at once | Sim |
| Self-test failed or stuck | `tb_soc_lockstep.a_self_test_that_never_finishes_keeps_the_soc_safe_and_reports_it`, `tb_comparator_self_test` | Safe and reported | Sim |
| Mismatch in a UART byte or CAN frame | `tb_soc_lockstep.lockstep_trip_in_a_uart_byte_goes_to_mark_and_drops_the_byte`, `tb_soc_lockstep.lockstep_trip_in_a_can_frame_goes_recessive_and_drops_the_frame` | Mark and recessive from the trip edge | Sim |
| Double-bit error | `tb_soc_ecc.two_stuck_bits_lock_the_soc_within_the_ftti` | Safe within the provisional 50 µs | Sim |
| Stopped system clock | `tb_soc_watchdog.watchdog_makes_the_soc_safe_if_the_clock_stops` | The watchdog resets the SoC | Sim |
| Faults after the comparator | Fault campaign: CAN and UART output registers | 9 of 9 effective faults undetected | Pending: no read-back (FMEDA FM-19, FM-20, FM-22) |

## Watchdog (HSI 8.4)

| Req | Test | Result | Status |
|-----|------|--------|--------|
| WD-01 Inclusive window | `tb_watchdog_window.kick_at_min_is_accepted`, `tb_watchdog_window.kick_at_max_is_accepted`, `tb_watchdog_window.kick_at_min_minus_one_is_early`, `tb_watchdog_window.no_kick_at_max_is_the_timeout`, `tb_watchdog_supervisor.kick_sampled_at_each_window_boundary_at_every_clock_ratio` | Boundaries exact at every tested clock ratio | Sim |
| WD-02 Duplicate kicks | `tb_watchdog_supervisor.kick_made_while_one_is_crossing_counts_as_the_same_kick` | Passes | Sim |
| WD-03 Reset cause | `tb_watchdog_supervisor.cold_reset_clears_reset_src`, `tb_soc_watchdog.program_kicks_in_the_window_then_times_out_then_kicks_early` | Passes | Sim |
| WD-04 Watchdog clock loss | `tb_soc_watchdog.soc_still_runs_with_a_dead_oscillator` shows the SoC runs unsupervised | No containment | Pending: board supervisor (DFA DF-04) |

## ECC repair and telemetry (HSI 8.5)

| Req | Test | Result | Status |
|-----|------|--------|--------|
| ECC-05 Writeback | `tb_ecc_data_ram.a_load_writes_back_a_stored_single_bit_error` | A second load finds nothing | Sim |
| ECC-06 Patrol | `tb_ecc_data_ram.the_patrol_repairs_a_stored_error_that_nothing_reads`, `tb_ecc_data_ram.the_patrol_reports_an_uncorrectable_word_without_tripping` | Repaired within one pass; latent DBE flagged, no trip | Sim |
| ECC-07 Arbitration | `tb_ecc_data_ram.the_patrol_covers_the_ram_under_back_to_back_accesses_and_delays_none` | 65,538 clocks a pass under the worst load; no access delayed | Sim |
| ECC-08 Telemetry | `tb_ecc_data_ram.the_first_error_is_kept_through_a_warm_reset_and_cleared_cold`, `tb_telemetry_port`, `tb_soc_ecc.the_first_fault_reads_out_over_the_diagnostic_port_with_the_bus_shut` | Record read over SPI with the bus shut | Sim |

## Lockstep and diagnostic coverage

| Claim | Evidence | Result | Status |
|-------|----------|--------|--------|
| Core B is core A two clocks late | `tb_soc_lockstep.core_b_is_core_a_two_clocks_ago_all_through_the_program`, `tb_soc_trace.core_b_retires_exactly_what_core_a_retired_all_through_the_program` | Every input and every retirement | Sim |
| A common glitch in one cycle is caught | `tb_soc_lockstep.same_glitch_on_both_core_buses_is_caught`, `tb_soc_lockstep.same_glitch_on_both_cores_read_data_is_caught` | Passes | Sim |
| Comparator latent faults are tested | `tb_comparator_self_test`, `tb_soc_lockstep.comparator_stuck_at_no_error_keeps_the_soc_safe` | At startup only | Sim; periodic test Pending (R2.4, FMEDA FM-07) |
| Register-only divergence | `tb_soc_trace.a_register_only_divergence_is_caught_by_the_trace_and_not_by_the_bus` | Caught by the trace, in verification builds only | Sim |
| Fault campaign coverage | `docs/verification/fault_campaign.md`, seed 2026 | 67 of 88 effective faults detected in time; the rest are after the comparator or in the reset synchroniser | Sim; sample, not an FMEDA coverage figure |
| Test strength | `sim/scripts/mutate.py`, 430 mutants | Every mutant of R4.1 and R4.3 killed; full campaign before a release | Sim |
| Synthesis keeps the safety encodings | `docs/verification/synthesis.md`, `fpga/arty_a7_100t/build.tcl` | Checks written | Pending: no Vivado build has run |

## Safety analysis

| Item | Document | Status |
|------|----------|--------|
| Item definition, safety goals, FTTI, external safe state | | Pending: needs an integrator and a target (milestone 5, item 1) |
| FMEDA inputs | `docs/safety/fmeda_inputs.csv`, checked by `sim/scripts/fmeda.py` | 25 failure modes classified; failure rates and coverages TBD, so no metric is computed |
| Earlier FMEDA figures | `docs/safety/fmeda_analysis.md` | Illustrative, kept for provenance; superseded by the input table |
| Dependent-failure analysis | `docs/safety/dependent_failure_analysis.md` | Checklist with 17 initiators; 5 open, 4 target-dependent; not independently reviewed |
| Tool confidence | `docs/safety/dependent_failure_analysis.md` | Arguments listed; no tool qualified |
| CAN interoperability | `docs/verification/can_support.md` | Support matrix in simulation; bench measurement Pending |
| Hardware | `fpga/arty_a7_100t/README.md` | Pending: no build, no bench run |
| External assessment | | Out of scope for this release |
