-- ============================================================================
-- Testbench: Fatal Fault Input to the Lockstep Comparator
-- ============================================================================
-- A fault that another block reports has to do everything a core mismatch does,
-- and it has to last just as long.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_lockstep_fatal_fault is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_fatal_fault;

architecture tb of tb_lockstep_fatal_fault is

  constant c_clk_period : time := 20 ns;

  constant c_store : t_rv_bus :=
  (
    addr  => x"20000000",
    data  => x"12345678",
    we    => '1',
    valid => '1',
    sel   => "1111"
  );

  signal clk         : std_logic;
  signal rst_n       : std_logic;
  signal core_bus    : t_rv_bus;
  signal fatal_fault : std_logic;
  signal nmi_fault   : std_logic;
  signal safe_state  : std_logic;
  signal bus_valid   : std_logic;
  signal sys_bus     : t_rv_bus;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  dut : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk,
      rst_n_syn_i   => rst_n,
      core_a_bus_i  => core_bus,
      core_b_bus_i  => core_bus,
      fatal_fault_i => fatal_fault,
      nmi_fault_o   => nmi_fault,
      safe_state_o  => safe_state,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus
    );

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      core_bus    <= c_store;
      fatal_fault <= '0';
      rst_n       <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n       <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check_equal(safe_state, '0', "clean to start with");
      check_equal(bus_valid, '1', "bus open to start with");
      check_equal(sys_bus.valid, '1', "the store passes");

      if run("fatal_fault_trips_at_once_and_stays_tripped") then
        fatal_fault <= '1';
        wait for 1 ns;
        check_equal(nmi_fault, '1', "NMI straight away");
        wait until rising_edge(clk);
        fatal_fault <= '0';
        wait until rising_edge(clk);
        check_equal(safe_state, '1', "actuators safe");
        check_equal(bus_valid, '0', "bus closed");
        check_equal(sys_bus.valid, '0', "the store is stopped");
        check_equal(nmi_fault, '1', "NMI held");

        for dummy in 1 to 10 loop

          wait until rising_edge(clk);

        end loop;

        check_equal(safe_state, '1', "one clock of fault is enough");
        check_equal(bus_valid, '0', "still closed");
        check_equal(nmi_fault, '1', "NMI still held");
      elsif run("only_a_reset_clears_it") then
        fatal_fault <= '1';
        wait until rising_edge(clk);
        fatal_fault <= '0';
        wait until rising_edge(clk);
        check_equal(safe_state, '1', "tripped");
        rst_n       <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst_n       <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(safe_state, '0', "reset");
        check_equal(bus_valid, '1', "bus open again");
        check_equal(nmi_fault, '0', "NMI gone");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
