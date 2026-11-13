-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Dual-Core Lockstep (DCLS) Core Comparator
-- Module Name:  lockstep_comparator - rtl
-- Description:  Monitors two identical RISC-V cores cycle-by-cycle.
--               Flashes an immediate, latching NMI on any output bus mismatch.
--               Uses high-Hamming-distance safe state encoding.
--
-- Traces to:    TSR_LOCKSTEP_001, TSR_SAFETY_GATE_001
-- Cores:        Compatible with NEORV32 / Generic 32-bit RISC-V cores
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity lockstep_comparator is
  port (
    -- --------------------------------------------------------------------
    -- Clock & Reset Domain (Rule 1.1, 1.2, 1.4)
    -- --------------------------------------------------------------------
    -- Global system clock
    clk_i : in    std_logic;
    -- Synchronously de-asserted reset
    rst_n_syn_i : in    std_logic;

    -- --------------------------------------------------------------------
    -- Core A Interface (Master Core)
    -- --------------------------------------------------------------------
    core_a_bus_i : in    t_rv_bus;

    -- --------------------------------------------------------------------
    -- Core B Interface (Checker Core)
    -- --------------------------------------------------------------------
    core_b_bus_i : in    t_rv_bus;

    -- --------------------------------------------------------------------
    -- A fault elsewhere that the cores cannot see, because they both read the
    -- same bad value. It trips the same latch as a mismatch.
    -- --------------------------------------------------------------------
    fatal_fault_i : in    std_logic;

    -- --------------------------------------------------------------------
    -- Safety Supervisor & Actuator Intercept
    -- --------------------------------------------------------------------
    -- Fault now or latched: follows the compare at once
    nmi_fault_o : out   std_logic;
    -- Fault latched: from registers only, for pins and MEI
    fault_o : out   std_logic;
    -- Force vehicle actuators to safe mode
    safe_state_o : out   std_logic;
    -- Hardware transaction validation gate
    bus_valid_o : out   std_logic;

    -- System Outputs (Only passes Master Core signals forward if safe)
    sys_bus_o : out   t_rv_bus
  );
end entity lockstep_comparator;

architecture rtl of lockstep_comparator is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_001, TSR_SAFETY_GATE_001";

  -- Safe State Encoding (Rule 3.1)
  signal r_current_state : t_safe_state;
  signal w_next_state    : t_safe_state;

  -- Internal monitoring signals
  signal w_mismatch_detected : std_logic;
  signal r_fault_latched     : std_logic;
  signal w_trip              : std_logic;
  signal w_state_illegal     : std_logic;
  signal w_fault_now         : std_logic;
  signal w_fault_reg         : std_logic;
  signal w_bus_open          : std_logic;

  -- The encoding is the protection, so synthesis has to keep every bit as
  -- written. Without these, a 7-series flow re-encodes the state as an FSM, and
  -- merges the bits that always hold equal or opposite values, down to two
  -- flip-flops (docs/verification/synthesis.md). fsm_encoding and dont_touch
  -- are Vivado's names; the FPGA build checks that all nine flip-flops remain.
  attribute fsm_encoding : string;
  attribute dont_touch   : string;
  attribute fsm_encoding of r_current_state : signal is "none";
  attribute dont_touch of r_current_state   : signal is "true";
  attribute dont_touch of r_fault_latched   : signal is "true";

