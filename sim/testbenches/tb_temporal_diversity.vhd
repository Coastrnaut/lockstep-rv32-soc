-- ============================================================================
-- Testbench: Temporal Diversity Delay
-- ============================================================================
-- Every bit on both delay lines has to come out exactly two clocks after it went
-- in, whatever the traffic. Random values change every line on most clocks, so
-- no two clocks of history look alike and an off-by-one cannot pass by luck.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library osvvm;
  use osvvm.randompkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_temporal_diversity is
  generic (
    runner_cfg : string := ""
  );
end entity tb_temporal_diversity;

architecture tb of tb_temporal_diversity is

  constant c_clk_period : time    := 20 ns;
  constant c_skew       : natural := 2;
  constant c_clocks     : natural := 2000;

  signal clk      : std_logic;
  signal bus_in   : t_rv_bus;
  signal bus_out  : t_rv_bus;
  signal core_in  : t_core_inputs;
  signal core_out : t_core_inputs;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  dut : entity lockstep.temporal_diversity
    port map (
      clk_i        => clk,
      core_a_bus_i => bus_in,
      core_a_bus_o => bus_out,
      core_a_in_i  => core_in,
      core_b_in_o  => core_out
    );

  p_stim : process is

    type t_bus_history is array (0 to c_skew) of t_rv_bus;

    type t_input_history is array (0 to c_skew) of t_core_inputs;

    variable v_random : randomptype;
    variable v_bus    : t_bus_history;
    variable v_inputs : t_input_history;
    variable v_flags  : std_logic_vector(6 downto 0);

  begin

    test_runner_setup(runner, runner_cfg);
    v_random.InitSeed(tb_temporal_diversity'instance_name);

    while test_suite loop

      if run("both_lines_are_exactly_two_clocks_long") then

        for clock in 0 to c_clocks - 1 loop

          v_flags := v_random.RandSlv(7);

          bus_in  <=
          (
            addr  => v_random.RandSlv(32),
            data  => v_random.RandSlv(32),
            sel   => v_flags(3 downto 0),
            we    => v_flags(4),
            valid => v_flags(5)
          );
          v_flags := v_random.RandSlv(7);
          core_in <=
          (
            rst_n => v_flags(0),
            rdata => v_random.RandSlv(32),
            ack   => v_flags(1),
            msi   => v_flags(2),
            mti   => v_flags(3),
            mei   => v_flags(4)
          );

          -- The end of this clock, while the outputs still show its values
          wait until rising_edge(clk);
          v_bus(c_skew)    := bus_in;
          v_inputs(c_skew) := core_in;

          if (clock >= c_skew) then
            check(bus_out = v_bus(0), "bus");
            check(core_out = v_inputs(0), "inputs");
          end if;

          v_bus(0 to c_skew - 1)    := v_bus(1 to c_skew);
          v_inputs(0 to c_skew - 1) := v_inputs(1 to c_skew);

        end loop;

      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
