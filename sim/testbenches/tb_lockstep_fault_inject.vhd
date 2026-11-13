-- ============================================================================
-- Testbench: Lockstep Comparator — Fault Injection
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_lockstep_fault_inject is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_fault_inject;

architecture rtl of tb_lockstep_fault_inject is

  constant c_clk_period : time := 20 ns;

  signal tb_clk     : std_logic;
  signal tb_rst_n   : std_logic;
  signal core_a_bus : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal nmi_fault  : std_logic;
  signal safe_state : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    tb_clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  i_dut : entity lockstep.lockstep_comparator
    port map (
      clk_i         => tb_clk,
      rst_n_syn_i   => tb_rst_n,
      core_a_bus_i  => core_a_bus,
      core_b_bus_i  => core_b_bus,
      fatal_fault_i => '0',
      nmi_fault_o   => nmi_fault,
      safe_state_o  => safe_state,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus

    );p_stim : process is

    constant c_clean_bus : t_rv_bus :=
    (
      addr  => x"00001000",
      data  => x"00000001",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );

  begin

    test_runner_setup(runner, runner_cfg);
    tb_rst_n <= '0';

    loop_dummy : for lv_dummy in 1 to 10 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy;

    tb_rst_n <= '1';

    loop_dummy_2 : for lv_dummy in 1 to 10 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy_2;

    -- --- Fault 1: Address mismatch ---
    core_a_bus <=
    (
      addr  => x"00001000",
      data  => x"00000001",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );
    core_b_bus <=
    (
      addr  => x"00002000",
      data  => x"00000001",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );

    loop_dummy_3 : for lv_dummy in 1 to 3 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy_3;

    check(nmi_fault = '1', "NMI on addr mismatch");
    check(bus_valid = '0', "bus isolated on addr mismatch");

    -- --- Fault 2: Write-enable mismatch ---
    core_a_bus <=
    (
      addr  => x"00003000",
      data  => x"00000002",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );
    core_b_bus <=
    (
      addr  => x"00003000",
      data  => x"00000002",
      we    => '0',
      valid => '1',
      sel   => "1111"
    );

    loop_dummy_4 : for lv_dummy in 1 to 3 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy_4;

    check(nmi_fault = '1', "NMI on WE mismatch (latched)");

    -- --- Fault 3: Single-bit data flip ---
    core_a_bus <=
    (
      addr  => x"00004000",
      data  => x"00000000",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );
    core_b_bus <=
    (
      addr  => x"00004000",
      data  => x"00000001",
      we    => '1',
      valid => '1',
      sel   => "1111"
    );

    loop_dummy_5 : for lv_dummy in 1 to 3 loop

      wait until rising_edge(tb_clk);

    end loop loop_dummy_5;

    check(nmi_fault = '1', "NMI on single-bit data flip (latched)");

    -- --- Every bus field trips the comparator on its own, from a clean reset ---
    loop_field : for lv_field in 0 to 4 loop

      tb_rst_n   <= '0';
      core_a_bus <= c_clean_bus;
      core_b_bus <= c_clean_bus;

      loop_dummy_6 : for lv_dummy in 1 to 3 loop

        wait until rising_edge(tb_clk);

      end loop loop_dummy_6;

      tb_rst_n <= '1';

      loop_dummy_7 : for lv_dummy in 1 to 3 loop

        wait until rising_edge(tb_clk);

      end loop loop_dummy_7;

      check(nmi_fault = '0', "no fault while the cores agree");
      check(bus_valid = '1', "bus open while the cores agree");

      case lv_field is

        when 0 =>

          core_b_bus.addr(31) <= '1';

        when 1 =>

          core_b_bus.data(31) <= '1';

        when 2 =>

          core_b_bus.sel(3) <= '0';

        when 3 =>

          core_b_bus.we <= '0';

        when others =>

          core_b_bus.valid <= '0';

      end case;

      loop_dummy_8 : for lv_dummy in 1 to 3 loop

        wait until rising_edge(tb_clk);

      end loop loop_dummy_8;

      check(nmi_fault = '1', "NMI from one field");
      check(bus_valid = '0', "bus isolated by one field");
      check_equal(sys_bus.sel, std_logic_vector'("0000"), "isolated bus carries no byte enables");

    end loop loop_field;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture rtl;
