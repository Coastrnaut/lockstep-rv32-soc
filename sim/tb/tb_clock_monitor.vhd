-- ============================================================================
-- Testbench: the system clock monitor
-- ============================================================================
-- A 50 MHz system clock checked against a 1 MHz watchdog clock, over windows
-- of 64 watchdog clocks (12.5 changes of the divider's top bit in a window at
-- the nominal rate; 9 to 16 accepted at 25 %). The system clock's period is
-- the bench's to change, and it can stop. Checked: a clock at or near its
-- rate is no fault; one stopped, or far too fast or too slow, is one within
-- two windows; the first window after a reset is not judged; the fault holds
-- through a recovered clock and a system reset, and only the cold reset in
-- the watchdog clock domain clears it.
--
-- Traces to:   TSR_CLOCK_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;

library lockstep;

entity tb_clock_monitor is
  generic (
    g_test : string := ""
  );
end entity tb_clock_monitor;

architecture tb of tb_clock_monitor is

  constant c_wd_period : time     := 1000 ns;
  constant c_window    : positive := 64;

  signal clk        : std_logic;
  signal wd_clk     : std_logic;
  signal rst_n      : std_logic;
  signal wd_rst_n   : std_logic;
  signal fault      : std_logic;
  signal sys_period : time;
  signal sys_run    : boolean;

begin

  p_clk : process is
  begin

    clk <= '0';

    if (not sys_run) then
      wait until sys_run;
    end if;

    clk <= '1';
    wait for sys_period / 2;
    clk <= '0';
    wait for sys_period - sys_period / 2;

  end process p_clk;

  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after c_wd_period / 2;
    wait for c_wd_period;

  end process p_wd_clk;

  test_runner_watchdog(20 ms);

  i_dut : entity lockstep.clock_monitor
    generic map (
      g_sys_clk_hz    => 50_000_000,
      g_wd_clk_hz     => 1_000_000,
      g_window        => c_window,
      g_tolerance_pct => 25
    )
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      wd_clk_i   => wd_clk,
      wd_rst_n_i => wd_rst_n,
      fault_o    => fault
    );

  p_stim : process is

    procedure wait_windows (
      constant n : in positive
    ) is
    begin

      wait for c_wd_period * c_window * n;

    end procedure wait_windows;

    procedure cold_reset is
    begin

      rst_n    <= '0';
      wd_rst_n <= '0';
      wait for c_wd_period * 3;
      rst_n    <= '1';
      wd_rst_n <= '1';

    end procedure cold_reset;

    -- A wrong clock is a fault within two windows (the window it starts in
    -- may still look right), and three watchdog clocks to latch

    procedure check_fault_soon (
      constant label_s : in string
    ) is
    begin

      if (fault /= '1') then
        wait until fault = '1' for c_wd_period * (2 * c_window + 3);
      end if;

      check_equal(fault, '1', label_s);

    end procedure check_fault_soon;

  begin

    test_runner_setup(g_test);
    sys_period <= 20 ns;
    sys_run    <= true;

    loop_while : while test_suite loop

      cold_reset;

      if run("a_clock_at_its_rate_is_no_fault") then
        wait_windows(20);
        check_equal(fault, '0', "20 windows at 50 MHz");
      elsif run("a_clock_ten_percent_off_is_no_fault") then
        sys_period <= 22 ns;
        wait_windows(10);
        check_equal(fault, '0', "10 windows 9 % slow");
        sys_period <= 18 ns;
        wait_windows(10);
        check_equal(fault, '0', "10 windows 11 % fast");
      elsif run("a_stopped_clock_is_a_fault_within_two_windows") then
        wait_windows(3);
        check_equal(fault, '0', "running");
        sys_run <= false;
        check_fault_soon("stopped");
        info("a stopped clock is a fault");
      elsif run("a_clock_half_as_fast_again_is_a_fault") then
        wait_windows(3);
        sys_period <= 13 ns;
        check_fault_soon("about 77 MHz");
      elsif run("a_clock_at_half_its_rate_is_a_fault") then
        wait_windows(3);
        sys_period <= 40 ns;
        check_fault_soon("25 MHz");
      elsif run("the_first_window_after_a_reset_is_not_judged") then
        -- The system clock domain leaves reset most of a window after the
        -- watchdog clock domain, so the first window sees few changes
        rst_n    <= '0';
        wd_rst_n <= '0';
        wait for c_wd_period * 3;
        wd_rst_n <= '1';
        wait for c_wd_period * (c_window - 4);
        rst_n    <= '1';
        wait_windows(5);
        check_equal(fault, '0', "no fault from the first window");
      elsif run("the_fault_holds_until_the_cold_reset") then
        wait_windows(2);
        sys_run <= false;
        check_fault_soon("stopped");
        sys_run <= true;
        wait_windows(5);
        check_equal(fault, '1', "still a fault with the clock back");
        rst_n   <= '0';
        wait for c_wd_period * 3;
        rst_n   <= '1';
        wait_windows(2);
        check_equal(fault, '1', "still a fault after a system reset");
        cold_reset;
        wait for c_wd_period * 2;
        check_equal(fault, '0', "the cold reset clears it");
        wait_windows(5);
        check_equal(fault, '0', "and the clock is right again");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
