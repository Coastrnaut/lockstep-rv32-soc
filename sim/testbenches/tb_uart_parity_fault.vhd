-- ============================================================================
-- Testbench: UART Parity Fault
-- ============================================================================
-- Nothing on the bus can make the UART store bad parity, so this bench forces
-- the stored bit, as an upset in that flip-flop would. The gate must stop every
-- byte, and the error must stay visible to software until software clears it.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_uart_parity_fault is
  generic (
    runner_cfg : string := ""
  );
end entity tb_uart_parity_fault;

architecture tb of tb_uart_parity_fault is

  constant c_clk_period : time := 20 ns;

  -- STATUS with the interrupt set and the UART idle
  constant c_status_error : natural := 2;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  signal clk         : std_logic;
  signal rst_n       : std_logic;
  signal bus_i       : t_rv_bus;
  signal bus_ok      : std_logic;
  signal rdata       : std_logic_vector(31 downto 0);
  signal uart_tx     : std_logic;
  signal uart_busy   : std_logic;
  signal uart_error  : std_logic;
  signal uart_irq    : std_logic;
  signal uart_starts : natural;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 1 ms);

  i_dut : entity lockstep.safe_uart
    port map (
      clk_i        => clk,
      rst_n_i      => rst_n,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok,
      rdata_o      => rdata,
      uart_tx_o    => uart_tx,
      uart_busy_o  => uart_busy,
      uart_error_o => uart_error,
      uart_irq_o   => uart_irq
    );

  p_uart_starts : process (uart_tx) is
  begin

    if falling_edge(uart_tx) then
      uart_starts <= uart_starts + 1;
    end if;

  end process p_uart_starts;

  p_stim : process is

    procedure write_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0)
    ) is
    begin

      bus_i <=
      (
        addr  => addr,
        data  => data,
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;

    end procedure write_bus;

    procedure check_read (
      constant addr     : in std_logic_vector(31 downto 0);
      constant expected : in natural;
      constant label_s  : in string
    ) is
    begin

      bus_i <=
      (
        addr  => addr,
        data  => (others => '0'),
        we    => '0',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;
      wait until rising_edge(clk);
      check_equal(rdata, std_logic_vector(to_unsigned(expected, 32)), label_s);

    end procedure check_read;

    -- Upset the stored parity of a byte that has even parity, so that the bit
    -- should be 0, and give the UART time to act on it

    procedure send_byte is
    begin

      << signal i_dut.r_tx_parity : std_logic >> <= force '1';
      write_bus(c_uart_tx_data_addr, x"00000042");

      loop_dummy : for lv_dummy in 1 to 4 loop

        wait until rising_edge(clk);

      end loop loop_dummy;

    end procedure send_byte;

    procedure settle is
    begin

      wait until rising_edge(clk);
      wait until rising_edge(clk);

    end procedure settle;

  begin

    test_runner_setup(runner, runner_cfg);

    loop_while : while test_suite loop

      bus_i  <= c_bus_idle;
      bus_ok <= '1';
      rst_n  <= '0';
      settle;
      settle;
      rst_n  <= '1';
      settle;

      if run("bad_parity_stops_the_byte_and_is_reported") then
        check_equal(uart_irq, '0', "no interrupt after reset");
        check_read(c_uart_parity_addr, 1, "PARITY good before any byte");
        send_byte;
        check_equal(uart_starts, 0, "no start bit");
        check_equal(uart_busy, '0', "not busy");
        check_equal(uart_irq, '1', "interrupt");
        check_read(c_uart_status_addr, c_status_error, "STATUS");
        check_read(c_uart_parity_addr, 0, "PARITY bad");
      elsif run("error_stays_until_status_is_written") then
        send_byte;
        check_equal(uart_error, '0', "the raw error lasts one clock");

        -- Reading must not clear it: software polling STATUS would lose it
        check_read(c_uart_status_addr, c_status_error, "first read");
        check_read(c_uart_status_addr, c_status_error, "second read");
        check_equal(uart_irq, '1', "reads leave the interrupt set");

        write_bus(c_uart_parity_addr, x"00000000");
        write_bus(x"C0000404", x"00000000");
        settle;
        check_equal(uart_irq, '1', "a write elsewhere leaves it set");

        write_bus(c_uart_status_addr, x"00000000");
        settle;
        check_equal(uart_irq, '0', "a write to STATUS clears it");
        check_read(c_uart_status_addr, 0, "STATUS clear");

        -- Every error raises it again
        send_byte;
        check_equal(uart_irq, '1', "the next error raises it again");
      elsif run("safety_gate_blocks_clearing_the_error") then
        send_byte;
        bus_ok <= '0';
        write_bus(c_uart_status_addr, x"00000000");
        bus_ok <= '1';
        settle;
        check_equal(uart_irq, '1', "the gate blocks the write");
      elsif run("error_beats_a_status_write_on_the_same_clock") then
        -- The error appears the clock after the byte is stored
        << signal i_dut.r_tx_parity : std_logic >> <= force '1';
        write_bus(c_uart_tx_data_addr, x"00000042");
        write_bus(c_uart_status_addr, x"00000000");
        settle;
        check_equal(uart_irq, '1', "the error is not lost");
      elsif run("reset_clears_the_error") then
        send_byte;
        rst_n <= '0';
        settle;
        rst_n <= '1';
        settle;
        check_equal(uart_irq, '0', "reset clears the interrupt");
        check_read(c_uart_status_addr, 0, "STATUS clear");
      end if;

    end loop loop_while;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
