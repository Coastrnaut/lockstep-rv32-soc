-- ============================================================================
-- Testbench: the redundant comparator pair, healthy
-- ============================================================================
-- Both comparators work. A matched request passes unchanged; a mismatch in any
-- of the 70 compared bits trips both comparators in the same cycle, so the
-- pair agrees and reports the trip on both of its views; the fatal input
-- trips both; only a reset clears them. No fault is injected, so this bench
-- runs on GHDL and xsim. tb_dual_comparator_faults breaks one comparator.
--
-- Traces to:   TSR_LOCKSTEP_001, TSR_LOCKSTEP_044
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;
  use work.tb_random_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_dual_comparator is
  generic (
    g_test : string := ""
  );
end entity tb_dual_comparator;

architecture tb of tb_dual_comparator is

  constant c_clk_period : time     := 20 ns;
  constant c_lanes      : positive := 70;

  constant c_quiet_bus : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  signal clk        : std_logic;
  signal rst_n      : std_logic;
  signal core_a_bus : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal fatal      : std_logic;
  signal nmi_fault  : std_logic;
  signal fault      : std_logic;
  signal safe_state : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;
  signal test_nmi   : std_logic;
  signal test_fault : std_logic;
  signal test_safe  : std_logic;
  signal test_valid : std_logic;
  signal disagree   : std_logic;

  function flip_lane (
    bus_in : t_rv_bus;
    lane   : natural
  ) return t_rv_bus is

    variable v_bus : t_rv_bus;

  begin

    v_bus := bus_in;

    if (lane < 32) then
      v_bus.addr(lane) := not v_bus.addr(lane);
    elsif (lane < 64) then
      v_bus.data(lane - 32) := not v_bus.data(lane - 32);
    elsif (lane < 68) then
      v_bus.sel(lane - 64) := not v_bus.sel(lane - 64);
    elsif (lane = 68) then
      v_bus.we := not v_bus.we;
    else
      v_bus.valid := not v_bus.valid;
    end if;

    return v_bus;

  end function flip_lane;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(1 ms);

  i_dut : entity lockstep.dual_comparator
    port map (
      clk_i             => clk,
      rst_a_n_i         => rst_n,
      rst_b_n_i         => rst_n,
      a_core_a_bus_i    => core_a_bus,
      a_core_b_bus_i    => core_b_bus,
      b_core_a_bus_i    => core_a_bus,
      b_core_b_bus_i    => core_b_bus,
      fatal_fault_i     => fatal,
      nmi_fault_o       => nmi_fault,
      fault_o           => fault,
      safe_state_o      => safe_state,
      bus_valid_o       => bus_valid,
      sys_bus_o         => sys_bus,
      test_nmi_fault_o  => test_nmi,
      test_fault_o      => test_fault,
      test_safe_state_o => test_safe,
      test_bus_valid_o  => test_valid,
      disagree_o        => disagree
    );

  p_stim : process is

    variable v_rand : t_random;
    variable v_bus  : t_rv_bus;

    procedure reset is
    begin

      core_a_bus <= c_quiet_bus;
      core_b_bus <= c_quiet_bus;
      fatal      <= '0';
      rst_n      <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n      <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure reset;

    procedure check_healthy (
      constant label_s : in string
    ) is
    begin

      check_equal(nmi_fault, '0', label_s & ": no fault");
      check_equal(fault, '0', label_s & ": no registered fault");
      check_equal(safe_state, '0', label_s & ": not safe");
      check_equal(bus_valid, '1', label_s & ": bus open");
      check_equal(disagree, '0', label_s & ": the comparators agree");
      check_equal(test_nmi, '0', label_s & ": the self-test sees no trip");
      check_equal(test_valid, '1', label_s & ": the self-test sees the bus open");

    end procedure check_healthy;

    procedure check_tripped (
      constant label_s : in string
    ) is
    begin

      check_equal(nmi_fault, '1', label_s & ": fault");
      check_equal(fault, '1', label_s & ": registered fault");
      check_equal(safe_state, '1', label_s & ": safe state");
      check_equal(bus_valid, '0', label_s & ": bus closed");
      check_equal(sys_bus.valid, '0', label_s & ": nothing on the system bus");
      check_equal(test_nmi, '1', label_s & ": both comparators tripped");
      check_equal(test_fault, '1', label_s & ": both comparators' registered faults");
      check_equal(test_safe, '1', label_s & ": both comparators safe");
      check_equal(test_valid, '0', label_s & ": both comparators closed the bus");
      check_equal(disagree, '0', label_s & ": the comparators agree");

    end procedure check_tripped;

  begin

    test_runner_setup(g_test);
    v_rand.init_seed("tb_dual_comparator");

    loop_while : while test_suite loop

      reset;

      if run("matched_requests_pass_unchanged") then

        loop_request : for lv_n in 1 to 200 loop

          v_bus.addr  := v_rand.rand_slv(32);
          v_bus.data  := v_rand.rand_slv(32);
          v_bus.sel   := v_rand.rand_slv(4);
          v_bus.we    := v_rand.rand_slv(1)(0);
          v_bus.valid := '1';
          core_a_bus  <= v_bus;
          core_b_bus  <= v_bus;
          wait for 1 ns;
          check_equal(sys_bus.addr, v_bus.addr, "request " & integer'image(lv_n) & ": address");
          check_equal(sys_bus.data, v_bus.data, "request " & integer'image(lv_n) & ": data");
          check_equal(sys_bus.sel, v_bus.sel, "request " & integer'image(lv_n) & ": byte enables");
          check_equal(sys_bus.we, v_bus.we, "request " & integer'image(lv_n) & ": write");
          check_equal(sys_bus.valid, '1', "request " & integer'image(lv_n) & ": strobe");
          wait until rising_edge(clk);
          wait for 1 ns;
          check_healthy("request " & integer'image(lv_n));

        end loop loop_request;

        info("200 matched requests passed");
      elsif run("a_mismatch_in_any_lane_trips_both_comparators_together") then

        loop_lane : for lv_lane in 0 to c_lanes - 1 loop

          v_bus.addr  := v_rand.rand_slv(32);
          v_bus.data  := v_rand.rand_slv(32);
          v_bus.sel   := v_rand.rand_slv(4);
          v_bus.we    := v_rand.rand_slv(1)(0);
          v_bus.valid := '1';
          core_a_bus  <= v_bus;
          core_b_bus  <= flip_lane(v_bus, lv_lane);
          wait for 1 ns;
          check_equal(nmi_fault, '1', "lane " & integer'image(lv_lane) & ": fault in the same cycle");
          check_equal(test_nmi, '1', "lane " & integer'image(lv_lane) & ": both comparators in the same cycle");
          check_equal(sys_bus.valid, '0', "lane " & integer'image(lv_lane) & ": nothing on the system bus");
          wait until rising_edge(clk);
          core_b_bus  <= v_bus;
          wait for 1 ns;
          check_tripped("lane " & integer'image(lv_lane));
          reset;
          check_healthy("after the reset, lane " & integer'image(lv_lane));

        end loop loop_lane;

        info("all 70 lanes trip both comparators");
      elsif run("the_fatal_input_trips_both_and_the_trip_holds_until_reset") then
        fatal <= '1';
        wait for 1 ns;
        check_equal(test_nmi, '1', "both comparators in the same cycle");
        wait until rising_edge(clk);
        fatal <= '0';
        wait for 1 ns;
        check_tripped("fatal");

        loop_hold : for lv_n in 1 to 20 loop

          wait until rising_edge(clk);

        end loop loop_hold;

        wait for 1 ns;
        check_tripped("20 clocks later");
        reset;
        check_healthy("after the reset");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
