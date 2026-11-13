-- ============================================================================
-- Testbench: Bus Responses on the Running SoC
-- ============================================================================
-- HSI section 8.1 through real loads and stores. RESET_SRC is forced to read 3
-- once, which sends sim/scripts/soc_firmware.py to its bus probes: loads and
-- stores at the edges of the RAM and of each register block, unmapped aliases of
-- the UART and CAN registers, and stores that leave byte 0 or the whole word
-- out. The program counts the access faults that the ERRs cause, and reports
-- the count and whether the RAM read back right.
--
-- A monitor checks every clock that each request the comparator accepts gets
-- exactly one response at core A's pins, in the next cycle, and that nothing
-- else does.
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

entity tb_soc_fabric is
  generic (
    runner_cfg : string := "";
    -- The SoC's RAM profile (roadmap R4.3): 15 is the full 256 KB
    g_ram_addr_bits : positive range 4 to 15 := 15
  );
end entity tb_soc_fabric;

architecture tb of tb_soc_fabric is

  constant c_clk_period    : time := 20 ns;
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;
  constant c_timeout       : time := 2 ms;

  -- A smaller RAM profile ends below the program's last-word probes, so its
  -- store and load there answer ERR too, and the word does not read back
  constant c_small_ram : boolean := g_ram_addr_bits < 15;

  -- The unmapped loads and stores among the program's probes
  constant c_probe_errs : natural := 11 + 2 * boolean'pos(c_small_ram);

  type t_flag is array (boolean) of std_logic_vector(7 downto 0);

  -- 'P' when the RAM kept its data through the probes; 'F' when the last-word
  -- probe did not read back, as it cannot past a smaller RAM
  constant c_probe_flag : t_flag := (false => x"50", true => x"46");

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus   : std_logic;
  signal ack_tx    : std_logic;
  signal rx_done   : natural;
  signal rx_starts : natural;
  signal rx_frame  : t_rx_frame;

  -- What the receiver on uart_tx saw

  type t_byte_log is array (1 to 16) of std_logic_vector(7 downto 0);

  signal uart_count : natural;
  signal uart_log   : t_byte_log;

  -- From the monitor
  signal accepted : natural;
  signal acks     : natural;
  signal errs     : natural;

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
      g_boot_mode     => 2,
      g_ram_addr_bits => g_ram_addr_bits
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
      starts_o     => rx_starts,
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

  -- Each accepted request is answered at core A's pins in the next cycle with
  -- one of ACK and ERR, and nothing else is. Core A's pins see the response
  -- undelayed. Core B's are the same two clocks later, which tb_soc_lockstep
  -- checks for every input.
  p_monitor : process is

    alias sys_bus   is << signal i_soc.w_safe_sys_bus : t_rv_bus >>;
    alias soc_rst_n is << signal i_soc.w_rst_n : std_logic >>;
    alias a_ack     is << signal i_soc.i_cpu_master.xbus_ack_i : std_ulogic >>;
    alias a_err     is << signal i_soc.i_cpu_master.xbus_err_i : std_ulogic >>;
    alias ram_write is << signal i_soc.i_ecc_ram.r_write : std_logic >>;

    variable v_pending : boolean;

  begin

    wait until rising_edge(clk);

    -- The cores ignore their bus while in reset, so the check starts after it
    if (soc_rst_n = '0') then
      null;
    elsif (v_pending) then
      check((a_ack xor a_err) = '1', "exactly one of ACK and ERR for an accepted request");
    else
      check_equal(a_ack, '0', "no ACK without an accepted request");
      check_equal(a_err, '0', "no ERR without an accepted request");
    end if;

    if (a_ack = '1') then
      acks <= acks + 1;
    end if;

    if (a_err = '1') then
      errs <= errs + 1;
      -- The RAM decodes its own range, which must be the fabric's: a store the
      -- fabric refuses, past a smaller RAM's end, must not land in it either
      check_equal(ram_write, '0', "no RAM write for a request answered ERR");
    end if;

    v_pending := sys_bus.valid = '1' and soc_rst_n = '1';

    if (v_pending) then
      accepted <= accepted + 1;
    end if;

  end process p_monitor;

  p_stim : process is

    alias sys_bus    is << signal i_soc.w_safe_sys_bus : t_rv_bus >>;
    alias status_sys is << signal i_soc.i_watchdog_supervisor.r_status_sys : std_logic_vector(9 downto 0) >>;
    alias wd_reset   is << signal i_soc.w_wd_reset : std_logic >>;
    alias soc_rst_n  is << signal i_soc.w_rst_n : std_logic >>;
    alias ram_word   is << signal i_soc.i_ecc_ram.r_word : std_logic_vector(71 downto 0) >>;
    alias a_ack      is << signal i_soc.i_cpu_master.xbus_ack_i : std_ulogic >>;
    alias a_err      is << signal i_soc.i_cpu_master.xbus_err_i : std_ulogic >>;

    variable v_found : boolean;

    procedure wait_for_request (
      constant addr : in std_logic_vector(31 downto 0);
      constant we   : in std_logic
    ) is
    begin

      v_found := false;

      while not v_found loop

        wait until rising_edge(clk);
        v_found := sys_bus.valid = '1' and sys_bus.we = we and sys_bus.addr = addr;

      end loop;

    end procedure wait_for_request;

    procedure check_uart_byte (
      constant count    : in natural;
      constant expected : in std_logic_vector(7 downto 0)
    ) is
    begin

      if (uart_count < count) then
        wait until uart_count >= count for c_timeout;
      end if;

      check(uart_count >= count, "UART byte " & integer'image(count) & " arrived");
      check_equal(uart_log(count), expected, "UART byte " & integer'image(count));

    end procedure check_uart_byte;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

      if run("probes_get_one_response_each_and_unmapped_ones_change_nothing") then
        -- RESET_SRC reads 3 until the program has read it
        status_sys <= force "1100000000";
        wait_for_request(c_wd_reset_src_addr, '0');
        wait until rising_edge(clk);
        status_sys <= release;

        -- '3', then 'A' plus the count of access faults, then 'P' if the RAM
        -- held its data through the unmapped stores
        check_uart_byte(1, x"33");
        check_uart_byte(2, std_logic_vector(to_unsigned(character'pos('A') + c_probe_errs, 8)));
        check_uart_byte(3, c_probe_flag(c_small_ram));

        -- Long enough for a byte or a frame from an alias to have come out
        wait for c_uart_bit_time * 30;
        check_equal(uart_count, 3, "no byte from the aliased or lane-less stores");
        check_equal(rx_starts, 0, "no frame from the aliased or partial TX_REQUEST stores");
        check_equal(errs, c_probe_errs, "one ERR for each unmapped probe");
        check_equal(acks + errs, accepted, "one response for each accepted request");
        check_equal(nmi_fault, '0', "an unmapped address is not a fault");
        check_equal(actuator_safe, '0', "actuators free");
      elsif run("warm_reset_drops_a_store_caught_between_acceptance_and_commit") then
        -- The program's first store to the RAM, word 0x20000008. A watchdog reset
        -- arrives in its response cycle, before the edge that would write it.
        wait_for_request(x"20000008", '1');
        wd_reset <= force '1';
        wait for 1 ns;
        check_equal(soc_rst_n, '0', "warm reset");
        check_equal(a_ack, '0', "no ACK in the reset");
        check_equal(a_err, '0', "no ERR in the reset");
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wd_reset <= release;

        -- The program runs again from the start. Its store to the same word
        -- reads it first: still zero, so the dropped store never landed.
        wait_for_request(x"20000008", '1');
        wait for 1 ns;
        check_equal(ram_word(31 downto 0), std_logic_vector'(x"00000000"), "the store caught by the reset never landed");

        -- '0' from each start, then 'M': the program's RAM test passed
        check_uart_byte(2, x"30");
        check_uart_byte(3, x"4D");
        check_equal(nmi_fault, '0', "a warm reset is not a fault");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
