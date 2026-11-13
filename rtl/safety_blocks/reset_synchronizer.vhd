-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Reset Synchroniser
-- Module Name:  reset_synchronizer - rtl
-- Description:  Asserts a reset at once, with or without a clock, and releases
--               it on a rising edge of clk_i (Rule 1.4). This is the only
--               asynchronous reset in the design: every block after it sees a
--               reset that is synchronous to its clock (Rule M-04).
--
--               Both cores share one of these. Each core also has a synchroniser
--               of its own, but two of them can settle on different clocks if
--               the reset is released close to a clock edge, and that would
--               start the cores out of step.
--
-- Traces to:    TSR_RESET_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

entity reset_synchronizer is
  generic (
    -- Flip-flops between the asynchronous input and the output
    g_stages : positive range 2 to 8 := 2
  );
  port (
    clk_i : in    std_logic;

    -- Asynchronous, active low
    rst_n_i : in    std_logic;

    -- Falls with rst_n_i, and rises on a rising edge of clk_i
    rst_n_syn_o : out   std_logic
  );
end entity reset_synchronizer;

architecture rtl of reset_synchronizer is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_RESET_001";

  signal r_stages : std_logic_vector(g_stages - 1 downto 0);

begin

  -- ========================================================================
  -- 1. SYNCHRONISER CHAIN
  -- ========================================================================
  p_stages : process (clk_i, rst_n_i) is
  begin

    if (rst_n_i = '0') then
      r_stages <= (others => '0');
    elsif rising_edge(clk_i) then
      r_stages <= r_stages(g_stages - 2 downto 0) & '1';
    end if;

  end process p_stages;

  rst_n_syn_o <= r_stages(g_stages - 1);

  -- ========================================================================
  -- 2. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: The chain fills from the input end, so that a flipped bit in it
  --           is reported rather than releasing the reset early
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then

      loop_i : for lv_i in 1 to g_stages - 1 loop

        assert not (r_stages(lv_i) = '1' and r_stages(lv_i - 1) = '0')
          report "FORMAL FAIL: reset chain released out of order"
          severity error;

      end loop loop_i;

    end if;

  end process p_formal_asserts;

end architecture rtl;
