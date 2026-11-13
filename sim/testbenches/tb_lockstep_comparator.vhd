-- ============================================================================
-- Testbench: Lockstep Comparator, constrained-random and coverage-driven
-- ============================================================================
-- OSVVM chooses the stimulus and tracks coverage; VUnit's checks decide the
-- verdict. (OSVVM's own AffirmIf checks log an alert that VUnit never sees, so
-- an earlier version of this bench passed with its expectations inverted.)
--
-- Each vector is a random request from core A, and core B's copy of it,
-- either identical or with one of the 70 compared bits flipped: address 0-31,
-- data 32-63, byte enables 64-67, write 68 and strobe 69. A flip goes to a
-- lane the coverage model has not yet seen (intelligent coverage), so every
-- lane is hit. The loop runs until every lane has been flipped and every
-- combination of read or write with a matched or mismatched copy has run.
--
-- Checked for every vector:
--   matched     in the same cycle, core A's request on the system bus, no fault;
--               after the edge, still healthy
--   mismatched  in the same cycle, the fault output high and a quiet system bus;
--               after the edge, the safe state latched and the bus closed; then
--               a cold reset, after which the comparator is healthy again
--
-- Traces to:   TSR_LOCKSTEP_001, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library osvvm;
  use osvvm.coveragepkg.all;
  use osvvm.randompkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_lockstep_comparator is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_comparator;

architecture behavior of tb_lockstep_comparator is

  -- The randomiser is a protected type, so a shared variable
  shared variable v_rv : randomptype;

  constant c_clk_period : time := 20 ns;

  -- The compared lanes
  constant c_lanes : positive := 70;

  constant c_quiet_bus : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  signal clk_s           : std_logic;
  signal rst_n_s         : std_logic;
  signal core_a_bus_s    : t_rv_bus;
  signal core_b_bus_s    : t_rv_bus;
  signal sys_bus_s       : t_rv_bus;
  signal nmi_fault_s     : std_logic;
  signal actuator_safe_s : std_logic;
  signal bus_valid_s     : std_logic;

  -- Core A's request with one compared lane flipped

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
    clk_s <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  i_uut : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk_s,
      rst_n_syn_i   => rst_n_s,
      core_a_bus_i  => core_a_bus_s,
      core_b_bus_i  => core_b_bus_s,
      fatal_fault_i => '0',
      nmi_fault_o   => nmi_fault_s,
      safe_state_o  => actuator_safe_s,
      bus_valid_o   => bus_valid_s,
      sys_bus_o     => sys_bus_s
    );

  p_stimulus : process is

    -- Coverage models: one bin per lane, and read or write by matched or not
    variable v_cov_lane : coverageidtype;
    variable v_cov_kind : coverageidtype;

    variable v_bus      : t_rv_bus;
    variable v_we       : natural range 0 to 1;
    variable v_mismatch : natural range 0 to 1;
    variable v_lane     : natural range 0 to c_lanes - 1;
    variable v_vectors  : natural;

    procedure cold_reset is
    begin

      rst_n_s <= '0';
      wait until rising_edge(clk_s);
      wait until rising_edge(clk_s);
      rst_n_s <= '1';
      wait until rising_edge(clk_s);

    end procedure cold_reset;

    procedure check_bus (
      constant actual   : in t_rv_bus;
      constant expected : in t_rv_bus;
      constant label_s  : in string
    ) is
    begin

      check_equal(actual.addr, expected.addr, label_s & ": address");
      check_equal(actual.data, expected.data, label_s & ": data");
      check_equal(actual.sel, expected.sel, label_s & ": byte enables");
      check_equal(actual.we, expected.we, label_s & ": write");
      check_equal(actual.valid, expected.valid, label_s & ": strobe");

    end procedure check_bus;

  begin

    test_runner_setup(runner, runner_cfg);

    -- The same seed every run, so a failure repeats
    v_rv.InitSeed(v_rv'instance_name);

    v_cov_lane := NewID("compared lane flipped");
    AddBins(v_cov_lane, GenBin(0, c_lanes - 1));
    v_cov_kind := NewID("write by mismatch");
    AddCross(v_cov_kind, GenBin(0, 1), GenBin(0, 1));

    core_a_bus_s <= c_quiet_bus;
    core_b_bus_s <= c_quiet_bus;
    cold_reset;
    v_vectors    := 0;

    loop_vector : while not (IsCovered(v_cov_lane) and IsCovered(v_cov_kind)) loop

      v_we       := v_rv.RandInt(0, 1);
      v_mismatch := v_rv.RandInt(0, 1);

      v_bus.addr  := v_rv.RandSlv(32);
      v_bus.data  := v_rv.RandSlv(32);
      v_bus.sel   := v_rv.RandSlv(4);
      v_bus.we    := '1' when v_we = 1 else '0';
      v_bus.valid := '1';

      core_a_bus_s <= v_bus;

      if (v_mismatch = 1) then
        -- A lane not flipped yet, while any is left
        v_lane       := GetRandPoint(v_cov_lane);
        core_b_bus_s <= flip_lane(v_bus, v_lane);
        ICover(v_cov_lane, v_lane);
      else
        core_b_bus_s <= v_bus;
      end if;

      ICover(v_cov_kind, (v_we, v_mismatch));
      v_vectors := v_vectors + 1;

      -- In the same cycle
      wait for 1 ns;

      if (v_mismatch = 1) then
        check_equal(nmi_fault_s, '1', "lane " & integer'image(v_lane) & ": fault in the same cycle");
        check_bus(sys_bus_s, c_quiet_bus, "lane " & integer'image(v_lane) & ": nothing on the system bus");
      else
        check_equal(nmi_fault_s, '0', "matched: no fault");
        check_bus(sys_bus_s, v_bus, "matched: core A's request on the system bus");
        check_equal(bus_valid_s, '1', "matched: bus open");
      end if;

      -- After the edge
      wait until rising_edge(clk_s);
      wait for 1 ns;

      if (v_mismatch = 1) then
        check_equal(actuator_safe_s, '1', "lane " & integer'image(v_lane) & ": safe state latched");
        check_equal(bus_valid_s, '0', "lane " & integer'image(v_lane) & ": bus closed");
        check_equal(nmi_fault_s, '1', "lane " & integer'image(v_lane) & ": fault held");

        -- Only a cold reset ends the fault (HSI FLT-04)
        core_b_bus_s <= v_bus;
        cold_reset;
        check_equal(actuator_safe_s, '0', "healthy after a cold reset");
        check_equal(bus_valid_s, '1', "open after a cold reset");
      else
        check_equal(actuator_safe_s, '0', "matched: still healthy");
      end if;

    end loop loop_vector;

    info("coverage closed after " & integer'image(v_vectors) & " vectors");
    WriteBin(v_cov_kind);

    test_runner_cleanup(runner);

  end process p_stimulus;

end architecture behavior;
