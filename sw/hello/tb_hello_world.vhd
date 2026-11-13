-- ============================================================================
-- Testbench: hello, world on the SoC
-- ============================================================================
-- Runs sw/hello/hello_imem_image.vhd (sw/hello/main.c, built by sw/build.py)
-- on top_automotive_soc, both cores in lockstep, and reads the UART: the
-- program must print "Hello, world!" and a line end once, with no fault, and
-- keep the watchdog content through several windows. sim/run.py runs it on
-- GHDL and xsim.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;

library work;
  use work.tb_pkg.all;

entity tb_hello_world is
  generic (
    g_test : string := ""
  );
end entity tb_hello_world;

architecture tb of tb_hello_world is

  constant c_clk_period : time := 20 ns;

  -- A fast watchdog clock, so that several kick windows pass quickly
  constant c_wd_period : time            := 40 ns;
  constant c_bit_time  : time            := c_clk_period * 434;
  constant c_expected  : string(1 to 15) := "Hello, world!" & CR & LF;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal actuator_en   : std_logic;
  signal wd_reset      : std_logic;

  type t_log is array (1 to 32) of character;

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

  test_runner_watchdog(30 ms);

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2,
      g_wd_clk_hz => 25_000_000
    )
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      wd_clk_i        => wd_clk,
      can_tx_o        => open,
      can_rx_i        => '1',
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

    uart_count <= 0;

    loop_byte : loop

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

    end loop loop_byte;

  end process p_uart_rx;

  p_check : process is

    alias x_w_wd_reset is << signal i_soc.w_wd_reset : std_logic >>;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

      if (run("prints_hello_world_once_and_keeps_the_watchdog_content")) then
        wait until uart_count >= c_expected'length for 10 ms;
        check_equal(uart_count, c_expected'length, "bytes on the UART");

        loop_char : for lv_i in c_expected'range loop

          check_equal(character'pos(uart_log(lv_i)), character'pos(c_expected(lv_i)),
                      "byte " & integer'image(lv_i));

        end loop loop_char;

        -- Three kick windows: 40,960 watchdog clocks each
        wait for c_wd_period * 41000 * 3;
        check_equal(uart_count, c_expected'length, "nothing more on the UART");
        check_equal(x_w_wd_reset, '0', "no watchdog reset");
        check_equal(actuator_safe, '0', "no fault: actuators");
        check_equal(actuator_en, '1', "no fault: the second channel");
        check_equal(nmi_fault, '0', "no fault: the fault pin");
        info("hello, world printed, and the watchdog kept content");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_check;

end architecture tb;
