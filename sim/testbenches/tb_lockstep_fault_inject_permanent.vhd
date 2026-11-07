
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_lockstep_fault_inject_permanent is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_fault_inject_permanent;

architecture tb of tb_lockstep_fault_inject_permanent is

  constant clk_period : time := 20 ns;
  signal   clk        : std_logic;
  signal   rst_n      : std_logic;
  signal   core_a_bus : t_rv_bus;
  signal   core_b_bus : t_rv_bus;
  signal   nmi_fault  : std_logic;
  signal   safe_state : std_logic;
  signal   bus_valid  : std_logic;
  signal   sys_bus    : t_rv_bus;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after clk_period / 2;
    wait for clk_period;

  end process p_clk;

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

    -- Every fault starts from a clean reset. The comparator latches, so without
    -- that the first fault would pass all the checks after it.

    procedure inject (
      constant bus_a   : in t_rv_bus;
      constant bus_b   : in t_rv_bus;
      constant label_s : in string
    ) is
    begin

      core_a_bus <= bus_a;
      core_b_bus <= bus_a;
      rst_n      <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n      <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check(safe_state = '0', label_s & ": clean before the fault");
      check(nmi_fault = '0', label_s & ": no NMI before the fault");

      core_b_bus <= bus_b;
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check(safe_state = '1', label_s & ": fault tripped");
      check(nmi_fault = '1', label_s & ": NMI");

    end procedure inject;

  begin

    test_runner_setup(runner, runner_cfg);

    -- TEST 1: Stuck-at-0 on data bit 0 (core B only)
    inject((addr => x"00001000", data => x"00000001", we => '1', valid => '1', sel => "1111"),
           (addr => x"00001000", data => x"00000000", we => '1', valid => '1', sel => "1111"),
           "stuck-at-0 data(0)");

    -- TEST 2: Stuck-at-1 on data bit 31 (core B only)
    inject((addr => x"00002000", data => x"00000000", we => '1', valid => '1', sel => "1111"),
           (addr => x"00002000", data => x"80000000", we => '1', valid => '1', sel => "1111"),
           "stuck-at-1 data(31)");

    -- TEST 3: Stuck-at-0 on address bit 0
    inject((addr => x"00003001", data => x"AAAAAAAA", we => '1', valid => '1', sel => "1111"),
           (addr => x"00003000", data => x"AAAAAAAA", we => '1', valid => '1', sel => "1111"),
           "stuck-at-0 addr(0)");

    -- TEST 4: Stuck-at-0 on write enable
    inject((addr => x"00004000", data => x"11111111", we => '1', valid => '1', sel => "1111"),
           (addr => x"00004000", data => x"11111111", we => '0', valid => '1', sel => "1111"),
           "stuck-at-0 we");

    -- TEST 5: Permanent fault campaign (data bits 0-7)
    for bit_index in 0 to 7 loop

      inject((addr  => x"00005000", data => std_logic_vector(to_unsigned(2 ** bit_index, 32)), we => '1',
              valid => '1', sel => "1111"),
             (addr => x"00005000", data => x"00000000", we => '1', valid => '1', sel => "1111"),
             "campaign bit" & integer'image(bit_index));

    end loop;

    -- TEST 6: Verify recovery after reset
    core_a_bus <= (addr => x"00006000", data => x"00000042", we => '1', valid => '1', sel => "1111");
    core_b_bus <= (addr => x"00006000", data => x"00000042", we => '1', valid => '1', sel => "1111");
    rst_n      <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst_n      <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    check(safe_state = '0', "recovery: fault cleared");
    check(nmi_fault = '0', "recovery: no NMI");

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process p_test;

end architecture tb;
