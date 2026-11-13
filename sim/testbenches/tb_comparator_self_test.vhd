-- ============================================================================
-- Testbench: Comparator Startup Self-Test
-- ============================================================================
-- Wires the self-test to a real comparator, as the SoC does, and breaks the
-- comparator in the ways the verification specification worries about. Each
-- break has to stop the cores from starting, and a healthy comparator has to
-- come through with every line tried and nothing left disturbed.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_comparator_self_test is
  generic (
    runner_cfg : string := ""
  );
end entity tb_comparator_self_test;

architecture tb of tb_comparator_self_test is

  constant c_clk_period : time := 20 ns;

  -- Four clocks to settle, then four for each of 70 bus bits and the fatal input
  constant c_bus_bits    : natural := 70;
  constant c_test_clocks : natural := 4 + (c_bus_bits + 1) * 4;

  -- Both cores are in reset for the test, so their buses agree
  constant c_core_bus : t_rv_bus :=
  (
    addr  => x"00000000",
    data  => x"00000000",
    sel   => "0000",
    we    => '0',
    valid => '0'
  );

  signal clk   : std_logic;
  signal rst_n : std_logic;

  signal flip_bus      : t_rv_bus;
  signal test_fatal    : std_logic;
  signal test_rst_n    : std_logic;
  signal core_b_bus    : t_rv_bus;
  signal fatal_fault   : std_logic;
  signal compare_rst_n : std_logic;
  signal nmi_fault     : std_logic;
  signal fault         : std_logic;
  signal safe_state    : std_logic;
  signal bus_valid     : std_logic;
  signal sys_bus       : t_rv_bus;

  -- What the comparator tells the self-test, which a fault can get in the way of
  signal nmi_seen   : std_logic;
  signal fault_seen : std_logic;
  signal safe_seen  : std_logic;
  signal valid_seen : std_logic;
  signal passed     : std_logic;
  signal failed     : std_logic;

  -- Faults this bench can put between the two blocks
  signal blind_lanes  : std_logic_vector(c_bus_bits - 1 downto 0);
  signal blind_fatal  : std_logic;
  signal never_clears : std_logic;
  signal nmi_stuck    : std_logic;
  signal fault_stuck  : std_logic;
  signal safe_stuck   : std_logic;
  signal valid_stuck  : std_logic;
  signal nmi_late     : boolean;
  signal r_nmi_late   : std_logic;
  signal nmi_no_latch : boolean;

  -- What the test tried
  signal lanes_tried   : std_logic_vector(c_bus_bits downto 0);
  signal flips_at_once : natural;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 10 ms);

  -- As the SoC wires it, with a way to make one line or the fatal input useless
  core_b_bus.addr  <= c_core_bus.addr xor (flip_bus.addr and not blind_lanes(31 downto 0));
  core_b_bus.data  <= c_core_bus.data xor (flip_bus.data and not blind_lanes(63 downto 32));
  core_b_bus.sel   <= c_core_bus.sel xor (flip_bus.sel and not blind_lanes(67 downto 64));
  core_b_bus.we    <= c_core_bus.we xor (flip_bus.we and not blind_lanes(68));
  core_b_bus.valid <= c_core_bus.valid xor (flip_bus.valid and not blind_lanes(69));
  fatal_fault      <= test_fatal and not blind_fatal;
  compare_rst_n    <= rst_n when (never_clears = '1') else
                      test_rst_n;

  -- 'Z' means working, and anything else is the level an output has stuck at
  nmi_seen   <= nmi_stuck when (nmi_stuck /= 'Z') else
                nmi_fault and r_nmi_late when (nmi_late) else
                nmi_fault and (test_fatal or flip_bus.valid or flip_bus.we or (or flip_bus.sel) or
                                (or flip_bus.data) or (or flip_bus.addr)) when (nmi_no_latch) else
                nmi_fault;
  fault_seen <= fault when (fault_stuck = 'Z') else
                fault_stuck;
  safe_seen  <= safe_state when (safe_stuck = 'Z') else
                safe_stuck;
  valid_seen <= bus_valid when (valid_stuck = 'Z') else
                valid_stuck;

  i_comparator : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk,
      rst_n_syn_i   => compare_rst_n,
      core_a_bus_i  => c_core_bus,
      core_b_bus_i  => core_b_bus,
      fatal_fault_i => fatal_fault,
      nmi_fault_o   => nmi_fault,
      fault_o       => fault,
      safe_state_o  => safe_state,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus
    );

  i_dut : entity lockstep.comparator_self_test
    port map (
      clk_i         => clk,
      rst_n_i       => rst_n,
      flip_bus_o    => flip_bus,
      fatal_fault_o => test_fatal,
      rst_n_o       => test_rst_n,
      nmi_fault_i   => nmi_seen,
      fault_i       => fault_seen,
      safe_state_i  => safe_seen,
      bus_valid_i   => valid_seen,
      passed_o      => passed,
      failed_o      => failed
    );

  -- An NMI that rises a clock late, and falls on time
  p_nmi_late : process (clk) is
  begin

    if rising_edge(clk) then
      r_nmi_late <= nmi_fault;
    end if;

  end process p_nmi_late;

  p_lanes : process (clk) is

    variable v_flips : std_logic_vector(c_bus_bits downto 0);
    variable v_count : natural;

  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        lanes_tried   <= (others => '0');
        flips_at_once <= 0;
      else
        v_flips := test_fatal & flip_bus.valid & flip_bus.we & flip_bus.sel & flip_bus.data & flip_bus.addr;
        v_count := 0;

        loop_lane : for lv_lane in v_flips'range loop

          if (v_flips(lv_lane) = '1') then
            v_count := v_count + 1;
          end if;

        end loop loop_lane;

        lanes_tried <= lanes_tried or v_flips;

        if (v_count > flips_at_once) then
          flips_at_once <= v_count;
        end if;
      end if;
    end if;

  end process p_lanes;

  p_stim : process is

    alias comparator_mismatch is << signal i_comparator.w_mismatch_detected : std_logic >>;
    alias test_result         is << signal i_dut.r_result : t_safe_state >>;
    alias test_lane           is << signal i_dut.r_lane : natural range 0 to c_bus_bits >>;

    procedure cold_reset is
    begin

      rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n <= '1';

    end procedure cold_reset;

    -- Long enough for any test to end, however early it fails

    procedure wait_for_the_test is
    begin

      loop_dummy : for lv_dummy in 1 to c_test_clocks + 4 loop

        wait until rising_edge(clk);

      end loop loop_dummy;

    end procedure wait_for_the_test;

    procedure check_cores_kept_in_reset (
      constant label_s : in string
    ) is
    begin

      wait_for_the_test;
      check_equal(passed, '0', "no pass: " & label_s);
      check_equal(failed, '1', "reported: " & label_s);

    end procedure check_cores_kept_in_reset;

  begin

    test_runner_setup(runner, runner_cfg);

    loop_while : while test_suite loop

      blind_lanes  <= (others => '0');
      blind_fatal  <= '0';
      never_clears <= '0';
      nmi_stuck    <= 'Z';
      fault_stuck  <= 'Z';
      safe_stuck   <= 'Z';
      valid_stuck  <= 'Z';
      nmi_late     <= false;
      nmi_no_latch <= false;

      if run("healthy_comparator_passes_with_every_line_tried") then
        cold_reset;
        wait until rising_edge(clk);
        check_equal(passed, '0', "no pass before the test");

        loop_dummy_2 : for lv_dummy in 1 to c_test_clocks - 2 loop

          wait until rising_edge(clk);
          check_equal(passed, '0', "no pass until the end");
          check_equal(failed, '0', "no failure");

        end loop loop_dummy_2;

        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(passed, '1', "passed on time");
        check_equal(failed, '0', "no failure");
        check_equal(lanes_tried, std_logic_vector'((c_bus_bits downto 0 => '1')), "every line");
        check_equal(flips_at_once, 1, "one at a time");
      elsif run("comparator_is_left_clean_and_alone") then
        cold_reset;
        wait_for_the_test;
        check_equal(passed, '1', "passed");
        check_equal(nmi_fault, '0', "no NMI");
        check_equal(safe_state, '0', "not tripped");
        check_equal(bus_valid, '1', "bus open");

        loop_dummy_3 : for lv_dummy in 1 to 20 loop

          wait until rising_edge(clk);
          check_equal(test_rst_n, '1', "comparator no longer reset");
          check_equal(test_fatal, '0', "nothing injected");
          check_equal(flip_bus.valid, '0', "nothing injected");

        end loop loop_dummy_3;

      elsif run("stuck_at_no_error_stops_the_cores") then
        comparator_mismatch <= force '0';
        cold_reset;
        check_cores_kept_in_reset("mismatch stuck at no error");
      elsif run("stuck_at_error_stops_the_cores") then
        comparator_mismatch <= force '1';
        cold_reset;
        check_cores_kept_in_reset("mismatch stuck at error");
      elsif run("every_blind_bus_line_stops_the_cores") then

        loop_lane_2 : for lv_lane in 0 to c_bus_bits - 1 loop

          blind_lanes          <= (others => '0');
          blind_lanes(lv_lane) <= '1';
          cold_reset;
          check_cores_kept_in_reset("line " & integer'image(lv_lane));

        end loop loop_lane_2;

      elsif run("a_blind_fatal_input_stops_the_cores") then
        blind_fatal <= '1';
        cold_reset;
        check_cores_kept_in_reset("fatal input");
      elsif run("a_trip_that_will_not_clear_stops_the_cores") then
        never_clears <= '1';
        cold_reset;
        check_cores_kept_in_reset("no reset");
      elsif run("each_output_stuck_stops_the_cores") then
        nmi_stuck <= '0';
        cold_reset;
        check_cores_kept_in_reset("NMI stuck low");
        nmi_stuck <= '1';
        cold_reset;
        check_cores_kept_in_reset("NMI stuck high");
        nmi_stuck <= 'Z';

        safe_stuck <= '0';
        cold_reset;
        check_cores_kept_in_reset("safe state stuck low");
        safe_stuck <= '1';
        cold_reset;
        check_cores_kept_in_reset("safe state stuck high");
        safe_stuck <= 'Z';

        valid_stuck <= '1';
        cold_reset;
        check_cores_kept_in_reset("bus valid stuck high");
        valid_stuck <= '0';
        cold_reset;
        check_cores_kept_in_reset("bus valid stuck low");
      elsif run("a_registered_fault_stuck_either_way_stops_the_cores") then
        -- Roadmap R2.4: a fault in the reporting path, the registered output
        -- that drives the pin and MEI, is caught as well as one in the compare
        fault_stuck <= '0';
        cold_reset;
        check_cores_kept_in_reset("registered fault stuck low");
        fault_stuck <= '1';
        cold_reset;
        check_cores_kept_in_reset("registered fault stuck high");
      elsif run("an_nmi_that_comes_late_stops_the_cores") then
        nmi_late <= true;
        cold_reset;
        check_cores_kept_in_reset("the NMI has to follow the compare at once");
      elsif run("an_nmi_that_does_not_hold_stops_the_cores") then
        nmi_no_latch <= true;
        cold_reset;
        check_cores_kept_in_reset("the NMI has to stay once the cause has gone");
      elsif run("upset_in_the_result_stops_the_cores_even_later") then
        cold_reset;
        wait_for_the_test;
        check_equal(passed, '1', "passed");

        loop_index : for lv_index in t_safe_state'range loop

          test_result <= force st_system_ok xor std_logic_vector(shift_left(to_unsigned(1, 8), lv_index));
          wait until rising_edge(clk);
          wait for 1 ns;
          check_equal(passed, '0', "one flipped bit is not a pass");
          check_equal(failed, '1', "and it is reported");
          test_result <= release;
          wait until rising_edge(clk);
          wait for 1 ns;

        end loop loop_index;

      elsif run("a_sequencer_that_never_finishes_reports_a_failure") then
        -- Roadmap R2.4: a sequencer stuck busy keeps the cores in reset, but
        -- must not stay silent. Holding the lane at 0 makes it go round for ever.
        test_lane <= force 0;
        cold_reset;
        wait_for_the_test;
        check_equal(passed, '0', "no pass while still going round");

        -- The self-test allows itself 8 clocks more than a healthy run takes
        loop_dummy_4 : for lv_dummy in 1 to 8 loop

          wait until rising_edge(clk);

        end loop loop_dummy_4;

        wait for 1 ns;
        check_equal(passed, '0', "no pass from a sequencer that never finished");
        check_equal(failed, '1', "and the failure is reported");
        check_equal(flip_bus.valid or test_fatal, '0', "and it stops disturbing the comparator");
        test_lane <= release;
      elsif run("a_cold_reset_runs_the_test_again") then
        cold_reset;
        wait_for_the_test;
        check_equal(passed, '1', "passed");
        cold_reset;
        wait until rising_edge(clk);
        check_equal(passed, '0', "the old pass has gone");
        wait_for_the_test;
        check_equal(passed, '1', "passed again");
      end if;

    end loop loop_while;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
