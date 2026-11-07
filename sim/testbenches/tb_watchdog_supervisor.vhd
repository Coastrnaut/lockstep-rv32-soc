-- ============================================================================
-- Testbench: Watchdog Supervisor
-- ============================================================================
-- Each test picks the speed of the watchdog clock. A real RC oscillator is far
-- slower than clk_i, but nothing about it is guaranteed, so the crossings are
-- tested with the watchdog clock on both sides of it.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_watchdog_supervisor is
  generic (
    runner_cfg : string := ""
  );
end entity tb_watchdog_supervisor;

architecture tb of tb_watchdog_supervisor is

  constant c_clk_period : time := 20 ns;

  -- Half periods of the watchdog clock, in nanoseconds
  constant c_fast : natural := 2;
  constant c_slow : natural := 90;

  -- Counts in watchdog clocks. c_inside is well inside the kick window. Kicks
  -- and resets arrive c_crossing or fewer late, however the clocks compare.
  constant c_inside   : natural := 45000;
  constant c_late     : natural := 50000;
  constant c_crossing : natural := 40;
  constant c_pulse    : natural := 16;

  constant c_src_normal : natural := 0;
  constant c_src_early  : natural := 1;
  constant c_src_late   : natural := 2;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  signal clk         : std_logic;
  signal clk_stopped : boolean;
  signal wd_clk      : std_logic;
  signal wd_half_ns  : natural;
  signal rst_n       : std_logic;
  signal wd_rst_n    : std_logic;
  signal bus_i       : t_rv_bus;
  signal bus_ok      : std_logic;
  signal rdata       : std_logic_vector(31 downto 0);
  signal sys_reset   : std_logic;
  signal resets      : natural;

