-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Retirement Comparator
-- Module Name:  retire_comparator - rtl
-- Description:  The bus comparator sees only what reaches the bus. A fault in a
--               core's registers, program counter or control state stays
--               hidden until it changes a bus access, or for ever if nothing
--               ever uses the value (docs/verification/fault_campaign.md:
--               "latent"). This block compares the two cores' retirements
--               instead, from NEORV32's trace port, every clock.
--
--               Core B runs a fixed g_cycles behind core A on the same inputs,
--               so its retirement record is core A's from g_cycles clocks
--               before, field for field. Core A's record goes through a delay
--               line of that length, and the two are compared: whether an
--               instruction retired, and for one that did, the instruction,
--               both program counters, the trap and interrupt flags, the
--               destination register, its write data and the CSR write data.
--               Memory accesses are not compared here: they reach the bus,
--               where the bus comparator stops them before any effect.
--
--               It only detects. A difference, registered, goes to the
--               comparators' fatal input, which closes the bus and raises the
--               fault pin; containment stays with the bus comparator.
--
--               It compares while core B is out of reset. Core B's reset is
--               core A's, delayed with its other inputs, so core B leaves and
--               enters reset g_cycles after core A, just as its retirements
--               follow core A's. The delay line itself has no reset: it holds
--               core A's last records into a reset, which core B still has to
--               match.
--
-- Traces to:    TSR_LOCKSTEP_046
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library neorv32;
  use neorv32.neorv32_package.all;

entity retire_comparator is
  generic (
    -- Core B's lag behind core A, as temporal_diversity's g_cycles
    g_cycles : positive range 1 to 8 := 2
  );
  port (
    clk_i : in    std_logic;
    -- Cold reset, synchronous to clk_i: clears the registered difference
    rst_n_i : in    std_logic;
    -- Core B's own reset, as core B receives it: compare while it is high
    core_b_rst_n_i : in    std_logic;

    -- Each core's retirement record
    trace_a_i : in    trace_port_t;
    trace_b_i : in    trace_port_t;

    -- The retirements differed in the clock before: one clock wide or longer,
    -- for the comparators' fatal input, which holds it
    fault_o : out   std_logic
  );
end entity retire_comparator;

architecture rtl of retire_comparator is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_046";

  -- What is compared of one retirement

  type t_retire is record
    valid    : std_logic;
    insn     : std_logic_vector(31 downto 0);
    pc       : std_logic_vector(31 downto 0);
    pc_next  : std_logic_vector(31 downto 0);
    trap     : std_logic;
    intr     : std_logic;
    rd_addr  : std_logic_vector(4 downto 0);
    rd_wdata : std_logic_vector(31 downto 0);
    csr_data : std_logic_vector(31 downto 0);
  end record t_retire;

  type t_stages is array (1 to g_cycles) of t_retire;

  function select_fields (
    t : trace_port_t
  ) return t_retire is

    variable v_r : t_retire;

  begin

    v_r.valid    := t.valid;
    v_r.insn     := std_logic_vector(t.insn);
    v_r.pc       := std_logic_vector(t.pc_rdata);
    v_r.pc_next  := std_logic_vector(t.pc_wdata);
    v_r.trap     := t.trap;
    v_r.intr     := t.intr;
    v_r.rd_addr  := std_logic_vector(t.rd_addr);
    v_r.rd_wdata := std_logic_vector(t.rd_wdata);
    v_r.csr_data := std_logic_vector(t.csr_wdata);

    return v_r;

  end function select_fields;

  signal r_a_late : t_stages;
  signal w_a      : t_retire;
  signal w_b      : t_retire;
  signal w_differ : std_logic;
  signal r_fault  : std_logic;

begin

  -- ========================================================================
  -- 1. CORE A'S RECORD, g_cycles LATE
  -- ========================================================================
  p_delay : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_a_late(1) <= select_fields(trace_a_i);

      loop_i : for lv_i in 2 to g_cycles loop

        r_a_late(lv_i) <= r_a_late(lv_i - 1);

      end loop loop_i;

    end if;

  end process p_delay;

  w_a <= r_a_late(g_cycles);
  w_b <= select_fields(trace_b_i);

  -- ========================================================================
  -- 2. COMPARE
  -- ========================================================================
  -- Whether an instruction retired is compared in every clock; what it did,
  -- only when it did, so that fields NEORV32 leaves undefined in between do
  -- not matter.
  -- ========================================================================
  w_differ <= '1' when (core_b_rst_n_i = '1' and
                         (w_a.valid /= w_b.valid or (w_b.valid = '1' and w_a /= w_b))) else
              '0';

  p_fault : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_fault <= '0';
      else
        r_fault <= w_differ;
      end if;
    end if;

  end process p_fault;

  fault_o <= r_fault;

end architecture rtl;
