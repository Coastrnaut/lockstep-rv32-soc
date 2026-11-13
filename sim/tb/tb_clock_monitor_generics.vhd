-- ============================================================================
-- Testbench: the clock monitor's check of its own generics
-- ============================================================================
-- A window too short to tell a fast clock from a slow one (here 4 watchdog
-- clocks: fewer than one change of the divider's top bit) must be reported as
-- the design is built. A bench of its own, since the check fires before any
-- test starts.
--
-- Traces to:   TSR_CLOCK_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;

library lockstep;

entity tb_clock_monitor_generics is
  generic (
    g_test : string := ""
  );
end entity tb_clock_monitor_generics;

architecture tb of tb_clock_monitor_generics is

  signal fault : std_logic;

begin

  i_dut : entity lockstep.clock_monitor
    generic map (
      g_sys_clk_hz         => 50_000_000,
      g_wd_clk_hz          => 1_000_000,
      g_window             => 4,
      g_tolerance_low_pct  => 25,
      g_tolerance_high_pct => 25
    )
    port map (
      clk_i      => '0',
      rst_n_i    => '0',
      wd_clk_i   => '0',
      wd_rst_n_i => '0',
      fault_o    => fault
    );

  p_stim : process is
  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      if run("assertion_a_window_too_short_is_reported") then
        expect_assertion("clock_monitor: a window of 4 watchdog clocks is too short");
        wait for 10 ns;
        check_equal(fault, '0', "no fault before the watchdog clock has run");
        info("a window too short is reported");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
