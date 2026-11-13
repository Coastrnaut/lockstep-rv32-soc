-- ============================================================================
-- Testbench: Retirement Trace Comparison on the Running SoC (roadmap R2.2)
-- ============================================================================
-- Runs sim/scripts/soc_firmware.py with both cores' trace ports on, and
-- compares their retirements with trace_compare. The XBus comparator only
-- sees what reaches the bus, so a divergence in a register that no access
-- uses stays hidden from it. The trace comparison sees it at the instruction
-- that wrote the register.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;

library work;
  use work.can_test_pkg.all;

entity tb_soc_trace is
  generic (
    g_test : string := ""
  );
end entity tb_soc_trace;

architecture tb of tb_soc_trace is

  constant c_clk_period   : time := 20 ns;
  constant c_can_bit_time : time := c_clk_period * 100;
  constant c_timeout      : time := 3 ms;

  -- s5 (x21): the program clears it at start and reads it only on an access
  -- fault, so on a cold start no bus access ever depends on it
  constant c_s5 : std_ulogic_vector(4 downto 0) := "10101";

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal actuator_en   : std_logic;

  -- The CAN bus: the SoC and a receiver that acknowledges
  signal can_bus  : std_logic;
  signal ack_tx   : std_logic;
  signal rx_done  : natural;
  signal rx_frame : t_rx_frame;

  -- From trace_compare
  signal compared   : natural;
  signal mismatch   : std_logic;
  signal first      : natural;
  signal first_time : time;
  signal field      : string(1 to 9);

  -- Core A's first retirement that writes s5 once s5_watch is set: p_s5 records
  -- it on the clock edge, so the result does not depend on when p_stim resumes
  -- (xsim resumes it after a force a few delta cycles late)
  signal core_a_trace : trace_port_t;
  signal s5_watch     : std_logic;
  signal s5_seen      : std_logic;
  signal s5_order     : natural;
  signal s5_time      : time;

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

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2,
      g_trace_en  => true
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

  -- After i_soc, so that its trace signals exist when these names are resolved

  b_trace : block is

    alias trace_a is << signal ^.i_soc.w_core_a_trace : trace_port_t >>;
    alias trace_b is << signal ^.i_soc.w_core_b_trace : trace_port_t >>;

  begin

    i_compare : entity work.trace_compare
      port map (
        clk_i        => clk,
        trace_a_i    => trace_a,
        trace_b_i    => trace_b,
        compared_o   => compared,
        mismatch_o   => mismatch,
        first_o      => first,
        first_time_o => first_time,
        field_o      => field
      );

    -- Core A's trace for p_s5. xsim reads the 64-bit order field wrongly
    -- through an external name in a process (twice the value), but rightly
    -- through a port or an assignment like this one.
    core_a_trace <= trace_a;

  end block b_trace;

  p_stim : process is

    alias a_rd_we    is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.rf_we
      : std_ulogic >>;
    alias a_rd_addr  is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.addr
      : std_ulogic_vector(4 downto 0) >>;
    alias a_wdata    is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.rf_wdata
      : std_ulogic_vector(31 downto 0) >>;
    alias trace_a    is << signal i_soc.w_core_a_trace : trace_port_t >>;
    alias status_sys is << signal i_soc.i_watchdog_supervisor.r_status_sys : std_logic_vector(9 downto 0) >>;

    variable v_traps : natural;

    variable v_order : natural;
    variable v_time  : time;

  begin

    test_runner_setup(g_test);
    s5_watch <= '0';

    loop_while : while test_suite loop

      rst_n <= '0';
      wait for c_clk_period * 5;
      rst_n <= '1';

      if run("core_b_retires_exactly_what_core_a_retired_all_through_the_program") then
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "the program sent its CAN frame");
        wait for 100 us;
        check(compared > 1000, "more than 1000 retirements compared: " & integer'image(compared));
        check_equal(mismatch, '0', "no retirement differs");
        check_equal(nmi_fault, '0', "no fault");
        info("retirements compared: " & integer'image(compared));
      elsif run("access_faults_and_their_handler_retire_the_same_on_both_cores") then
        -- The firmware's bus probes (RESET_SRC forced to 3, as in tb_soc_fabric)
        -- take 11 access faults, so the trap fields are compared as well
        status_sys <= force "1100000000";
        wait for 20 us;
        status_sys <= release;
        v_traps    := 0;

        loop_dummy : for lv_dummy in 1 to 10000 loop

          wait until rising_edge(clk);

          if (trace_a.valid = '1' and trace_a.intr = '1') then
            v_traps := v_traps + 1;
          end if;

        end loop loop_dummy;

        check_equal(v_traps, 11, "11 trap handler entries on core A");
        check_equal(mismatch, '0', "no retirement differs, traps included");
        info("trap entries: " & integer'image(v_traps) & ", retirements compared: " & integer'image(compared));
      elsif run("a_register_only_divergence_is_caught_by_the_trace_and_not_by_the_bus") then
        -- Core A's write of 0 to s5 at the start of the program writes another
        -- value instead. Core B's does not.
        wait until a_rd_we = '1' and a_rd_addr = c_s5 for c_timeout;
        check_equal(a_rd_addr, c_s5, "core A writes s5");
        -- From here, p_s5 records the order number of that instruction, from
        -- core A's own trace
        s5_watch <= '1';
        a_wdata  <= force x"DEADBEEF";
        wait until rising_edge(clk);
        a_wdata  <= release;

        if (s5_seen /= '1') then
          wait until s5_seen = '1' for c_clk_period * 8;
        end if;

        check_equal(s5_seen, '1', "core A retired the corrupted write");
        v_order := s5_order;
        v_time  := s5_time;

        if (mismatch /= '1') then
          wait until mismatch = '1' for 1 us;
        end if;

        check_equal(mismatch, '1', "the trace comparison sees it");
        check_equal(first, v_order, "at that instruction");
        check_equal(field, string'("rd       "), "in the register write");
        check(first_time - v_time <= c_clk_period * 4,
              "within 4 clocks of core A retiring it: " & integer'image((first_time - v_time) / 1 ns) & " ns");
        info("divergence at order " & integer'image(v_order) & ", core A retired it at " &
             integer'image(v_time / 1 ns) & " ns, trace mismatch at " & integer'image(first_time / 1 ns) & " ns");

        -- The bus comparator never sees it: the program runs to the end
        wait until rx_done = 1 for c_timeout;
        check_equal(rx_done, 1, "the program sent its CAN frame");
        check_equal(rx_frame.crc, rx_frame.crc_expected, "a good frame");
        check_equal(nmi_fault, '0', "the bus comparator saw nothing");
        check_equal(actuator_safe, '0', "the actuators were never made safe");
        info("retirements compared by the end: " & integer'image(compared) & ", fault pin still " &
             std_logic'image(nmi_fault));
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

  p_s5 : process (clk) is
  begin

    if rising_edge(clk) then
      if (s5_watch /= '1') then
        s5_seen <= '0';
      elsif (s5_seen = '0' and core_a_trace.valid = '1' and core_a_trace.rd_addr = c_s5) then
        s5_seen  <= '1';
        s5_order <= to_integer(unsigned(core_a_trace.order(31 downto 0)));
        s5_time  <= now;
      end if;
    end if;

  end process p_s5;

end architecture tb;
