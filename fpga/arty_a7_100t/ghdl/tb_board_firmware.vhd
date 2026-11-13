-- ============================================================================
-- Testbench: the Arty A7 board image on the SoC (roadmap R3.3)
-- ============================================================================
-- Runs fpga/arty_a7_100t/board_imem_image.vhd on top_automotive_soc, with a
-- fast watchdog clock so that several kick windows pass quickly. The board
-- image must print "LS0" after a cold start, then a dot for each kick, with no
-- watchdog reset and no fault. Plain GHDL, run by check_board.py.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;

entity tb_board_firmware is
end entity tb_board_firmware;

architecture tb of tb_board_firmware is

  constant c_clk_period : time := 20 ns;
  constant c_wd_period  : time := 40 ns;  -- 40,960 of these open the window
  constant c_bit_time   : time := c_clk_period * 434;
  constant c_expected   : string(1 to 6) := "LS0...";

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  type t_log is array (1 to 16) of character;

  signal uart_log   : t_log;
  signal uart_count : natural;

begin

  p_clk : process is
  begin

    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after c_wd_period / 2;
    wait for c_wd_period;

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
      can_rx_i        => '1',
      uart_tx_o       => uart_tx,
      nmi_fault_o     => nmi_fault,
      actuator_safe_o => actuator_safe,
      diag_cs_n_i     => '1',
      diag_sck_i      => '0',
      diag_sdo_o      => open
    );

  -- 8 data bits LSB first, then parity and stop
  p_uart_rx : process is

    variable v_byte : std_logic_vector(7 downto 0);

  begin

    wait until uart_tx = '0';
    wait for c_bit_time / 2;

    for i in 0 to 7 loop

      wait for c_bit_time;
      v_byte(i) := uart_tx;

    end loop;

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

    wait until uart_count >= c_expected'length for 20 ms;
    assert uart_count >= c_expected'length
      report "BOARD FIRMWARE FAIL: " & integer'image(uart_count) & " bytes on the UART"
      severity failure;

    for i in c_expected'range loop

      assert uart_log(i) = c_expected(i)
        report "BOARD FIRMWARE FAIL: byte " & integer'image(i) & " is '" & uart_log(i) &
               "', expected '" & c_expected(i) & "'"
        severity failure;

    end loop;

    assert actuator_safe = '0' and nmi_fault = '0'
      report "BOARD FIRMWARE FAIL: a fault or a reset during the run"
      severity failure;

    report "BOARD FIRMWARE PASS: " & string(uart_log(1 to c_expected'length));
    std.env.finish;

  end process p_check;

end architecture tb;
