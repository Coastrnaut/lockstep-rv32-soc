# CAN support matrix (roadmap R4.2)

What the CAN node (`automotive_can_controller` with `can_receiver`) supports,
against Classical CAN as ISO 11898-1 defines it, and how far each item has been
checked. Every check so far is in simulation, against models written in this
repository (`sim/scripts/can_frame_model.py`, `sim/tb/lib/can_test_node.vhd`).
No real transceiver, independent controller or analyser has been on the bus
yet, so nothing here is a measured bound on hardware.

**Profile:** Classical CAN, 500 kbit/s from a 50 MHz clock
(`g_clks_per_bit = 100`), one transmit mailbox, one receive buffer, register
interface of HSI section 3.4.

Status words: **Sim** checked in simulation by the named tests. **Design** true
by construction, not tested at its limit. **No** not supported.

## Frames

| Item | Transmit | Receive | Evidence |
|------|----------|---------|----------|
| Base data frame, 11-bit ID, DLC 0 to 8 | Sim | Sim | `tb_can`: `frame_fields_for_every_dlc`, `every_identifier_bit_reaches_the_wire`, `wire_bits_match_reference_model`; `tb_can_receive.every_frame_is_received_and_acknowledged` (32 reference frames) |
| DLC 9 to 15 | Sim: sends 8 bytes, DLC as written | Sim: 8 bytes | `tb_can.dlc_above_8_sends_8_bytes` |
| Extended data frame, 29-bit ID | **No** | Sim | `tb_can_receive.every_frame_is_received_and_acknowledged` |
| Remote frame | **No** | Sim, base and extended | Same |
| Error frame, active and passive flags | Sim | Sim | `tb_can.missing_ack_sends_error_flag_and_retries`, `error_passive_sends_recessive_flags_and_suspends`; `tb_can_receive.bad_frames_get_an_error_flag_in_the_right_bit` |
| Overload frame | **No**: never sent | Tolerated: a dominant intermission bit holds off the next frame | `tb_can_receive.overload_flag_from_another_node_just_holds_off_the_next_frame`, `tb_can.dominant_in_intermission_does_not_repeat_the_frame` |
| CAN FD, CAN XL | **No** | **No**; how this receiver answers an FD frame on a mixed bus is not tested | |

## Bit timing and synchronisation

| Item | Status | Value and evidence |
|------|--------|--------------------|
| Bit time | Sim | 100 clocks; `tb_can.bits_last_exactly_one_bit_time` |
| Sample point | Design | 75 % of the bit, less 3 clocks for the input synchroniser |
| Hard synchronisation on SOF | Sim | Any phase: `tb_can_receive.a_sof_is_taken_once_at_any_phase_of_the_bit_timer`, `tb_can.joins_a_simultaneous_start_at_any_phase` |
| Resynchronisation, SJW | Sim | SJW = 1/8 bit (12 clocks); one edge per bit; not on a node's own ACK or flag: `late_edge_moves_the_sample_point_later_up_to_a_limit`, `early_edge_moves_...`, `only_one_edge_moves_...`, `no_edge_after_a_dominant_bit_...` |
| Oscillator mismatch | Sim | Frames from senders 1 % and 1.5 % fast and slow are received: `tb_can_receive.fast_and_slow_senders_are_followed` |
| Transceiver and bus loop delay | Design | Must stay below the sample point less 3 clocks, 72 clocks or 1.44 µs at 500 kbit/s. The benches use a 20 ns loop |
| Other bit rates | Design | `g_clks_per_bit` from 8 to 65,535; only 100 is tested. The UART and system clock are fixed at 50 MHz (`docs/verification/integration.md`) |

## Arbitration and bus access

| Item | Status | Evidence |
|------|--------|----------|
| Wait for bus idle, 11 recessive bits after reset | Sim | `tb_can.waits_for_11_recessive_bits_after_reset`, `tb_can_receive.nothing_is_received_until_the_bus_has_been_idle` |
| Lose arbitration, stop, receive the winner, retry | Sim | `tb_can.lost_arbitration_stops_and_retries`, `tb_can_receive.losing_arbitration_leaves_the_winner_received` |
| Start in the third intermission bit | Sim | `tb_can.joins_a_sof_in_the_third_intermission_bit`, `tb_can_receive.frames_follow_each_other_in_the_third_intermission_bit` |
| Stuck-dominant bus | Sim: never starts | `tb_can.stuck_dominant_bus_blocks_transmission` |
| Multi-node traffic | Sim, with the bench's model nodes | `tb_can`, `tb_can_receive` |

