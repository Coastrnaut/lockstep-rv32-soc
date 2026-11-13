-- ============================================================================
-- Testbench: Temporal Diversity Delay
-- ============================================================================
-- Every bit on both delay lines has to come out exactly two clocks after it went
-- in, whatever the traffic. Random values change every line on most clocks, so
-- no two clocks of history look alike and an off-by-one cannot pass by luck.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;
  use work.tb_random_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_temporal_diversity is
  generic (
    g_test : string := ""
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

  i_dut : entity lockstep.temporal_diversity
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

    variable v_random : t_random;
    variable v_bus    : t_bus_history;
    variable v_inputs : t_input_history;
    variable v_flags  : std_logic_vector(6 downto 0);

  begin

    test_runner_setup(g_test);
    v_random.init_seed("tb_temporal_diversity");

    loop_while : while test_suite loop

      if run("both_lines_are_exactly_two_clocks_long") then

        loop_clock : for lv_clock in 0 to c_clocks - 1 loop

          v_flags := v_random.rand_slv(7);

          bus_in  <=
          (
            addr  => v_random.rand_slv(32),
            data  => v_random.rand_slv(32),
            sel   => v_flags(3 downto 0),
            we    => v_flags(4),
            valid => v_flags(5)
          );
          v_flags := v_random.rand_slv(7);
          core_in <=
          (
            rst_n => v_flags(0),
            rdata => v_random.rand_slv(32),
            ack   => v_flags(1),
            err   => v_flags(5),
            msi   => v_flags(2),
            mti   => v_flags(3),
            mei   => v_flags(4)
          );

          -- The end of this clock, while the outputs still show its values
          wait until rising_edge(clk);
          v_bus(c_skew)    := bus_in;
          v_inputs(c_skew) := core_in;

          if (lv_clock >= c_skew) then
            check(bus_out = v_bus(0), "bus");
            check(core_out = v_inputs(0), "inputs");
          end if;

          v_bus(0 to c_skew - 1)    := v_bus(1 to c_skew);
          v_inputs(0 to c_skew - 1) := v_inputs(1 to c_skew);

        end loop loop_clock;

      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
