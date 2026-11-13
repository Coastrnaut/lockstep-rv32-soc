-- ============================================================================
-- Testbench: Lockstep on the Running SoC
-- ============================================================================
-- Runs sim/scripts/soc_firmware.py with core B two clocks behind core A, and
-- hits both cores at the same instant. Two cores in step would do the same wrong
-- thing and agree about it. With the delay they cannot, and these tests would
-- fail without it.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library osvvm;
  use osvvm.coveragepkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;

entity tb_soc_lockstep is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_lockstep;

architecture tb of tb_soc_lockstep is

  constant c_clk_period    : time := 20 ns;
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;
  constant c_timeout       : time := 3 ms;

  -- More than a reset and the comparator self-test take
  constant c_boot : time := c_clk_period * 400;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal uart_starts   : natural;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus  : std_logic;
  signal ack_tx   : std_logic;
  signal rx_done  : natural;
  signal rx_frame : t_rx_frame;

  signal check_skew : boolean;

  -- Functional coverage of the bus traffic that the delay has to survive:
  -- whether each access is a load or a store, what it reaches, and how close it
  -- comes after the last one. A core stalls for each access, so the closest are
  -- the ones where it is straight back on the bus. Polling loops, which take a
  -- branch each time round, come in the middle.
  constant c_load       : natural := 0;
  constant c_store      : natural := 1;
  constant c_ram        : natural := 0;
  constant c_peripheral : natural := 1;
  constant c_close      : natural := 0;
  constant c_polling    : natural := 1;
  constant c_apart      : natural := 2;

  signal cov_kind_gap    : coverageidtype;
  signal cov_kind_target : coverageidtype;

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

  test_runner_watchdog(runner, 20 ms);

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

  p_uart_starts : process (uart_tx) is
  begin

    if falling_edge(uart_tx) then
      uart_starts <= uart_starts + 1;
    end if;

  end process p_uart_starts;

  -- Core B's bus has to be core A's from exactly two clocks before, on every
  -- clock, without leaning on the comparator to say so
  p_skew : process is

    alias core_a_bus is << signal i_soc.w_core_a_bus : t_rv_bus >>;
    alias core_b_bus is << signal i_soc.w_core_b_bus : t_rv_bus >>;

    variable v_one_ago : t_rv_bus;
    variable v_two_ago : t_rv_bus;
    variable v_gap     : natural;
    variable v_kind    : natural;
    variable v_target  : natural;
    variable v_spacing : natural;

  begin

    wait until rising_edge(clk);

    if (check_skew) then
      check(core_b_bus = v_two_ago, "core B is core A two clocks ago");

      if (core_a_bus.valid = '1') then
        v_kind    := c_load;
        v_target  := c_peripheral;
        v_spacing := c_apart;

        if (core_a_bus.we = '1') then
          v_kind := c_store;
        end if;

        if (core_a_bus.addr(31 downto 28) = c_ram_base_addr(31 downto 28)) then
          v_target := c_ram;
        end if;

        if (v_gap <= 8) then
          v_spacing := c_close;
        elsif (v_gap <= 17) then
          v_spacing := c_polling;
        end if;

        ICover(cov_kind_gap, (v_kind, v_spacing));
        ICover(cov_kind_target, (v_kind, v_target));
        v_gap := 0;
      else
        v_gap := v_gap + 1;
      end if;
    end if;

    v_two_ago := v_one_ago;
    v_one_ago := core_a_bus;

  end process p_skew;

  -- So does everything that reaches core B's pins, in every test. It is what
  -- keeps core B a copy, and the firmware alone would not notice a late MEI.
  p_input_skew : process is

    alias core_a_in is << signal i_soc.w_core_a_in : t_core_inputs >>;
    alias b_rst_n   is << signal i_soc.i_cpu_checker.rstn_i : std_ulogic >>;
    alias b_rdata   is << signal i_soc.i_cpu_checker.xbus_dat_i : std_ulogic_vector(31 downto 0) >>;
    alias b_ack     is << signal i_soc.i_cpu_checker.xbus_ack_i : std_ulogic >>;
    alias b_msi     is << signal i_soc.i_cpu_checker.irq_msi_i : std_ulogic >>;
    alias b_mti     is << signal i_soc.i_cpu_checker.irq_mti_i : std_ulogic >>;
    alias b_mei     is << signal i_soc.i_cpu_checker.irq_mei_i : std_ulogic >>;

    variable v_one_ago : t_core_inputs;
    variable v_two_ago : t_core_inputs;

  begin

    wait until rising_edge(clk);
    check(b_rst_n = v_two_ago.rst_n, "core B's reset is core A's two clocks ago");
    check(b_rdata = v_two_ago.rdata, "core B's read data is core A's two clocks ago");
    check(b_ack = v_two_ago.ack, "core B's acknowledge is core A's two clocks ago");
    check(b_msi = v_two_ago.msi, "core B's MSI is core A's two clocks ago");
    check(b_mti = v_two_ago.mti, "core B's MTI is core A's two clocks ago");
    check(b_mei = v_two_ago.mei, "core B's MEI is core A's two clocks ago");

    v_two_ago := v_one_ago;
    v_one_ago := core_a_in;

  end process p_input_skew;

  p_stim : process is

    alias core_a_data is << signal i_soc.w_core_a_xbus_data : std_logic_vector(31 downto 0) >>;
    alias core_b_data is << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >>;
    alias core_a_bus  is << signal i_soc.w_core_a_bus : t_rv_bus >>;

    -- The bus response inside each core. A glitch further upstream would reach
    -- core B through its delay line and look the same to both, as any fault in
    -- data that they share does.
    alias core_a_rsp is << signal i_soc.i_cpu_master.xbus_rsp : bus_rsp_t >>;
    alias core_b_rsp is << signal i_soc.i_cpu_checker.xbus_rsp : bus_rsp_t >>;

    alias comparator_state is << signal i_soc.i_lockstep_gate.r_current_state : t_safe_state >>;
    alias soc_bus_valid    is << signal i_soc.w_bus_valid : std_logic >>;
    alias soc_rst_n        is << signal i_soc.w_rst_n : std_logic >>;
    alias self_test_passed is << signal i_soc.w_self_test_passed : std_logic >>;
    alias wd_counter       is << signal i_soc.i_watchdog_supervisor.i_watchdog.r_counter : unsigned(15 downto 0) >>;

    procedure cold_reset is
    begin

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

    end procedure cold_reset;

    procedure wait_clocks (
      constant count : in natural
    ) is
    begin

      for dummy in 1 to count loop

        wait until rising_edge(clk);

      end loop;

    end procedure wait_clocks;

    procedure check_tripped (
      constant label_s : in string
    ) is
    begin

      wait_clocks(4);
      check_equal(nmi_fault, '1', "NMI from " & label_s);
      check_equal(actuator_safe, '1', "actuators safe from " & label_s);

    end procedure check_tripped;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("core_b_is_core_a_two_clocks_ago_all_through_the_program") then
        cov_kind_gap    <= NewID("load or store, by spacing");
        cov_kind_target <= NewID("load or store, by target");
        wait for 0 ns;
        AddCross(cov_kind_gap, GenBin(c_load, c_store), GenBin(c_close, c_apart));
        AddCross(cov_kind_target, GenBin(c_load, c_store), GenBin(c_ram, c_peripheral));

        cold_reset;
        wait for c_boot;
        check_skew <= true;
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "CAN frame sent");
        wait for c_uart_bit_time * 30;
        check_equal(nmi_fault, '0', "no fault");
        check(IsCovered(cov_kind_gap), "every kind of access at every spacing");
        check(IsCovered(cov_kind_target), "every kind of access to every target");
      elsif run("same_glitch_on_both_core_buses_is_caught") then

        for length in 1 to 6 loop

          cold_reset;
          wait for c_boot;
          wait until rising_edge(clk);
          core_a_data <= force x"DEADBEEF";
          core_b_data <= force x"DEADBEEF";
          wait_clocks(length);
          core_a_data <= release;
          core_b_data <= release;
          check_tripped("a glitch of " & integer'image(length) & " clocks");

        end loop;

      elsif run("same_glitch_on_both_cores_read_data_is_caught") then

        for length in 1 to 2 loop

          cold_reset;

          -- Core A polling for the UART: it answers "busy" until the byte is out
          wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_status_addr for c_timeout;
          wait until core_a_rsp.ack = '1' for c_timeout;
          wait for 1 ns;
          check_equal(std_logic_vector(core_a_rsp.data), std_logic_vector'(x"00000001"), "busy");

          -- This answers "not busy" to core A. Core B's answer is two clocks away.
          core_a_rsp.data <= force x"00000000";
          core_b_rsp.data <= force x"00000000";
          wait_clocks(length);
          core_a_rsp.data <= release;
          core_b_rsp.data <= release;

          wait until actuator_safe = '1' for c_timeout;
          check_tripped("a glitch of " & integer'image(length) & " clocks on the read data");

        end loop;

      elsif run("comparator_stuck_at_no_error_keeps_the_soc_safe") then
        << signal i_soc.i_lockstep_gate.w_mismatch_detected : std_logic >> <= force '0';
        cold_reset;
        wait for c_boot;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(nmi_fault, '1', "reported on the pin");
        check_equal(<< signal i_soc.w_rst_n : std_logic >>, '0', "the cores never started");

        -- Well past the first bytes the program would send
        wait for c_uart_bit_time * 24;
        check_equal(uart_starts, 0, "nothing from the UART");
        check_equal(rx_done, 0, "nothing on the CAN bus");
        check_equal(actuator_safe, '1', "actuators still safe");
      elsif run("store_the_cores_disagree_on_never_reaches_a_peripheral") then
        cold_reset;

        -- The first store: a byte for the UART. It reaches the comparator two
        -- clocks after core A makes it, and this spoils core B's in that cycle.
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        check_equal(core_a_bus.we, '1', "a store");
        wait_clocks(2);
        core_b_data <= force x"FFFFFFFF";
        wait_clocks(1);
        core_b_data <= release;
        check_tripped("the store");

        wait for c_uart_bit_time * 2;
        check_equal(uart_starts, 0, "the byte never reached the UART");
      elsif run("illegal_comparator_state_is_reported_kept_by_a_watchdog_reset_and_cleared_cold") then
        -- HSI FLT-03 and FLT-04, for each one-bit corruption of 0x5A
        for bit_index in 0 to 7 loop

          cold_reset;
          wait for c_boot;
          check_equal(nmi_fault, '0', "healthy before bit " & integer'image(bit_index));
          wait until rising_edge(clk);
          comparator_state <= force st_system_ok xor std_logic_vector(shift_left(to_unsigned(1, 8), bit_index));
          wait_clocks(1);
          comparator_state <= release;
          wait_clocks(2);
          check_equal(nmi_fault, '1', "bit " & integer'image(bit_index) & ": reported on the pin");
          check_equal(actuator_safe, '1', "bit " & integer'image(bit_index) & ": actuators safe");
          check_equal(soc_bus_valid, '0', "bit " & integer'image(bit_index) & ": bus closed");

          -- A watchdog reset restarts the cores and keeps the fault
          wd_counter <= force to_unsigned(49990, 16);
          wait until rising_edge(wd_clk);
          wd_counter <= release;
          wait until soc_rst_n = '0' for c_timeout;
          check_equal(soc_rst_n, '0', "bit " & integer'image(bit_index) & ": the watchdog reset the SoC");
          wait until soc_rst_n = '1' for c_timeout;
          wait_clocks(20);
          check_equal(nmi_fault, '1', "bit " & integer'image(bit_index) & ": still reported after a watchdog reset");
          check_equal(actuator_safe, '1', "bit " & integer'image(bit_index) & ": still safe after a watchdog reset");
          check_equal(soc_bus_valid, '0', "bit " & integer'image(bit_index) & ": still closed after a watchdog reset");

          -- A cold reset clears it, and the self-test qualifies the comparator again
          cold_reset;
          wait for c_boot;
          check_equal(comparator_state, st_system_ok, "bit " & integer'image(bit_index) & ": healthy after a cold reset");
          check_equal(nmi_fault, '0', "bit " & integer'image(bit_index) & ": cleared by a cold reset");
          check_equal(actuator_safe, '0', "bit " & integer'image(bit_index) & ": actuators released");
          check_equal(self_test_passed, '1', "bit " & integer'image(bit_index) & ": the self-test passed again");

        end loop;

      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
