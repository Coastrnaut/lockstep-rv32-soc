# Integration refactoring (roadmap R4.3)

Three changes that remove duplication from the SoC's integration without
changing what it does: one register table, one core wrapper, and a RAM size
profile at the board boundary.

## One register table

`tools/register_map.py` holds every address the RTL decodes. It writes
the address constants in `rtl/pkg/package_soc_types.vhd` (between the GENERATED
markers), the C header `sw/include/lockstep_soc_regs.h`, and the reference page
`docs/safety/register_map.md`. `tools/check_fixtures.py`, which CI runs,
regenerates all three and fails if any differs, so an address cannot change in
one place only.

The addresses are those published in HSI sections 3 and 5.1, unchanged. The
benches keep their own expectations: `tb_soc_bus_fabric` and `tb_soc_fabric`
probe the decode with literal addresses, not with the generated constants, so a
wrong table entry fails them rather than moving with them.

## One core wrapper

`rtl/soc/lockstep_core.vhd` is one NEORV32 as the SoC uses it. Both cores are
instances of it, so the 160-line NEORV32 configuration is written once and the
two cores cannot be configured apart. Before, the top level had two copies of
it, about 270 lines each, and a diagnostic process (`p_diag_monitor`) whose
only job was to read the unused NEORV32 outputs so that `-Wall` did not
report them. The wrapper leaves those outputs open, so the process is gone.

What leaves the wrapper is what the SoC uses: the XBus request and response,
the three interrupts and the trace port of the one hart. Its ports keep
NEORV32's names, so the benches reach a core's bus inputs as before
(`i_cpu_master.xbus_dat_i`) and its internals one level down
(`i_cpu_master.i_neorv32.core_complex_gen(0)...`).

The top level went from 1,112 lines to about 400.

### Equivalence evidence

| Check | Before | After |
|-------|--------|-------|
| Full regression | 235 of 235 pass | 235 of 235 pass, the same tests |
| Fault campaign, seed 7, 2 trials per site and the reference: every result file (`fault_result.txt`: injection, detection and safe times, every UART byte and CAN frame with its time, the first retirement divergence and the retirement count) | 31 files | The same 31 files, byte for byte |
| Mutation patterns (`mutate.py --check`) | 416 apply | 416 apply; the seven IRQ patterns now allow for the realigned port map |
| GHDL lint, VSG, board check | Pass | Pass |

The campaign comparison is the strongest of these: it runs the firmware on both
cores for 700 µs per trial, with faults at 15 sites, and compares outputs and
timings to the picosecond.

## RAM size profile

`top_automotive_soc` has a generic `g_ram_addr_bits`, 4 to 15 bits of 64-bit
words. 15, the default, is the 256 KB of HSI section 5; 12 is 32 KB. It sets
both the RAM's size and the fabric's decode of it, so the window above a
smaller RAM answers ERR, as the HSI requires for any address it does not list.
The board wrapper passes it on, and `fpga/arty_a7_100t/build.py
--ram-addr-bits N` builds that profile and records it in the build manifest.

| Test | What it shows |
|------|---------------|
| `tb_soc_fabric.ram_256k.probes_get_one_response_each_and_unmapped_ones_change_nothing` | The program's probes on the full RAM: 11 ERRs, and the last RAM word reads back |
| `tb_soc_fabric.ram_32k.probes_get_one_response_each_and_unmapped_ones_change_nothing` | The same program on 32 KB: the last-word store and load answer ERR too, 13 ERRs, and the word does not read back |
| Every `tb_soc_fabric` test | No request answered ERR writes the RAM |
| Mutant "profile: fabric keeps the full RAM decode" | Killed: a 32 KB RAM behind a full decode answers ACK past its end |
| Mutant "profile: RAM keeps its full size" | Killed: a full RAM behind a 32 KB decode stores a write the fabric refused |

The clock is not a profile. The UART and CAN dividers assume 50 MHz, and the
board makes 50 MHz from its oscillator, so a second clock target needs those
dividers made generic first.

## Not done

| Item | Status |
|------|--------|
| Area and timing of each profile | Not recorded. `build.py` records them per profile, but the Artix-7 devices are installed, but Vivado reports an Alveo licence and `get_parts` then lists no parts (`docs/verification/toolchain.md`), so no build has run (see `fpga/arty_a7_100t/README.md`) |
| Clock profiles | Not started: needs generic UART and CAN timing |
| Register descriptions beyond addresses | Field layouts are in the table's text and the HSI, not generated |
