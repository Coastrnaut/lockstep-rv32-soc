-- ============================================================================
-- Testbench: UART Abort on a Closed Gate or a Reset
-- ============================================================================
-- HSI section 8.3: when the safety gate closes, or a reset asserts, the TX pin
-- goes to mark at once, and the byte on the wire and any byte waiting behind it
-- are discarded, so that neither can come out when the gate opens again. A
-- reset does that even with the clock stopped.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_uart_abort is
  generic (
    runner_cfg : string := ""
  );
end entity tb_uart_abort;

architecture tb of tb_uart_abort is

  constant c_clk_period : time := 20 ns;
  constant c_bit_time   : time := c_clk_period * 434;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    sel   => "0000",
    we    => '0',
    valid => '0'
  );

  signal clk         : std_logic;
  signal clk_stopped : boolean;
  signal rst_n       : std_logic;
  signal bus_i       : t_rv_bus;
  signal bus_ok      : std_logic;
  signal uart_tx     : std_logic;
  signal uart_busy   : std_logic;
  signal starts      : natural;

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

  i_uart : entity lockstep.safe_uart
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      bus_i       => bus_i,
      bus_ok_i    => bus_ok,
      uart_tx_o   => uart_tx,
      uart_busy_o => uart_busy
    );

  -- Start bits seen on the pin
  p_starts : process (uart_tx) is
  begin

    if falling_edge(uart_tx) then
      starts <= starts + 1;
    end if;

  end process p_starts;

  p_stim : process is

    variable v_starts : natural;

    procedure send (
      constant byte : in std_logic_vector(7 downto 0)
    ) is
    begin

      bus_i <=
      (
        addr  => c_uart_tx_data_addr,
        data  => x"000000" & byte,
        sel   => "1111",
        we    => '1',
        valid => '1'
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;

    end procedure send;

    -- Mark for a byte and more, with nothing starting

    procedure check_quiet (
      constant label_s : in string
    ) is
    begin

      v_starts := starts;
      wait until uart_tx = '0' for c_bit_time * 13;
      check_equal(uart_tx, '1', label_s & ": the pin stays at mark");
      check_equal(starts, v_starts, label_s & ": nothing starts");
      check_equal(uart_busy, '0', label_s & ": not busy");

    end procedure check_quiet;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      clk_stopped <= false;
      bus_i       <= c_bus_idle;
      bus_ok      <= '1';
      rst_n       <= '0';
      wait for c_clk_period * 3;
      rst_n       <= '1';
      wait until rising_edge(clk);

      if run("gate_drop_in_the_start_bit_goes_to_mark_and_drops_the_byte") then
        send(x"55");
        wait until uart_tx = '0' for c_bit_time;
        check_equal(uart_tx, '0', "start bit");
        wait for c_bit_time / 2;
        bus_ok <= '0';
        wait for 1 ns;
        check_equal(uart_tx, '1', "mark as soon as the gate closes");
        check_quiet("gate closed");

        -- The gate opening again must not bring the byte back
        bus_ok <= '1';
        check_quiet("gate open again");
      elsif run("gate_drop_in_a_data_bit_goes_to_mark_and_drops_the_byte") then
        -- 0x00: every data bit is a space
        send(x"00");
        wait until uart_tx = '0' for c_bit_time;
        wait for c_bit_time * 3.5;
        check_equal(uart_tx, '0', "a data bit");
        wait until rising_edge(clk);
        bus_ok <= '0';
        wait for 1 ns;
        check_equal(uart_tx, '1', "mark as soon as the gate closes");
        wait until rising_edge(clk);
        bus_ok <= '1';
        check_quiet("gate open again after one clock");
      elsif run("gate_drop_discards_the_byte_waiting_behind_the_one_on_the_wire") then
        send(x"55");
        wait until uart_tx = '0' for c_bit_time;
        send(x"AA");
        wait for c_bit_time;
        bus_ok <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        bus_ok <= '1';
        check_quiet("neither byte comes out");
      elsif run("one_clock_gate_drop_discards_the_byte_waiting_too") then
        -- The shortest drop: the serializer is idle at the edge after it, and a
        -- byte still waiting would start there unless the drop discarded it
        send(x"55");
        wait until uart_tx = '0' for c_bit_time;
        send(x"AA");
        wait for c_bit_time;
        wait until rising_edge(clk);
        bus_ok <= '0';
        wait until rising_edge(clk);
        bus_ok <= '1';
        check_quiet("neither byte comes out after one clock");
      elsif run("reset_goes_to_mark_without_a_clock") then
        send(x"00");
        wait until uart_tx = '0' for c_bit_time;
        wait for c_bit_time * 2;
        clk_stopped <= true;
        wait for c_clk_period * 3;
        check_equal(uart_tx, '0', "the byte stopped with the clock");
        rst_n       <= '0';
        wait for 1 ns;
        check_equal(uart_tx, '1', "mark at once, with no clock");
        wait for c_bit_time;
        check_equal(uart_tx, '1', "and it stays at mark");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
