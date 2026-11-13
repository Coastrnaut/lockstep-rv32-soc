-- ============================================================================
-- Testbench: Safe UART — TX + Parity Protection
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_uart is
  generic (
    runner_cfg : string := ""
  );
end entity tb_uart;

architecture rtl of tb_uart is

  constant c_clk_period : time := 20 ns;
  constant c_bit_time   : time := c_clk_period * 434;

  signal tb_clk    : std_logic;
  signal tb_rst_n  : std_logic;
  signal bus_i     : t_rv_bus;
  signal bus_ok    : std_logic;
  signal uart_tx   : std_logic;
  signal uart_busy : std_logic;
  signal uart_err  : std_logic;
  signal rdata     : std_logic_vector(31 downto 0);

  -- What the receiver on uart_tx saw
  signal rx_count  : natural;
  signal rx_byte   : std_logic_vector(7 downto 0);
  signal rx_parity : std_logic;
  signal rx_stop   : std_logic;

  -- Measured from the start bit of a byte whose first data bit is 1
  signal start_width : time;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    tb_clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  i_uart : entity lockstep.safe_uart
    port map (
      clk_i        => tb_clk,
      rst_n_i      => tb_rst_n,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok,
      rdata_o      => rdata,
      uart_tx_o    => uart_tx,
      uart_busy_o  => uart_busy,
      uart_error_o => uart_err

    );

  -- Independent UART receiver: samples mid-bit on its own timing from the start
  -- bit. A frame is a start bit, 8 data bits LSB first, even parity and a stop bit.
  p_uart_rx : process is

    variable v_byte : std_logic_vector(7 downto 0);

  begin

    wait until uart_tx = '0';
    wait for c_bit_time / 2;

    loop_i : for lv_i in 0 to 7 loop

      wait for c_bit_time;
      v_byte(lv_i) := uart_tx;

    end loop loop_i;

    wait for c_bit_time;
    rx_parity <= uart_tx;
    wait for c_bit_time;
    rx_stop   <= uart_tx;
    rx_byte   <= v_byte;
    rx_count  <= rx_count + 1;

  end process p_uart_rx;

  p_start_width : process is

    variable v_fall : time;

  begin

    wait until uart_tx = '0';
    v_fall      := now;
    wait until uart_tx = '1';
    start_width <= now - v_fall;
    wait until uart_busy = '0';

  end process p_start_width;

  p_stim : process is

    type t_patterns is array (0 to 5) of std_logic_vector(7 downto 0);

    constant c_patterns : t_patterns :=
    (
      x"00",
      x"FF",
      x"55",
      x"AA",
      x"01",
      x"80"
    );

    variable v_addr : std_logic_vector(31 downto 0);
    variable v_data : std_logic_vector(7 downto 0);

    -- One-clock read: the CPU takes the data in the cycle after the strobe

    procedure check_read (
      constant addr     : in std_logic_vector(31 downto 0);
      constant expected : in natural;
      constant label_s  : in string
    ) is
    begin

      bus_i       <=
      (
        addr  => addr,
        data  => (others => '0'),
        we    => '0',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(tb_clk);
      bus_i.valid <= '0';
      wait until rising_edge(tb_clk);
      check_equal(rdata, std_logic_vector(to_unsigned(expected, 32)), label_s);

    end procedure check_read;

  begin

    test_runner_setup(runner, runner_cfg);

    tb_rst_n <= '0';
    bus_ok   <= '1';
    bus_i    <=
    (
      addr  => (others => '0'),
      data  => (others => '0'),
      we    => '0',
      valid => '0',
      sel   => "1111"
    );

    loop_dummy : for lv_dummy in 1 to 5 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy;

    tb_rst_n <= '1';

    loop_dummy_2 : for lv_dummy in 1 to 5 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy_2;

    -- --- Test 1: Idle state ---
    check(uart_busy = '0', "UART idle at start");
    check(uart_tx = '1', "TX recessive at idle");

    -- --- Test 2: Write valid data → TX starts ---
    bus_i <=
    (
      addr  => c_uart_tx_data_addr,
      data  => x"00000041",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );
    -- p_rx_regs accepts write
    wait until rising_edge(tb_clk);
    bus_i.valid <= '0';
    -- FSM sees r_tx_valid, transitions
    wait until rising_edge(tb_clk);
    -- extra margin
    wait until rising_edge(tb_clk);
    check(uart_busy = '1', "UART busy after write");
    check(uart_err = '0', "no parity error on valid write");
    check_read(c_uart_status_addr, 1, "STATUS while busy");
    check_read(c_uart_parity_addr, 1, "PARITY good");

    -- STATUS is not zero while busy, so a stray decode would show here
    loop_addr_bit : for lv_addr_bit in 0 to 31 loop

      v_addr              := c_uart_status_addr;
      v_addr(lv_addr_bit) := not v_addr(lv_addr_bit);
      check_read(v_addr, 0, "another address reads zero");

    end loop loop_addr_bit;

    -- --- Test 3: Wait for TX to finish (max 10000 cycles) ---
    loop_dummy_3 : for lv_dummy in 1 to 10000 loop

      wait until rising_edge(tb_clk);

      if (uart_busy = '0') then
        exit;
      end if;

    end loop loop_dummy_3;

    check(uart_busy = '0', "UART idle after TX complete");
    wait until rising_edge(tb_clk);
    wait until rising_edge(tb_clk);
    check_read(c_uart_status_addr, 0, "STATUS when idle");

    -- The byte really went out on the pin
    check_equal(rx_count, 1, "one frame on uart_tx");
    check_equal(rx_byte, std_logic_vector'(x"41"), "data bits on uart_tx");
    check_equal(rx_parity, '0', "even parity on uart_tx");
    check_equal(rx_stop, '1', "stop bit on uart_tx");
    check_equal(start_width, c_bit_time, "434 clocks per bit: 115200 baud from 50 MHz");

    -- --- Test 4: A write one address bit away, or to the CAN mailbox, is ignored ---
    loop_addr_bit_2 : for lv_addr_bit in 0 to 32 loop

      bus_i <=
      (
        addr  => c_can_tx_request_addr,
        data  => x"00000042",
        we    => '1',
        valid => '1',
        sel   => "1111"
      );

      if (lv_addr_bit < 32) then
        bus_i.addr              <= c_uart_tx_data_addr;
        bus_i.addr(lv_addr_bit) <= not c_uart_tx_data_addr(lv_addr_bit);
      end if;

      wait until rising_edge(tb_clk);
      bus_i.valid <= '0';
      wait until rising_edge(tb_clk);
      wait until rising_edge(tb_clk);
      wait until rising_edge(tb_clk);
      check(uart_busy = '0', "no TX from another address");

    end loop loop_addr_bit_2;

    -- --- Test 5: Reads answer only at their own addresses ---
    check_read(c_uart_tx_data_addr, 0, "TX_DATA is write only");

    loop_addr_bit_3 : for lv_addr_bit in 0 to 31 loop

      v_addr              := c_uart_parity_addr;
      v_addr(lv_addr_bit) := not v_addr(lv_addr_bit);
      check_read(v_addr, 0, "another address reads zero");

    end loop loop_addr_bit_3;

    bus_ok <= '0';
    check_read(c_uart_parity_addr, 0, "gate low reads zero");
    bus_ok <= '1';

    -- --- Test 6: Every data bit reaches the pin, with the right parity ---
    loop_pattern : for lv_pattern in 0 to 5 loop

      v_data      := c_patterns(lv_pattern);
      bus_i       <=
      (
        addr  => c_uart_tx_data_addr,
        data  => x"000000" & v_data,
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(tb_clk);
      bus_i.valid <= '0';
      wait until rx_count = lv_pattern + 2 for c_bit_time * 13;
      check_equal(rx_count, lv_pattern + 2, "frame on uart_tx");
      check_equal(rx_byte, v_data, "data bits on uart_tx");
      check_equal(rx_parity, xor v_data, "even parity on uart_tx");
      check_equal(rx_stop, '1', "stop bit on uart_tx");
      wait for c_bit_time;

    end loop loop_pattern;

    -- --- Test 7: A store has to include byte 0, where the data is ---
    bus_i       <=
    (
      addr  => c_uart_tx_data_addr,
      data  => x"00000042",
      we    => '1',
      valid => '1',
      sel   => "1110"
    );
    wait until rising_edge(tb_clk);
    bus_i.valid <= '0';
    wait until rising_edge(tb_clk);
    wait until rising_edge(tb_clk);
    wait until rising_edge(tb_clk);
    check(uart_busy = '0', "store without byte 0 ignored");

    bus_i       <=
    (
      addr  => c_uart_tx_data_addr,
      data  => x"00000042",
      we    => '1',
      valid => '1',
      sel   => "0001"
    );
    wait until rising_edge(tb_clk);
    bus_i.valid <= '0';
    wait until rx_count = 8 for c_bit_time * 13;
    check_equal(rx_byte, std_logic_vector'(x"42"), "byte store sent");

    test_runner_cleanup(runner);

  end process p_stim;

end architecture rtl;
