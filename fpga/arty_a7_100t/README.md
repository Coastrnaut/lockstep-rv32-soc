# Arty A7-100T reference build (roadmap milestone 3)

The first FPGA target: a Digilent Arty A7-100T (`xc7a100tcsg324-1`) built with
Vivado. This folder has everything for a build and a bench run. A build has
**not** run yet: see Status.

| File | What it is |
|------|------------|
| `arty_a7_top.vhd` | Board wrapper: clocks, reset, pins |
| `arty_a7_100t.xdc` | Pins, clocks and clock-domain-crossing constraints |
| `build.tcl` | Vivado non-project build, with checks that stop it if the safety structure is lost or timing is missed |
| `build.py` | Runs `build.tcl`, hashes the bitstream, writes `build/manifest.json` |
| `board_imem_image.vhd` | The board's boot image: `sw/board/` (C, with startup code and a linker script) built by `sw/build.py` with the pinned xPack GCC 15.2.0-1 |
| `check_board.py` | Checks the wrapper and the image with GHDL alone; CI runs it |
| `sim/` | A stand-in for the UNISIM primitives, and the board image testbench (run by `sim/run.py` on GHDL and xsim) |

## The design on the board

| Item | Choice |
|------|--------|
| System clock | 100 MHz oscillator, MMCM to 50 MHz, the frequency the UART and CAN dividers assume |
| Watchdog clock | The FPGA's internal configuration oscillator (STARTUPE2 CFGMCLK, nominally 65 MHz) divided by 64, about 1 MHz. It shares no source with the board oscillator, so a stopped system clock does not stop the watchdog |
| Reset | The reset button, held until the MMCM locks |
| Boot | Boot mode 2: the IMEM image built from `sw/board/`, in both cores |
| Memory | The 256 KB ECC RAM in block RAM: 2,304 Kib of the device's 4,860 Kib. `build.py --ram-addr-bits 12` builds a 32 KB profile instead (`docs/verification/integration.md`) |

| Signal | Board connection |
|--------|------------------|
| UART TX | USB UART bridge (115,200 baud, 8 data bits, even parity, 1 stop bit) and Pmod JA7 |
| CAN TX, RX | Pmod JA1, JA2, for an external 3.3 V CAN transceiver; RX is pulled up |
| `nmi_fault_o` | LED LD5 and Pmod JA3 |
| `actuator_safe_o` | LED LD4 and Pmod JA4 |
| MMCM locked | LED LD6 |
| Watchdog clock | Pmod JA8, and a heartbeat on LED LD7, about 1 Hz |

The board image prints `LS` and RESET_SRC as a digit (0 cold start, 1 early
kick, 2 timeout), then kicks the watchdog in every window and prints a dot. It
waits for the window by reading the watchdog's own counter, so the loose
frequency of the configuration oscillator only changes how often dots appear.

## Build

```bash
python fpga/arty_a7_100t/check_board.py      # GHDL only: wrapper synthesis and the board image
python fpga/arty_a7_100t/build.py            # Vivado: bitstream, reports, manifest.json
```

`build.tcl` turns FSM extraction off and checks, after synthesis, that each of the two
comparators' states and the self-test result keep 8 flip-flops each, with
each comparator's latch and the disagreement latch
(`docs/verification/synthesis.md`), that both cores and the bus delay line are
present, and that the ECC RAM is in block RAM. After routing it requires
setup and hold slack of at least zero, and repeats the flip-flop checks. It
writes utilisation, RAM, timing, CDC, clock-interaction, methodology and DRC
reports.

## Bench procedure (roadmap R3.2)

Each measurement records the sample count, the probe points and the
analyser's resolution.

1. **Boot.** After a power cycle and after the reset button, the UART shows
   `LS0` and a dot about every 45 ms.
2. **Fault to pin.** Trigger on the first edge of `probe_fault_o` (JA3) and
   `probe_safe_o` (JA4), and on the actuator disable stage of the external
   circuit. Inject a fault through the reset-free path that the simulation
   uses: a mismatch needs a debug build that can force a core bus bit, which is
   the next firmware item.
3. **Watchdog.** Stop the system clock by holding the MMCM in reset (a debug
   build input): the actuators must go safe within 50,000 watchdog clocks and
   stay safe. Measure the watchdog clock on JA8.
4. **Watchdog clock lost.** Not testable on this board, because the
   configuration oscillator cannot be stopped. It needs the external
   supervisor of HSI WD-04.
5. **Reset during TX.** Press reset during a UART byte and during a CAN frame:
   UART at mark and CAN recessive at once.
6. **Power.** Note that the system and watchdog clocks share the board's
   supply. A supply fault is a common cause that this board cannot separate.

## Status

| Item | Status |
|------|--------|
| Wrapper, constraints, build script, board image | Written. `check_board.py` passes: the wrapper synthesises in GHDL, and the board image prints `LS0...` on the SoC in simulation |
| Vivado build | **Blocked.** Vivado 2026.1 and its Artix-7 devices are installed on the development machine, but Vivado reports an Alveo licence and `get_parts` then lists no parts, so `build.py` stops at `set_part`. A licence that offers the xc7a100t (the free Standard edition covers it) unblocks it |
| Vivado simulation | **Runs.** `sim/run.py` runs the board image bench, and every bench in `sim/tb`, on xsim as well as GHDL and compares the two (`docs/verification/toolchain.md`) |
| Timing, utilisation, mapped-design checks | Waiting for the build |
| Bench (R3.2) | Needs the board and a logic analyser |
| Compiled firmware with a pinned toolchain (R3.3) | **Done for the first program.** `sw/board/` (startup and trap code in `start.S`, the program in `main.c` on the generated register header, `link.ld`) built by `sw/build.py` with xPack GCC 15.2.0-1 into `board_imem_image.vhd`, with `sw/build/board.map`; CI installs the same compiler and checks the image is a build of the sources. The program uses the UART, the watchdog and, for its stack, the ECC RAM; CAN is not in it yet |
