# Arty A7-100T: setting up and testing the lockstep SoC

The first FPGA target: a Digilent Arty A7-100T (`xc7a100tcsg324-1`), built
with Vivado. This guide takes you from a bare board to the SoC printing its
self-checks on the UART, and then through the bench tests (roadmap R3.1,
R3.2, R3.3).

> **Before you power the board: put a jumper wire from Pmod JA pin 4 to Pmod
> JB pin 7 (JA4 to JB7).**
>
> JA4 carries `actuator_safe_o`; JB7 is `actuator_fb_i`, the line read back
> from the actuator's driver (TSR_ACTUATOR_001). On a bare board there is no
> driver, so the jumper stands in for it. Without it JB7's pull-up reads "safe"
> while the program releases the actuator, the read-back disagrees with its
> command, and the SoC goes to its safe state at start: the fault LED lights
> and the UART stays silent after `LS`. That is the read-back working, not a
> broken board.

A build has **not** run on hardware yet; see Status at the end.

## 1. What you need

| Item | Needed for | Notes |
|------|------------|-------|
| Digilent Arty A7-100T | Everything | The 35T is too small for the 256 KB ECC RAM; `--ram-addr-bits 12` builds a 32 KB profile if needed |
| Micro-USB cable | Programming, power and the UART | The board's FTDI bridge carries both JTAG and the UART |
| One jumper wire (female-female) | Everything | **JA4 to JB7**, see above |
| Vivado ML **Standard** 2026.1 (free), or a licence covering the xc7a100t | Building the bitstream | Enterprise with only an Alveo licence lists no parts: `docs/verification/bench_hardware.md`, section 1 |
| Python 3.11 or later | `build.py`, `sw/build.py` | |
| A serial terminal | Reading the UART | PuTTY, Tera Term, minicom or `python -m serial.tools.miniterm` |
| 3.3 V CAN transceiver breakout and a second CAN node | The CAN check (`C0`) | Optional: without them the program prints `C1`. See section 6 |
| Logic analyser, 8 channels, 100 MS/s or more | The timing tests in section 7 | Optional |

The full bench list, with examples, is in `docs/verification/bench_hardware.md`.

## 2. The design on the board

| Item | Choice |
|------|--------|
| System clock | The 100 MHz oscillator, an MMCM to 50 MHz, the frequency the UART and CAN dividers assume |
| Watchdog clock | The FPGA's internal configuration oscillator, STARTUPE2 CFGMCLK, 65 MHz typical and ±50 % at most (DS181 v1.27, Table 66), divided by 64: 0.51 to 1.52 MHz. It shares no source with the board oscillator, so a stopped system clock does not stop the watchdog. The clock monitor's tolerances are set from that range, 40 % below and 110 % above (`docs/verification/clocks.md`) |
| Reset | The red RESET button (`ck_rst_i`), held until the MMCM locks |
| Boot | Boot mode 2: the IMEM image of the program, in both cores |
| Memory | The 256 KB ECC RAM in block RAM: 2,304 Kib of the device's 4,860 Kib |

### Pins

| Signal | Board connection | Direction |
|--------|------------------|-----------|
| UART TX (`uart_tx_o`) | The USB UART bridge, and Pmod JA7 | Out |
| CAN TX, RX (`can_tx_o`, `can_rx_i`) | Pmod JA1, JA2, to a 3.3 V CAN transceiver; RX is pulled up | Out, in |
| `nmi_fault_o` | LED LD5 and Pmod JA3 | Out |
| `actuator_safe_o` (first channel, high: safe) | LED LD4 and Pmod JA4 | Out |
| `actuator_en_o` (second channel, high: may be powered) | Pmod JB4 | Out |
| `actuator_fb_i` (first channel read back) | Pmod JB7, pulled up | In: **jumper from JA4** |
| Diagnostic SPI (ECC first-fault record) | Pmod JB1 (chip select, pulled up), JB2 (clock), JB3 (data out) | In, in, out |
| MMCM locked | LED LD6 | Out |
| Watchdog clock | Pmod JA8, and a heartbeat on LED LD7, about 1 Hz | Out |

