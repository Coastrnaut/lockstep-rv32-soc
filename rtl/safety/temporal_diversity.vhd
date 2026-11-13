-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Temporal Diversity Delay
-- Module Name:  temporal_diversity - rtl
-- Description:  Keeps core B a fixed number of clocks behind core A. Everything
--               that changes on core A's inputs reaches core B that much later,
--               reset included, so core B is an exact copy of core A at an earlier
--               moment. A glitch that hits both cores at once finds them at
--               different points in the program, and cannot do the same thing to
--               both, which is what lets the comparator see it.
--
--               Every field of t_core_inputs is delayed, so a field added to that
--               record, such as the bus error, reaches core B with the rest.
--
--               Core A's bus is held back by the same amount, so that it reaches
--               the comparator together with core B's. It goes no further until
--               it has been compared, so nothing that the cores disagree on can
--               leave them.
--
-- Traces to:    TSR_LOCKSTEP_043
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity temporal_diversity is
  generic (
    -- Clocks that core B runs behind core A
    g_cycles : positive range 1 to 8 := 2
  );
  port (
    clk_i : in    std_logic;

    -- Core A's bus, on its way to the comparator
    core_a_bus_i : in    t_rv_bus;
    core_a_bus_o : out   t_rv_bus;

    -- What core A receives, on its way to core B
    core_a_in_i : in    t_core_inputs;
    core_b_in_o : out   t_core_inputs
  );
end entity temporal_diversity;

architecture rtl of temporal_diversity is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_043";

  type t_bus_stages is array (1 to g_cycles) of t_rv_bus;

  type t_input_stages is array (1 to g_cycles) of t_core_inputs;

  signal r_bus    : t_bus_stages;
  signal r_inputs : t_input_stages;

begin

  -- ========================================================================
  -- DELAY LINES
  -- ========================================================================
  -- No reset. Reset is one of the inputs being delayed, so that core B leaves it
  -- and enters it late as well, and whatever is in here has passed through by
  -- the time a reset has lasted g_cycles clocks. A bit that flips in here makes
  -- the cores disagree, which the comparator reports.
  -- ========================================================================
  p_stages : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_bus(1)    <= core_a_bus_i;
      r_inputs(1) <= core_a_in_i;

      loop_i : for lv_i in 2 to g_cycles loop

        r_bus(lv_i)    <= r_bus(lv_i - 1);
        r_inputs(lv_i) <= r_inputs(lv_i - 1);

      end loop loop_i;

    end if;

  end process p_stages;

  core_a_bus_o <= r_bus(g_cycles);
  core_b_in_o  <= r_inputs(g_cycles);

end architecture rtl;
