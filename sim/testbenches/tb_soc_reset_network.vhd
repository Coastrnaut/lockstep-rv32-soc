-- ============================================================================
-- Testbench: SoC Reset Network
-- ============================================================================
-- Resets the SoC while sim/scripts/soc_firmware.py runs on it. The 3 ns pulses
-- fall between two clock edges, so only the reset synchroniser can see them, and
-- each has to reach every block as a full reset.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;

library work;
  use work.can_test_pkg.all;

entity tb_soc_reset_network is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_reset_network;

architecture tb of tb_soc_reset_network is

  constant c_clk_period   : time := 20 ns;
  constant c_can_bit_time : time := c_clk_period * 100;
  constant c_timeout      : time := 2 ms;

  -- Long enough for the reset to have been released again
  constant c_after_reset : time := c_clk_period * 4;

  signal clk           : std_logic;
  signal clk_stopped   : boolean;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus  : std_logic;
  signal ack_tx   : std_logic;
  signal rx_done  : natural;
  signal rx_frame : t_rx_frame;

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

  test_runner_watchdog(runner, 10 ms);

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2
    )
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      can_tx_o        => can_tx,
      can_rx_i        => can_bus,
      uart_tx_o       => uart_tx,
      nmi_fault_o     => nmi_fault,
      actuator_safe_o => actuator_safe
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
      done_o       => rx_done
    );

  p_stim : process is

    -- Called just after a rising clock edge, and over long before the next

    procedure short_reset is
    begin

      wait for 3 ns;
      rst_n <= '0';
      wait for 3 ns;
      rst_n <= '1';
      wait for 1 ns;

    end procedure short_reset;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

      if run("reset_makes_the_outputs_safe_without_a_clock") then
        wait until can_tx = '0' for c_timeout;
        check_equal(can_tx, '0', "frame started");
        clk_stopped <= true;
        wait for c_clk_period * 3;
        check_equal(can_tx, '0', "the frame stopped with the clock");
        check_equal(actuator_safe, '0', "not safe yet");

        rst_n <= '0';
        wait for 1 ns;
        check_equal(can_tx, '1', "CAN pin recessive");
        check_equal(actuator_safe, '1', "actuators safe");
      elsif run("short_pulse_stops_a_uart_byte_and_restarts_the_program") then
        wait until uart_tx = '0' for c_timeout;
        check_equal(uart_tx, '0', "byte started");
        short_reset;
        check_equal(actuator_safe, '1', "safe until the reset has been released");
        wait for c_after_reset;
        check_equal(actuator_safe, '0', "released");
        check_equal(uart_tx, '1', "the byte stopped");

        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "the program ran again");
        check_equal(rx_frame.id, std_logic_vector(to_unsigned(16#123#, 11)), "CAN frame ID");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");
        check_equal(nmi_fault, '0', "cores left reset together");
      elsif run("short_pulse_stops_a_can_frame") then
        wait until can_tx = '0' for c_timeout;
        check_equal(can_tx, '0', "frame started");
        short_reset;
        wait for c_after_reset;
        check_equal(can_tx, '1', "the frame stopped");
      elsif run("short_pulse_clears_a_lockstep_fault") then
        wait until rising_edge(clk);
        << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >> <= force x"FFFFFFFF";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >> <= release;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(nmi_fault, '1', "fault latched");
        check_equal(actuator_safe, '1', "actuators safe");

        short_reset;
        wait for c_after_reset;
        check_equal(nmi_fault, '0', "fault cleared");
        check_equal(actuator_safe, '0', "actuators released");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
