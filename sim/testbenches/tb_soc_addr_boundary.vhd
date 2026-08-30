
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_soc_addr_boundary is
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_addr_boundary;

architecture tb of tb_soc_addr_boundary is

  signal   clk        : std_logic;
  constant clk_per    : time := 10 ns;
  signal   rst_n      : std_logic;
  signal   core_a_bus : t_rv_bus;
  signal   core_b_bus : t_rv_bus;
  signal   safe_state : std_logic;
  signal   nmi_fault  : std_logic;
  signal   bus_valid  : std_logic;
  signal   sys_bus    : t_rv_bus;begin

  clk <= not clk after clk_per / 2;

  u_dut : entity lockstep.lockstep_comparator
    port map (
      clk_i        => clk,
      rst_n_syn_i  => rst_n,
      core_a_bus_i => core_a_bus,
      core_b_bus_i => core_b_bus,
      safe_state_o => safe_state,
      nmi_fault_o  => nmi_fault,
      bus_valid_o  => bus_valid,
      sys_bus_o    => sys_bus

    );test_proc : process is
  begin

    test_runner_setup(runner, runner_cfg);

    -- Idle, safe_state should be '0'
    core_a_bus.addr  <= (others => '0');
    core_a_bus.data  <= (others => '0');
    core_a_bus.we    <= '0';
    core_a_bus.valid <= '0';
    core_b_bus.addr  <= (others => '0');
    core_b_bus.data  <= (others => '0');
    core_b_bus.we    <= '0';
    core_b_bus.valid <= '0';
    wait for 20 ns;
    check(safe_state = '0', "Reset: safe_state=0");

    rst_n <= '1';
    wait for 20 ns;

    -- TEST 1: Min address match
    core_a_bus.addr  <= x"00000000";
    core_a_bus.data  <= x"11111111";
    core_a_bus.we    <= '1';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000000";
    core_b_bus.data  <= x"11111111";
    core_b_bus.we    <= '1';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '0', "TEST1: min addr match");
    check(bus_valid = '1', "TEST1: bus valid");

    -- TEST 2: Max address match
    core_a_bus.addr  <= x"FFFFFFFF";
    core_a_bus.data  <= x"22222222";
    core_a_bus.we    <= '0';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"FFFFFFFF";
    core_b_bus.data  <= x"22222222";
    core_b_bus.we    <= '0';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '0', "TEST2: max addr match");

    -- TEST 3: Address mismatch -> fault
    core_a_bus.addr  <= x"00000001";
    core_a_bus.data  <= x"33333333";
    core_a_bus.we    <= '1';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000002";
    core_b_bus.data  <= x"33333333";
    core_b_bus.we    <= '1';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '1', "TEST3: addr mismatch fault");
    check(nmi_fault = '1', "TEST3: NMI fires");

    -- TEST 4: Data mismatch -> fault
    core_a_bus.addr  <= x"00000010";
    core_a_bus.data  <= x"AAAAAAAA";
    core_a_bus.we    <= '0';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000010";
    core_b_bus.data  <= x"BBBBBBBB";
    core_b_bus.we    <= '0';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '1', "TEST4: data mismatch fault");

    -- TEST 5: Valid deasserted -> fault latched
    core_a_bus.addr  <= x"00000020";
    core_a_bus.data  <= x"CCCCCCCC";
    core_a_bus.we    <= '1';
    core_a_bus.valid <= '0';
    core_b_bus.addr  <= x"00000020";
    core_b_bus.data  <= x"DDDDDDDD";
    core_b_bus.we    <= '1';
    core_b_bus.valid <= '0';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '1', "TEST5: fault latched");

    -- TEST 6: Reset clears fault
    -- Match buses first so comparator sees no mismatch during reset
    core_a_bus.addr  <= x"00000050";
    core_a_bus.data  <= x"EEEEEEEE";
    core_a_bus.we    <= '1';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000050";
    core_b_bus.data  <= x"EEEEEEEE";
    core_b_bus.we    <= '1';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    rst_n            <= '0';
    wait for 10 ns;
    rst_n            <= '1';
    wait for 20 ns;
    check(safe_state = '0', "TEST6: reset clears fault");

    -- TEST 7: Zero data match
    core_a_bus.addr  <= x"00000030";
    core_a_bus.data  <= x"00000000";
    core_a_bus.we    <= '1';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000030";
    core_b_bus.data  <= x"00000000";
    core_b_bus.we    <= '1';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '0', "TEST7: zero data match");

    -- TEST 8: Max data match
    core_a_bus.addr  <= x"00000040";
    core_a_bus.data  <= x"FFFFFFFF";
    core_a_bus.we    <= '0';
    core_a_bus.valid <= '1';
    core_b_bus.addr  <= x"00000040";
    core_b_bus.data  <= x"FFFFFFFF";
    core_b_bus.we    <= '0';
    core_b_bus.valid <= '1';
    wait for clk_per;
    wait for clk_per;
    check(safe_state = '0', "TEST8: max data match");

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process test_proc;

end architecture tb;
