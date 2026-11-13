-- ============================================================================
-- Testbench: Watchdog Window Boundaries
-- ============================================================================
-- HSI section 8.4, WD-01: a kick sampled at a count from MIN to MAX inclusive is
-- accepted, one below MIN is early, and with no kick the count reaching MAX is
-- the timeout. Each case puts the counter at the count under test just before
-- the edge that decides it, and reads sys_reset_o as that edge samples it,
-- because that is what watchdog_supervisor acts on.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_watchdog_window is
  generic (
    runner_cfg : string := ""
  );
end entity tb_watchdog_window;

architecture tb of tb_watchdog_window is

  constant c_wd_clk_period : time := 10 ns;

  constant c_min : natural := to_integer(c_wd_min_count);
  constant c_max : natural := to_integer(c_wd_max_count);

  signal wd_clk   : std_logic;
  signal wd_rst_n : std_logic;
  signal cpu_kick : std_logic;
  signal sys_rst  : std_logic;
  signal wd_stat  : std_logic_vector(7 downto 0);

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    wd_clk <= '0', '1' after c_wd_clk_period / 2;
    wait for c_wd_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 1 ms);

  i_wdt : entity lockstep.hardware_watchdog
    port map (
      wd_clk_i    => wd_clk,
      rst_n_i     => wd_rst_n,
      cpu_kick_i  => cpu_kick,
      sys_reset_o => sys_rst,
      wd_status_o => wd_stat
    );

  p_stim : process is

    alias counter is << signal i_wdt.r_counter : unsigned(15 downto 0) >>;
    alias latched is << signal i_wdt.r_timeout_latched : std_logic >>;

    variable v_sampled : std_logic;

    -- Hold the counter at count for the next edge, with or without a kick, and
    -- return sys_reset_o as that edge sampled it

    procedure decide_at (
      constant count     : in natural;
      constant with_kick : in std_logic
    ) is
    begin

      wait until falling_edge(wd_clk);
      counter  <= force to_unsigned(count, 16);
      cpu_kick <= with_kick;
      wait until rising_edge(wd_clk);
      -- Still the value from before the edge
      v_sampled := sys_rst;
      counter   <= release;
      cpu_kick  <= '0';
      wait until falling_edge(wd_clk);

    end procedure decide_at;

    procedure check_accepted (
      constant label_s : in string
    ) is
    begin

      check_equal(v_sampled, '0', label_s & ": no reset sampled at the deciding edge");
      check_equal(latched, '0', label_s & ": no violation held");
      check_equal(counter, to_unsigned(0, 16), label_s & ": the count restarted");
      wait until rising_edge(wd_clk);
      wait until falling_edge(wd_clk);
      check_equal(sys_rst, '0', label_s & ": still no reset");

    end procedure check_accepted;

    procedure check_violation (
      constant label_s : in string
    ) is
    begin

      check_equal(v_sampled, '1', label_s & ": reset sampled at the deciding edge");
      check_equal(latched, '1', label_s & ": violation held");
      check_equal(sys_rst, '1', label_s & ": reset held");

    end procedure check_violation;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      cpu_kick <= '0';
      wd_rst_n <= '0';
      wait until rising_edge(wd_clk);
      wait until rising_edge(wd_clk);
      wd_rst_n <= '1';
      wait until rising_edge(wd_clk);

      if run("kick_at_min_minus_one_is_early") then
        decide_at(c_min - 1, '1');
        check_violation("MIN-1");
        check_equal(wd_stat(7 downto 5), std_logic_vector'("100"), "STATUS shows a held violation");
      elsif run("kick_at_min_is_accepted") then
        decide_at(c_min, '1');
        check_accepted("MIN");
      elsif run("kick_at_max_minus_one_is_accepted") then
        decide_at(c_max - 1, '1');
        check_accepted("MAX-1");
      elsif run("kick_at_max_is_accepted") then
        decide_at(c_max, '1');
        check_accepted("MAX");
      elsif run("no_kick_at_max_minus_one_is_no_timeout") then
        decide_at(c_max - 1, '0');
        check_equal(v_sampled, '0', "no reset sampled at MAX-1");
        check_equal(latched, '0', "no violation held");
        check_equal(counter, to_unsigned(c_max, 16), "the count reached MAX");
      elsif run("no_kick_at_max_is_the_timeout") then
        decide_at(c_max, '0');
        check_violation("MAX without a kick");
      elsif run("count_runs_from_reset_to_the_timeout_in_max_clocks") then
        -- No forcing: the reset restarts the count at zero, and the edge after
        -- each wait has the count before it equal to the loop index
        for count in 1 to c_max - 1 loop

          wait until rising_edge(wd_clk);
          check_equal(sys_rst, '0', "no reset before MAX");

        end loop;

        wait until falling_edge(wd_clk);
        check_equal(counter, to_unsigned(c_max, 16), "MAX clocks after reset");
        check_equal(sys_rst, '1', "timeout at MAX");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