## Error handling and fault confinement

| Item | Status | Evidence |
|------|--------|----------|
| Bit, stuff, CRC, form and ACK errors | Sim | `tb_can.dominant_on_recessive_bit_is_a_bit_error`, `recessive_on_dominant_bit_...`, `dominant_on_control_bit_...`; `tb_can_receive.bad_frames_get_an_error_flag_in_the_right_bit` |
| Arbitration exceptions: a dominant ID bit is not an error; a stuff error before RTR is not counted | Sim | `dominant_on_id_bit_loses_arbitration_without_a_flag`, `dominant_stuff_bit_in_arbitration_is_not_counted` |
| TEC: +8 per error, −1 per good frame | Sim | `status_register_follows_the_frame_and_the_error_counter` |
| REC: +1, +8 for a dominant bit after the flag, −1 per good frame, stops at 255 | Sim | `dominant_after_the_flag_adds_8`, `good_frames_take_the_error_count_down_one_at_a_time`, `error_count_stops_at_255` |
| Error passive at 128, recessive flags, suspend transmission | Sim | `error_passive_sends_recessive_flags_and_suspends`, `error_passive_suspends_after_a_good_frame`, `suspend_time_gives_way_to_another_node`, `error_passive_at_128_with_recessive_flags` |
| A lone node retries forever while error passive and never reaches bus-off | Sim, deliberate (the ISO 11898-1 ACK-error exception) | The mutant `can: lone node ACK exception removed` is killed; `error_passive_flag_answered_on_the_bus_is_counted` checks the other side, an answered flag counts |
| Bus-off at TEC 256 | Sim | `bus_off_after_32_errors_until_reset`, `a_bus_off_node_stays_off_the_bus` |
| Bus-off recovery, 128 × 11 recessive bits | **No**: bus-off is latched until reset | Decision: recovery is left to a reset, so software and the supervisor decide when the node comes back |
| TEC +8 for a transmitter's bit error in its own flag; 14 dominant bits after a flag; 8 more after that | **No** | Known gaps against ISO 11898-1. A node that keeps failing still reaches error passive and bus-off through its other errors |

## Interface and safety

| Item | Status | Evidence |
|------|--------|----------|
| One transmit mailbox, locked while its frame is pending | Sim | `mailbox_is_locked_until_the_frame_is_sent`, `mailbox_keeps_its_contents_to_send_again` |
| One receive buffer; the first frame kept on overrun, which is reported | Sim | `tb_can_receive.full_buffer_keeps_the_first_frame_and_reports_the_second`, `a_frame_on_the_clock_of_a_release_is_kept` |
| Acceptance filtering | **No**: every frame from another node is delivered | |
| Own frames not delivered back | Sim | `own_frames_are_not_delivered` |
| Word stores only to the registers | Sim | `partial_stores_do_not_reach_the_registers` |
| Comparator trip: TX recessive at once, mailbox cleared, frame abandoned without retry; receiving and acknowledging stop | Sim | `gate_drop_forces_recessive_and_abandons_frame`, `one_clock_gate_drop_leaves_no_glitch`, `gate_down_stops_acknowledging_and_receiving`; `tb_soc_lockstep.lockstep_trip_in_a_can_frame_goes_recessive_and_drops_the_frame` |
| Reset: TX recessive without a clock | Sim | `tb_soc_reset_network` |

## What the bench work still has to measure

These need the board, an external 3.3 V transceiver on Pmod JA, and at least
one independent controller or analyser (`fpga/arty_a7_100t/README.md`):

1. Golden frames compared with a wire capture, for every DLC and the stuffing
   corner cases above.
2. Loop delay and sample point margin with the real transceiver, and frames
   from a sender with a measured oscillator offset, to replace the simulated
   1.5 %.
3. Arbitration against an independent node, both winning and losing, and
   multi-node traffic with the receive overrun counted under load.
4. Error and recovery on an isolated bench: forced bit errors, missing ACK,
   error passive, bus-off and the reset that recovers it.

Each run records phase, oscillator mismatch, propagation delay, sample count
and the probe points. Until then the supported subset above is a simulation
claim only.