begin

  p_clk : process is
  begin

    if (clk_stopped) then
      wait until not clk_stopped;
    end if;

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  p_wd_clk : process is
  begin

    if (wd_half_ns = 0) then
      wait until wd_half_ns /= 0;
    end if;

    wd_clk <= '0', '1' after wd_half_ns * 1 ns;
    wait for wd_half_ns * 2 ns;

  end process p_wd_clk;

  test_runner_watchdog(runner, 40 ms);

  dut : entity lockstep.watchdog_supervisor
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      bus_i       => bus_i,
      bus_ok_i    => bus_ok,
      rdata_o     => rdata,
      wd_clk_i    => wd_clk,
      wd_rst_n_i  => wd_rst_n,
      sys_reset_o => sys_reset
    );

  p_resets : process (sys_reset) is
  begin

    if rising_edge(sys_reset) then
      resets <= resets + 1;
    end if;

  end process p_resets;

  p_stim : process is

    variable v_rdata : std_logic_vector(31 downto 0);

    procedure cold_reset is
    begin

      rst_n    <= '0';
      wd_rst_n <= '0';
      wait until rising_edge(wd_clk);
      wait until rising_edge(wd_clk);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n    <= '1';
      wd_rst_n <= '1';

    end procedure cold_reset;

    procedure wait_wd_clocks (
      constant count : in natural
    ) is
    begin

      for dummy in 1 to count loop

        wait until rising_edge(wd_clk);

      end loop;

    end procedure wait_wd_clocks;

    procedure write_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant sel  : in std_logic_vector(3 downto 0) := "1111"
    ) is
    begin

      bus_i <=
      (
        addr  => addr,
        data  => data,
        we    => '1',
        valid => '1',
        sel   => sel
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;

    end procedure write_bus;

    procedure kick is
    begin

      write_bus(c_wd_kick_addr, x"0000DEAD");

    end procedure kick;

    procedure read_bus (
      constant addr : in std_logic_vector(31 downto 0)
    ) is
    begin

      bus_i   <=
      (
        addr  => addr,
        data  => (others => '0'),
        we    => '0',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      bus_i   <= c_bus_idle;
      wait until rising_edge(clk);
      v_rdata := rdata;

    end procedure read_bus;

    -- Give the status time to cross first

    procedure check_reset_src (
      constant expected : in natural
    ) is
    begin

      wait_wd_clocks(c_crossing);
      wait for c_clk_period * 8;
      read_bus(c_wd_reset_src_addr);
      check_equal(v_rdata, std_logic_vector(to_unsigned(expected, 32)), "RESET_SRC");

    end procedure check_reset_src;

    -- Call this just as the watchdog restarts: it must time out on schedule

    procedure check_late_reset is
    begin

      wait_wd_clocks(c_late - c_crossing);
      check_equal(sys_reset, '0', "no reset before the timeout");
      wait until sys_reset = '1' for c_crossing * wd_half_ns * 4 ns;
      check_equal(sys_reset, '1', "reset at the timeout");

    end procedure check_late_reset;

    procedure wait_for_reset is
    begin

      wait until sys_reset = '1' for (c_late + c_crossing) * wd_half_ns * 2 ns;
      check_equal(sys_reset, '1', "reset");

    end procedure wait_for_reset;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      bus_i      <= c_bus_idle;
      bus_ok     <= '1';
      wd_half_ns <= c_fast;

      if (run("kicks_in_the_window_keep_the_soc_running_fast_clock") or
          run("kicks_in_the_window_keep_the_soc_running_slow_clock")) then
        if (running_test_case = "kicks_in_the_window_keep_the_soc_running_slow_clock") then
          wd_half_ns <= c_slow;
        end if;

        cold_reset;

        for window in 1 to 3 loop

          wait_wd_clocks(c_inside);
          kick;

        end loop;

        wait_wd_clocks(c_inside);
        check_equal(resets, 0, "no reset");
        check_reset_src(c_src_normal);
      elsif (run("missed_kick_resets_the_soc_once_and_lets_it_run_fast_clock") or
             run("missed_kick_resets_the_soc_once_and_lets_it_run_slow_clock")) then
        if (running_test_case = "missed_kick_resets_the_soc_once_and_lets_it_run_slow_clock") then
          wd_half_ns <= c_slow;
        end if;

        cold_reset;
        check_late_reset;
        wait_wd_clocks(c_pulse);
        check_equal(sys_reset, '1', "the pulse is held");
        wait_wd_clocks(1);
        check_equal(sys_reset, '0', "and then ends");
        check_equal(resets, 1, "one reset");

        -- The watchdog restarted with the SoC, so it times out again, in full
        check_late_reset;
        check_reset_src(c_src_late);
        check_equal(resets, 2, "a second reset");
      elsif (run("early_kick_resets_the_soc_fast_clock") or
             run("early_kick_resets_the_soc_slow_clock")) then
        if (running_test_case = "early_kick_resets_the_soc_slow_clock") then
          wd_half_ns <= c_slow;
        end if;

        cold_reset;
        kick;
        wait until sys_reset = '1' for c_crossing * wd_half_ns * 4 ns;
        check_equal(sys_reset, '1', "reset");
        wait_wd_clocks(c_pulse + 1);
        check_equal(sys_reset, '0', "pulse over");
        check_reset_src(c_src_early);
      elsif run("second_kick_soon_after_the_first_is_early") then
        cold_reset;
        wait_wd_clocks(c_inside);
        kick;
        wait_wd_clocks(c_crossing);
        wait for c_clk_period * 8;
        check_equal(resets, 0, "the first kick was in the window");
        kick;
        wait_wd_clocks(c_crossing);
        check_equal(resets, 1, "the second was not");
        check_reset_src(c_src_early);
      elsif run("kick_made_while_one_is_crossing_counts_as_the_same_kick") then
        cold_reset;
        wait_wd_clocks(c_inside);
        kick;
        kick;
        wait_wd_clocks(c_crossing);
        check_equal(resets, 0, "no early kick");
        wait_wd_clocks(c_inside);
        kick;
        wait_wd_clocks(c_crossing);
        check_equal(resets, 0, "the watchdog restarted from the first one");
      elsif run("only_a_word_store_of_the_key_to_kick_counts") then
        cold_reset;

        -- This early, a kick would be an early violation
        write_bus(c_wd_kick_addr, x"0000DEAC");
        write_bus(c_wd_kick_addr, x"8000DEAD");
        write_bus(c_wd_status_addr, x"0000DEAD");
        write_bus(c_wd_reset_src_addr, x"0000DEAD");
        write_bus(x"40000300", x"0000DEAD");
        write_bus(x"C0000200", x"0000DEAD");

        for pattern in 0 to 14 loop

          write_bus(c_wd_kick_addr, x"0000DEAD", std_logic_vector(to_unsigned(pattern, 4)));

        end loop;

        bus_ok <= '0';
        kick;
        bus_ok <= '1';

        bus_i       <=
        (
          addr  => c_wd_kick_addr,
          data  => x"0000DEAD",
          we    => '0',
          valid => '1',
          sel   => "1111"
        );
        wait until rising_edge(clk);
        bus_i.we    <= '1';
        bus_i.valid <= '0';
        wait until rising_edge(clk);
        bus_i       <= c_bus_idle;

        wait_wd_clocks(c_crossing);
        wait for c_clk_period * 8;
        check_equal(resets, 0, "none of those was a kick");

        kick;
        wait_wd_clocks(c_crossing);
        check_equal(resets, 1, "this was");
      elsif run("status_shows_the_counter") then
        cold_reset;

        -- Bits 4:0 are the top of the counter, which moves every 2048 clocks
        wait_wd_clocks(2048 * 3 + 1024);
        wait for c_clk_period * 8;
        read_bus(c_wd_status_addr);
        check_equal(v_rdata, std_logic_vector(to_unsigned(3, 32)), "STATUS");

        wait_wd_clocks(2048 * 17);
        wait for c_clk_period * 8;
        read_bus(c_wd_status_addr);
        check_equal(v_rdata, std_logic_vector(to_unsigned(20, 32)), "STATUS");
      elsif run("other_addresses_read_zero") then
        cold_reset;
        wait_wd_clocks(2048 + 1024);
        wait for c_clk_period * 8;
        read_bus(c_wd_kick_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "KICK reads zero");
        read_bus(x"40000300");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "CAN reads zero here");
        read_bus(x"C0000204");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "the whole address counts");

        -- A write reads nothing back either
        write_bus(c_wd_status_addr, x"00000000");
        wait until rising_edge(clk);
        check_equal(rdata, std_logic_vector'(x"00000000"), "no read data from a write");
      elsif run("safety_gate_blocks_reads") then
        cold_reset;
        wait_wd_clocks(2048 + 1024);
        wait for c_clk_period * 8;
        bus_ok <= '0';
        read_bus(c_wd_status_addr);
        bus_ok <= '1';
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "gated read");
      elsif run("watchdog_still_resets_the_soc_with_clk_stopped") then
        cold_reset;
        clk_stopped <= true;
        check_late_reset;
      elsif run("cold_reset_clears_reset_src") then
        cold_reset;
        kick;
        wait_wd_clocks(c_crossing);
        check_reset_src(c_src_early);

        -- The next one replaces it
        wait_for_reset;
        check_reset_src(c_src_late);

        cold_reset;
        check_reset_src(c_src_normal);
      elsif run("no_oscillator_means_no_reset_from_here") then
        -- The watchdog's reset synchroniser cannot release without a clock
        wd_half_ns <= 0;
        rst_n      <= '0';
        wd_rst_n   <= '0';
        wait for c_clk_period * 3;
        rst_n      <= '1';
        wait for c_clk_period * 3;
        check_equal(sys_reset, '0', "no reset, and not an unknown one");
        read_bus(c_wd_reset_src_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RESET_SRC is known too");
      elsif run("cold_reset_restarts_the_count") then
        cold_reset;
        wait_wd_clocks(c_inside);
        cold_reset;
        check_late_reset;
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
