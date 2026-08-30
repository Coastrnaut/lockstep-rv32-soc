
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_watchdog_osvvm is
  generic (
    runner_cfg : string := ""
  );
end entity tb_watchdog_osvvm;

architecture tb of tb_watchdog_osvvm is

  constant clk_period : time := 20 ns;
  signal   clk        : std_logic;
  signal   rst_n      : std_logic;

  signal wd_clk      : std_logic;
  signal cpu_kick    : std_logic;
  signal sys_reset_o : std_logic;
  signal wd_status_o : std_logic_vector(7 downto 0);begin

  clk    <= not clk after clk_period / 2;
  wd_clk <= not wd_clk after clk_period / 2;

  uut : entity lockstep.hardware_watchdog
    port map (
      wd_clk_i    => wd_clk,
      rst_n_i     => rst_n,
      cpu_kick_i  => cpu_kick,
      sys_reset_o => sys_reset_o,
      wd_status_o => wd_status_o

    );p_test : process is
  begin

    test_runner_setup(runner, runner_cfg);

    rst_n    <= '0';
    cpu_kick <= '0';
    wait for 100 ns;
    rst_n    <= '1';
    wait for clk_period * 2;

    -- TEST 1: Normal periodic kicks at 45000 cycles (within [40000, 50000))
    report "TEST: Normal periodic kicks";

    for dummy in 0 to 1 loop

      wait for clk_period * 45000;
      cpu_kick <= '1';
      wait until rising_edge(wd_clk);
      cpu_kick <= '0';
      check(sys_reset_o = '0', "normal kick #");

    end loop;

    -- TEST 2: Watchdog timeout (no kick past C_WD_MAX_COUNT = 50000)
    report "TEST: Watchdog timeout";
    rst_n    <= '0';
    wait for clk_period * 2;
    rst_n    <= '1';
    wait for clk_period * 2;
    cpu_kick <= '0';
    wait for clk_period * 50001;                                -- counter reaches 50001
    check(sys_reset_o = '1', "timeout: sys_reset asserted");

    -- TEST 3: Early kick (kick before C_WD_MIN_COUNT = 40000)
    report "TEST: Early kick";
    rst_n <= '0';
    wait for clk_period * 2;
    rst_n <= '1';
    wait for clk_period * 2;
    -- Kick immediately (counter = 0, below C_WD_MIN_COUNT)
    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    check(sys_reset_o = '1', "early kick: sys_reset asserted");

    -- TEST 4: Late kick (kick just before C_WD_MAX_COUNT)
    report "TEST: Late kick near timeout";
    rst_n <= '0';
    wait for clk_period * 2;
    rst_n <= '1';
    -- Counter starts at 0, increments each cycle. Kick at counter=45000 (within window).
    wait for clk_period * 44998;                                -- counter = 45000 after this
    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    wait for clk_period * 5;
    check(sys_reset_o = '0', "late kick: still alive");

    -- TEST 5: Kick pattern — two kicks in window
    report "TEST: Regular kick pattern";
    rst_n <= '0';
    wait for clk_period * 2;
    rst_n <= '1';
    wait for clk_period * 2;
    -- Kick at 45000
    wait for clk_period * 45000;
    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    -- Kick at 45000 again
    wait for clk_period * 45000;
    cpu_kick <= '1';
    wait until rising_edge(wd_clk);
    cpu_kick <= '0';
    wait for clk_period * 5;
    check(sys_reset_o = '0', "regular: no reset");

    -- TEST 6: Verify status output
    report "TEST: Watchdog status output";
    rst_n <= '0';
    wait for clk_period * 2;
    rst_n <= '1';
    wait for clk_period * 3000;                                 -- counter = 3000, bits 15:11 set
    check(wd_status_o /= x"00", "status: reflects counter");

    test_runner_cleanup(runner);

  end process p_test;

end architecture tb;
