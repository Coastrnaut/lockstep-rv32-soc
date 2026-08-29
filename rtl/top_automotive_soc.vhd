-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  ASIL-V Reference Hardware Platform
-- Module Name:  top_automotive_soc - structural
-- Description:  Master structural fabric. Instantiates two parallel NEORV32
--               RISC-V cores (Master & Checker), routing their internal memory
--               buses into the lockstep comparator safety block.
--
-- Traces to:    TSR_LOCKSTEP_001, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Import custom automotive system types and records
library work;
use work.package_soc_types.all;

-- Explicitly declare the compiled NEORV32 library containing the submodule IPs
library neorv32;

entity top_automotive_soc is
    port (
        -- --------------------------------------------------------------------
        -- Global Clock and Reset System
        -- --------------------------------------------------------------------
        clk_i           : in  std_logic; -- Main system clock string
        rst_n_i         : in  std_logic; -- External master hardware reset

        -- --------------------------------------------------------------------
        -- Functional Automotive Interfaces
        -- --------------------------------------------------------------------
        can_tx_o        : out std_logic; -- Hardened CAN-Bus transmission line
        can_rx_i        : in  std_logic; -- Hardened CAN-Bus reception line

        -- --------------------------------------------------------------------
        -- Safety Supervisor & Actuator Isolation Pins
        -- --------------------------------------------------------------------
        nmi_fault_o     : out std_logic; -- Diagnostic non-maskable interrupt flag
        actuator_safe_o : out std_logic  -- Hardwired actuator lockdown control
    );
end entity top_automotive_soc;

architecture structural of top_automotive_soc is

    -- Traceability attribute tracking for ISO 26262 audit pipelines
    attribute requirement_id : string;
    attribute requirement_id of structural : architecture is "TSR_LOCKSTEP_001";

    -- Interconnect buses structured as explicit records to prevent routing bugs
    signal w_core_a_bus   : t_rv_bus;
    signal w_core_b_bus   : t_rv_bus;
    signal w_safe_sys_bus : t_rv_bus;

    -- Internal safety status tracking wires
    signal w_nmi          : std_logic;
    signal w_bus_valid    : std_logic;

    -- Local signal maps to catch individual flat port lines out of NEORV32 instances
    signal w_core_a_addr  : std_logic_vector(31 downto 0);
    signal w_core_b_addr  : std_logic_vector(31 downto 0);
    signal w_core_a_data  : std_logic_vector(31 downto 0);
    signal w_core_b_data  : std_logic_vector(31 downto 0);
    signal w_core_a_we    : std_logic;
    signal w_core_b_we    : std_logic;
    signal w_core_a_valid : std_logic;
    signal w_core_b_valid : std_logic;

begin

    -- ========================================================================
    -- 1. BUS RECORD PACKAGING
    -- ========================================================================
    -- Aggregates the standard individual output wires coming out of the core
    -- instances into clean, auditable records for the lockstep safety engine.
    -- ========================================================================
    w_core_a_bus.addr   <= w_core_a_addr;
    w_core_a_bus.data   <= w_core_a_data;
    w_core_a_bus.we     <= w_core_a_we;
    w_core_a_bus.valid  <= w_core_a_valid;

    w_core_b_bus.addr   <= w_core_b_addr;
    w_core_b_bus.data   <= w_core_b_data;
    w_core_b_bus.we     <= w_core_b_we;
    w_core_b_bus.valid  <= w_core_b_valid;

    -- ========================================================================
    -- 2. INSTANCE: MASTER CPU (CORE A)
    -- ========================================================================
    i_cpu_master : entity neorv32.neorv32_top
        generic map (
            CLOCK_FREQUENCY   => 50_000_000, -- 50 MHz Automotive baseline
            INT_BOOTLOADER_EN => false,      -- Boot directly from flash
            IO_GPIO_NUM       => 0,          -- Unused for raw computational core
            MEM_INT_IMEM_EN   => true,       -- Enable internal instruction memory
            MEM_INT_IMEM_SIZE => 16384       -- 16 KB Boot Cache
        )
        port map (
            -- Global Signals
            clk_i          => clk_i,
            rstn_i         => rst_n_i,

            -- Wishbone External Memory Bus Port Maps
            wb_adr_o       => w_core_a_addr,
            wb_dat_o       => w_core_a_data,
            wb_we_o        => w_core_a_we,
            wb_stb_o       => w_core_a_valid,
            wb_dat_i       => (others => '0'), -- Read lines handled downstream
            wb_ack_i       => w_bus_valid,     -- Only acknowledge if safety gate clears

            -- Custom External Interrupts
            ext_irq_i      => w_nmi            -- Feed the safety latch directly back as NMI
        );

    -- ========================================================================
    -- 3. INSTANCE: MIRROR CHECKER CPU (CORE B)
    -- ========================================================================
    -- Exact identical hardware instance. Receives identical inputs. Output
    -- lines are kept separate to feed exclusively into the safety comparator.
    -- ========================================================================
    i_cpu_checker : entity neorv32.neorv32_top
        generic map (
            CLOCK_FREQUENCY   => 50_000_000,
            INT_BOOTLOADER_EN => false,
            IO_GPIO_NUM       => 0,
            MEM_INT_IMEM_EN   => true,
            MEM_INT_IMEM_SIZE => 16384
        )
        port map (
            -- Global Signals
            clk_i          => clk_i,
            rstn_i         => rst_n_i,

            -- Wishbone External Memory Bus Port Maps
            wb_adr_o       => w_core_b_addr,
            wb_dat_o       => w_core_b_data,
            wb_we_o        => w_core_b_we,
            wb_stb_o       => w_core_b_valid,
            wb_dat_i       => (others => '0'),
            wb_ack_i       => w_bus_valid,     -- Synced lockstep clock gating

            -- Custom External Interrupts
            ext_irq_i      => w_nmi
        );

    -- ========================================================================
    -- 4. INSTANCE: HARDENED DUAL-CORE LOCKSTEP COMPARATOR
    -- ========================================================================
    -- Monitors cycle-by-cycle. Drops validity immediately on any mismatch.
    -- ========================================================================
    i_lockstep_gate : entity work.lockstep_comparator
        port map (
            clk_i        => clk_i,
            rst_n_syn_i  => rst_n_i,

            -- Core Feeders
            core_a_bus_i => w_core_a_bus,
            core_b_bus_i => w_core_b_bus,

            -- Safety Monitoring Outputs
            nmi_fault_o  => w_nmi,
            safe_state_o => actuator_safe_o,

            -- Gated System Infrastructure Connections
            sys_bus_o    => w_safe_sys_bus,
            bus_valid_o  => w_bus_valid
        );

    -- ========================================================================
    -- 5. AUTOMOTIVE BUS CONTROLLER INTEGRATION
    -- ========================================================================
    -- Only receives commands if the lockstep core validates the current
    -- bus state transaction.
    -- ========================================================================
    i_automotive_can : entity work.automotive_can_controller
        port map (
            clk_i      => clk_i,
            rst_n_i    => rst_n_i,
            bus_i      => w_safe_sys_bus,  -- Connects to the filtered safety bus
            bus_ok_i   => w_bus_valid,     -- Hardware transaction validation gate
            can_tx_o   => can_tx_o,
            can_rx_i   => can_rx_i
        );

end architecture structural;
