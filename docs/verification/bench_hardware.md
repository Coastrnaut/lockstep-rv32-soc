# Bench hardware (roadmap R3.2, R4.2) and the Vivado build (R3.1)

What a bench needs to run the Arty A7-100T build, measure its safety
reactions, and validate its CAN controller, and how to get the Vivado build
running on the development machine.

## 1. Getting the Vivado build to run

`fpga/arty_a7_100t/build.py` stops at `set_part`: Vivado 2026.1 reports "A
valid Vivado Design Suite ALVEO license has been detected", and `get_parts`
returns no parts, although `data/installed.devices` lists the xc7a100t.

**Cause.** The install log (`%USERPROFILE%\.Xilinx\xinstall\xinstall-*.log`)
shows the package installed was **Vivado ML Enterprise Edition**
(`VivadoMLEnterpriseEdition`). Enterprise needs a licence for device access.
The only licence it finds covers Alveo accelerator cards, and its folder for
the free device licence, `Vivado\data\licenses_webpack`, is empty. The
xc7a100t is in the free **Vivado ML Standard** edition's device list, so no
paid licence is needed, only the right edition or licence.

**Fix, in order of preference (each is the user's to do; nothing here changes
the licence setup):**

1. Add Vivado ML Standard: run the 2026.1 installer again (or *Add Design
   Tools or Devices* in the AMD Information Center), choose **Vivado ML
   Standard**, and keep the Artix-7 devices. Standard ships its own device
   licence and needs no licence file.
2. Or keep Enterprise and add the free licence: on AMD's Product Licensing
   site, generate the no-charge **Vivado ML Standard** licence (node-locked),
   and load it with the Vivado License Manager (`vlm`, *Load License*).
3. Then check, in the Vivado Tcl console:

   ```tcl
   get_parts xc7a100tcsg324-1
   ```

   which must list the part. `python fpga/arty_a7_100t/build.py` then runs
   synthesis, place and route, the safety-structure checks in `build.tcl`,
   and writes the bitstream and `build/manifest.json`.

If an `XILINXD_LICENSE_FILE` or `LM_LICENSE_FILE` variable is set later and
points at the Alveo licence only, it can hide the free one: Vivado's
*Help > Manage License* shows which licences it found.

## 2. Bench hardware

### Board and wiring (R3.1, R3.2)

| Item | Example | Why |
|------|---------|-----|
| FPGA board | Digilent Arty A7-100T (xc7a100tcsg324-1) | The build's target |
| USB cable | Micro-USB | Programming, and the UART (`LS0E0C0...`) |
| Jumper wire | JA4 to JB7 | Closes the actuator read-back on a bare board; without it the SoC goes to its safe state at start (`TSR_ACTUATOR_001`) |
| Watchdog oscillator | 1 MHz crystal oscillator module on a Pmod pin, ±100 ppm or better | Replaces CFGMCLK (±50 %, `docs/verification/clocks.md`) as `wd_clk_i`; needs a board-wrapper option to take it |
| Reset supervisor | A voltage supervisor with a manual-reset input, on `ck_rst` | Filtered, monitored cold reset (AoU-04 in `docs/safety/item_definition.md`) |

### Measuring the safety reactions (R3.2)

| Item | Example | Why |
|------|---------|-----|
| Logic analyser, 8 channels, 100 MS/s or more | Saleae Logic Pro 8, or Digilent Analog Discovery 3 | Fault-to-pin timing on JA3 (`probe_fault_o`), JA4 (`probe_safe_o`), JB4 (`actuator_en_o`), JA8 (`probe_wd_clk_o`), against the UART |
| Actuator stand-in | An H-bridge Pmod (e.g. Digilent Pmod HB5) and a small DC motor; or two MOSFET switches and LEDs | The two disable paths (JA4 blocks, JB4 supplies) with the driver's enable state wired back to JB7 |
| Means to stop the system clock | A test build that gates `clk_i` from a switch | The clock monitor's reaction on the board (`tb_soc_watchdog.a_stopped_system_clock_is_reported_within_two_monitor_windows` in simulation) |

### CAN (R4.2)

| Item | Example | Why |
|------|---------|-----|
| 3.3 V CAN transceiver | A TCAN1042-3.3 or SN65HVD230 breakout, on JA1 (TX) and JA2 (RX) | The SoC has a CAN controller, not a transceiver |
| Second node, or analyser | PEAK PCAN-USB, Kvaser Leaf Light, or a CANable with SocketCAN | Acknowledges frames (the board program prints `C0` only with an ACK), sends frames to the SoC, and records error frames |
| Bus | Twisted pair, 120 Ω at each end | A real 500 kbit/s bus |

With these, the support matrix in `docs/verification/can_support.md` can be
measured on a wire: frame formats, arbitration, ACK, error frames, error
counters and bus-off against an independent controller.

## 3. What each closes

| Roadmap item | Closed by |
|--------------|-----------|
| R3.1 FPGA build | Section 1 |
| R3.2 bench bring-up | Board, wiring and measurement equipment |
| R4.2 CAN validation | The CAN rows |
| AoU-03, AoU-04 (item definition) | The watchdog oscillator and the reset supervisor |
