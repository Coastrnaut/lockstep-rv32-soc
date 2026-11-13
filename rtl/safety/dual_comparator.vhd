-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Redundant Lockstep Comparator
-- Module Name:  dual_comparator - rtl
-- Description:  Two lockstep comparators on the same buses, each with its own
--               state, as docs/verification/diagnostics.md recommends (option
--               B). A comparator that fails after the startup self-test no
--               longer goes unseen until the next cold reset:
--
--                 - The system bus carries core A's request only when both
--                   comparators pass it, and pass the same thing.
--                 - Either comparator's trip is a fault.
--                 - The two comparators' decisions are compared every clock.
--                   Any difference (on the system bus, the gate, the fault or
--                   the safe state) is a fault too: it latches here, and trips
--                   both comparators through their fatal fault input, so a
--                   comparator stuck at "no error" or stuck tripped is found at
--                   once, and the SoC is held safe until a cold reset.
--
--               So a dangerous failure needs both comparators to fail the same
--               way, in the same clock.
--
--               The startup self-test sees the pair through test_*_o: there a
--               trip counts only when both comparators trip, and the bus counts
--               as closed only when both close it. A comparator that does not
--               trip fails the test; one stuck tripped makes the two disagree,
--               which trips both, and fails the test's check that a reset
--               clears the trip.
--
--               The two instances carry keep_hierarchy and dont_touch, so that
--               synthesis cannot merge them into one (docs/verification/
--               synthesis.md).
--
-- Traces to:    TSR_LOCKSTEP_001, TSR_LOCKSTEP_044, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity dual_comparator is
  port (
    clk_i       : in    std_logic;
    rst_n_syn_i : in    std_logic;

    -- Both cores' buses, to both comparators
    core_a_bus_i : in    t_rv_bus;
    core_b_bus_i : in    t_rv_bus;

    -- A fault the cores cannot see for themselves
    fatal_fault_i : in    std_logic;

    -- The pair, as the SoC sees it: either comparator, or a disagreement
    nmi_fault_o  : out   std_logic;
    fault_o      : out   std_logic;
    safe_state_o : out   std_logic;
    bus_valid_o  : out   std_logic;
    sys_bus_o    : out   t_rv_bus;

    -- The pair, as the startup self-test sees it: both comparators
    test_nmi_fault_o  : out   std_logic;
    test_fault_o      : out   std_logic;
    test_safe_state_o : out   std_logic;
    test_bus_valid_o  : out   std_logic;

    -- The two comparators disagreed since the last reset
    disagree_o : out   std_logic
  );
end entity dual_comparator;

architecture rtl of dual_comparator is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_001, TSR_LOCKSTEP_044, TSR_SAFETY_GATE_001";

  constant c_quiet_bus : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => (others => '0')
  );

  signal w_fatal : std_logic;

  signal w_nmi_a   : std_logic;
  signal w_nmi_b   : std_logic;
  signal w_fault_a : std_logic;
  signal w_fault_b : std_logic;
  signal w_safe_a  : std_logic;
  signal w_safe_b  : std_logic;
  signal w_valid_a : std_logic;
  signal w_valid_b : std_logic;
  signal w_bus_a   : t_rv_bus;
  signal w_bus_b   : t_rv_bus;

  signal w_differ : std_logic;
  signal r_differ : std_logic;

  -- Two comparators, not one: synthesis must keep both
  attribute keep_hierarchy : string;
  attribute dont_touch     : string;
  attribute dont_touch of r_differ           : signal is "true";
  attribute keep_hierarchy of i_comparator_a : label is "yes";
  attribute keep_hierarchy of i_comparator_b : label is "yes";
  attribute dont_touch of i_comparator_a     : label is "true";
  attribute dont_touch of i_comparator_b     : label is "true";

begin

  -- A disagreement trips both comparators from the clock after it is seen
  w_fatal <= fatal_fault_i or r_differ;

  i_comparator_a : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk_i,
      rst_n_syn_i   => rst_n_syn_i,
      core_a_bus_i  => core_a_bus_i,
      core_b_bus_i  => core_b_bus_i,
      fatal_fault_i => w_fatal,
      nmi_fault_o   => w_nmi_a,
      fault_o       => w_fault_a,
      safe_state_o  => w_safe_a,
      bus_valid_o   => w_valid_a,
      sys_bus_o     => w_bus_a
    );

  i_comparator_b : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk_i,
      rst_n_syn_i   => rst_n_syn_i,
      core_a_bus_i  => core_a_bus_i,
      core_b_bus_i  => core_b_bus_i,
      fatal_fault_i => w_fatal,
      nmi_fault_o   => w_nmi_b,
      fault_o       => w_fault_b,
      safe_state_o  => w_safe_b,
      bus_valid_o   => w_valid_b,
      sys_bus_o     => w_bus_b
    );

  -- ========================================================================
  -- 1. CROSS-CHECK: the two decisions, every clock
  -- ========================================================================
  w_differ <= '1' when (w_bus_a /= w_bus_b or w_valid_a /= w_valid_b or w_fault_a /= w_fault_b or
                         w_safe_a /= w_safe_b) else
              '0';

  -- Held until the reset, like a comparator's own fault latch
  p_differ : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_syn_i = '0') then
        r_differ <= '0';
      elsif (w_differ = '1') then
        r_differ <= '1';
      end if;
    end if;

  end process p_differ;

  -- ========================================================================
  -- 2. THE SOC'S VIEW: a trip of either, or a disagreement
  -- ========================================================================
  -- The bus is core A's request only when both comparators pass the same
  -- request; in the clock a disagreement is seen, nothing goes out.
  sys_bus_o <= w_bus_a when (w_differ = '0' and r_differ = '0') else
               c_quiet_bus;

  nmi_fault_o  <= w_nmi_a or w_nmi_b or w_differ or r_differ;
  fault_o      <= w_fault_a or w_fault_b or r_differ;
  safe_state_o <= w_safe_a or w_safe_b or r_differ;
  bus_valid_o  <= w_valid_a and w_valid_b and not r_differ;

  -- ========================================================================
  -- 3. THE SELF-TEST'S VIEW: both comparators
  -- ========================================================================
  test_nmi_fault_o  <= w_nmi_a and w_nmi_b;
  test_fault_o      <= w_fault_a and w_fault_b;
  test_safe_state_o <= w_safe_a and w_safe_b;
  test_bus_valid_o  <= w_valid_a or w_valid_b or r_differ;

  disagree_o <= r_differ;

  -- ========================================================================
  -- 4. SIMULATION ASSERTIONS
  -- ========================================================================
  -- Property: nothing leaves on the system bus that both comparators did not pass
  -- ========================================================================
  p_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_syn_i = '1' and sys_bus_o.valid = '1') then
        assert w_bus_a = w_bus_b and w_bus_a.valid = '1'
          report "FORMAL FAIL: a request left that one comparator did not pass"
          severity error;
      end if;
    end if;

  end process p_asserts;

end architecture rtl;
