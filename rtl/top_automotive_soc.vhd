-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  ASIL-V Reference Hardware Platform
-- Module Name:  top_automotive_soc - structural
-- Description:  Master structural fabric. Instantiates two parallel NEORV32
--               RISC-V cores (Master & Checker), routing their external bus
--               signals into the lockstep comparator safety block.
--
-- Traces to:    TSR_LOCKSTEP_001, TSR_SAFETY_GATE_001
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Import custom automotive system types and records
library lockstep;
use lockstep.package_soc_types.all;

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
        uart_tx_o       : out std_logic; -- Safe UART diagnostic output

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

    -- Peripheral diagnostic signals
    signal w_can_busy     : std_logic;
    signal w_uart_busy    : std_logic;
    signal w_uart_error   : std_logic;

    -- XBus signals from each NEORV32 instance
    signal w_core_a_xbus_addr : std_logic_vector(31 downto 0);
    signal w_core_b_xbus_addr : std_logic_vector(31 downto 0);
    signal w_core_a_xbus_data : std_logic_vector(31 downto 0);
    signal w_core_b_xbus_data : std_logic_vector(31 downto 0);
    signal w_core_a_xbus_we   : std_logic;
    signal w_core_b_xbus_we   : std_logic;
    signal w_core_a_xbus_stb  : std_logic;
    signal w_core_b_xbus_stb  : std_logic;

    -- Reset outputs from NEORV32
    signal w_core_a_rstn_ocd : std_logic;
    signal w_core_b_rstn_ocd : std_logic;
    signal w_core_a_rstn_wdt : std_logic;
    signal w_core_b_rstn_wdt : std_logic;

    -- Trace ports (always present)
    signal w_core_a_trace : std_logic_vector(31 downto 0);
    signal w_core_b_trace : std_logic_vector(31 downto 0);