Pmod pin numbers: pin 1 is marked on the board's silkscreen; pins 1 to 6 are
the top row (5 is GND, 6 is 3.3 V) and 7 to 12 the bottom row (11 GND,
12 3.3 V).

## 3. Build the bitstream

```bash
git clone --recursive https://github.com/Coastrnaut/lockstep-rv32-soc.git
cd lockstep-rv32-soc
python fpga/arty_a7_100t/check_board.py            # GHDL only: the wrapper synthesises, the image runs
python fpga/arty_a7_100t/build.py                  # Vivado: bitstream, reports, manifest.json
python fpga/arty_a7_100t/build.py --program hello  # the same, booting hello, world
```

`check_board.py` needs only GHDL and takes a few seconds; run it first. It
should end with `ok: printed LS0E0C0...`.

`build.py` runs `build.tcl` in Vivado batch mode, into
`fpga/arty_a7_100t/build/`: `arty_a7_lockstep.bit`, the utilisation, timing,
CDC, DRC and methodology reports, and `manifest.json` (commit, Vivado
version, program, timing, utilisation, the checks that passed, the
bitstream's SHA-256). The build stops with `BUILD CHECK FAILED` if synthesis
lost a safety structure: each comparator's 8-bit state and latch, the
disagreement latch, comparator B's own delay line and reset synchroniser,
the clock monitor's latch and the self-test result
(`docs/verification/synthesis.md`); or if timing is not met after routing.

If `build.py` says Vivado lists no xc7a100t, fix the licence first
(`docs/verification/bench_hardware.md`, section 1).

## 4. Program the board

1. Plug in the USB cable. The power LED lights.
2. Fit the **JA4 to JB7** jumper.
3. In Vivado: *Open Hardware Manager*, *Open Target*, *Auto Connect*, then
   *Program Device* with `fpga/arty_a7_100t/build/arty_a7_lockstep.bit`.
   Or, with openFPGALoader: `openFPGALoader -b arty_a7_100t fpga/arty_a7_100t/build/arty_a7_lockstep.bit`.

This loads the FPGA until power is removed. To keep it across power cycles,
write it to the board's SPI flash (Vivado: *Add Configuration Memory Device*,
the Arty's flash part, with a `.bin` made by `write_cfgmem`).

## 5. First power-on: what you should see

Open the serial port the board's USB bridge provides (the higher-numbered of
its two ports on Windows) at **115,200 baud, 8 data bits, even parity, 1 stop
bit, no flow control**. The UART sends a parity bit, so a terminal left at
"no parity" shows garbage. Press RESET.

The board program prints, in order:

