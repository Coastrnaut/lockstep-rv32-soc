# Clocks: the system clock monitor and the board's watchdog clock

How the system clock is checked (TSR_CLOCK_001), and what the Arty board's
watchdog clock means for that check and for the watchdog itself.

## The monitor

`rtl/safety/clock_monitor.vhd` divides the system clock until the divider's
top bit changes at most once every four watchdog clocks, and counts those
changes in the watchdog clock domain over windows of 256 watchdog clocks. A
count outside the accepted range latches a fault that raises `nmi_fault_o` and
holds the SoC in reset, both without needing the system clock, until a cold
reset. The first window after a reset is not judged.

The count goes with the system clock's frequency, and with one over the
watchdog clock's. Its accepted range is therefore set by two tolerances:

| Generic (top level) | Meaning | Default |
|---------------------|---------|---------|
| `g_sys_clk_hz` | Nominal system clock | 50 MHz |
| `g_wd_clk_hz` | Nominal watchdog clock | 1 MHz |
| `g_clk_tol_low_pct` | How far below nominal the count may fall | 25 % |
| `g_clk_tol_high_pct` | How far above nominal the count may rise | 25 % |

## The Arty A7-100T: CFGMCLK

The board has one oscillator, the 100 MHz one the system clock comes from, so
its watchdog clock is the FPGA's internal configuration oscillator, CFGMCLK,
from STARTUPE2, divided by 64.

**DS181 (Artix-7 Data Sheet: DC and AC Switching Characteristics), v1.27,
February 10, 2022, Table 66, STARTUPE2 Ports:**

| Symbol | Description | Value |
|--------|-------------|-------|
| F_CFGMCLK | STARTUPE2 CFGMCLK output frequency | 65.00 MHz, typical |
| F_CFGMCLKTOL | STARTUPE2 CFGMCLK output frequency tolerance | ±50 %, maximum |

So the watchdog clock is 1.016 MHz nominal, and anywhere from 0.51 MHz to
1.52 MHz on a given part at a given temperature and voltage.

**What that does to the monitor.** A correct 50 MHz system clock reads from
1/1.5 = 0.67 to 1/0.5 = 2.0 times the nominal count. The earlier setting,
60 % either way (0.4 to 1.6 times), was **wrong**: a slow CFGMCLK would have
tripped it on a healthy board. The Arty now uses 40 % below and 110 % above
(`fpga/arty_a7_100t/arty_a7_top.vhd`), which takes the whole ±50 % with some
margin; `tb_clock_monitor.the_arty_profile_accepts_cfgmclk_anywhere_in_its_range`
runs the two ends, and
`tb_clock_monitor.the_arty_profile_still_finds_a_stopped_clock` shows a
stopped clock is still found with the watchdog clock at its slowest.

The price: on the Arty the monitor cannot tell a system clock 30 % fast from a
fast CFGMCLK. It finds a stopped clock, and one that is grossly wrong
(below 0.6 times or above 2.1 times its rate), and nothing finer.

**What that does to the watchdog.** The watchdog's window is counted in
watchdog clocks: the kick window from 40,000 to 50,000 of them is 39 to 49 ms
at 1.016 MHz, and 26 to 98 ms over CFGMCLK's range. The board program kicks by
watching the counter, so it keeps up; but the worst-case time to find a
stopped program doubles, which matters against the item's FTTI
(`docs/safety/item_definition.md`, section 5).

## Recommendation

For a product, and for a bench run that measures timing: give `wd_clk_i` an
oscillator of its own with a known tolerance, such as a 1 MHz crystal
oscillator module on a Pmod pin (`docs/verification/bench_hardware.md`), and
set the monitor's tolerances from both clocks' data sheets. CFGMCLK is
independent of the system clock, which is what the watchdog needs, but not
accurate.
