-- ============================================================================
-- Testbench: the redundant comparator pair, with one comparator broken
-- ============================================================================
-- Each test breaks one comparator with a VHDL-2008 force, as a fault that
-- appears after the startup self-test would: stuck at "no error", or stuck
-- tripped. The pair must still keep a divergence off the system bus, report
-- it at once, latch the disagreement, and hold it until a reset. (Forces need
-- GHDL: xsim cannot simulate them.)
--
-- Traces to:   TSR_LOCKSTEP_001, TSR_LOCKSTEP_044
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_dual_comparator_faults is
  generic (
    g_test : string := ""
  );
end entity tb_dual_comparator_faults;

architecture tb of tb_dual_comparator_faults is

  constant c_clk_period : time := 20 ns;

  constant c_quiet_bus : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  constant c_request : t_rv_bus :=
  (
    addr  => x"40000400",
    data  => x"00000055",
    we    => '1',
    valid => '1',
    sel   => "1111"
  );

  signal clk        : std_logic;
  signal rst_n      : std_logic;
  signal core_a_bus : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal nmi_fault  : std_logic;
  signal fault      : std_logic;
  signal safe_state : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;
  signal test_nmi   : std_logic;
  signal disagree   : std_logic;

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
      rst_n_syn_i       => rst_n,
      core_a_bus_i      => core_a_bus,
      core_b_bus_i      => core_b_bus,
      fatal_fault_i     => '0',
      nmi_fault_o       => nmi_fault,
      fault_o           => fault,
      safe_state_o      => safe_state,
      bus_valid_o       => bus_valid,
      sys_bus_o         => sys_bus,
      test_nmi_fault_o  => test_nmi,
      test_fault_o      => open,
      test_safe_state_o => open,
      test_bus_valid_o  => open,
      disagree_o        => disagree
    );

  p_stim : process is

    alias mismatch_a is << signal i_dut.i_comparator_a.w_mismatch_detected : std_logic >>;
    alias mismatch_b is << signal i_dut.i_comparator_b.w_mismatch_detected : std_logic >>;
    alias state_b    is << signal i_dut.i_comparator_b.r_current_state : t_safe_state >>;

    procedure reset is
    begin

      core_a_bus <= c_quiet_bus;
      core_b_bus <= c_quiet_bus;
      rst_n      <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n      <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure reset;

    -- A divergence: core B's copy of the request has one data bit flipped

    procedure diverge is
    begin

      core_a_bus      <= c_request;
      core_b_bus      <= c_request;
      core_b_bus.data <= c_request.data xor x"00000001";
      wait for 1 ns;

    end procedure diverge;

    procedure check_held_safe (
      constant label_s : in string
    ) is
    begin

      check_equal(nmi_fault, '1', label_s & ": fault");
      check_equal(fault, '1', label_s & ": registered fault");
      check_equal(safe_state, '1', label_s & ": safe state");
      check_equal(bus_valid, '0', label_s & ": bus closed");
      check_equal(sys_bus.valid, '0', label_s & ": nothing on the system bus");
      check_equal(disagree, '1', label_s & ": the disagreement is latched");

    end procedure check_held_safe;

    procedure wait_clocks (
      constant n : in positive
    ) is
    begin

      loop_clock : for lv_i in 1 to n loop

        wait until rising_edge(clk);

      end loop loop_clock;

      wait for 1 ns;

    end procedure wait_clocks;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      reset;

      if run("comparator_b_stuck_at_no_error_is_found_at_the_first_divergence") then
        mismatch_b <= force '0';
        diverge;
        -- Comparator A trips; B passes the request. They differ, so nothing goes
        -- out, and the fault is up in the same cycle.
        check_equal(sys_bus.valid, '0', "the divergent store does not leave");
        check_equal(nmi_fault, '1', "fault in the same cycle");
        check_equal(test_nmi, '0', "only one comparator tripped on the compare");
        wait_clocks(1);
        core_b_bus <= c_request;
        check_held_safe("the clock after");
        wait_clocks(20);
        check_held_safe("20 clocks later");
        mismatch_b <= release;
      elsif run("comparator_a_stuck_at_no_error_cannot_open_the_bus") then
        -- A's view is the one the system bus carries, so this is the case that
        -- would let the divergent request out if B did not stop it
        mismatch_a <= force '0';
        diverge;
        check_equal(sys_bus.valid, '0', "the divergent store does not leave");
        check_equal(nmi_fault, '1', "fault in the same cycle");
        wait_clocks(1);
        core_b_bus <= c_request;
        check_held_safe("the clock after");
        mismatch_a <= release;
      elsif run("a_comparator_stuck_tripped_is_found_with_no_divergence") then
        core_a_bus <= c_request;
        core_b_bus <= c_request;
        wait_clocks(2);
        check_equal(sys_bus.valid, '1', "matched requests pass first");
        state_b    <= force st_fault_tripped;
        wait for 1 ns;
        check_equal(sys_bus.valid, '0', "nothing out once the comparators disagree");
        check_equal(nmi_fault, '1', "fault in the same cycle");
        check_equal(bus_valid, '0', "the gate closes in the same cycle");
        wait_clocks(1);
        state_b    <= release;
        wait_clocks(1);
        check_held_safe("after the upset");
        -- The disagreement trips comparator A too, so the self-test, which needs
        -- both, sees a trip that a reset must clear
        check_equal(test_nmi, '1', "both comparators tripped");
      elsif run("a_trip_only_comparator_b_sees_on_an_idle_cycle_is_reported_at_once") then
        -- Comparator A is blind, and passes core A's idle bus, which matches
        -- comparator B's closed one: only B's own fault output shows the trip
        mismatch_a      <= force '0';
        core_a_bus      <= c_quiet_bus;
        core_b_bus      <= c_quiet_bus;
        core_b_bus.addr <= x"00000001";
        wait for 1 ns;
        check_equal(nmi_fault, '1', "fault in the same cycle");
        wait_clocks(1);
        core_b_bus      <= c_quiet_bus;
        -- B's state now differs from A's: safe at once, latched at the next edge
        check_equal(nmi_fault, '1', "the clock after: fault");
        check_equal(safe_state, '1', "the clock after: safe state");
        check_equal(bus_valid, '0', "the clock after: bus closed");
        wait_clocks(1);
        check_held_safe("two clocks after");
        mismatch_a <= release;
      elsif run("only_a_reset_clears_a_disagreement") then
        mismatch_b <= force '0';
        diverge;
        wait_clocks(1);
        mismatch_b <= release;
        core_b_bus <= c_request;
        wait_clocks(50);
        check_held_safe("50 clocks later, comparator B healthy again");
        reset;
        check_equal(disagree, '0', "a reset clears it");
        check_equal(bus_valid, '1', "and opens the bus");
        check_equal(nmi_fault, '0', "with no fault");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
