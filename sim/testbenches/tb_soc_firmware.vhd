-- ============================================================================
-- Testbench: Firmware on the Lockstep Cores
-- ============================================================================
-- Boots top_automotive_soc from sim/scripts/soc_firmware.py, so that real load
-- and store instructions on both cores reach the peripherals. The program sends
-- a CAN frame, polls STATUS, and reports what it read over the UART. The cores
-- only stay in lockstep if they both read the same data.
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

entity tb_soc_firmware is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_firmware;

architecture tb of tb_soc_firmware is

  constant c_clk_period : time := 20 ns;

  -- 50 MHz clock: 500 kbit/s CAN and 115200 baud UART
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;

  -- How long the program may take to answer
  constant c_timeout : time := 4 ms;

  signal clk           : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus    : std_logic;
  signal ack_tx     : std_logic;
  signal ack_enable : std_logic;
  signal rx_starts  : natural;
  signal rx_done    : natural;
  signal rx_frame   : t_rx_frame;

  -- What the receiver on uart_tx saw
  signal uart_count : natural;
  signal uart_byte  : std_logic_vector(7 downto 0);

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 20 ms);

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
      ack_enable_i => ack_enable,
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
    uart_byte  <= v_byte;
    uart_count <= uart_count + 1;

  end process p_uart_rx;

  -- The cores must stay in lockstep for the whole program
  p_lockstep : process (clk) is
  begin

    if (rising_edge(clk) and rst_n = '1') then
      check(actuator_safe /= '1', "cores stayed in lockstep");
    end if;

  end process p_lockstep;

  p_stim : process is

    procedure check_uart_byte (
      constant count    : in natural;
      constant expected : in std_logic_vector(7 downto 0)
    ) is
    begin

      wait until uart_count = count for c_timeout;
      check_equal(uart_count, count, "UART byte arrived");
      check_equal(uart_byte, expected, "UART byte");

    end procedure check_uart_byte;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      ack_enable <= '1';
      rst_n      <= '0';
      wait for c_clk_period * 5;
      rst_n      <= '1';

      if run("program_sends_a_frame_and_reads_back_success") then
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "CAN frame finished");
        check(not rx_frame.stuff_error, "CAN frame stuffing");
        check_equal(rx_frame.id, std_logic_vector(to_unsigned(16#123#, 11)), "CAN frame ID");
        check_equal(rx_frame.dlc, std_logic_vector(to_unsigned(2, 4)), "CAN frame DLC");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");

        -- 'K' means both cores read an error counter of zero. 'D' means they
        -- saw UART STATUS busy and then clear, and 'B' would mean it never set.
        check_uart_byte(1, x"4B");
        check_uart_byte(2, x"44");
        check_equal(rx_starts, 1, "one CAN frame");
        check_equal(nmi_fault, '0', "no lockstep fault");
      elsif run("program_reads_a_nonzero_error_counter") then
        -- Two attempts go unacknowledged, so STATUS holds 8 + 8 - 1 = 15
        ack_enable <= '0';
        wait until rx_done = 2 for c_timeout;
        check_equal(rx_done, 2, "two failed attempts");
        ack_enable <= '1';

        check_uart_byte(1, x"46");
        check_uart_byte(2, x"44");
        check_equal(rx_starts, 3, "the third attempt got through");
        check_equal(nmi_fault, '0', "no lockstep fault");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
