-- ============================================================================
-- Testbench: UART Parity Error Through the SoC
-- ============================================================================
-- Boots the same firmware as tb_soc_firmware with the UART's stored parity bit
-- forced wrong, as an upset in that flip-flop would. The parity gate must stop
-- the byte leaving the pin, and UART_ERROR must reach the trap handler. The
-- firmware cannot use the UART to say so, so it sends a CAN frame with ID 0x0EE.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;

entity tb_soc_uart_error is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_uart_error;

architecture tb of tb_soc_uart_error is

  constant c_clk_period   : time := 20 ns;
  constant c_can_bit_time : time := c_clk_period * 100;
  constant c_timeout      : time := 2 ms;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal uart_starts   : natural;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus  : std_logic;
  signal ack_tx   : std_logic;
  signal rx_done  : natural;
  signal rx_frame : t_rx_frame;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  -- The watchdog does not time out for 50 ms, and no test runs that long
  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after 500 ns;
    wait for 1 us;

  end process p_wd_clk;

  test_runner_watchdog(runner, 10 ms);

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

  p_uart_starts : process (uart_tx) is
  begin

    if falling_edge(uart_tx) then
      uart_starts <= uart_starts + 1;
    end if;

  end process p_uart_starts;

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';
      wait for c_clk_period * 2;

      if run("parity_error_blocks_the_byte_and_reaches_the_cpu") then
        -- The first byte the program sends has even parity
        << signal i_soc.i_safe_uart.r_tx_parity : std_logic >> <= force '1';
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "the handler saw UART_ERROR and the program went on");
        check_equal(rx_frame.id, std_logic_vector(to_unsigned(16#0EE#, 11)), "CAN frame ID");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");
        check_equal(uart_starts, 0, "the byte never left the pin");
        check_equal(nmi_fault, '0', "no lockstep fault");
        check_equal(actuator_safe, '0', "cores stayed in lockstep");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
