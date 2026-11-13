-- ============================================================================
-- Testbench: the actuator read-back and second shutdown channel
-- ============================================================================
-- The read-back line is the bench's: it follows the command after a delay the
-- test chooses, or sticks at either level. Checked: a line that follows its
-- command within the filter is no fault; one that lags by more, or sticks at
-- "permit" or at "safe", is a fault on the next change of command, held until
-- the cold reset and no other; the second channel follows the permission
-- through its own register, and drops at once on a fault, and on the SoC
-- reset without a clock.
--
-- Traces to:   TSR_ACTUATOR_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;

library lockstep;

entity tb_actuator_monitor is
  generic (
    g_test : string := ""
  );
end entity tb_actuator_monitor;

architecture tb of tb_actuator_monitor is

  constant c_clk_period : time     := 20 ns;
  constant c_filter     : positive := 8;

  -- How the read-back line behaves

  type t_line is (line_follows, line_stuck_permit, line_stuck_safe);

  signal clk       : std_logic;
  signal clk_run   : boolean;
  signal rst_n     : std_logic;
  signal sys_rst_n : std_logic;
  signal safe_cmd  : std_logic;
  signal fb        : std_logic;
  signal permit    : std_logic;
  signal enable    : std_logic;
  signal fault     : std_logic;
  signal line      : t_line;
  signal lag       : natural;
  signal history   : std_logic_vector(31 downto 0);

begin

  p_clk : process is
  begin

    clk <= '0';

    if (not clk_run) then
      wait until clk_run;
    end if;

    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(1 ms);

  -- The command as it was lag clocks ago, as a slow driver would give it back
  p_history : process (clk) is
  begin

    if rising_edge(clk) then
      history <= history(30 downto 0) & safe_cmd;
    end if;

  end process p_history;

  fb <= '0' when (line = line_stuck_permit) else
        '1' when (line = line_stuck_safe) else
        safe_cmd when (lag = 0) else
        history(lag - 1);

  i_dut : entity lockstep.actuator_monitor
    generic map (
      g_filter_clocks => c_filter
    )
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      sys_rst_n_i => sys_rst_n,
      safe_cmd_i  => safe_cmd,
      fb_i        => fb,
      permit_i    => permit,
      enable_o    => enable,
      fault_o     => fault
    );

  p_stim : process is

    procedure wait_clocks (
      constant n : in positive
    ) is
    begin

      loop_clock : for lv_i in 1 to n loop

        wait until rising_edge(clk);

      end loop loop_clock;

      wait for 1 ns;

    end procedure wait_clocks;

    procedure cold_reset is
    begin

      line      <= line_follows;
      lag       <= 0;
      safe_cmd  <= '1';
      permit    <= '0';
      rst_n     <= '0';
      sys_rst_n <= '0';
      wait_clocks(4);
      rst_n     <= '1';
      sys_rst_n <= '1';
      wait_clocks(4);

    end procedure cold_reset;

    -- Run the actuator: permitted, then released from safe

    procedure run_actuator is
    begin

      permit   <= '1';
      safe_cmd <= '0';
      wait_clocks(c_filter + 6);

    end procedure run_actuator;

  begin

    test_runner_setup(g_test);
    clk_run <= true;

    loop_while : while test_suite loop

      cold_reset;

      if run("a_line_that_follows_its_command_is_no_fault") then

        loop_toggle : for lv_n in 1 to 20 loop

          safe_cmd <= not safe_cmd;
          wait_clocks(3 + lv_n mod 5);

        end loop loop_toggle;

        wait_clocks(c_filter + 4);
        check_equal(fault, '0', "20 changes of command, all followed");
      elsif run("a_lag_inside_the_filter_is_no_fault_and_a_longer_one_is") then
        -- The read-back is compared after two clocks of synchronising, against
        -- the command delayed as long, so the filter is the allowance
        lag      <= c_filter - 1;
        wait_clocks(1);
        safe_cmd <= '0';
        wait_clocks(c_filter + 6);
        safe_cmd <= '1';
        wait_clocks(c_filter + 6);
        check_equal(fault, '0', "a driver " & integer'image(c_filter - 1) & " clocks slow");
        lag      <= c_filter + 2;
        wait_clocks(c_filter + 6);
        safe_cmd <= '0';
        wait_clocks(c_filter + 6);
        check_equal(fault, '1', "a driver " & integer'image(c_filter + 2) & " clocks slow");
      elsif run("a_line_stuck_at_permit_is_found_on_the_next_demand") then
        run_actuator;
        check_equal(enable, '1', "running: the second channel permits");
        line <= line_stuck_permit;
        wait_clocks(50);
        check_equal(fault, '0', "latent while the command is permit too");
        -- The demand: the first channel cannot make the actuator safe, so the
        -- second must
        safe_cmd <= '1';
        permit   <= '0';
        wait_clocks(1);
        check_equal(enable, '0', "the second channel follows the permission at once");
        wait_clocks(c_filter + 3);
        check_equal(fault, '1', "found within the filter and the synchroniser");
        permit   <= '1';
        wait_clocks(3);
        check_equal(enable, '0', "the second channel stays down with the fault");
      elsif run("a_line_stuck_at_safe_is_found_when_the_actuator_is_released") then
        line <= line_stuck_safe;
        wait_clocks(20);
        check_equal(fault, '0', "no fault while the command is safe");
        run_actuator;
        check_equal(fault, '1', "found when the command is permit");
        check_equal(enable, '0', "the second channel is down");
      elsif run("a_line_stuck_at_permit_is_found_at_every_start") then
        -- The reset holds the command at safe, so the start checks the line
        line <= line_stuck_permit;
        wait_clocks(c_filter + 4);
        check_equal(fault, '1', "found at the start, before any demand");
      elsif run("the_fault_holds_until_the_cold_reset") then
        line      <= line_stuck_permit;
        wait_clocks(c_filter + 4);
        check_equal(fault, '1', "fault");
        line      <= line_follows;
        wait_clocks(20);
        check_equal(fault, '1', "still a fault with the line well again");
        sys_rst_n <= '0';
        wait_clocks(3);
        sys_rst_n <= '1';
        wait_clocks(3);
        check_equal(fault, '1', "still a fault after a SoC reset");
        cold_reset;
        check_equal(fault, '0', "the cold reset clears it");
      elsif run("the_second_channel_drops_with_the_reset_without_a_clock") then
        run_actuator;
        check_equal(enable, '1', "running");
        clk_run   <= false;
        wait for c_clk_period * 3;
        sys_rst_n <= '0';
        wait for 1 ns;
        check_equal(enable, '0', "down at once, with no clock");
        clk_run   <= true;
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
