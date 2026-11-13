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
  constant c_data_width : positive := 32;
  constant c_addr_width : positive := 32;

  -- ------------------------------------------------------------------------
  -- RISC-V Bus Record
  -- ------------------------------------------------------------------------
  -- Groups the standard processor bus into an auditable record to prevent
  -- messy port maps and ensure uniform interfaces across all safety blocks.
  -- ------------------------------------------------------------------------

  type t_rv_bus is record
    addr : std_logic_vector(C_ADDR_WIDTH - 1 downto 0);
    data : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
    -- Byte enables: 1111 is a word store
    sel   : std_logic_vector(3 downto 0);
    we    : std_logic;
    valid : std_logic;
  end record t_rv_bus;

  -- ------------------------------------------------------------------------
  -- Bus Response Record
  -- ------------------------------------------------------------------------
  -- The one response to an accepted request (HSI section 8.1): read data, and
  -- exactly one of ack and err, in the cycle after the request was accepted.
  -- ------------------------------------------------------------------------

  type t_bus_rsp is record
    rdata : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
    ack   : std_logic;
    err   : std_logic;
  end record t_bus_rsp;

  -- ------------------------------------------------------------------------
  -- Core Input Record
  -- ------------------------------------------------------------------------
  -- Everything that changes on a core's inputs. Core B has to receive all of it
  -- late, or it stops being a copy of core A. A field added here reaches core B
  -- through temporal_diversity with the rest.
  -- ------------------------------------------------------------------------

  type t_core_inputs is record
    rst_n : std_logic;
    rdata : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
    ack   : std_logic;
    err   : std_logic;
    msi   : std_logic;
    mti   : std_logic;
    mei   : std_logic;
  end record t_core_inputs;

  -- ------------------------------------------------------------------------
  -- Peripheral Interface Record
  -- ------------------------------------------------------------------------
  -- Memory-mapped peripheral bus for safe routing to IO devices.
  -- ------------------------------------------------------------------------

  type t_periph_bus is record
    addr  : std_logic_vector(C_ADDR_WIDTH - 1 downto 0);
    wdata : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
    rdata : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
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

  -- "01011010"
  constant st_system_ok : t_safe_state := x"5A";

  -- "10100101"
  constant st_fault_tripped : t_safe_state := x"A5";

  -- ------------------------------------------------------------------------
  -- Watchdog Timing Constants
  -- ------------------------------------------------------------------------
  constant c_wd_min_count : unsigned(15 downto 0) := to_unsigned(40000, 16);
  constant c_wd_max_count : unsigned(15 downto 0) := to_unsigned(50000, 16);

  -- Only this value in the KICK register counts as a kick
  constant c_wd_kick_key : std_logic_vector(c_data_width - 1 downto 0) := x"0000DEAD";

  -- ------------------------------------------------------------------------
  -- Peripheral Address Map
  -- ------------------------------------------------------------------------
  -- Inside the 4K peripheral window: docs/safety/hsi_specification.md section 5.1
  -- ------------------------------------------------------------------------
  -- The ECC block's telemetry, as the diagnostic port shifts it out, first bit
  -- first: FIRST_INFO, FIRST_ADDR, FIRST_TIME, PATROL, then SBE_COUNT in 31:16
  -- and DBE_COUNT in 15:0 of the last word (HSI section 3.2)
  constant c_telemetry_bits : positive := 160;

  subtype t_telemetry is std_logic_vector(c_telemetry_bits - 1 downto 0);

  -- BEGIN GENERATED by tools/register_map.py: edit the table there
  constant c_can_id_addr         : std_logic_vector(c_addr_width - 1 downto 0) := x"40000300";
  constant c_can_dlc_addr        : std_logic_vector(c_addr_width - 1 downto 0) := x"40000304";
  constant c_can_data_addr       : std_logic_vector(c_addr_width - 1 downto 0) := x"40000308";
  constant c_can_status_addr     : std_logic_vector(c_addr_width - 1 downto 0) := x"4000030C";
  constant c_can_data_hi_addr    : std_logic_vector(c_addr_width - 1 downto 0) := x"40000310";
  constant c_can_tx_request_addr : std_logic_vector(c_addr_width - 1 downto 0) := x"40000314";
  constant c_can_rx_id_addr      : std_logic_vector(c_addr_width - 1 downto 0) := x"40000318";
  constant c_can_rx_info_addr    : std_logic_vector(c_addr_width - 1 downto 0) := x"4000031C";
  constant c_can_rx_data_addr    : std_logic_vector(c_addr_width - 1 downto 0) := x"40000320";
  constant c_can_rx_data_hi_addr : std_logic_vector(c_addr_width - 1 downto 0) := x"40000324";
  constant c_can_rx_status_addr  : std_logic_vector(c_addr_width - 1 downto 0) := x"40000328";
  constant c_can_rx_irq_en_addr  : std_logic_vector(c_addr_width - 1 downto 0) := x"4000032C";
  constant c_ram_base_addr       : std_logic_vector(c_addr_width - 1 downto 0) := x"20000000";
  constant c_ecc_sbe_count_addr  : std_logic_vector(c_addr_width - 1 downto 0) := x"40000100";
  constant c_ecc_dbe_count_addr  : std_logic_vector(c_addr_width - 1 downto 0) := x"40000104";
  constant c_ecc_syndrome_addr   : std_logic_vector(c_addr_width - 1 downto 0) := x"40000108";
  constant c_ecc_status_addr     : std_logic_vector(c_addr_width - 1 downto 0) := x"4000010C";
  constant c_ecc_first_info_addr : std_logic_vector(c_addr_width - 1 downto 0) := x"40000110";
  constant c_ecc_first_addr_addr : std_logic_vector(c_addr_width - 1 downto 0) := x"40000114";
  constant c_ecc_first_time_addr : std_logic_vector(c_addr_width - 1 downto 0) := x"40000118";
  constant c_ecc_patrol_addr     : std_logic_vector(c_addr_width - 1 downto 0) := x"4000011C";
  constant c_wd_kick_addr        : std_logic_vector(c_addr_width - 1 downto 0) := x"40000200";
  constant c_wd_status_addr      : std_logic_vector(c_addr_width - 1 downto 0) := x"40000204";
  constant c_wd_reset_src_addr   : std_logic_vector(c_addr_width - 1 downto 0) := x"40000208";
  constant c_uart_tx_data_addr   : std_logic_vector(c_addr_width - 1 downto 0) := x"40000400";
  constant c_uart_status_addr    : std_logic_vector(c_addr_width - 1 downto 0) := x"40000404";
  constant c_uart_parity_addr    : std_logic_vector(c_addr_width - 1 downto 0) := x"40000408";

-- END GENERATED

end package package_soc_types;