| Text | Meaning |
|------|---------|
| `LS` | Reset released, both cores running the program in lockstep |
| `0` | RESET_SRC: 0 after a cold start, 1 after an early watchdog kick, 2 after a watchdog timeout |
| `E0` | ECC RAM: a pattern and its complement written and read back through the comparator, with no error counted. `1`: read back wrong; `2`: corrected errors; `3`: an uncorrectable word |
| `C0` / `C1` | CAN: one frame (ID 0x123, data "LS") acknowledged with no transmit errors; `C1` with no other node on the bus or no transceiver |
| `.` | One per watchdog kick, about every 45 ms (26 to 98 ms over CFGMCLK's range) |

So a bare board prints `LS0E0C1` and then dots; with a CAN node (section 6),
`LS0E0C0`.

The LEDs:

| LED | Normal | Meaning when it is not |
|-----|--------|------------------------|
| LD4 (actuator safe) | Off once the program runs | On: a fault, a reset, or a read-back that does not follow (check the jumper) |
| LD5 (fault) | Off | On: the comparators tripped, the self-test failed, or the clock monitor saw a wrong system clock |
| LD6 (MMCM locked) | On | Off: the system clock is not running |
| LD7 (heartbeat) | Blinks about once a second | Steady: no watchdog clock |

To run hello, world instead, build with `--program hello`: it prints
`Hello, world!` once and keeps the watchdog content.

## 6. CAN

The SoC has a CAN controller, not a transceiver. Wire a 3.3 V transceiver
breakout (TCAN1042-3.3 or SN65HVD230) to JA1 (its TXD), JA2 (its RXD), 3.3 V
and GND, and its CANH/CANL to a second node (PCAN-USB, Kvaser Leaf Light or a
CANable) over twisted pair with 120 Ω at each end, at **500 kbit/s**.

After RESET the program sends one Classical CAN frame, standard ID `0x123`,
two data bytes `4C 53` ("LS"); the second node must receive it and the UART
shows `C0`. The supported frame formats, error handling and what a bench must
still measure are in `docs/verification/can_support.md`.

## 7. Bench tests (roadmap R3.2)

Record for each: the sample count, the probe points and the analyser's
resolution.

1. **Boot.** After a power cycle and after RESET, the UART shows `LS0E0C0`
   (or `C1`) and dots. Twenty resets, twenty clean starts.
2. **Actuator read-back.** Remove the JA4 to JB7 jumper and press RESET:
   LD4 and LD5 stay on, JB4 (`actuator_en_o`) stays low, and nothing follows
   `LS0E0C*` on the UART. Refit the jumper and press RESET: normal again.
3. **Second channel.** Probe JA4 and JB4 together: JB4 is high only while JA4
   is low. On every reset and every fault JB4 falls, without waiting for a
   clock.
4. **Fault to pin.** Trigger on the first edge of `probe_fault_o` (JA3), and
   measure to JA4 and JB4. Injecting a lockstep mismatch on the board needs a
   debug build that can force a core bus bit; that is the next firmware item.
5. **System clock monitor.** A test build that gates `clk_i` from a switch:
   stopping it must raise LD5 and hold the SoC in reset within two monitor
   windows (512 watchdog clocks, under 1 ms), well inside the watchdog's
   timeout.
6. **Watchdog.** Measure the watchdog clock on JA8, and the time between dots;
   a program that stops kicking (a debug build) must reset the SoC within the
   window.
7. **Reset during transmission.** Press RESET during a UART byte and during a
   CAN frame: the UART line goes to mark and CAN recessive at once.
8. **Watchdog clock lost.** Not testable on this board: the configuration
   oscillator cannot be stopped. It needs the external supervisor of HSI WD-04.
9. **Power.** The system and watchdog clocks share the board's supply; a
   supply fault is a common cause this board cannot separate.

## 8. Without a board

```bash
python fpga/arty_a7_100t/check_board.py      # GHDL: the wrapper synthesises, the image prints LS0E0C0...
cd sim && python run.py "tb_board_firmware.*" "tb_hello_world.*"   # both programs, GHDL and xsim
python sw/build.py                           # rebuild both images after changing sw/ (pinned xPack GCC)
```

The simulation bench puts an acknowledging CAN node on the bus, so it expects
`C0`.

## Files

| File | What it is |
|------|------------|
| `arty_a7_top.vhd` | Board wrapper: clocks, reset, pins |
| `arty_a7_100t.xdc` | Pins, clocks and clock-domain-crossing constraints |
| `build.tcl` | Vivado non-project build, with checks that stop it if the safety structure is lost or timing is missed |
| `build.py` | Runs `build.tcl` (`--program board` or `hello`, `--ram-addr-bits`), hashes the bitstream, writes `build/manifest.json` |
| `board_imem_image.vhd` | The board program's image: `sw/board/main.c` with `sw/common/`, built by `sw/build.py` with the pinned xPack GCC 15.2.0-1 |
| `check_board.py` | Checks the wrapper and the image with GHDL alone; CI runs it |
| `sim/` | A stand-in for the UNISIM primitives, and the board image bench (run by `sim/run.py` on GHDL and xsim) |

## Status

| Item | Status |
|------|--------|
| Wrapper, constraints, build script, programs | Written. `check_board.py` passes, and both programs pass on GHDL and xsim |
| Vivado build | **Blocked** on the licence: the installed edition is Vivado ML Enterprise with only an Alveo licence. Adding Vivado ML Standard, or its free licence, unblocks it |
| Timing, utilisation, mapped-design checks | Waiting for the build |
| Bench (R3.2) | Needs the board and the equipment in section 1 |
| Compiled firmware (R3.3) | Done in simulation: the board program (UART, watchdog, ECC RAM, CAN) and hello, world, built with the pinned compiler; CI checks the images |