begin

    -- ========================================================================
    -- 1. BUS RECORD PACKAGING
    -- ========================================================================
    -- Aggregate XBus output wires into clean records for the lockstep engine.
    -- ========================================================================
    w_core_a_bus.addr   <= w_core_a_xbus_addr;
    w_core_a_bus.data   <= w_core_a_xbus_data;
    w_core_a_bus.we     <= w_core_a_xbus_we;
    w_core_a_bus.valid  <= w_core_a_xbus_stb;

    w_core_b_bus.addr   <= w_core_b_xbus_addr;
    w_core_b_bus.data   <= w_core_b_xbus_data;
    w_core_b_bus.we     <= w_core_b_xbus_we;
    w_core_b_bus.valid  <= w_core_b_xbus_stb;

    -- ========================================================================
    -- 2. INSTANCE: MASTER CPU (CORE A)
    -- ========================================================================
    i_cpu_master : entity neorv32.neorv32_top
        generic map (
            -- General
            CLOCK_FREQUENCY   => 50_000_000,
            TRACE_PORT_EN     => false,
            DUAL_CORE_EN      => false,

            -- Boot
            BOOT_MODE_SELECT  => 0,
            BOOT_ADDR_CUSTOM  => x"00000000",

            -- OCD
            OCD_EN            => false,
            OCD_NUM_HW_TRIGGERS => 0,
            OCD_AUTHENTICATION => false,
            OCD_JEDEC_ID      => (others => '0'),

            -- RISC-V Extensions
            RISCV_ISA_C       => false,
            RISCV_ISA_E       => false,
            RISCV_ISA_M       => false,
            RISCV_ISA_U       => false,
            RISCV_ISA_Zaamo   => false,
            RISCV_ISA_Zalrsc  => false,
            RISCV_ISA_Zba     => false,
            RISCV_ISA_Zbb     => false,
            RISCV_ISA_Zbc     => false,
            RISCV_ISA_Zbkb    => false,
            RISCV_ISA_Zbkc    => false,
            RISCV_ISA_Zbkx    => false,
            RISCV_ISA_Zbs     => false,
            RISCV_ISA_Zcb     => false,
            RISCV_ISA_Zcmop   => false,
            RISCV_ISA_Zfinx   => false,
            RISCV_ISA_Zibi    => false,
            RISCV_ISA_Zicntr  => false,
            RISCV_ISA_Zicond  => false,
            RISCV_ISA_Zihpm   => false,
            RISCV_ISA_Zimop   => false,
            RISCV_ISA_Zknd    => false,
            RISCV_ISA_Zkne    => false,
            RISCV_ISA_Zknh    => false,
            RISCV_ISA_Zksed   => false,
            RISCV_ISA_Zksh    => false,
            RISCV_ISA_Zmmul   => false,
            RISCV_ISA_Smcntrpmf => false,
            RISCV_ISA_Xcfu    => false,

            -- Tuning
            CPU_CONSTT_BR_EN  => false,
            CPU_FAST_MUL_EN   => false,
            CPU_FAST_MUL_REGS => 1,
            CPU_FAST_SHIFT_EN => false,
            CPU_RF_ARCH_SEL   => 0,

            -- PMP
            PMP_NUM_REGIONS   => 0,
            PMP_MIN_GRANULARITY => 4,
            PMP_TOR_MODE_EN   => false,
            PMP_NAP_MODE_EN   => false,

            -- HPM
            HPM_NUM_CNTS      => 0,
            HPM_CNT_WIDTH     => 64,

            -- IMEM
            IMEM_EN           => true,
            IMEM_BASE         => x"00000000",
            IMEM_SIZE         => 16384,
            IMEM_OUTREG_EN    => false,

            -- DMEM
            DMEM_EN           => false,
            DMEM_BASE         => x"80000000",
            DMEM_SIZE         => 8192,
            DMEM_OUTREG_EN    => false,

            -- Caches
            ICACHE_EN         => false,
            ICACHE_NUM_BLOCKS => 4,
            DCACHE_EN         => false,
            DCACHE_NUM_BLOCKS => 4,
            CACHE_BLOCK_SIZE  => 64,
            CACHE_BURSTS_EN   => true,
            CACHE_UC_BASE     => x"F0000000",

            -- SMC
            SMC_EN            => false,
            SMC_BASE          => x"E0000000",

            -- XBus
            XBUS_EN           => true,
            XBUS_TIMEOUT      => 2048,
            XBUS_REGSTAGE_EN  => false,

            -- GPIO
            IO_GPIO_NUM       => 0,
            IO_GPIO_DIR_EN    => false,

            -- CLINT
            IO_CLINT_EN       => false,

            -- UARTs
            IO_UART0_EN       => false,
            IO_UART0_RX_FIFO  => 1,
            IO_UART0_TX_FIFO  => 1,
            IO_UART1_EN       => false,
            IO_UART1_RX_FIFO  => 1,
            IO_UART1_TX_FIFO  => 1,

            -- SPI/SDI
            IO_SPI_EN         => false,
            IO_SPI_FIFO       => 1,
            IO_SDI_EN         => false,
            IO_SDI_FIFO       => 1,

            -- TWI/TWD
            IO_TWI_EN         => false,
            IO_TWI_FIFO       => 1,
            IO_TWD_EN         => false,
            IO_TWD_RX_FIFO    => 1,
            IO_TWD_TX_FIFO    => 1,

            -- PWM
            IO_PWM_NUM        => 0,

            -- WDT
            IO_WDT_EN         => false,

            -- TRNG
            IO_TRNG_EN        => false,
            IO_TRNG_FIFO      => 1,
            IO_TRNG_NUM_RO    => 3,
            IO_TRNG_NUM_INV   => 5,
            IO_TRNG_NUM_RBIT  => 64,

            -- CFS
            IO_CFS_EN         => false,

            -- NEOLED
            IO_NEOLED_EN      => false,
            IO_NEOLED_TX_FIFO => 1,

            -- GPTMR
            IO_GPTMR_NUM      => 0,

            -- ONEWIRE
            IO_ONEWIRE_EN     => false,
            IO_ONEWIRE_FIFO   => 1,

            -- DMA
            IO_DMA_EN         => false,
            IO_DMA_DSC_FIFO   => 4,

            -- SLINK
            IO_SLINK_EN       => false,
            IO_SLINK_RX_FIFO  => 1,
            IO_SLINK_TX_FIFO  => 1,

            -- TRACER
            IO_TRACER_EN      => false,
            IO_TRACER_BUFFER  => 1,
            IO_TRACER_SIMLOG_EN => false
        )
        port map (
            -- Global
            clk_i          => clk_i,
            rstn_i         => rst_n_i,
            rstn_ocd_o     => w_core_a_rstn_ocd,
            rstn_wdt_o     => w_core_a_rstn_wdt,

            -- Trace
            trace_cpu0_o   => open,
            trace_cpu1_o   => open,

            -- JTAG (disabled)
            jtag_tck_i     => '0',
            jtag_tdi_i     => '0',
            jtag_tdo_o     => open,
            jtag_tms_i     => '0',

            -- SMC (disabled)
            smc_ioen_o     => open,
            smc_sck_o      => open,
            smc_csn_o      => open,
            smc_sdo_o      => open,
            smc_sdi_i      => '0',

            -- XBus
            xbus_adr_o     => w_core_a_xbus_addr,
            xbus_dat_o     => w_core_a_xbus_data,
            xbus_cti_o     => open,
            xbus_tag_o     => open,
            xbus_we_o      => w_core_a_xbus_we,
            xbus_sel_o     => open,
            xbus_stb_o     => w_core_a_xbus_stb,
            xbus_cyc_o     => open,
            xbus_dat_i     => (others => '0'),
            xbus_ack_i     => w_bus_valid,
            xbus_err_i     => '0',

            -- SLINK (disabled)
            slink_rx_dat_i => (others => '0'),
            slink_rx_src_i => (others => '0'),
            slink_rx_val_i => '0',
            slink_rx_lst_i => '0',
            slink_rx_rdy_o => open,
            slink_tx_dat_o => open,
            slink_tx_dst_o => open,
            slink_tx_val_o => open,
            slink_tx_lst_o => open,
            slink_tx_rdy_i => '0',

            -- GPIO (disabled)
            gpio_dir_o     => open,
            gpio_o         => open,
            gpio_i         => (others => '0'),

            -- UART0/1 (disabled)
            uart0_txd_o    => open,
            uart0_rxd_i    => '0',
            uart0_rtsn_o   => open,
            uart0_ctsn_i   => '0',
            uart1_txd_o    => open,
            uart1_rxd_i    => '0',
            uart1_rtsn_o   => open,
            uart1_ctsn_i   => '0',

            -- SPI (disabled)
            spi_clk_o      => open,
            spi_dat_o      => open,
            spi_dat_i      => '0',
            spi_csn_o      => open,

            -- SDI (disabled)
            sdi_clk_i      => '0',
            sdi_dat_o      => open,
            sdi_dat_i      => '0',
            sdi_csn_i      => '1',

            -- TWI (disabled)
            twi_sda_i      => '1',
            twi_sda_o      => open,
            twi_scl_i      => '1',
            twi_scl_o      => open,

            -- TWD (disabled)
            twd_sda_i      => '1',
            twd_sda_o      => open,
            twd_scl_i      => '1',

            -- ONEWIRE (disabled)
            onewire_i      => '1',
            onewire_o      => open,

            -- PWM (disabled)
            pwm_o          => open,

            -- CFS (disabled)
            cfs_in_i       => (others => '0'),
            cfs_out_o      => open,

            -- NEOLED (disabled)
            neoled_o       => open,

            -- CLINT (disabled)
            mtime_time_o   => open,

            -- Interrupts
            irq_msi_i      => '0',
            irq_mti_i      => '0',
            irq_mei_i      => w_nmi
        );

    -- ========================================================================
    -- 3. INSTANCE: MIRROR CHECKER CPU (CORE B)
    -- ========================================================================
    i_cpu_checker : entity neorv32.neorv32_top
        generic map (
            -- General
            CLOCK_FREQUENCY   => 50_000_000,
            TRACE_PORT_EN     => false,
            DUAL_CORE_EN      => false,

            -- Boot
            BOOT_MODE_SELECT  => 0,
            BOOT_ADDR_CUSTOM  => x"00000000",

            -- OCD
            OCD_EN            => false,
            OCD_NUM_HW_TRIGGERS => 0,
            OCD_AUTHENTICATION => false,
            OCD_JEDEC_ID      => (others => '0'),

            -- RISC-V Extensions (same as Core A)
            RISCV_ISA_C       => false,
            RISCV_ISA_E       => false,
            RISCV_ISA_M       => false,
            RISCV_ISA_U       => false,
            RISCV_ISA_Zaamo   => false,
            RISCV_ISA_Zalrsc  => false,
            RISCV_ISA_Zba     => false,
            RISCV_ISA_Zbb     => false,
            RISCV_ISA_Zbc     => false,
            RISCV_ISA_Zbkb    => false,
            RISCV_ISA_Zbkc    => false,
            RISCV_ISA_Zbkx    => false,
            RISCV_ISA_Zbs     => false,
            RISCV_ISA_Zcb     => false,
            RISCV_ISA_Zcmop   => false,
            RISCV_ISA_Zfinx   => false,
            RISCV_ISA_Zibi    => false,
            RISCV_ISA_Zicntr  => false,
            RISCV_ISA_Zicond  => false,
            RISCV_ISA_Zihpm   => false,
            RISCV_ISA_Zimop   => false,
            RISCV_ISA_Zknd    => false,
            RISCV_ISA_Zkne    => false,
            RISCV_ISA_Zknh    => false,
            RISCV_ISA_Zksed   => false,
            RISCV_ISA_Zksh    => false,
            RISCV_ISA_Zmmul   => false,
            RISCV_ISA_Smcntrpmf => false,
            RISCV_ISA_Xcfu    => false,

            -- Tuning
            CPU_CONSTT_BR_EN  => false,
            CPU_FAST_MUL_EN   => false,
            CPU_FAST_MUL_REGS => 1,
            CPU_FAST_SHIFT_EN => false,
            CPU_RF_ARCH_SEL   => 0,

            -- PMP
            PMP_NUM_REGIONS   => 0,
            PMP_MIN_GRANULARITY => 4,
            PMP_TOR_MODE_EN   => false,
            PMP_NAP_MODE_EN   => false,

            -- HPM
            HPM_NUM_CNTS      => 0,
            HPM_CNT_WIDTH     => 64,

            -- IMEM
            IMEM_EN           => true,
            IMEM_BASE         => x"00000000",
            IMEM_SIZE         => 16384,
            IMEM_OUTREG_EN    => false,

            -- DMEM
            DMEM_EN           => false,
            DMEM_BASE         => x"80000000",
            DMEM_SIZE         => 8192,
            DMEM_OUTREG_EN    => false,

            -- Caches
            ICACHE_EN         => false,
            ICACHE_NUM_BLOCKS => 4,
            DCACHE_EN         => false,
            DCACHE_NUM_BLOCKS => 4,
            CACHE_BLOCK_SIZE  => 64,
            CACHE_BURSTS_EN   => true,
            CACHE_UC_BASE     => x"F0000000",

            -- SMC
            SMC_EN            => false,
            SMC_BASE          => x"E0000000",

            -- XBus
            XBUS_EN           => true,
            XBUS_TIMEOUT      => 2048,
            XBUS_REGSTAGE_EN  => false,

            -- GPIO
            IO_GPIO_NUM       => 0,
            IO_GPIO_DIR_EN    => false,

            -- CLINT
            IO_CLINT_EN       => false,

            -- UARTs
            IO_UART0_EN       => false,
            IO_UART0_RX_FIFO  => 1,
            IO_UART0_TX_FIFO  => 1,
            IO_UART1_EN       => false,
            IO_UART1_RX_FIFO  => 1,
            IO_UART1_TX_FIFO  => 1,

            -- SPI/SDI
            IO_SPI_EN         => false,
            IO_SPI_FIFO       => 1,
            IO_SDI_EN         => false,
            IO_SDI_FIFO       => 1,

            -- TWI/TWD
            IO_TWI_EN         => false,
            IO_TWI_FIFO       => 1,
            IO_TWD_EN         => false,
            IO_TWD_RX_FIFO    => 1,
            IO_TWD_TX_FIFO    => 1,

            -- PWM
            IO_PWM_NUM        => 0,

            -- WDT
            IO_WDT_EN         => false,

            -- TRNG
            IO_TRNG_EN        => false,
            IO_TRNG_FIFO      => 1,
            IO_TRNG_NUM_RO    => 3,
            IO_TRNG_NUM_INV   => 5,
            IO_TRNG_NUM_RBIT  => 64,

            -- CFS
            IO_CFS_EN         => false,

            -- NEOLED
            IO_NEOLED_EN      => false,
            IO_NEOLED_TX_FIFO => 1,

            -- GPTMR
            IO_GPTMR_NUM      => 0,

            -- ONEWIRE
            IO_ONEWIRE_EN     => false,
            IO_ONEWIRE_FIFO   => 1,

            -- DMA
            IO_DMA_EN         => false,
            IO_DMA_DSC_FIFO   => 4,

            -- SLINK
            IO_SLINK_EN       => false,
            IO_SLINK_RX_FIFO  => 1,
            IO_SLINK_TX_FIFO  => 1,

            -- TRACER
            IO_TRACER_EN      => false,
            IO_TRACER_BUFFER  => 1,
            IO_TRACER_SIMLOG_EN => false
        )
        port map (
            -- Global
            clk_i          => clk_i,
            rstn_i         => rst_n_i,
            rstn_ocd_o     => w_core_b_rstn_ocd,
            rstn_wdt_o     => w_core_b_rstn_wdt,

            -- Trace
            trace_cpu0_o   => open,
            trace_cpu1_o   => open,

            -- JTAG (disabled)
            jtag_tck_i     => '0',
            jtag_tdi_i     => '0',
            jtag_tdo_o     => open,
            jtag_tms_i     => '0',

            -- SMC (disabled)
            smc_ioen_o     => open,
            smc_sck_o      => open,
            smc_csn_o      => open,
            smc_sdo_o      => open,
            smc_sdi_i      => '0',

            -- XBus
            xbus_adr_o     => w_core_b_xbus_addr,
            xbus_dat_o     => w_core_b_xbus_data,
            xbus_cti_o     => open,
            xbus_tag_o     => open,
            xbus_we_o      => w_core_b_xbus_we,
            xbus_sel_o     => open,
            xbus_stb_o     => w_core_b_xbus_stb,
            xbus_cyc_o     => open,
            xbus_dat_i     => (others => '0'),
            xbus_ack_i     => w_bus_valid,
            xbus_err_i     => '0',

            -- SLINK (disabled)
            slink_rx_dat_i => (others => '0'),
            slink_rx_src_i => (others => '0'),
            slink_rx_val_i => '0',
            slink_rx_lst_i => '0',
            slink_rx_rdy_o => open,
            slink_tx_dat_o => open,
            slink_tx_dst_o => open,
            slink_tx_val_o => open,
            slink_tx_lst_o => open,
            slink_tx_rdy_i => '0',

            -- GPIO (disabled)
            gpio_dir_o     => open,
            gpio_o         => open,
            gpio_i         => (others => '0'),

            -- UART0/1 (disabled)
            uart0_txd_o    => open,
            uart0_rxd_i    => '0',
            uart0_rtsn_o   => open,
            uart0_ctsn_i   => '0',
            uart1_txd_o    => open,
            uart1_rxd_i    => '0',
            uart1_rtsn_o   => open,
            uart1_ctsn_i   => '0',

            -- SPI (disabled)
            spi_clk_o      => open,
            spi_dat_o      => open,
            spi_dat_i      => '0',
            spi_csn_o      => open,

            -- SDI (disabled)
            sdi_clk_i      => '0',
            sdi_dat_o      => open,
            sdi_dat_i      => '0',
            sdi_csn_i      => '1',

            -- TWI (disabled)
            twi_sda_i      => '1',
            twi_sda_o      => open,
            twi_scl_i      => '1',
            twi_scl_o      => open,

            -- TWD (disabled)
            twd_sda_i      => '1',
            twd_sda_o      => open,
            twd_scl_i      => '1',

            -- ONEWIRE (disabled)
            onewire_i      => '1',
            onewire_o      => open,

            -- PWM (disabled)
            pwm_o          => open,

            -- CFS (disabled)
            cfs_in_i       => (others => '0'),
            cfs_out_o      => open,

            -- NEOLED (disabled)
            neoled_o       => open,

            -- CLINT (disabled)
            mtime_time_o   => open,

            -- Interrupts
            irq_msi_i      => '0',
            irq_mti_i      => '0',
            irq_mei_i      => w_nmi
        );

    -- ========================================================================
    -- 4. INSTANCE: HARDENED DUAL-CORE LOCKSTEP COMPARATOR
    -- ========================================================================
    i_lockstep_gate : entity lockstep.lockstep_comparator
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
    i_automotive_can : entity lockstep.automotive_can_controller
        port map (
            clk_i      => clk_i,
            rst_n_i    => rst_n_i,
            bus_i      => w_safe_sys_bus,
            bus_ok_i   => w_bus_valid,
            can_tx_o   => can_tx_o,
            can_rx_i   => can_rx_i,
            can_busy_o => w_can_busy
        );

    -- ========================================================================
    -- 6. SAFE UART DIAGNOSTIC INTERFACE
    -- ========================================================================
    i_safe_uart : entity lockstep.safe_uart
        port map (
            clk_i      => clk_i,
            rst_n_i    => rst_n_i,
            bus_i      => w_safe_sys_bus,
            bus_ok_i   => w_bus_valid,
            uart_tx_o  => uart_tx_o,
            uart_busy_o  => w_uart_busy,
            uart_error_o => w_uart_error
        );

end architecture structural;
