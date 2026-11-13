-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  System Clock Monitor
-- Module Name:  clock_monitor - rtl
-- Description:  Checks the system clock against the watchdog clock, which
--               comes from its own oscillator. Both comparators, both cores
--               and everything that reacts to a fault run on the system clock:
--               a clock that stops, or runs too fast or too slow, is a cause
--               they all share (docs/safety/dependent_failure_analysis.md,
--               DF-15). The watchdog finds a stopped clock only when its window
--               runs out; this finds it within two windows of g_window watchdog
--               clocks, and finds a clock that runs at the wrong rate as well.
--
--               In the system clock domain a divider counts clocks, and its top
--               bit toggles slowly enough for the watchdog clock to see every
--               change. In the watchdog clock domain that bit is synchronised
--               and its changes counted over each window. Outside the expected
--               count, plus or minus g_tolerance_pct, the fault latches. Only a
--               cold reset (wd_rst_n_i) clears it: a stopped system clock cannot
--               clear anything. The first window after the reset is not judged,
--               since the two clocks leave reset at different times.
--
--               fault_o is in the watchdog clock domain and needs no system
--               clock. The top level ORs it into the fault pin and holds the
--               SoC in reset with it: the reset takes effect without a clock,
--               so the actuators go safe, the CAN pin recessive and the UART
--               to mark whether the system clock has stopped or only strayed.
--
-- Traces to:    TSR_CLOCK_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

entity clock_monitor is
  generic (
    -- Nominal frequencies of the two clocks
    g_sys_clk_hz : positive := 50_000_000;
    g_wd_clk_hz  : positive := 1_000_000;
    -- Watchdog clocks in each window
    g_window : positive := 256;
    -- How far the count may be from the nominal one, in percent
    g_tolerance_pct : natural range 1 to 90 := 25
  );
  port (
    clk_i : in    std_logic;
    -- System clock domain, synchronous, active low
    rst_n_i : in    std_logic;

    wd_clk_i : in    std_logic;
    -- Watchdog clock domain, synchronous, active low: the cold reset
    wd_rst_n_i : in    std_logic;

    -- Watchdog clock domain, held until wd_rst_n_i
    fault_o : out   std_logic
  );
end entity clock_monitor;

architecture rtl of clock_monitor is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_CLOCK_001";

  -- The divider's top bit changes every 2**(c_div_bits - 1) system clocks. That
  -- is at least four watchdog clocks apart, so that a two-flip-flop
  -- synchroniser sees every change.
  constant c_ratio    : real     := 4.0 * real(g_sys_clk_hz) / real(g_wd_clk_hz);
  constant c_div_bits : positive := integer(ceil(log2(realmax(c_ratio, 2.0)))) + 1;

  -- Changes of the top bit in one window, nominal, and the accepted range
  constant c_nominal : real    := real(g_window) * real(g_sys_clk_hz) /
                                  (real(g_wd_clk_hz) * 2.0 ** (c_div_bits - 1));
  constant c_min     : natural := integer(floor(c_nominal * real(100 - g_tolerance_pct) / 100.0));
  constant c_max     : natural := integer(ceil(c_nominal * real(100 + g_tolerance_pct) / 100.0));

  -- System clock domain
  signal r_div : unsigned(c_div_bits - 1 downto 0);

  -- Watchdog clock domain
  signal r_sample : std_logic_vector(2 downto 0);
  signal r_tick   : natural range 0 to g_window - 1;
  signal r_count  : natural range 0 to c_max + 1;
  signal r_armed  : std_logic;
  signal r_fault  : std_logic;

  -- The fault latch must not be merged or optimised away
  attribute dont_touch : string;
  attribute dont_touch of r_fault : signal is "true";

begin

  -- ========================================================================
  -- 1. SYSTEM CLOCK DOMAIN: the divider
  -- ========================================================================
  p_div : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_div <= (others => '0');
      else
        r_div <= r_div + 1;
      end if;
    end if;

  end process p_div;

  -- ========================================================================
  -- 2. WATCHDOG CLOCK DOMAIN: count the changes in each window
  -- ========================================================================
  p_count : process (wd_clk_i) is
  begin

    if rising_edge(wd_clk_i) then
      -- The first two flip-flops synchronise; the third gives the edge
      r_sample <= r_sample(1 downto 0) & r_div(c_div_bits - 1);

      if (wd_rst_n_i = '0') then
        r_tick  <= 0;
        r_count <= 0;
        r_armed <= '0';
        r_fault <= '0';
      else
        if (r_tick = g_window - 1) then
          r_tick  <= 0;
          r_count <= 0;
          r_armed <= '1';

          if (r_armed = '1' and (r_count < c_min or r_count > c_max)) then
            r_fault <= '1';
          end if;
        else
          r_tick <= r_tick + 1;

          if (r_sample(2) /= r_sample(1) and r_count <= c_max) then
            r_count <= r_count + 1;
          end if;
        end if;
      end if;
    end if;

  end process p_count;

  -- Before the watchdog clock has run, the latch holds no value yet: that is no
  -- fault (in simulation, where it starts unknown; in silicon it is 0 or 1)
  fault_o <= '1' when (r_fault = '1') else
             '0';

  -- ========================================================================
  -- 3. ELABORATION CHECK
  -- ========================================================================
  -- Property: a window holds enough changes to tell a fast clock from a slow one
  -- ========================================================================
  assert c_min >= 2 and c_max > c_min
    report "clock_monitor: a window of " & integer'image(g_window) &
           " watchdog clocks is too short for these clock frequencies"
    severity failure;

end architecture rtl;
