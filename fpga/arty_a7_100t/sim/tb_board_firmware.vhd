-- ============================================================================
-- Testbench: the Arty A7 board image on the SoC (roadmap R3.3)
-- ============================================================================
-- Runs fpga/arty_a7_100t/board_imem_image.vhd on top_automotive_soc, with a
-- fast watchdog clock so that several kick windows pass quickly, and a CAN
-- node on the bus that acknowledges good frames. The board image must print
-- "LS0" after a cold start, "E0" for the ECC RAM check, "C0" for a CAN frame
-- sent and acknowledged (and the node must have received it whole), then a
-- dot for each kick, with no watchdog reset and no fault. sim/run.py runs it on GHDL and xsim, and
-- check_board.py on GHDL.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;

library work;
  use work.tb_pkg.all;
  use work.can_test_pkg.all;

entity tb_board_firmware is
  generic (
    g_test : string := ""
  );
end entity tb_board_firmware;

architecture tb of tb_board_firmware is

  constant c_clk_period : time := 20 ns;

  -- 40,960 of these open the window
  constant c_wd_period : time            := 40 ns;
  constant c_bit_time  : time            := c_clk_period * 434;
  constant c_expected  : string(1 to 10) := "LS0E0C0...";

  -- 500 kbit/s at 50 MHz
  constant c_can_bit_time : time := c_clk_period * 100;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal can_bus       : std_logic;
  signal ack_tx        : std_logic;
  signal rx_frame      : t_rx_frame;
  signal rx_done       : natural;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal actuator_en   : std_logic;

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

  -- Another node on the bus: the wired-AND of both, and it acknowledges
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

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2,
      g_wd_clk_hz => 25_000_000
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
      actuator_en_o   => actuator_en,
      actuator_fb_i   => actuator_safe,
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

    test_runner_setup(g_test);
    rst_n <= '0';
    wait for c_clk_period * 5;
    rst_n <= '1';

    wait until uart_count >= c_expected'length for 20 ms;
    check(uart_count >= c_expected'length, integer'image(uart_count) & " bytes on the UART");

    loop_char : for lv_i in c_expected'range loop

      check_equal(uart_log(lv_i), c_expected(lv_i), "byte " & integer'image(lv_i));

    end loop loop_char;

    check_equal(rx_done, 1, "one CAN frame on the bus");
    check_equal(rx_frame.crc, rx_frame.crc_expected, "with a good CRC");
    check_equal(rx_frame.id, "00100100011", "identifier 0x123");
    check_equal(rx_frame.dlc, "0010", "two data bytes");
    check_equal(rx_frame.data(63 downto 48), x"4C53", "the data, LS");
    check_equal(actuator_safe, '0', "no fault or reset during the run: actuators");
    check_equal(nmi_fault, '0', "no fault or reset during the run: fault pin");

    info("board image printed " & string(uart_log(1 to c_expected'length)));
    test_runner_cleanup;

  end process p_check;

end architecture tb;
