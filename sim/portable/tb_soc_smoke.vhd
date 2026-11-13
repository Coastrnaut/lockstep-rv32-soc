-- ============================================================================
-- Testbench: the simulation firmware on the SoC, for any simulator
-- ============================================================================
-- Plain VHDL-2008 with no VUnit, so it runs on simulators that cannot run
-- VUnit's library, such as Vivado's xsim. sim/scripts/vivado_sim.py runs it on
-- both xsim and GHDL and compares the outcomes.
--
-- It checks what tb_soc_firmware.program_sends_a_frame_and_reads_back_success
-- checks: the program prints "0M0KD" on the UART, sends one CAN frame with
-- ID 0x123, two data bytes A5 5A and a good CRC, and nothing trips. It ends
-- with "SOC SMOKE PASS", or a failure naming what differed.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;

library work;
  use work.can_test_pkg.all;

entity tb_soc_smoke is
end entity tb_soc_smoke;

architecture tb of tb_soc_smoke is

  constant c_clk_period   : time           := 20 ns;
  constant c_can_bit_time : time           := c_clk_period * 100;
  constant c_bit_time     : time           := c_clk_period * 434;
  constant c_timeout      : time           := 2 ms;
  constant c_expected     : string(1 to 5) := "0M0KD";

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal can_bus       : std_logic;
  signal ack_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  -- The CAN node that acknowledges and records the frame
  signal rx_frame  : t_rx_frame;
  signal rx_starts : natural;
  signal rx_done   : natural;

  type t_log is array (1 to 16) of character;

  signal uart_log   : t_log;
  signal uart_count : natural;

begin

  p_clk : process is
  begin

    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  -- The watchdog does not time out within the run
  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after 500 ns;
    wait for 1 us;

  end process p_wd_clk;

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

  -- 8 data bits LSB first, then parity and stop
  p_uart_rx : process is

    variable v_byte : std_logic_vector(7 downto 0);

  begin

    wait until uart_tx = '0';
    wait for c_bit_time / 2;

    loop_bit : for lv_i in 0 to 7 loop

      wait for c_bit_time;
      v_byte(lv_i) := uart_tx;

    end loop loop_bit;

    wait for c_bit_time * 2;

    if (uart_count < uart_log'high) then
      uart_log(uart_count + 1) <= character'val(to_integer(unsigned(v_byte)));
      uart_count               <= uart_count + 1;
    end if;

  end process p_uart_rx;

  p_check : process is
  begin

    rst_n <= '0';
    wait for c_clk_period * 5;
    rst_n <= '1';

    wait until rx_done = 1 for c_timeout;
    assert rx_done = 1
      report "SOC SMOKE FAIL: no CAN frame finished"
      severity failure;
    assert rx_frame.id = std_logic_vector(to_unsigned(16#123#, 11))
      report "SOC SMOKE FAIL: CAN frame ID"
      severity failure;
    assert rx_frame.dlc = std_logic_vector(to_unsigned(2, 4))
      report "SOC SMOKE FAIL: CAN frame DLC"
      severity failure;
    assert rx_frame.data = std_logic_vector'(x"A55A000000000000")
      report "SOC SMOKE FAIL: CAN frame data"
      severity failure;
    assert rx_frame.crc = rx_frame.crc_expected
      report "SOC SMOKE FAIL: CAN frame CRC"
      severity failure;

    wait until uart_count >= c_expected'length for c_timeout;
    -- Long enough for one more byte, which must not come
    wait for c_bit_time * 12;
    assert uart_count = c_expected'length
      report "SOC SMOKE FAIL: " & integer'image(uart_count) & " bytes on the UART, expected " &
             integer'image(c_expected'length)
      severity failure;

    loop_byte : for lv_i in c_expected'range loop

      assert uart_log(lv_i) = c_expected(lv_i)
        report "SOC SMOKE FAIL: byte " & integer'image(lv_i) & " is '" & uart_log(lv_i) &
               "', expected '" & c_expected(lv_i) & "'"
        severity failure;

    end loop loop_byte;

    assert rx_starts = 1 and actuator_safe = '0' and nmi_fault = '0'
      report "SOC SMOKE FAIL: a second frame, a fault or a reset during the run"
      severity failure;

    report "SOC SMOKE PASS: " & string(uart_log(1 to c_expected'length)) & ", one CAN frame";
    std.env.finish;

  end process p_check;

end architecture tb;
