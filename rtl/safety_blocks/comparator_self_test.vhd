-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Comparator Startup Self-Test
-- Module Name:  comparator_self_test - rtl
-- Description:  Proves that the lockstep comparator works before the cores may
--               start. A comparator stuck at "no error" gives no sign of it until
--               the fault it should have caught, so this makes it catch one.
--
--               With both cores in reset, their buses agree. The test flips each
--               bit of core B's bus in turn, and then raises the fatal fault
--               input, and each time checks that the comparator trips, that the
--               trip holds once the cause has gone, and that a reset clears it.
--               These are real trips, through the same logic as a real fault.
--               There is no test mode, because an input that told the comparator
--               to ignore a mismatch would be a new way to blind it.
--
--               If any of that goes wrong, the cores never leave reset, which
--               also keeps the actuators safe, and passed_o stays low.
--
--               This runs once after each cold reset, so a fault that appears
--               later stays hidden until the next one.
--
-- Traces to:    TSR_LOCKSTEP_044
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity comparator_self_test is
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic; -- Cold reset, synchronous to clk_i

    -- What the test does to the comparator
    flip_bus_o    : out   t_rv_bus;  -- Bits to flip in core B's bus
    fatal_fault_o : out   std_logic;
    rst_n_o       : out   std_logic; -- The comparator's reset

    -- What the comparator does about it
    nmi_fault_i  : in    std_logic;
    safe_state_i : in    std_logic;
    bus_valid_i  : in    std_logic;

    -- The result. The cores stay in reset until passed_o rises.
    passed_o : out   std_logic;
    failed_o : out   std_logic
  );
end entity comparator_self_test;

architecture rtl of comparator_self_test is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_044";

  -- One lane for each bit of the bus, in t_rv_bus order, and one for the fatal
  -- fault input, which is the last
  constant c_fatal_lane : natural := c_addr_width + c_data_width + 4 + 1 + 1;

  -- Clocks for the delay lines and the comparator to settle after a cold reset
  constant c_settle_clocks : natural := 4;

  type t_step is (step_settle, step_inject, step_hold, step_clear, step_recover, step_done);

  signal r_step   : t_step;
  signal r_settle : natural range 0 to c_settle_clocks - 1;
  signal r_lane   : natural range 0 to c_fatal_lane;

  -- The pass result, in the safe state encoding, so that one flipped bit cannot
  -- turn a fail into a pass (Rule 3.1)
  signal r_result : t_safe_state;

  signal w_inject  : std_logic_vector(c_fatal_lane downto 0);
  signal w_clean   : std_logic;
  signal w_tripped : std_logic;

begin

  -- ========================================================================
  -- 1. WHAT THE COMPARATOR SHOULD BE SHOWING
  -- ========================================================================
  w_clean <= '1' when (nmi_fault_i = '0' and safe_state_i = '0' and bus_valid_i = '1') else
             '0';

  w_tripped <= '1' when (nmi_fault_i = '1' and safe_state_i = '1' and bus_valid_i = '0') else
               '0';

  -- ========================================================================
  -- 2. TEST SEQUENCE (Rule 3.1, 3.3)
  -- ========================================================================
  -- Every lane takes four clocks. Anything unexpected ends the test with the
  -- result still at fault.
  -- ========================================================================
  p_test : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_step   <= step_settle;
        r_settle <= 0;
        r_lane   <= 0;
        r_result <= st_fault_tripped;
      else

        case r_step is

          when step_settle =>

            if (r_settle = c_settle_clocks - 1) then
              r_step <= step_inject;
            else
              r_settle <= r_settle + 1;
            end if;

          when step_inject =>

            -- The NMI follows the compare at once. The rest take a clock.
            if (nmi_fault_i = '1') then
              r_step <= step_hold;
            else
              r_step <= step_done;
            end if;

          when step_hold =>

            -- The flip has gone by now, so this is the latch
            if (w_tripped = '1') then
              r_step <= step_clear;
            else
              r_step <= step_done;
            end if;

          when step_clear =>

            r_step <= step_recover;

          when step_recover =>

            if (w_clean = '0') then
              r_step <= step_done;
            elsif (r_lane = c_fatal_lane) then
              r_step   <= step_done;
              r_result <= st_system_ok;
            else
              r_step <= step_inject;
              r_lane <= r_lane + 1;
            end if;

          when others =>

            r_step <= step_done;

        end case;

      end if;
    end if;

  end process p_test;

  -- ========================================================================
  -- 3. WHAT THE TEST DOES TO THE COMPARATOR
  -- ========================================================================
  p_inject : process (all) is
  begin

    w_inject <= (others => '0');

    if (r_step = step_inject) then
      w_inject(r_lane) <= '1';
    end if;

  end process p_inject;

  flip_bus_o.addr  <= w_inject(c_addr_width - 1 downto 0);
  flip_bus_o.data  <= w_inject(c_addr_width + c_data_width - 1 downto c_addr_width);
  flip_bus_o.sel   <= w_inject(c_addr_width + c_data_width + 3 downto c_addr_width + c_data_width);
  flip_bus_o.we    <= w_inject(c_addr_width + c_data_width + 4);
  flip_bus_o.valid <= w_inject(c_addr_width + c_data_width + 5);
  fatal_fault_o    <= w_inject(c_fatal_lane);

  rst_n_o <= '0' when (rst_n_i = '0' or r_step = step_clear) else
             '1';

  -- ========================================================================
  -- 4. THE RESULT
  -- ========================================================================
  -- A flipped bit in r_result is neither pass nor fail, so it stops the cores
  -- and reports a fault, even long after the test has finished.
  -- ========================================================================
  passed_o <= '1' when (r_result = st_system_ok) else
              '0';

  failed_o <= '1' when (r_step = step_done and r_result /= st_system_ok) else
              '0';

  -- ========================================================================
  -- 5. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: The cores are only released once every lane has been tried
  -- Property: One lane is tried at a time, and none once the test is over
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '1') then
        if (r_result = st_system_ok) then
          assert r_lane = c_fatal_lane
            report "FORMAL FAIL: cores released with a lane untried"
            severity error;
        end if;
        if (r_step /= step_inject) then
          assert unsigned(w_inject) = 0
            report "FORMAL FAIL: comparator disturbed outside the test"
            severity error;
        end if;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
