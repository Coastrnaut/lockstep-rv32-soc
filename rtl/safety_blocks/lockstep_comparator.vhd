-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Dual-Core Lockstep (DCLS) Core Comparator
-- Module Name:  lockstep_comparator - rtl
-- Description:  Monitors two identical RISC-V cores cycle-by-cycle.
--               Flashes an immediate, latching NMI on any output bus mismatch.
--               Uses high-Hamming-distance safe state encoding.
--
-- Traces to:    TSR_LOCKSTEP_042, TSR_SAFETY_GATE_001
-- Cores:        Compatible with NEORV32 / Generic 32-bit RISC-V cores
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.package_soc_types.all;

entity lockstep_comparator is
    port (
        -- --------------------------------------------------------------------
        -- Clock & Reset Domain (Rule 1.1, 1.2, 1.4)
        -- --------------------------------------------------------------------
        clk_i           : in  std_logic; -- Global system clock
        rst_n_syn_i     : in  std_logic; -- Synchronously de-asserted reset

        -- --------------------------------------------------------------------
        -- Core A Interface (Master Core)
        -- --------------------------------------------------------------------
        core_a_bus_i    : in  t_rv_bus;

        -- --------------------------------------------------------------------
        -- Core B Interface (Checker Core)
        -- --------------------------------------------------------------------
        core_b_bus_i    : in  t_rv_bus;

        -- --------------------------------------------------------------------
        -- Safety Supervisor & Actuator Intercept
        -- --------------------------------------------------------------------
        nmi_fault_o     : out std_logic; -- Latching Non-Maskable Interrupt
        safe_state_o    : out std_logic; -- Force vehicle actuators to safe mode
        bus_valid_o     : out std_logic; -- Hardware transaction validation gate

        -- System Outputs (Only passes Master Core signals forward if safe)
        sys_bus_o       : out t_rv_bus
    );
end entity lockstep_comparator;

architecture rtl of lockstep_comparator is

    -- ISO 26262 Automated Traceability Attributes
    attribute requirement_id : string;
    attribute requirement_id of rtl : architecture is "TSR_LOCKSTEP_042, TSR_SAFETY_GATE_001";

    -- Safe State Encoding (Rule 3.1)
    signal r_current_state : t_safe_state := ST_SYSTEM_OK;
    signal w_next_state    : t_safe_state;

    -- Internal monitoring signals
    signal w_mismatch_detected : std_logic;
    signal r_fault_latched     : std_logic;

begin

    -- ========================================================================
    -- 1. COMBINATIONAL BUS COMPARATOR (Rule 2.1, 2.2, 2.3)
    -- ========================================================================
    -- Explicit sensitivity list for formal verification tool compatibility.
    -- ========================================================================
    p_bus_compare : process(
        core_a_bus_i.addr,  core_b_bus_i.addr,
        core_a_bus_i.data,  core_b_bus_i.data,
        core_a_bus_i.we,    core_b_bus_i.we,
        core_a_bus_i.valid, core_b_bus_i.valid
    )
    begin
        -- Default assignments to prevent hardware latches (Rule 2.1)
        w_mismatch_detected <= '0';

        if (core_a_bus_i.addr  /= core_b_bus_i.addr)  or
           (core_a_bus_i.data  /= core_b_bus_i.data)  or
           (core_a_bus_i.we    /= core_b_bus_i.we)    or
           (core_a_bus_i.valid /= core_b_bus_i.valid) then

            w_mismatch_detected <= '1';
        end if;
    end process p_bus_compare;


    -- ========================================================================
    -- 2. HARDENED FINITE STATE MACHINE (Rule 3.1, 3.2, 3.3)
    -- ========================================================================
    -- Decoupled combinational process for auditability.
    -- ========================================================================
    p_fsm_next_state : process(w_mismatch_detected, r_current_state)
    begin
        -- Strict default fallback assignment
        w_next_state <= ST_SYSTEM_OK;

        if r_current_state = ST_SYSTEM_OK then
            if w_mismatch_detected = '1' then
                w_next_state <= ST_FAULT_TRIPPED;
            else
                w_next_state <= ST_SYSTEM_OK;
            end if;

        elsif r_current_state = ST_FAULT_TRIPPED then
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
    p_fsm_sync : process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n_syn_i = '0' then
                r_current_state <= ST_SYSTEM_OK;
                r_fault_latched <= '0';
            else
                r_current_state <= w_next_state;

                -- Latch the fault signal permanently on mismatch
                if w_mismatch_detected = '1' then
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
    nmi_fault_o   <= r_fault_latched or w_mismatch_detected;
    safe_state_o  <= '1' when (r_current_state = ST_FAULT_TRIPPED) else '0';
    bus_valid_o   <= '1' when (r_current_state = ST_SYSTEM_OK) else '0';

    -- System Gating: If system is operating normally, route Master Core A.
    -- If a fault occurs, isolate the system bus by driving flat zeros.
    sys_bus_o.addr  <= core_a_bus_i.addr  when (r_current_state = ST_SYSTEM_OK) else (others => '0');
    sys_bus_o.data  <= core_a_bus_i.data  when (r_current_state = ST_SYSTEM_OK) else (others => '0');
    sys_bus_o.we    <= core_a_bus_i.we    when (r_current_state = ST_SYSTEM_OK) else '0';
    sys_bus_o.valid <= core_a_bus_i.valid when (r_current_state = ST_SYSTEM_OK) else '0';

end architecture rtl;
