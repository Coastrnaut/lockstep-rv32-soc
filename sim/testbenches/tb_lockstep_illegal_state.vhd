-- ============================================================================
-- Testbench: Illegal Comparator State
-- ============================================================================
-- HSI section 8.2, FLT-03: any value of the state register other than 0x5A or
-- 0xA5 is a fault. Each one-bit corruption of the healthy 0x5A is forced for
-- one clock in an otherwise healthy cycle, with both buses agreeing. The bus
-- has to close at once, and the fault has to be reported, latched and held
-- until a reset, as for a mismatch.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_lockstep_illegal_state is
  generic (
    runner_cfg : string := ""
  );
end entity tb_lockstep_illegal_state;

architecture tb of tb_lockstep_illegal_state is

  constant c_clk_period : time := 10 ns;

  constant c_store : t_rv_bus :=
  (
    addr  => x"20000008",
    data  => x"12345678",
    sel   => "1111",
    we    => '1',
    valid => '1'
  );

  signal clk        : std_logic;
  signal rst_n      : std_logic;
  signal core_bus   : t_rv_bus;
  signal core_b_bus : t_rv_bus;
  signal safe_state : std_logic;
  signal nmi_fault  : std_logic;
  signal fault      : std_logic;
  signal bus_valid  : std_logic;
  signal sys_bus    : t_rv_bus;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 1 ms);

  -- The cores agree unless a test says otherwise
  i_dut : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk,
      rst_n_syn_i   => rst_n,
      core_a_bus_i  => core_bus,
      core_b_bus_i  => core_b_bus,
      fatal_fault_i => '0',
      safe_state_o  => safe_state,
      nmi_fault_o   => nmi_fault,
      fault_o       => fault,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus
    );

  p_stim : process is

    alias state   is << signal i_dut.r_current_state : t_safe_state >>;
    alias latched is << signal i_dut.r_fault_latched : std_logic >>;

    procedure reset_dut is
    begin

      rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      check_equal(state, st_system_ok, "healthy after reset");
      check_equal(nmi_fault, '0', "no fault after reset");
      check_equal(bus_valid, '1', "gate open after reset");
      check_equal(sys_bus.valid, '1', "the store passes while healthy");

    end procedure reset_dut;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      core_bus   <= c_store;
      core_b_bus <= c_store;

      if run("every_one_bit_corruption_of_the_healthy_state_is_a_held_fault") then

        for bit_index in 0 to 7 loop

          reset_dut;

          -- One clock with a single bit of 0x5A flipped, and the buses agreeing
          state <= force st_system_ok xor std_logic_vector(shift_left(to_unsigned(1, 8), bit_index));
          wait for 1 ns;
          check_equal(sys_bus.valid, '0', "bit " & integer'image(bit_index) & ": store stopped at once");
          check_equal(bus_valid, '0', "bit " & integer'image(bit_index) & ": gate closed at once");
          check_equal(nmi_fault, '1', "bit " & integer'image(bit_index) & ": fault reported at once");
          check_equal(fault, '1', "bit " & integer'image(bit_index) & ": registered fault at once");
          check_equal(safe_state, '1', "bit " & integer'image(bit_index) & ": safe state at once");
          wait until rising_edge(clk);
          state <= release;

          -- The cause is gone and the buses still agree, but it stays
          for dummy in 1 to 5 loop

            wait until falling_edge(clk);
            check_equal(state, st_fault_tripped, "bit " & integer'image(bit_index) & ": tripped");
            check_equal(nmi_fault, '1', "bit " & integer'image(bit_index) & ": fault held");
            check_equal(fault, '1', "bit " & integer'image(bit_index) & ": registered fault held");
            check_equal(safe_state, '1', "bit " & integer'image(bit_index) & ": safe state held");
            check_equal(bus_valid, '0', "bit " & integer'image(bit_index) & ": gate held closed");
            check_equal(sys_bus.valid, '0', "bit " & integer'image(bit_index) & ": bus held closed");

          end loop;

        end loop;

        -- Only a reset clears it
        reset_dut;
      elsif run("registered_fault_rises_at_the_edge_after_a_mismatch") then
        -- HSI FLT-01: the compare can glitch while the buses settle, so the pin
        -- output must not follow it within the cycle
        reset_dut;
        core_b_bus.data <= x"00000000";
        wait for 1 ns;
        check_equal(nmi_fault, '1', "the compare trips at once");
        check_equal(fault, '0', "the registered fault waits for the edge");
        core_b_bus.data <= c_store.data;
        wait for 1 ns;
        check_equal(fault, '0', "a mismatch gone before the edge leaves no fault");
        check_equal(nmi_fault, '0', "nor a trip");
        core_b_bus.data <= x"00000000";
        wait until rising_edge(clk);
        core_b_bus.data <= c_store.data;
        wait for 1 ns;
        check_equal(fault, '1', "registered at the edge");

        for dummy in 1 to 3 loop

          wait until falling_edge(clk);
          check_equal(fault, '1', "and held");

        end loop;

      elsif run("an_upset_that_clears_the_latch_while_tripped_hides_nothing") then
        -- Found by the formal proof (R2.1): the latch and the state each report
        -- the fault, so an upset of one cannot hide it
        reset_dut;
        core_b_bus.data <= x"00000000";
        wait until rising_edge(clk);
        core_b_bus.data <= c_store.data;
        wait until falling_edge(clk);
        check_equal(state, st_fault_tripped, "tripped by a forced mismatch");
        latched         <= force '0';
        wait for 1 ns;
        check_equal(nmi_fault, '1', "the comparator still reports the fault");
        check_equal(fault, '1', "the registered fault still shows");
        check_equal(safe_state, '1', "still safe");
        check_equal(bus_valid, '0', "gate still closed");
        wait until rising_edge(clk);
        latched         <= release;
      elsif run("an_upset_that_sets_the_latch_trips_the_comparator") then
        -- A set latch with a healthy state can only be an upset: the state
        -- follows it at the next edge rather than leaving the bus open
        reset_dut;
        latched <= force '1';
        wait until rising_edge(clk);
        latched <= release;
        wait until falling_edge(clk);
        check_equal(state, st_fault_tripped, "tripped");
        check_equal(bus_valid, '0', "gate closed");
        check_equal(safe_state, '1', "safe");
        check_equal(fault, '1', "fault reported");
        check_equal(sys_bus.valid, '0', "nothing passes");
      elsif run("one_bit_corruption_of_the_tripped_state_stays_tripped") then

        for bit_index in 0 to 7 loop

          reset_dut;
          core_b_bus.data <= x"00000000";
          wait until rising_edge(clk);
          core_b_bus.data <= c_store.data;
          wait until falling_edge(clk);
          check_equal(state, st_fault_tripped, "tripped by a forced mismatch");
          state           <= force st_fault_tripped xor std_logic_vector(shift_left(to_unsigned(1, 8), bit_index));
          wait until rising_edge(clk);
          state           <= release;
          wait until falling_edge(clk);
          check_equal(state, st_fault_tripped, "bit " & integer'image(bit_index) & ": still tripped");
          check_equal(nmi_fault, '1', "bit " & integer'image(bit_index) & ": fault still reported");
          check_equal(fault, '1', "bit " & integer'image(bit_index) & ": registered fault still reported");
          check_equal(safe_state, '1', "bit " & integer'image(bit_index) & ": still safe");
          check_equal(bus_valid, '0', "bit " & integer'image(bit_index) & ": gate still closed");

        end loop;

      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
