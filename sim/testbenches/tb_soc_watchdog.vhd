-- ============================================================================
-- Testbench: Watchdog in the SoC
-- ============================================================================
-- Runs sim/scripts/soc_firmware.py with a watchdog clock fast enough to reach
-- the kick window in a simulation. Each time the program starts it reports
-- RESET_SRC as a digit, and then does what takes it round this loop:
--
--   Cold start:  kicks twice in the window, then stops, so the watchdog times out
--   After that:  kicks far too early, so the watchdog resets the SoC at once
--   After that:  stops, so the watchdog times out again
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;

library work;
  use work.can_test_pkg.all;

entity tb_soc_watchdog is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_watchdog;

architecture tb of tb_soc_watchdog is

  constant c_clk_period    : time := 20 ns;
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;

  -- Not a multiple of the system clock, so the clocks drift through each other
  constant c_wd_clk_period : time := 23 ns;

  -- Longest the watchdog can take to time out
  constant c_wd_timeout : time := c_wd_clk_period * 51000;

  -- How long the program may take to answer
  constant c_timeout : time := 3 ms;

  signal clk           : std_logic;
  signal clk_stopped   : boolean;
  signal wd_clk        : std_logic;
  signal wd_dead       : boolean;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus   : std_logic;
  signal ack_tx    : std_logic;
  signal rx_starts : natural;
  signal rx_done   : natural;
  signal rx_frame  : t_rx_frame;

  -- What the receiver on uart_tx saw

  type t_byte_log is array (1 to 8) of std_logic_vector(7 downto 0);

  signal uart_count : natural;
  signal uart_log   : t_byte_log;

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

    -- This gives the stimulus time to say that the oscillator is dead
    wait for c_wd_clk_period;

    while (not wd_dead) loop

      wd_clk <= '0', '1' after c_wd_clk_period / 2;
      wait for c_wd_clk_period;

    end loop;

    wait;

  end process p_wd_clk;

  test_runner_watchdog(runner, 20 ms);

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2
    )
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      wd_clk_i        => wd_clk,
      can_tx_o        => can_tx,
      can_rx_i        => can_bus,
      uart_tx_o       => uart_tx,
      nmi_fault_o     => nmi_fault,
      actuator_safe_o => actuator_safe,
      diag_cs_n_i     => '1',
      diag_sck_i      => '0',
      diag_sdo_o      => open
    );

  can_bus <= can_tx and ack_tx;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_can_bit_time
    )
    port map (
      bus_i        => can_bus,
      dut_tx_i     => can_tx,
      ack_enable_i => '1',
      ack_o        => ack_tx,
      frame_o      => rx_frame,
      starts_o     => rx_starts,
      done_o       => rx_done
    );

  -- Independent UART receiver: 8 data bits LSB first, parity and stop
  p_uart_rx : process is

    variable v_byte : std_logic_vector(7 downto 0);

  begin

    wait until uart_tx = '0';
    wait for c_uart_bit_time / 2;

    for i in 0 to 7 loop

      wait for c_uart_bit_time;
      v_byte(i) := uart_tx;

    end loop;

    wait for c_uart_bit_time * 2;
    uart_log(uart_count + 1) <= v_byte;
    uart_count               <= uart_count + 1;

  end process p_uart_rx;

  p_stim : process is

    procedure cold_reset is
    begin

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

    end procedure cold_reset;

    procedure check_uart_byte (
      constant count    : in natural;
      constant expected : in std_logic_vector(7 downto 0)
    ) is
    begin

      if (uart_count < count) then
        wait until uart_count >= count for c_timeout;
      end if;

      check(uart_count >= count, "UART byte arrived");
      check_equal(uart_log(count), expected, "UART byte");

    end procedure check_uart_byte;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("program_kicks_in_the_window_then_times_out_then_kicks_early") then
        cold_reset;

        -- '0' is a cold start, and 'W' comes after two kicks in the window
        check_uart_byte(5, x"44");
        check_uart_byte(6, x"57");
        check_equal(actuator_safe, '0', "two kicks in the window, so no reset");

        wait until actuator_safe = '1' for c_wd_timeout;
        check_equal(actuator_safe, '1', "the timeout makes the actuators safe");
        wait until actuator_safe = '0' for c_clk_period * 100;
        check_equal(actuator_safe, '0', "and then the SoC restarts");

        -- '2' is a timeout. The program kicks at once, and '1' is that early kick.
        check_uart_byte(7, x"32");
        check_uart_byte(8, x"31");
        check_equal(rx_starts, 1, "the frame was sent once, by the cold start");
        check_equal(nmi_fault, '0', "both cores restarted together");
      elsif run("watchdog_reset_leaves_a_lockstep_fault_latched") then
        cold_reset;
        check_uart_byte(1, x"30");
        wait until rising_edge(clk);
        << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >> <= force x"FFFFFFFF";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >> <= release;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(nmi_fault, '1', "fault latched");
        check_equal(actuator_safe, '1', "actuators safe");

        -- The gate is shut, so no kick can get through
        wait until << signal i_soc.w_rst_n : std_logic >> = '0' for c_wd_timeout;
        check_equal(<< signal i_soc.w_rst_n : std_logic >>, '0', "the watchdog reset the SoC");
        wait until << signal i_soc.w_rst_n : std_logic >> = '1' for c_clk_period * 100;
        check_equal(<< signal i_soc.w_rst_n : std_logic >>, '1', "and let it restart");

        wait for c_clk_period * 20;
        check_equal(nmi_fault, '1', "only a cold reset clears the fault");
        check_equal(actuator_safe, '1', "actuators still safe");

        cold_reset;
        wait for c_clk_period * 300;
        check_equal(nmi_fault, '0', "a cold reset clears the fault");
        check_equal(actuator_safe, '0', "actuators released");
      elsif run("watchdog_makes_the_soc_safe_if_the_clock_stops") then
        cold_reset;
        wait until can_tx = '0' for c_timeout;
        check_equal(can_tx, '0', "frame started");
        clk_stopped <= true;
        wait until actuator_safe = '1' for c_wd_timeout;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(can_tx, '1', "CAN pin recessive");

        -- With no clock the reset cannot be released, so that lasts
        wait for c_wd_clk_period * 100;
        check_equal(actuator_safe, '1', "actuators still safe");
        check_equal(can_tx, '1', "CAN pin still recessive");
      elsif run("watchdog_runs_with_no_system_clock_at_all") then
        clk_stopped <= true;
        cold_reset;
        wait until << signal i_soc.w_wd_reset : std_logic >> = '1' for c_wd_timeout;
        check_equal(<< signal i_soc.w_wd_reset : std_logic >>, '1', "the watchdog timed out");
        check_equal(actuator_safe, '1', "actuators safe");
      elsif run("soc_still_runs_with_a_dead_oscillator") then
        wd_dead <= true;
        cold_reset;
        check_uart_byte(5, x"44");
        check_equal(actuator_safe, '0', "no reset");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
