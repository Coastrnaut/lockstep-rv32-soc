-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  lockstep-rv32-soc Global Types Package
-- Module Name:  package_soc_types - package
-- Description:  Defines uniform communication structures, safe state encodings,
--               and system-wide constants for the lockstep-rv32-soc platform.
--
-- Traces to:    TSR_TYPES_001, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package package_soc_types is

    -- ------------------------------------------------------------------------
    -- System-wide generics
    -- ------------------------------------------------------------------------
    constant C_DATA_WIDTH : positive := 32;
    constant C_ADDR_WIDTH : positive := 32;

    -- ------------------------------------------------------------------------
    -- RISC-V Bus Record
    -- ------------------------------------------------------------------------
    -- Groups the standard processor bus into an auditable record to prevent
    -- messy port maps and ensure uniform interfaces across all safety blocks.
    -- ------------------------------------------------------------------------
    type t_rv_bus is record
        addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        data  : std_logic_vector(C_DATA_WIDTH-1 downto 0);
        we    : std_logic;
        valid : std_logic;
    end record t_rv_bus;

    -- ------------------------------------------------------------------------
    -- Peripheral Interface Record
    -- ------------------------------------------------------------------------
    -- Memory-mapped peripheral bus for safe routing to IO devices.
    -- ------------------------------------------------------------------------
    type t_periph_bus is record
        addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        wdata : std_logic_vector(C_DATA_WIDTH-1 downto 0);
        rdata : std_logic_vector(C_DATA_WIDTH-1 downto 0);
        we    : std_logic;
        re    : std_logic;
        ready : std_logic;
    end record t_periph_bus;

    -- ------------------------------------------------------------------------
    -- Safe State Encoding (High Hamming Distance)
    -- ------------------------------------------------------------------------
    -- Custom 8-bit vectors where a single bit flip cannot accidentally
    -- transition between valid states. Meets Rule 3.1.
    -- ------------------------------------------------------------------------
    subtype t_safe_state is std_logic_vector(7 downto 0);
    constant ST_SYSTEM_OK     : t_safe_state := X"5A"; -- "01011010"
    constant ST_FAULT_TRIPPED : t_safe_state := X"A5"; -- "10100101"

    -- ------------------------------------------------------------------------
    -- Watchdog Timing Constants
    -- ------------------------------------------------------------------------
    constant C_WD_MIN_COUNT : unsigned(15 downto 0) := to_unsigned(40000, 16);
    constant C_WD_MAX_COUNT : unsigned(15 downto 0) := to_unsigned(50000, 16);

end package package_soc_types;
