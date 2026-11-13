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

library work;
  use work.tb_pkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;

entity tb_soc_ecc is
  generic (
    g_test : string := ""
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
  signal actuator_en   : std_logic;

  -- The diagnostic SPI port, as an external supervisor drives it
  signal diag_cs_n : std_logic;
  signal diag_sck  : std_logic;
  signal diag_sdo  : std_logic;

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

  test_runner_watchdog(10 ms);

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
      actuator_en_o   => actuator_en,
      actuator_fb_i   => actuator_safe,
      diag_cs_n_i     => diag_cs_n,
      diag_sck_i      => diag_sck,
      diag_sdo_o      => diag_sdo
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

    loop_i : for lv_i in 0 to 7 loop

      wait for c_uart_bit_time;
      v_byte(lv_i) := uart_tx;

    end loop loop_i;

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
    alias sys_bus    is << signal i_soc.w_safe_sys_bus : t_rv_bus >>;
    alias ram_ecc    is << signal i_soc.i_ecc_ram.w_merged_ecc : std_logic_vector(7 downto 0) >>;
    alias telemetry  is << signal i_soc.w_ecc_telemetry : t_telemetry >>;
    alias bus_valid  is << signal i_soc.w_bus_valid : std_logic >>;

    variable v_ecc    : std_logic_vector(7 downto 0);
    variable v_record : t_telemetry;

    -- Read the 160 bits as an external supervisor would: SPI mode 0 at 1 MHz,
    -- sampling on the rising edge of the clock

    procedure read_diag_port is
    begin

      diag_cs_n <= '0';
      wait for 1 us;

      loop_i_2 : for lv_i in t_telemetry'range loop

        v_record(lv_i) := diag_sdo;
        diag_sck       <= '1';
        wait for 500 ns;
        diag_sck       <= '0';
        wait for 500 ns;

      end loop loop_i_2;

      diag_cs_n <= '1';
      wait for 1 us;

    end procedure read_diag_port;

    -- Each core's XBus response pins, and its trap entry and register writes
    alias x_w_core_a_in is << signal i_soc.w_core_a_in : t_core_inputs >>;
    alias a_ack         is x_w_core_a_in.ack;
    alias a_err         is x_w_core_a_in.err;
    alias a_dat         is x_w_core_a_in.rdata;
    alias x_w_core_b_in is << signal i_soc.w_core_b_in : t_core_inputs >>;
    alias b_ack         is x_w_core_b_in.ack;
    alias b_err         is x_w_core_b_in.err;
    alias b_dat         is x_w_core_b_in.rdata;
    alias a_enter       is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_control_inst.env_enter
      : std_ulogic >>;
    alias a_cause       is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_control_inst.ecause
      : std_ulogic_vector(6 downto 0) >>;
    alias b_enter       is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_control_inst.env_enter
      : std_ulogic >>;
    alias b_cause       is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_control_inst.ecause
      : std_ulogic_vector(6 downto 0) >>;
    alias a_rd_we       is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.rf_we
      : std_ulogic >>;
    alias a_rd_addr     is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.addr
      : std_ulogic_vector(4 downto 0) >>;
    alias b_rd_we       is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.rf_we
      : std_ulogic >>;
    alias b_rd_addr     is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.addr
      : std_ulogic_vector(4 downto 0) >>;

    -- The load and the byte store in the program's RAM test, to the word at
    -- 0x20000008, whose low half then holds 0x12345678 and 0x12345A78. Both have
    -- 00 in bits 1:0, so forcing them to 11 is a double-bit error.
    constant c_load_addr  : std_logic_vector(31 downto 0) := x"20000008";
    constant c_store_addr : std_logic_vector(31 downto 0) := x"20000009";
    constant c_t2         : std_ulogic_vector(4 downto 0) := "00111";

    variable v_found : boolean;

    -- Wait for the request to be accepted, then make its word uncorrectable for
    -- the response cycle, and check both cores' XBus pins (HSI BUS-04, BUS-09).
    -- Core B gets the response two clocks after core A.

    procedure double_bit_error_on (
      constant addr : in std_logic_vector(31 downto 0);
      constant we   : in std_logic
    ) is
    begin

      v_found := false;

      loop_while : while not v_found loop

        wait until rising_edge(clk);
        v_found := sys_bus.valid = '1' and sys_bus.we = we and sys_bus.addr = addr;

      end loop loop_while;

      wait for 1 ns;
      ram_word(1 downto 0) <= force "11";
      wait for 1 ns;
      check_equal(ecc_fatal, '1', "uncorrectable word");
      check_equal(a_err, '1', "core A: ERR");
      check_equal(a_ack, '0', "core A: no ACK");
      check_equal(a_dat, std_ulogic_vector'(x"00000000"), "core A: no data");
      wait until rising_edge(clk);
      ram_word(1 downto 0) <= release;
      wait until rising_edge(clk);
      wait for 1 ns;
      check_equal(b_err, '1', "core B: ERR two clocks later");
      check_equal(b_ack, '0', "core B: no ACK");
      check_equal(b_dat, std_ulogic_vector'(x"00000000"), "core B: no data");

    end procedure double_bit_error_on;

    -- The trap each core takes, with no write to t2 on the way (HSI BUS-08)

    procedure check_access_fault (
      constant cause : in std_ulogic_vector(6 downto 0)
    ) is

      variable v_a_done : boolean;
      variable v_b_done : boolean;

    begin

      v_a_done := false;
      v_b_done := false;

      loop_dummy : for lv_dummy in 1 to 100 loop

        wait until rising_edge(clk);
        check(not (a_rd_we = '1' and a_rd_addr = c_t2), "core A: no write to the load's register");
        check(not (b_rd_we = '1' and b_rd_addr = c_t2), "core B: no write to the load's register");

        if (a_enter = '1' and not v_a_done) then
          check_equal(a_cause, cause, "core A: access fault");
          v_a_done := true;
        end if;

        if (b_enter = '1' and not v_b_done) then
          check_equal(b_cause, cause, "core B: access fault");
          v_b_done := true;
        end if;

        exit when v_a_done and v_b_done;

      end loop loop_dummy;

      check(v_a_done, "core A took a trap");
      check(v_b_done, "core B took a trap");

    end procedure check_access_fault;

    variable v_sbe : unsigned(15 downto 0);

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

    test_runner_setup(g_test);

    loop_while_2 : while test_suite loop

      diag_cs_n <= '1';
      diag_sck  <= '0';
      rst_n     <= '0';
      wait for c_clk_period * 5;
      rst_n     <= '1';

      if run("one_stuck_bit_is_corrected_and_the_program_carries_on") then
        -- Data bit 0, which is 0 all through the program's RAM test
        ram_word(0) <= force '1';
        check_uart_byte(1, x"30");

        -- 'M' means the program read back what it stored. The bit is stuck in
        -- the RAM's read register, so the patrol, which reads a word in every
        -- clock without an access, finds it too, not only the program's two
        -- stores and its load: SBE_COUNT, printed as a digit, is past '3'.
        check_uart_byte(2, x"4D");

        if (uart_count < 3) then
          wait until uart_count >= 3 for c_timeout;
        end if;

        check(unsigned(uart_log(3)) > x"33", "SBE_COUNT counts the patrol's finds as well");
        ram_word(0) <= release;

        check_uart_byte(4, x"4B");
        check_uart_byte(5, x"44");
        check_equal(rx_done, 1, "CAN frame sent");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "CAN frame CRC");
        check_equal(nmi_fault, '0', "no fault");
        check_equal(actuator_safe, '0', "actuators free");
      elsif run("the_first_fault_reads_out_over_the_diagnostic_port_with_the_bus_shut") then
        -- An uncorrectable word stored by the program's first store to the RAM,
        -- which it reads back at its next store to the same word
        wait until rising_edge(clk) and sys_bus.valid = '1' and sys_bus.we = '1' and
                   sys_bus.addr = x"20000008" for c_timeout;
        wait for 1 ns;
        v_ecc   := ram_ecc;
        ram_ecc <= force v_ecc xor x"03";
        wait until rising_edge(clk);
        ram_ecc <= release;

        wait until ecc_fatal = '1' for c_timeout;
        check_equal(ecc_fatal, '1', "the program read the word");
        wait for 2 us;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(bus_valid, '0', "the bus is shut");

        -- The port reads the record with the bus shut, and opens nothing
        read_diag_port;
        -- PATROL can move on while the port shifts; the record and counts cannot
        check_equal(v_record(159 downto 64), telemetry(159 downto 64), "the record as the RAM holds it");
        check_equal(v_record(31 downto 0), telemetry(31 downto 0), "the counts as the RAM holds them");
        check_equal(v_record(159), '1', "a first error is held");
        check_equal(v_record(137 downto 136), std_logic_vector'("10"), "an uncorrectable word, found by an access");
        check_equal(v_record(127 downto 96), std_logic_vector'(x"20000008"), "its word");
        check_equal(v_record(15 downto 0), std_logic_vector'(x"0001"), "DBE_COUNT");
        check_equal(bus_valid, '0', "still shut");
        check_equal(actuator_safe, '1', "still safe");

        -- And once more, for the same record
        read_diag_port;
        check_equal(v_record(127 downto 96), std_logic_vector'(x"20000008"), "the same word again");
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
      elsif run("double_bit_error_on_a_load_answers_err_and_traps_without_writeback") then
        double_bit_error_on(c_load_addr, '0');
        check_access_fault(trap_laf_c);
        check_equal(nmi_fault, '1', "fault on the pin");
        check_equal(actuator_safe, '1', "actuators safe");
      elsif run("double_bit_error_on_a_byte_store_answers_err_and_leaves_the_word") then
        double_bit_error_on(c_store_addr, '1');
        check_access_fault(trap_saf_c);
        check_equal(actuator_safe, '1', "actuators safe");

        -- The program starts again, and its first store to the word reads it
        -- first: it still holds the word store, without the byte
        rst_n   <= '0';
        wait for c_clk_period * 5;
        rst_n   <= '1';
        v_found := false;

        loop_while_3 : while not v_found loop

          wait until rising_edge(clk);
          v_found := sys_bus.valid = '1' and sys_bus.we = '1' and sys_bus.addr = c_load_addr;

        end loop loop_while_3;

        wait for 1 ns;
        check_equal(ram_word(31 downto 0), std_logic_vector'(x"12345678"), "the byte never landed");
      elsif run("error_counts_outlast_a_watchdog_reset") then
        ram_word(0) <= force '1';

        if (uart_count < 3) then
          wait until uart_count >= 3 for c_timeout;
        end if;

        ram_word(0) <= release;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        v_sbe       := sbe_count;
        check(v_sbe > 3, "the accesses' errors and the patrol's counted");

        -- Move the watchdog to just short of its timeout
        wd_counter <= force to_unsigned(49990, 16);
        wait until rising_edge(wd_clk);
        wd_counter <= release;
        wait until soc_rst_n = '0' for c_timeout;
        check_equal(soc_rst_n, '0', "the watchdog reset the SoC");
        wait until soc_rst_n = '1' for c_timeout;
        check_equal(soc_rst_n, '1', "and let it restart");
        check_equal(sbe_count, v_sbe, "still the same count");
      end if;

    end loop loop_while_2;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