begin

  -- ========================================================================
  -- 1. COMBINATIONAL BUS COMPARATOR (Rule 2.1, 2.2, 2.3)
  -- ========================================================================
  -- Explicit sensitivity list for formal verification tool compatibility.
  -- ========================================================================
  p_bus_compare : process (
                           core_a_bus_i.addr,  core_b_bus_i.addr,
                           core_a_bus_i.data,  core_b_bus_i.data,
                           core_a_bus_i.sel,   core_b_bus_i.sel,
                           core_a_bus_i.we,    core_b_bus_i.we,
                           core_a_bus_i.valid, core_b_bus_i.valid
                          ) is
  begin

    -- Default assignments to prevent hardware latches (Rule 2.1)
    w_mismatch_detected <= '0';

    if ((core_a_bus_i.addr /= core_b_bus_i.addr)  or
        (core_a_bus_i.data /= core_b_bus_i.data)  or
        (core_a_bus_i.sel /= core_b_bus_i.sel)    or
        (core_a_bus_i.we /= core_b_bus_i.we)    or
        (core_a_bus_i.valid /= core_b_bus_i.valid)) then
      w_mismatch_detected <= '1';
    end if;

  end process p_bus_compare;

  w_trip <= w_mismatch_detected or fatal_fault_i;

  -- A state register holding neither encoding has been upset. That is a fault
  -- in its own right (HSI FLT-03), and is latched and reported like a trip.
  w_state_illegal <= '0' when (r_current_state = ST_SYSTEM_OK or r_current_state = ST_FAULT_TRIPPED) else
                     '1';

  w_fault_now <= w_trip or w_state_illegal;

  -- ========================================================================
  -- 2. HARDENED FINITE STATE MACHINE (Rule 3.1, 3.2, 3.3)
  -- ========================================================================
  -- Decoupled combinational process for auditability.
  -- ========================================================================
  p_fsm_next_state : process (w_trip, r_fault_latched, r_current_state) is
  begin

    -- Strict default fallback assignment
    w_next_state <= ST_SYSTEM_OK;

    if (r_current_state = ST_SYSTEM_OK) then
      -- A set latch with a healthy state can only be an upset. It is a fault,
      -- so the state follows it rather than leaving the bus open.
      if (w_trip = '1' or r_fault_latched = '1') then
        w_next_state <= ST_FAULT_TRIPPED;
      else
        w_next_state <= ST_SYSTEM_OK;
      end if;
    elsif (r_current_state = ST_FAULT_TRIPPED) then
      -- ASIL-D Lockdown: Once a core fault is tripped, the lockstep
      -- hardware refuses to recover until a full hardware cold-reset.
      w_next_state <= ST_FAULT_TRIPPED;
    else
      -- Defends against illegal states from bit-flips (Rule 3.1)
      w_next_state <= ST_FAULT_TRIPPED;
    end if;

  end process p_fsm_next_state;

  -- ========================================================================
  -- 3. SYNCHRONOUS REGISTER UPDATE (Rule 1.2, 1.4)
  -- ========================================================================
  p_fsm_sync : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_syn_i = '0') then
        r_current_state <= ST_SYSTEM_OK;
        r_fault_latched <= '0';
      else
        r_current_state <= w_next_state;

        -- Latch the fault signal permanently on mismatch or an illegal state
        if (w_fault_now = '1') then
          r_fault_latched <= '1';
        end if;
      end if;
    end if;

  end process p_fsm_sync;

  -- ========================================================================
  -- 4. SAFE INTERCEPT SIGNAL GENERATION & SYSTEM OUTPUT GATE
  -- ========================================================================
  -- Unconditionally drives safety lines and isolates faulty buses.
  -- ========================================================================
  -- nmi_fault_o follows the compare in the cycle it trips, which is what the
  -- startup self-test checks. fault_o comes from registers alone, so the settling
  -- of the compare cannot reach a pin through it (HSI FLT-01). Anything but the
  -- healthy encoding counts as a fault for both, and as the safe state.
  w_fault_reg <= '1' when (r_fault_latched = '1' or r_current_state /= ST_SYSTEM_OK) else
                 '0';

  -- Either one of the latch and the state is enough to report the fault, so an
  -- upset of the other cannot hide it (found by the formal proof, R2.1)
  nmi_fault_o  <= w_fault_reg or w_fault_now;
  fault_o      <= w_fault_reg;
  safe_state_o <= '1' when (r_current_state /= ST_SYSTEM_OK) else
                  '0';
  bus_valid_o  <= '1' when (r_current_state = ST_SYSTEM_OK) else
                  '0';

  -- System Gating: If system is operating normally, route Master Core A.
  -- If a fault occurs, isolate the system bus by driving flat zeros. That starts
  -- in the cycle the fault is found, so a store that the cores disagree on never
  -- reaches a peripheral. bus_valid_o stays with the registered state, because it
  -- reaches the CAN pin, and the compare can glitch while the buses settle. The
  -- system bus is only ever sampled on a clock edge.
  w_bus_open <= '1' when (r_current_state = ST_SYSTEM_OK and w_trip = '0') else
                '0';

  sys_bus_o.addr  <= core_a_bus_i.addr when (w_bus_open = '1') else
                     (others => '0');
  sys_bus_o.data  <= core_a_bus_i.data when (w_bus_open = '1') else
                     (others => '0');
  sys_bus_o.sel   <= core_a_bus_i.sel when (w_bus_open = '1') else
                     (others => '0');
  sys_bus_o.we    <= core_a_bus_i.we when (w_bus_open = '1') else
                     '0';
  sys_bus_o.valid <= core_a_bus_i.valid when (w_bus_open = '1') else
                     '0';

  -- ========================================================================
  -- 5. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Clocked assertion process: NMI within 2 cycles of mismatch, bus_valid
  -- deasserts, safe_state latches
  -- ========================================================================
  p_formal_asserts : process (clk_i) is

    variable v_mismatch_count : integer range 0 to 4;
    variable v_mismatch_seen  : std_logic;

  begin

    if rising_edge(clk_i) then
      if (rst_n_syn_i = '0') then
        v_mismatch_count := 0;
        v_mismatch_seen  := '0';
      else
        -- Property: an illegal state is reported, safe and closed at once
        if (w_state_illegal = '1') then
          assert nmi_fault_o = '1' and fault_o = '1' and safe_state_o = '1' and bus_valid_o = '0'
            report "FORMAL FAIL: illegal state not handled as a fault"
            severity error;
        end if;

        if (w_trip = '1') then
          v_mismatch_seen  := '1';
          v_mismatch_count := 0;
          -- Property: NMI asserted immediately on mismatch
          assert nmi_fault_o = '1'
            report "FORMAL FAIL: NMI not asserted on mismatch"
            severity error;
          -- Property: a bus cycle judged bad goes no further
          assert sys_bus_o.valid = '0'
            report "FORMAL FAIL: bad bus cycle reached the system bus"
            severity error;
        elsif (v_mismatch_seen = '1') then
          v_mismatch_count := v_mismatch_count + 1;
          -- Property: NMI latched within 2 cycles
          assert nmi_fault_o = '1'
            report "FORMAL FAIL: NMI not latched within 2 cycles"
            severity error;
          -- Property: bus_valid deasserted when fault active
          assert bus_valid_o = '0'
            report "FORMAL FAIL: bus_valid not deasserted on fault"
            severity error;
          -- Property: safe_state asserted when fault active
          assert safe_state_o = '1'
            report "FORMAL FAIL: safe_state not asserted on fault"
            severity error;
          if (v_mismatch_count >= 2) then
            v_mismatch_seen := '0';
          end if;
        end if;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
