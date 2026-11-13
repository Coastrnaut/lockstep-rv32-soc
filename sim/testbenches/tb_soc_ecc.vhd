-- ============================================================================
-- Testbench: ECC in the SoC
-- ============================================================================
-- Runs sim/scripts/soc_firmware.py with bits stuck in the word coming out of the
-- RAM. The program stores to the RAM, reads it back, and reports what it finds
-- and how many errors SBE_COUNT holds, so a bit that the ECC corrects should
-- change nothing but that count. Two bits are more than it can correct, and
-- those have to lock the SoC within the fault tolerant time of 50 us.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;

library work;
  use work.can_test_pkg.all;

entity tb_soc_ecc is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_ecc;

architecture tb of tb_soc_ecc is

  constant c_clk_period    : time := 20 ns;
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;
  constant c_timeout       : time := 1 ms;
  constant c_ftti          : time := 50 us;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
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

  -- What the receiver on uart_tx saw

  type t_byte_log is array (1 to 8) of std_logic_vector(7 downto 0);

  signal uart_count : natural;
  signal uart_log   : t_byte_log;

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

    alias ram_word   is << signal i_soc.i_ecc_ram.r_word : std_logic_vector(71 downto 0) >>;
    alias ecc_fatal  is << signal i_soc.w_ecc_fatal : std_logic >>;
    alias sbe_count  is << signal i_soc.i_ecc_ram.r_sbe_count : unsigned(15 downto 0) >>;
    alias wd_counter is << signal i_soc.i_watchdog_supervisor.i_watchdog.r_counter : unsigned(15 downto 0) >>;
    alias soc_rst_n  is << signal i_soc.w_rst_n : std_logic >>;

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

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

      if run("one_stuck_bit_is_corrected_and_the_program_carries_on") then
        -- Data bit 0, which is 0 all through the program's RAM test
        ram_word(0) <= force '1';
        check_uart_byte(1, x"30");

        -- 'M' means the program read back what it stored. '3' means SBE_COUNT saw
        -- the bit on the two stores and the load.
        check_uart_byte(2, x"4D");
        check_uart_byte(3, x"33");
        ram_word(0) <= release;

        check_uart_byte(4, x"4B");
        check_uart_byte(5, x"44");
        check_equal(rx_done, 1, "CAN frame sent");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");
        check_equal(nmi_fault, '0', "no fault");
        check_equal(actuator_safe, '0', "actuators free");
      elsif run("two_stuck_bits_lock_the_soc_within_the_ftti") then
        ram_word(0) <= force '1';
        ram_word(1) <= force '1';

        wait until ecc_fatal = '1' for c_timeout;
        check_equal(ecc_fatal, '1', "uncorrectable word found");

        -- The pin is registered (HSI FLT-01), so it rises at the next edge
        wait for 1 ns;
        check_equal(nmi_fault, '0', "no pin glitch in the cycle the error is found");
        wait until rising_edge(clk);
        wait for 1 ns;
        check_equal(nmi_fault, '1', "fault pin at the next edge");

        wait until actuator_safe = '1' for c_ftti;
        check_equal(actuator_safe, '1', "actuators safe in time");

        ram_word(0) <= release;
        ram_word(1) <= release;

        -- The fault is gone, but the bus stays shut, so nothing more comes out
        wait for c_uart_bit_time * 24;
        check_equal(uart_count, 1, "the program got no further than the first byte");
        check_equal(actuator_safe, '1', "actuators still safe");
        check_equal(nmi_fault, '1', "NMI held");
        check_equal(rx_done, 0, "no CAN frame");
      elsif run("error_counts_outlast_a_watchdog_reset") then
        ram_word(0) <= force '1';
        check_uart_byte(3, x"33");
        ram_word(0) <= release;
        check_equal(sbe_count, to_unsigned(3, 16), "three errors counted");

        -- Move the watchdog to just short of its timeout
        wd_counter <= force to_unsigned(49990, 16);
        wait until rising_edge(wd_clk);
        wd_counter <= release;
        wait until soc_rst_n = '0' for c_timeout;
        check_equal(soc_rst_n, '0', "the watchdog reset the SoC");
        wait until soc_rst_n = '1' for c_timeout;
        check_equal(soc_rst_n, '1', "and let it restart");
        check_equal(sbe_count, to_unsigned(3, 16), "still three");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
