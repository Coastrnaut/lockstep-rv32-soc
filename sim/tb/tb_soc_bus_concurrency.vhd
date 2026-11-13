-- ============================================================================
-- Design Name:  Bus Transaction Concurrency Testbench
-- Description:  Back-to-back writes, R/W contention, max bus stall latency.
-- Traces to:    docs/verification/specification.md 3A
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_soc_bus_concurrency is
  generic (
    g_test : string := ""
  );
end entity tb_soc_bus_concurrency;

architecture tb of tb_soc_bus_concurrency is

  constant c_clk_period : time := 20 ns;

  signal clk   : std_logic;
  signal rst_n : std_logic;

  signal core_a_bus : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal nmi_fault  : std_logic;
  signal safe_state : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  i_uut : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk,
      rst_n_syn_i   => rst_n,
      core_a_bus_i  => core_a_bus,
      core_b_bus_i  => core_b_bus,
      fatal_fault_i => '0',
      nmi_fault_o   => nmi_fault,
      safe_state_o  => safe_state,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus

    );p_test : process is
  begin

    test_runner_setup(g_test);

    rst_n <= '0';
    wait for 100 ns;
    rst_n <= '1';
    wait for c_clk_period * 2;

    -- TEST 1: Back-to-back writes (10 cycles)
    report "TEST: Back-to-back writes";

    loop_dummy : for lv_dummy in 0 to 9 loop

      core_a_bus <=
      (
        addr  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy * 17, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      core_b_bus <=
      (
        addr  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy * 17, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      check(safe_state = '0', "back-to-back #" & integer'image(lv_dummy) & ": ok");
      check(bus_valid = '1', "back-to-back #" & integer'image(lv_dummy) & ": valid");

    end loop loop_dummy;

    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    wait for c_clk_period;

    -- TEST 2: Alternating R/W
    report "TEST: Alternating R/W";

    loop_dummy_2 : for lv_dummy in 0 to 9 loop

      core_a_bus <=
      (
        addr  => x"00001000",
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      core_b_bus <=
      (
        addr  => x"00001000",
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      check(safe_state = '0', "alt R/W #" & integer'image(lv_dummy) & ": ok");

    end loop loop_dummy_2;

    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    wait for c_clk_period;

    -- TEST 3: Max bus stall (valid held 20 cycles)
    report "TEST: Max bus stall";

    loop_dummy_3 : for lv_dummy in 0 to 19 loop

      core_a_bus <= (addr => x"00002000", data => x"CAFECAFE", we => '1', valid => '1', sel => "1111");
      core_b_bus <= (addr => x"00002000", data => x"CAFECAFE", we => '1', valid => '1', sel => "1111");
      wait until rising_edge(clk);
      check(safe_state = '0', "stall #" & integer'image(lv_dummy) & ": ok");

    end loop loop_dummy_3;

    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    wait for c_clk_period;

    -- TEST 4: Rapid address changes
    report "TEST: Rapid address changes";

    loop_dummy_4 : for lv_dummy in 0 to 7 loop

      core_a_bus <=
      (
        addr  => std_logic_vector(to_unsigned(4096 + lv_dummy * 4, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      core_b_bus <=
      (
        addr  => std_logic_vector(to_unsigned(4096 + lv_dummy * 4, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      check(safe_state = '0', "rapid addr #" & integer'image(lv_dummy) & ": ok");

    end loop loop_dummy_4;

    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    wait for c_clk_period;

    -- TEST 5: Burst write
    report "TEST: Burst write 4 beats";

    loop_dummy_5 : for lv_dummy in 0 to 3 loop

      core_a_bus <=
      (
        addr  => std_logic_vector(to_unsigned(lv_dummy * 4, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      core_b_bus <=
      (
        addr  => std_logic_vector(to_unsigned(lv_dummy * 4, 32)),
        data  => std_logic_vector(to_unsigned(lv_dummy, 32)),
        we    => '1',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      check(safe_state = '0', "burst #" & integer'image(lv_dummy) & ": ok");

    end loop loop_dummy_5;

    core_a_bus.valid <= '0';
    core_b_bus.valid <= '0';
    wait for c_clk_period;

    test_runner_cleanup;

  end process p_test;

end architecture tb;
