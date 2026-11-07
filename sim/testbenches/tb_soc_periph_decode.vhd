-- ============================================================================
-- Testbench: Peripheral Address Decode
-- ============================================================================
-- CAN and UART on one bus, wired as they are in top_automotive_soc. Addresses
-- are written out from section 5.1 of docs/safety/hsi_specification.md rather
-- than taken from the package, so that a wrong address there fails this bench.
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

entity tb_soc_periph_decode is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_periph_decode;

architecture tb of tb_soc_periph_decode is

  constant c_clk_period   : time     := 20 ns;
  constant c_clks_per_bit : positive := 8;
  constant c_bit_time     : time     := c_clk_period * c_clks_per_bit;

  -- A whole CAN frame, plus the 11 recessive bits that come before it
  constant c_max_frame_time : time := c_bit_time * (c_max_frame_bits + 11);

  -- A UART byte is 11 bits of 435 clocks, with a bit to spare
  constant c_uart_byte_time : time := c_clk_period * 435 * 12;

  constant c_can_id_addr         : std_logic_vector(31 downto 0) := x"40000300";
  constant c_can_dlc_addr        : std_logic_vector(31 downto 0) := x"40000304";
  constant c_can_data_addr       : std_logic_vector(31 downto 0) := x"40000308";
  constant c_can_status_addr     : std_logic_vector(31 downto 0) := x"4000030C";
  constant c_can_data_hi_addr    : std_logic_vector(31 downto 0) := x"40000310";
  constant c_can_tx_request_addr : std_logic_vector(31 downto 0) := x"40000314";
  constant c_uart_addr           : std_logic_vector(31 downto 0) := x"40000400";
  constant c_uart_status_addr    : std_logic_vector(31 downto 0) := x"40000404";
  constant c_uart_parity_addr    : std_logic_vector(31 downto 0) := x"40000408";

  signal clk       : std_logic;
  signal rst_n     : std_logic;
  signal bus_i     : t_rv_bus;
  signal bus_ok    : std_logic;
  signal can_tx    : std_logic;
  signal can_busy  : std_logic;
  signal uart_tx   : std_logic;
  signal uart_busy : std_logic;
  signal uart_err  : std_logic;

  -- Read data, combined as in top_automotive_soc
  signal can_rdata  : std_logic_vector(31 downto 0);
  signal uart_rdata : std_logic_vector(31 downto 0);
  signal rdata      : std_logic_vector(31 downto 0);

  -- The CAN bus: the DUT and a receiver that acknowledges
  signal can_bus   : std_logic;
  signal ack_tx    : std_logic;
  signal rx_starts : natural;
  signal rx_done   : natural;
  signal rx_frame  : t_rx_frame;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 10 ms);

  i_can : entity lockstep.automotive_can_controller
    generic map (
      g_clks_per_bit => c_clks_per_bit
    )
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok,
      rdata_o    => can_rdata,
      can_tx_o   => can_tx,
      can_rx_i   => can_bus,
      can_busy_o => can_busy
    );

  i_uart : entity lockstep.safe_uart
    port map (
      clk_i        => clk,
      rst_n_i      => rst_n,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok,
      rdata_o      => uart_rdata,
      uart_tx_o    => uart_tx,
      uart_busy_o  => uart_busy,
      uart_error_o => uart_err
    );

  rdata <= can_rdata or uart_rdata;

  can_bus <= can_tx and ack_tx;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_bit_time
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

  p_stim : process is

    -- One-clock write, as a CPU store would be

    procedure write_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0)
    ) is
    begin

      bus_i       <=
      (
        addr  => addr,
        data  => data,
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      bus_i.valid <= '0';
      bus_i.we    <= '0';

    end procedure write_bus;

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
      wait until rising_edge(clk);
      bus_i.valid <= '0';
      wait until rising_edge(clk);
      check_equal(rdata, std_logic_vector(to_unsigned(expected, 32)), label_s);

    end procedure check_read;

    -- ID 0x123, DLC 2, data bytes 0xA5 and 0x5A

    procedure send_can_frame is
    begin

      write_bus(c_can_id_addr, x"00000123");
      write_bus(c_can_dlc_addr, x"00000002");
      write_bus(c_can_data_addr, x"A55A0000");
      write_bus(c_can_data_hi_addr, x"00000000");
      write_bus(c_can_tx_request_addr, x"00000001");

    end procedure send_can_frame;

    procedure check_both_idle (
      constant label_text : in string
    ) is
    begin

      wait for c_clk_period * 4;
      check(can_busy = '0', label_text & ": CAN idle");
      check(uart_busy = '0', label_text & ": UART idle");

    end procedure check_both_idle;

    procedure check_can_frame is
    begin

      wait until rx_done = 1 for c_max_frame_time;
      check_equal(rx_done, 1, "CAN frame finished");
      check(not rx_frame.stuff_error, "CAN frame stuffing");
      check_equal(rx_frame.id, std_logic_vector(to_unsigned(16#123#, 11)), "CAN frame ID");
      check_equal(rx_frame.dlc, std_logic_vector(to_unsigned(2, 4)), "CAN frame DLC");
      check_equal(rx_frame.data, std_logic_vector'(x"A55A000000000000"), "CAN frame data");
      check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");

    end procedure check_can_frame;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      rst_n  <= '0';
      bus_ok <= '1';
      bus_i  <=
      (
        addr  => (others => '0'),
        data  => (others => '0'),
        we    => '0',
        valid => '0',
        sel   => "1111"
      );
      wait for c_clk_period * 3;
      rst_n  <= '1';
      wait until rising_edge(clk);

      if run("can_address_reaches_only_can") then
        send_can_frame;
        wait for c_clk_period * 4;
        check(can_busy = '1', "CAN accepted the write");
        wait until uart_busy = '1' or rx_done = 1 for c_max_frame_time;
        check(uart_busy = '0', "UART stayed idle");
        check_can_frame;
      elsif run("uart_address_reaches_only_uart") then
        write_bus(c_uart_addr, x"00000041");
        wait for c_clk_period * 4;
        check(uart_busy = '1', "UART accepted the write");
        check(can_busy = '0', "CAN stayed idle");
        wait until uart_busy = '0' for c_uart_byte_time;
        check(uart_busy = '0', "UART sent the byte");
        check(can_busy = '0', "CAN stayed idle");
        check_equal(rx_starts, 0, "no CAN frame");
      elsif run("other_addresses_reach_neither") then
        -- Where every write went before there was any decoding
        write_bus(x"00000000", x"00000001");
        check_both_idle("address 0");

        -- The other blocks in the window, and the words beyond each peripheral
        write_bus(x"40000000", x"00000001");
        check_both_idle("lockstep block");
        write_bus(x"40000100", x"00000001");
        check_both_idle("ECC block");
        write_bus(x"40000200", x"00000001");
        check_both_idle("watchdog block");
        write_bus(x"40000318", x"00000001");
        check_both_idle("past the CAN registers");
        write_bus(x"40000404", x"00000001");
        check_both_idle("UART offset 4");

        -- The same low bits outside the peripheral window
        write_bus(x"50000314", x"00000001");
        check_both_idle("outside the window, CAN");
        write_bus(x"50000400", x"00000001");
        check_both_idle("outside the window, UART");

        wait for c_max_frame_time;
        check_equal(rx_starts, 0, "no CAN frame");
      elsif run("both_peripherals_run_at_once") then
        send_can_frame;
        write_bus(c_uart_addr, x"00000041");
        wait for c_clk_period * 4;
        check(can_busy = '1', "CAN busy");
        check(uart_busy = '1', "UART busy");
        check_can_frame;
        wait until uart_busy = '0' for c_uart_byte_time;
        check(uart_busy = '0', "UART sent the byte");
      elsif run("reads_come_from_the_addressed_peripheral") then
        write_bus(c_can_data_hi_addr, x"12345678");
        check_read(c_can_data_hi_addr, 16#12345678#, "CAN DATA_HI");
        check_read(c_can_status_addr, 0, "CAN idle");
        check_read(c_uart_status_addr, 0, "UART idle");

        write_bus(c_uart_addr, x"00000041");
        wait for c_clk_period * 4;
        check_read(c_uart_status_addr, 1, "UART busy");
        check_read(c_can_status_addr, 0, "CAN still idle");
        check_read(c_uart_parity_addr, 1, "UART parity good");
        wait until uart_busy = '0' for c_uart_byte_time;

        send_can_frame;
        wait until rising_edge(clk);
        check_read(c_can_status_addr, 1, "CAN busy");
        check_read(c_uart_status_addr, 0, "UART idle again");
        check_read(c_can_id_addr, 16#123#, "CAN ID");
        check_read(c_can_dlc_addr, 2, "CAN DLC");
        check_read(c_can_tx_request_addr, 0, "TX_REQUEST is write only");
        check_read(c_uart_addr, 0, "TX_DATA is write only");
      elsif run("safety_gate_blocks_both_addresses") then
        bus_ok <= '0';
        send_can_frame;
        write_bus(c_uart_addr, x"00000041");
        bus_ok <= '1';
        check_both_idle("gate low");
        wait for c_max_frame_time;
        check_equal(rx_starts, 0, "no CAN frame");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
