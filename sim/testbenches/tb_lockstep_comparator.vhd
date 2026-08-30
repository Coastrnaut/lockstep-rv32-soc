-- ============================================================================
-- Testbench: Lockstep Comparator — Constrained-Random Coverage-Driven
-- ============================================================================
-- Uses OSVVM RandomPType and CoveragePkg for intelligent pseudo-random
-- stimulus generation with functional coverage tracking.
-- Loop runs until the 2x3 cross-matrix (bus operation x fault vector)
-- reaches 100% bin coverage.
--
-- Traces to:   TSR_LOCKSTEP_042, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

-- VUnit runner support

library vunit_lib;
  context vunit_lib.vunit_context;

-- Import OSVVM core packages

library osvvm;
  use osvvm.alertlogpkg.all;
  use osvvm.coveragepkg.all;
  use osvvm.randompkg.all;
  use osvvm.reportpkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_lockstep_comparator is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_comparator;

architecture behavior of tb_lockstep_comparator is

  -- Declare OSVVM Randomizer (protected type — must be shared variable)
  shared variable rv : randomptype;

  -- Local Clock & Timing Wires
  signal clk_s   : std_logic;
  signal rst_n_s : std_logic;

  -- Mock CPU Bus Signals matching lockstep.package_soc_types
  signal core_a_bus_s : t_rv_bus;
  signal core_b_bus_s : t_rv_bus;

  -- Outward-facing monitored safety outputs
  signal nmi_fault_s     : std_logic;
  signal actuator_safe_s : std_logic;
  signal bus_valid_s     : std_logic;

  constant clk_period : time := 20 ns; -- 50 MHz Automotive baseline

begin

  -- Clock Generation Thread
  clk_s <= not clk_s after clk_period / 2;

  -- Unit Under Test
  uut : entity lockstep.lockstep_comparator
    port map (
      clk_i        => clk_s,
      rst_n_syn_i  => rst_n_s,
      core_a_bus_i => core_a_bus_s,
      core_b_bus_i => core_b_bus_s,
      nmi_fault_o  => nmi_fault_s,
      safe_state_o => actuator_safe_s,
      bus_valid_o  => bus_valid_s,
      sys_bus_o    => open

    ); -- ========================================================================

  -- CONSTRAINED-RANDOM STIMULUS & COVERAGE TRACKING LOOP
  -- ========================================================================
  p_stimulus : process is

    -- Coverage ID (record type, not protected — must be local variable)
    variable covmatrix : coverageidtype;
    -- Local storage variables to hold loop-generated parameters
    variable v_rand_we    : integer;
    variable v_rand_fault : integer;
    variable v_rand_data  : std_logic_vector(31 downto 0);
    variable v_rand_addr  : std_logic_vector(31 downto 0);
    variable v_cov_point  : integer_vector(1 to 2);

  begin

    test_runner_setup(runner, runner_cfg);

    -- Initialize the OSVVM Alert/Log naming context
    SetAlertLogName("tb_lockstep_randomized");

    -- Initialize the Random Seed Generator engine
    RV.InitSeed(rv'instance_name);

    -- Create a unique coverage ID
    covmatrix := NewID("CovMatrix");

    -- ----------------------------------------------------------------
    -- Define the Coverage Bins (Functional Matrix Geometry)
    -- ----------------------------------------------------------------
    -- Axis 1: Bus Operation Mode (0 = Read, 1 = Write)
    -- Axis 2: Fault Injection Vector (0 = Safe, 1 = Address Mismatch, 2 = Data Mismatch)
    -- Resulting Cross-Matrix total size = 6 distinct bins
    AddCross(covmatrix, GenBin(0, 1), GenBin(0, 2));

    -- System Hard Reset sequence
    rst_n_s <= '0';
    wait for clk_period * 2;
    rst_n_s <= '1';
    wait until rising_edge(clk_s);

    report "Launching Intelligent Constrained-Random Simulation Framework...";

    -- ----------------------------------------------------------------
    -- COVERAGE-DRIVEN LOOP: Runs until all 6 cross-bins are satisfied
    -- ----------------------------------------------------------------
    while not IsCovered(covmatrix) loop

      wait until rising_edge(clk_s);

      -- If a previous fault locked down the ASIL core, issue a synchronous
      -- soft-reset to restore the state machine for the next randomized vector
      if (actuator_safe_s = '1') then
        rst_n_s <= '0';
        wait until rising_edge(clk_s);
        rst_n_s <= '1';
        wait until rising_edge(clk_s);
      end if;

      -- 1. Generate pseudo-random hardware components using RV
      v_rand_we    := RV.RandInt(0, 1);                                                                       -- Randomly chooses Read (0) or Write (1)
      v_rand_fault := RV.RandInt(0, 2);                                                                       -- Randomly chooses Fault Injection profiles
      v_rand_addr  := RV.RandSlv(32);                                                                         -- Random 32-bit hex address
      v_rand_data  := RV.RandSlv(32);                                                                         -- Random 32-bit payload

      -- 2. Build the structural core assignments based on the chosen random mode
      case v_rand_fault is

        when 0 =>                                                                                             -- SAFE OPERATION: Core A and Core B are perfectly matched

          core_a_bus_s <=
          (
            addr  => v_rand_addr,
            data  => v_rand_data,
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );
          core_b_bus_s <=
          (
            addr  => v_rand_addr,
            data  => v_rand_data,
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );

        when 1 =>                                                                                             -- ADDRESS MISMATCH: Corrupt Core B's address line

          core_a_bus_s <=
          (
            addr  => v_rand_addr,
            data  => v_rand_data,
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );
          -- Bitwise flip the lowest address byte on Core B to create divergence
          core_b_bus_s <=
          (
            addr  => v_rand_addr xor x"00000001",
            data  => v_rand_data,
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );

        when 2 =>                                                                                             -- DATA MISMATCH: Corrupt Core B's data payload

          core_a_bus_s <=
          (
            addr  => v_rand_addr,
            data  => v_rand_data,
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );
          -- Bitwise flip data payload on Core B
          core_b_bus_s <=
          (
            addr  => v_rand_addr,
            data  => v_rand_data xor x"00000001",
            we    => std_logic(to_unsigned(v_rand_we, 1)(0)),
            valid => '1'
          );

        when others =>

          null;

      end case;

      -- Allow comparison combinational network to resolve
      wait for clk_period * 0.5;

      -- 3. Sample the active coverage matrix state
      v_cov_point(1) := v_rand_we;
      v_cov_point(2) := v_rand_fault;
      ICover(covmatrix, v_cov_point);

      -- 4. Check real-time structural assertions if an anomaly was injected
      if (v_rand_fault /= 0) then
        wait for clk_period;
        AffirmIfEqual(nmi_fault_s, '1', "ASIL-D Failure: System failed to generate immediate NMI trap!");
        AffirmIfEqual(actuator_safe_s, '1', "ASIL-D Failure: System failed to lock down vehicle actuators!");
      end if;

    end loop;

    -- ----------------------------------------------------------------
    -- Post-Simulation Metrics Consolidation
    -- ----------------------------------------------------------------
    report "Coverage block satisfied!";
    WriteBin(covmatrix);                                                                                      -- Dump exact distribution frequencies to log

    EndOfTestReports;                                                                                         -- OSVVM test report finalization

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process p_stimulus;

end architecture behavior;
