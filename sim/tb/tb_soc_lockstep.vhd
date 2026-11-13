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

library work;
  use work.tb_pkg.all;
  use work.tb_random_pkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;

entity tb_soc_lockstep is
  generic (
    g_test : string := ""
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
  signal actuator_en   : std_logic;
  signal actuator_fb   : std_logic;
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

  signal cov_kind_gap    : t_cover_id;
  signal cov_kind_target : t_cover_id;

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

  test_runner_watchdog(20 ms);

  -- The actuator's driver reads the first channel back as it is, unless a test
  -- forces it
  actuator_fb <= actuator_safe;

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
      actuator_fb_i   => actuator_fb,
      diag_cs_n_i     => '1',
      diag_sck_i      => '0',
      diag_sdo_o      => open
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

        sample(cov_kind_gap, (v_kind, v_spacing));
        sample(cov_kind_target, (v_kind, v_target));
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

    alias core_a_in     is << signal i_soc.w_core_a_in : t_core_inputs >>;
    alias x_w_core_b_in is << signal i_soc.w_core_b_in : t_core_inputs >>;
    alias b_rst_n       is x_w_core_b_in.rst_n;
    alias b_rdata       is x_w_core_b_in.rdata;
    alias b_ack         is x_w_core_b_in.ack;
    alias b_err         is x_w_core_b_in.err;
    alias b_msi         is x_w_core_b_in.msi;
    alias b_mti         is x_w_core_b_in.mti;
    alias b_mei         is x_w_core_b_in.mei;

    variable v_one_ago : t_core_inputs;
    variable v_two_ago : t_core_inputs;

  begin

    wait until rising_edge(clk);
    check(b_rst_n = v_two_ago.rst_n, "core B's reset is core A's two clocks ago");
    check(b_rdata = v_two_ago.rdata, "core B's read data is core A's two clocks ago");
    check(b_ack = v_two_ago.ack, "core B's acknowledge is core A's two clocks ago");
    check(b_err = v_two_ago.err, "core B's bus error is core A's two clocks ago");
    check(b_msi = v_two_ago.msi, "core B's MSI is core A's two clocks ago");
    check(b_mti = v_two_ago.mti, "core B's MTI is core A's two clocks ago");
    check(b_mei = v_two_ago.mei, "core B's MEI is core A's two clocks ago");

    v_two_ago := v_one_ago;
    v_one_ago := core_a_in;

  end process p_input_skew;

  p_stim : process is

    alias x_w_mismatch_detected    is << signal i_soc.i_lockstep_gate.i_comparator_a.w_mismatch_detected : std_logic >>;
    alias x_w_rst_n                is << signal i_soc.w_rst_n : std_logic >>;
    alias x_w_mismatch_detected_2  is << signal i_soc.i_lockstep_gate.i_comparator_b.w_mismatch_detected : std_logic >>;
    alias x_r_current_state        is << signal i_soc.i_lockstep_gate.i_comparator_b.r_current_state : t_safe_state >>;
    alias x_w_self_test_failed     is << signal i_soc.w_self_test_failed : std_logic >>;
    alias x_w_comparators_disagree is << signal i_soc.w_comparators_disagree : std_logic >>;

    -- Comparator B's own reset and its own copies of the buses (DF-15)
    alias cold_a_rst_n   is << signal i_soc.w_cold_rst_n : std_logic >>;
    alias cold_b_rst_n   is << signal i_soc.w_cold_b_rst_n : std_logic >>;
    alias b_core_a_bus   is << signal i_soc.w_core_a_bus_late_b : t_rv_bus >>;
    alias b_core_b_bus   is << signal i_soc.w_core_b_compared_b : t_rv_bus >>;
    alias actuator_fault is << signal i_soc.w_actuator_fault : std_logic >>;

    alias core_a_data is << signal i_soc.w_core_a_xbus_data : std_logic_vector(31 downto 0) >>;
    alias core_b_data is << signal i_soc.w_core_b_xbus_data : std_logic_vector(31 downto 0) >>;
    alias core_a_bus  is << signal i_soc.w_core_a_bus : t_rv_bus >>;

    -- The bus response inside each core. A glitch further upstream would reach
    -- core B through its delay line and look the same to both, as any fault in
    -- data that they share does.
    alias core_a_rsp is << signal i_soc.i_cpu_master.i_neorv32.xbus_rsp : bus_rsp_t >>;
    alias core_b_rsp is << signal i_soc.i_cpu_checker.i_neorv32.xbus_rsp : bus_rsp_t >>;

    alias can_busy       is << signal i_soc.i_automotive_can.w_busy : std_logic >>;
    alias self_test_lane is << signal i_soc.i_comparator_self_test.r_lane : natural range 0 to 70 >>;
    alias ram_word       is << signal i_soc.i_ecc_ram.r_word : std_logic_vector(71 downto 0) >>;
    alias sys_bus        is << signal i_soc.w_safe_sys_bus : t_rv_bus >>;

    -- Each core's interrupt logic: MEI pending, MEI pending and enabled (MEIE),
    -- an interrupt being taken (which needs MIE), and trap entry with its cause
    alias a_irq_pnd  is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_pnd
      : std_ulogic_vector(irq_width_c - 1 downto 0) >>;
    alias a_irq_buf  is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_buf
      : std_ulogic_vector(irq_width_c - 1 downto 0) >>;
    alias a_irq_fire is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_fire
      : std_ulogic_vector(1 downto 0) >>;
    alias a_enter    is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.env_enter
      : std_ulogic >>;
    alias a_cause    is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.ecause
      : std_ulogic_vector(6 downto 0) >>;
    alias b_irq_pnd  is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_pnd
      : std_ulogic_vector(irq_width_c - 1 downto 0) >>;
    alias b_irq_buf  is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_buf
      : std_ulogic_vector(irq_width_c - 1 downto 0) >>;
    alias b_irq_fire is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.irq_fire
      : std_ulogic_vector(1 downto 0) >>;
    alias b_enter    is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.env_enter
      : std_ulogic >>;
    alias b_cause    is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).neorv32_cpu_inst.neorv32_cpu_control_inst.ecause
      : std_ulogic_vector(6 downto 0) >>;

    variable v_found : boolean;

    alias comparator_state is << signal i_soc.i_lockstep_gate.i_comparator_a.r_current_state : t_safe_state >>;
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

      loop_dummy : for lv_dummy in 1 to count loop

        wait until rising_edge(clk);

      end loop loop_dummy;

    end procedure wait_clocks;

    -- A mismatch on core B's write data for two clocks, as in the other tests

    procedure trip_lockstep is
    begin

      wait until rising_edge(clk);
      core_b_data <= force x"FFFFFFFF";
      wait_clocks(2);
      core_b_data <= release;

    end procedure trip_lockstep;

    procedure check_tripped (
      constant label_s : in string
    ) is
    begin

      wait_clocks(4);
      check_equal(nmi_fault, '1', "NMI from " & label_s);
      check_equal(actuator_safe, '1', "actuators safe from " & label_s);

    end procedure check_tripped;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      if run("core_b_is_core_a_two_clocks_ago_all_through_the_program") then
        cov_kind_gap    <= new_cover("load or store, by spacing");
        cov_kind_target <= new_cover("load or store, by target");
        wait for 0 ns;
        add_cross(cov_kind_gap, gen_bin(c_load, c_store), gen_bin(c_close, c_apart));
        add_cross(cov_kind_target, gen_bin(c_load, c_store), gen_bin(c_ram, c_peripheral));

        cold_reset;
        wait for c_boot;
        check_skew <= true;
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "CAN frame sent");
        wait for c_uart_bit_time * 30;
        check_equal(nmi_fault, '0', "no fault");
        check(is_covered(cov_kind_gap), "every kind of access at every spacing");
        check(is_covered(cov_kind_target), "every kind of access to every target");
      elsif run("same_glitch_on_both_core_buses_is_caught") then

        loop_length : for lv_length in 1 to 6 loop

          cold_reset;
          wait for c_boot;
          wait until rising_edge(clk);
          core_a_data <= force x"DEADBEEF";
          core_b_data <= force x"DEADBEEF";
          wait_clocks(lv_length);
          core_a_data <= release;
          core_b_data <= release;
          check_tripped("a glitch of " & integer'image(lv_length) & " clocks");

        end loop loop_length;

      elsif run("same_glitch_on_both_cores_read_data_is_caught") then

        loop_length_2 : for lv_length in 1 to 2 loop

          cold_reset;

          -- Core A polling for the UART: it answers "busy" until the byte is out
          wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_status_addr for c_timeout;
          wait until core_a_rsp.ack = '1' for c_timeout;
          wait for 1 ns;
          check_equal(std_logic_vector(core_a_rsp.data), std_logic_vector'(x"00000001"), "busy");

          -- This answers "not busy" to core A. Core B's answer is two clocks away.
          core_a_rsp.data <= force x"00000000";
          core_b_rsp.data <= force x"00000000";
          wait_clocks(lv_length);
          core_a_rsp.data <= release;
          core_b_rsp.data <= release;

          wait until actuator_safe = '1' for c_timeout;
          check_tripped("a glitch of " & integer'image(lv_length) & " clocks on the read data");

        end loop loop_length_2;

      elsif run("comparator_stuck_at_no_error_keeps_the_soc_safe") then
        x_w_mismatch_detected <= force '0';
        cold_reset;
        wait for c_boot;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(nmi_fault, '1', "reported on the pin");
        check_equal(x_w_rst_n, '0', "the cores never started");

        -- Well past the first bytes the program would send
        wait for c_uart_bit_time * 24;
        check_equal(uart_starts, 0, "nothing from the UART");
        check_equal(rx_done, 0, "nothing on the CAN bus");
        check_equal(actuator_safe, '1', "actuators still safe");
      elsif run("comparator_b_stuck_at_no_error_also_fails_the_self_test") then
        -- The self-test needs both comparators of the pair to trip
        x_w_mismatch_detected_2 <= force '0';
        cold_reset;
        wait for c_boot;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(nmi_fault, '1', "reported on the pin");
        check_equal(x_w_rst_n, '0', "the cores never started");
        wait for c_uart_bit_time * 24;
        check_equal(uart_starts, 0, "nothing from the UART");
        check_equal(rx_done, 0, "nothing on the CAN bus");
      elsif run("comparator_b_stuck_tripped_fails_the_self_test") then
        -- The pair disagrees from the start, which trips both comparators, so
        -- the self-test's check that a reset clears the trip fails
        x_r_current_state <= force st_fault_tripped;
        cold_reset;
        wait for c_boot;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(nmi_fault, '1', "reported on the pin");
        check_equal(x_w_self_test_failed, '1', "the self-test failed");
        check_equal(x_w_rst_n, '0', "the cores never started");
      elsif run("a_comparator_that_stops_comparing_after_startup_is_found_at_the_first_divergence") then
        -- Roadmap R2.4: with one comparator, this fault stayed hidden until the
        -- next cold reset. The pair finds it at the first store the cores
        -- disagree on, and nothing reaches a peripheral.
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        x_w_mismatch_detected_2 <= force '0';
        wait_clocks(2);
        core_b_data             <= force x"FFFFFFFF";
        wait_clocks(1);
        core_b_data             <= release;
        check_tripped("a divergence that only comparator A saw");
        check_equal(x_w_comparators_disagree, '1', "the disagreement is latched");
        wait for c_uart_bit_time * 2;
        check_equal(uart_starts, 0, "the byte never reached the UART");
      elsif run("a_reset_of_comparator_b_alone_is_found_and_held") then
        -- A glitch or a fault in comparator B's own reset synchroniser resets
        -- comparator B and nothing else. The pair disagrees, and the trip holds
        -- after comparator B is out of reset again.
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        cold_b_rst_n <= force '0';
        wait_clocks(1);
        cold_b_rst_n <= release;
        check_tripped("a reset of comparator B alone");
        check_equal(x_w_comparators_disagree, '1', "the disagreement is latched");
        wait_clocks(50);
        check_equal(nmi_fault, '1', "still reported 50 clocks later");
        check_equal(actuator_safe, '1', "still safe 50 clocks later");
      elsif run("a_fault_on_comparator_b_copy_of_core_a_bus_is_found") then
        -- Comparator B's own delay line delivers one address bit wrong for a
        -- clock; comparator A's copy is right
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        b_core_a_bus.addr(2) <= force not b_core_a_bus.addr(2);
        wait_clocks(1);
        b_core_a_bus.addr(2) <= release;
        check_tripped("a fault on comparator B's copy of core A's bus");
        check_equal(x_w_comparators_disagree, '1', "the disagreement is latched");
        wait for c_uart_bit_time * 2;
        check_equal(uart_starts, 0, "the byte never reached the UART");
      elsif run("a_fault_on_comparator_b_copy_of_core_b_bus_is_found") then
        -- Comparator B's own injection point for core B's bus delivers one data
        -- bit wrong for a clock
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        b_core_b_bus.data(0) <= force not b_core_b_bus.data(0);
        wait_clocks(1);
        b_core_b_bus.data(0) <= release;
        check_tripped("a fault on comparator B's copy of core B's bus");
        check_equal(x_w_comparators_disagree, '1', "the disagreement is latched");
      elsif run("comparator_b_reset_released_a_clock_late_still_starts_the_pair_together") then
        -- Two reset synchronisers can release a clock apart. The self-test holds
        -- both comparators in reset through its settle time, so they still
        -- leave it together, and the pair never disagrees.
        cold_b_rst_n <= force '0';
        cold_reset;
        wait until cold_a_rst_n = '1' for c_timeout;
        wait_clocks(1);
        cold_b_rst_n <= release;
        wait for c_boot;
        check_equal(x_w_comparators_disagree, '0', "the pair never disagreed");
        check_equal(self_test_passed, '1', "the self-test passed");
        check_equal(actuator_safe, '0', "the cores run");
        check_equal(nmi_fault, '0', "no fault");
      elsif run("an_actuator_line_stuck_at_permit_is_found_and_the_second_channel_cuts_power") then
        -- FMEDA FM-22: the first channel's line sticks at "permit" while the
        -- program runs. On the next demand the read-back finds it, and the
        -- second channel has already taken the actuator's power away.
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.addr = c_uart_tx_data_addr for c_timeout;
        check_equal(actuator_en, '1', "running: the second channel permits");
        check_equal(actuator_safe, '0', "running: the first channel permits");
        actuator_fb <= force '0';
        wait_clocks(50);
        check_equal(actuator_fault, '0', "latent while nothing is demanded");
        trip_lockstep;
        wait_clocks(1);
        check_equal(actuator_en, '0', "the second channel cuts power at the trip");
        wait_clocks(12);
        check_equal(actuator_fault, '1', "the read-back finds the stuck line");
        check_equal(nmi_fault, '1', "reported on the pin");
        actuator_fb <= release;
      elsif run("an_actuator_line_stuck_at_safe_is_found_when_the_cores_start") then
        -- The line reads safe whatever the command: an open driver input, or
        -- the board's pull-up with nothing wired
        actuator_fb <= force '1';
        cold_reset;
        wait for c_boot;
        check_equal(actuator_fault, '1', "found when the reset released the actuator");
        check_equal(actuator_safe, '1', "the first channel commands safe");
        check_equal(actuator_en, '0', "the second channel never permits");
        check_equal(nmi_fault, '1', "reported on the pin");
        actuator_fb <= release;
      elsif run("an_actuator_line_stuck_at_permit_is_found_before_the_cores_start") then
        -- The reset holds the command at safe, so the start checks the line
        actuator_fb <= force '0';
        cold_reset;
        wait for c_boot;
        check_equal(actuator_fault, '1', "found during the start");
        check_equal(actuator_safe, '1', "the first channel commands safe");
        check_equal(actuator_en, '0', "the second channel never permits");
        check_equal(nmi_fault, '1', "reported on the pin");
        actuator_fb <= release;
      elsif run("a_self_test_that_never_finishes_keeps_the_soc_safe_and_reports_it") then
        -- Roadmap R2.4: holding the lane at 0 makes the sequencer go round for ever
        self_test_lane <= force 0;
        cold_reset;
        wait for c_boot;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(nmi_fault, '1', "the failure is on the pin");
        check_equal(soc_rst_n, '0', "the cores never started");
        wait for c_uart_bit_time * 2;
        check_equal(uart_starts, 0, "nothing from the UART");
        check_equal(rx_done, 0, "nothing on the CAN bus");
        self_test_lane <= release;
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
      elsif run("lockstep_trip_in_a_uart_byte_goes_to_mark_and_drops_the_byte") then
        -- HSI section 8.3: mark from the edge that makes the actuators safe
        cold_reset;
        wait until uart_tx = '0' for c_timeout;
        check_equal(uart_tx, '0', "the first byte started");
        wait for c_uart_bit_time / 2;
        trip_lockstep;
        wait until actuator_safe = '1' for c_clk_period * 5;
        wait for 1 ns;
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(uart_tx, '1', "UART at mark with the actuators");
        check_equal(can_tx, '1', "CAN recessive with the actuators");
        check_equal(nmi_fault, '1', "fault on the pin");

        -- Long enough for the abandoned byte, and the next, to have come out
        wait until uart_tx = '0' for c_uart_bit_time * 24;
        check_equal(uart_tx, '1', "the UART stays at mark");
        check_equal(uart_starts, 1, "only the start bit before the trip");
      elsif run("lockstep_trip_with_mie_and_meie_masked_is_contained_without_an_interrupt") then
        -- HSI FLT-02. The program's RAM test runs before it sets MIE, and it never
        -- sets MEIE. This spoils its byte store to the RAM at the comparator.
        cold_reset;
        wait until core_a_bus.valid = '1' and core_a_bus.we = '1' and core_a_bus.addr = x"20000009" for c_timeout;
        check_equal(core_a_bus.sel, std_logic_vector'("0010"), "the byte store");
        wait_clocks(2);
        core_b_data <= force x"FFFFFFFF";
        wait_clocks(1);
        core_b_data <= release;
        check_equal(sys_bus.valid, '0', "the store did not reach the RAM");
        wait_clocks(1);
        wait for 1 ns;
        check_equal(nmi_fault, '1', "fault on the pin");
        check_equal(actuator_safe, '1', "actuators safe");
        check_equal(soc_bus_valid, '0', "bus closed");

        -- MEI is up at both cores two clocks apart, and neither takes it
        wait_clocks(2);

        loop_dummy_2 : for lv_dummy in 1 to 3000 loop

          wait until rising_edge(clk);
          check_equal(a_irq_pnd(irq_mei_irq_c), '1', "core A: MEI pending");
          check_equal(a_irq_buf(irq_mei_irq_c), '0', "core A: MEIE masked");
          check_equal(a_irq_fire, std_ulogic_vector'("00"), "core A: no interrupt taken");
          check_equal(b_irq_pnd(irq_mei_irq_c), '1', "core B: MEI pending");
          check_equal(b_irq_buf(irq_mei_irq_c), '0', "core B: MEIE masked");
          check_equal(b_irq_fire, std_ulogic_vector'("00"), "core B: no interrupt taken");

          if (a_enter = '1') then
            check(a_cause(6) = '0', "core A: only exceptions");
          end if;

          if (b_enter = '1') then
            check(b_cause(6) = '0', "core B: only exceptions");
          end if;

          check_equal(nmi_fault, '1', "fault still on the pin");
          check_equal(actuator_safe, '1', "actuators still safe");
          check_equal(sys_bus.valid, '0', "nothing reaches the system bus");

        end loop loop_dummy_2;

        -- After a cold reset, the first store to that word reads it first: the
        -- word store before the trip is there, and the byte is not
        cold_reset;
        v_found := false;

        loop_while_2 : while not v_found loop

          wait until rising_edge(clk);
          v_found := sys_bus.valid = '1' and sys_bus.we = '1' and sys_bus.addr = x"20000008";

        end loop loop_while_2;

        wait for 1 ns;
        check_equal(ram_word(31 downto 0), std_logic_vector'(x"12345678"), "the spoiled byte store never landed");
      elsif run("lockstep_trip_in_a_can_frame_goes_recessive_and_drops_the_frame") then
        cold_reset;
        wait until can_tx = '0' for c_timeout;
        check_equal(can_tx, '0', "the frame started");
        wait for c_can_bit_time * 10.5;
        trip_lockstep;
        wait until actuator_safe = '1' for c_clk_period * 5;
        wait for 1 ns;
        check_equal(can_tx, '1', "CAN recessive with the actuators");
        check_equal(uart_tx, '1', "UART at mark with the actuators");
        wait_clocks(1);
        check_equal(can_busy, '0', "the mailbox was cleared");

        -- Long enough for the frame to be sent again if it could be. The other
        -- node gives up on the cut-off frame at its stuff error.
        wait until can_tx = '0' for c_can_bit_time * 200;
        check_equal(can_tx, '1', "the CAN pin stays recessive");
        check_equal(rx_done, 1, "one frame seen on the bus");
        check(rx_frame.stuff_error, "and it was cut off");
      elsif run("illegal_comparator_state_is_reported_kept_by_a_watchdog_reset_and_cleared_cold") then
        -- HSI FLT-03 and FLT-04, for each one-bit corruption of 0x5A
        loop_bit_index : for lv_bit_index in 0 to 7 loop

          cold_reset;
          wait for c_boot;
          check_equal(nmi_fault, '0', "healthy before bit " & integer'image(lv_bit_index));
          wait until rising_edge(clk);
          comparator_state <= force st_system_ok xor std_logic_vector(shift_left(to_unsigned(1, 8), lv_bit_index));
          wait_clocks(1);
          comparator_state <= release;
          wait_clocks(2);
          check_equal(nmi_fault, '1', "bit " & integer'image(lv_bit_index) & ": reported on the pin");
          check_equal(actuator_safe, '1', "bit " & integer'image(lv_bit_index) & ": actuators safe");
          check_equal(soc_bus_valid, '0', "bit " & integer'image(lv_bit_index) & ": bus closed");

          -- A watchdog reset restarts the cores and keeps the fault
          wd_counter <= force to_unsigned(49990, 16);
          wait until rising_edge(wd_clk);
          wd_counter <= release;
          wait until soc_rst_n = '0' for c_timeout;
          check_equal(soc_rst_n, '0', "bit " & integer'image(lv_bit_index) & ": the watchdog reset the SoC");
          wait until soc_rst_n = '1' for c_timeout;
          wait_clocks(20);
          check_equal(nmi_fault, '1',
                      "bit " & integer'image(lv_bit_index) & ": still reported after a watchdog reset");
          check_equal(actuator_safe, '1',
                      "bit " & integer'image(lv_bit_index) & ": still safe after a watchdog reset");
          check_equal(soc_bus_valid, '0',
                      "bit " & integer'image(lv_bit_index) & ": still closed after a watchdog reset");

          -- A cold reset clears it, and the self-test qualifies the comparator again
          cold_reset;
          wait for c_boot;
          check_equal(comparator_state, st_system_ok,
                      "bit " & integer'image(lv_bit_index) & ": healthy after a cold reset");
          check_equal(nmi_fault, '0', "bit " & integer'image(lv_bit_index) & ": cleared by a cold reset");
          check_equal(actuator_safe, '0', "bit " & integer'image(lv_bit_index) & ": actuators released");
          check_equal(self_test_passed, '1', "bit " & integer'image(lv_bit_index) & ": the self-test passed again");

        end loop loop_bit_index;

      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
