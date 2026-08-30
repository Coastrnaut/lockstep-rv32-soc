-- ============================================================================
-- Testbench: Windowed Hardware Watchdog
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_watchdog is
  generic (
    runner_cfg : string := ""
  );
end entity tb_watchdog;

architecture rtl of tb_watchdog is

  -- Independent watchdog clock (fast for simulation)
  constant wd_clk_period : time      := 10 ns;
  signal   wd_clk        : std_logic := '0';
  signal   wd_rst_n      : std_logic := '0';
  signal   cpu_kick      : std_logic := '0';
  signal   sys_rst       : std_logic;
  signal   wd_stat       : std_logic_vector(7 downto 0);

begin

  wd_clk <= not wd_clk after wd_clk_period / 2;

  i_wdt : entity lockstep.hardware_watchdog
    port map (
      wd_clk_i    => wd_clk,
      rst_n_i     => wd_rst_n,
      cpu_kick_i  => cpu_kick,
      sys_reset_o => sys_rst,
      wd_status_o => wd_stat
    );

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    cpu_kick <= '0';
    wd_rst_n <= '0';

    for dummy in 1 to 5 loop

      wait until rising_edge(wd_clk);

    end loop;

    wd_rst_n <= '1';

    for dummy in 1 to 10 loop

      wait until rising_edge(wd_clk);

    end loop;

    -- --- Test 1: Normal periodic kicks (within window) ---
    -- C_WD_MIN=40000, C_WD_MAX=50000 — kick at ~45000 counts
    for dummy in 1 to 45000 loop

      wait until rising_edge(wd_clk);

    end loop;

    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    check(sys_rst = '0', "no reset on valid kick");

    -- --- Test 2: Kick too early (below MIN) ---
    for dummy in 1 to 10 loop

      wait until rising_edge(wd_clk);

    end loop;

    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    wait until rising_edge(wd_clk);
    check(sys_rst = '1', "reset on early kick");

    test_runner_cleanup(runner);

  end process p_stim;

end architecture rtl;
