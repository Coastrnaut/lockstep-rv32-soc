-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  ASIL-V Global Types Package
-- Module Name:  package_soc_types - package
-- Description:  Defines uniform communication structures, safe state encodings,
--               and system-wide constants for the ASIL-V platform.
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
    -- Safe State Encoding (High Hamming Distance)
    -- ------------------------------------------------------------------------
    -- Custom 8-bit vectors where a single bit flip cannot accidentally
    -- transition between valid states. Meets Rule 3.1.
    -- ------------------------------------------------------------------------
    subtype t_safe_state is std_logic_vector(7 downto 0);
    constant ST_SYSTEM_OK     : t_safe_state := X"5A"; -- "01011010"
    constant ST_FAULT_TRIPPED : t_safe_state := X"A5"; -- "10100101"

    -- ------------------------------------------------------------------------
    -- Watchdog Timeout Constant
    -- ------------------------------------------------------------------------
    constant C_WD_TIMEOUT : unsigned(15 downto 0) := to_unsigned(50000, 16);

end package package_soc_types;
