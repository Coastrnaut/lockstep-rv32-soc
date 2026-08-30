-- ============================================================================
-- Design Name:  Reset De-assertion Timing Testbench
-- Description:  Synchronous and asynchronous reset release timing.
-- Traces to:    VERIFICATION_SPECIFICATION.md 3A
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_soc_reset_timing is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_reset_timing;

architecture tb of tb_soc_reset_timing is

  constant clk_period : time := 20 ns;
  signal   clk        : std_logic;
  signal   rst_n      : std_logic;

  signal core_a_bus : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal nmi_fault  : std_logic;
  signal safe_state : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;begin

  clk <= not clk after clk_period / 2;

  uut : entity lockstep.lockstep_comparator
    port map (
      clk_i        => clk,
      rst_n_syn_i  => rst_n,
      core_a_bus_i => core_a_bus,
      core_b_bus_i => core_b_bus,
      nmi_fault_o  => nmi_fault,
      safe_state_o => safe_state,
      bus_valid_o  => bus_valid,
      sys_bus_o    => sys_bus

    );p_test : process is
  begin

    test_runner_setup(runner, runner_cfg);

    -- TEST 1: Asynchronous reset release
    report "TEST: Async reset release";
    rst_n <= '0';
    wait for clk_period;
    rst_n <= '1';
    wait for clk_period / 2;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    check(safe_state = '0', "async reset: ok");
    check(nmi_fault = '0', "async reset: no NMI");

    -- TEST 2: Synchronous reset release
    report "TEST: Sync reset release";
    rst_n <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst_n <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    check(safe_state = '0', "sync reset: ok");

    -- TEST 3: Reset glitch (5 ns pulse)
    report "TEST: Reset glitch";
    rst_n <= '0';
    wait for 5 ns;
    rst_n <= '1';
    wait for clk_period * 3;
    check(safe_state = '0', "glitch: recovered");

    -- TEST 4: Multiple toggle during init
    report "TEST: Multiple reset toggles";
    rst_n <= '0';
    wait for clk_period;
    rst_n <= '1';
    wait for clk_period;
    rst_n <= '0';
    wait for clk_period;
    rst_n <= '1';
    wait for clk_period * 2;
    check(safe_state = '0', "multi-toggle: ok");

    -- TEST 5: Reset during active transaction
    report "TEST: Reset during transaction";
    core_a_bus       <= (addr => x"00001000", data => x"DEADBEEF", we => '1', valid => '1');
    core_b_bus       <= (addr => x"00001000", data => x"DEADBEEF", we => '1', valid => '1');
    wait until rising_edge(clk);
    rst_n            <= '0';
    wait for clk_period * 2;
    rst_n            <= '1';
    wait for clk_period * 3;
    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    check(safe_state = '0', "reset-during-tx: ok");

    -- TEST 6: Extended reset hold
    report "TEST: Extended reset hold";
    rst_n <= '0';
    wait for clk_period * 2;
    rst_n <= '1';
    wait for clk_period;
    check(safe_state = '0', "extended hold: ok");

    test_runner_cleanup(runner);

  end process p_test;

end architecture tb;
