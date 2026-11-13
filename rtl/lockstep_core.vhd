-- ============================================================================
-- Module Name:  lockstep_core - structural
-- Description:  One NEORV32 core as the SoC uses it, for both lockstep cores.
--               The configuration is written once here, so the two cores
--               cannot be configured apart (roadmap R4.3). Only the XBus, the
--               three interrupts and the trace port leave; every other
--               NEORV32 feature is off, its inputs tied and its outputs open.
--
--               The ports keep NEORV32's names, so a bench reaches a core's
--               bus inputs as i_cpu_master.xbus_dat_i, and its internals
--               under i_cpu_master.i_neorv32.
--
-- Traces to:    TSR_LOCKSTEP_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library neorv32;
  use neorv32.neorv32_package.all;

entity lockstep_core is
  generic (
    -- NEORV32 boot source: 0 = bootloader, 1 = custom address, 2 = IMEM image
    boot_mode_select : natural range 0 to 2 := 0;
    -- Execution trace port, for verification only (roadmap R2.2)
    trace_port_en : boolean := false
  );
  port (
    clk_i  : in    std_ulogic;
    rstn_i : in    std_ulogic;

    -- XBus request; the cycle tag, burst type and cycle line are not used
    xbus_adr_o : out   std_ulogic_vector(31 downto 0);
    xbus_dat_o : out   std_ulogic_vector(31 downto 0);
    xbus_we_o  : out   std_ulogic;
    xbus_sel_o : out   std_ulogic_vector(3 downto 0);
    xbus_stb_o : out   std_ulogic;

    -- XBus response
    xbus_dat_i : in    std_ulogic_vector(31 downto 0);
    xbus_ack_i : in    std_ulogic;
    xbus_err_i : in    std_ulogic;

    -- Interrupts
    irq_msi_i : in    std_ulogic;
    irq_mti_i : in    std_ulogic;
    irq_mei_i : in    std_ulogic;

    -- Retirement trace of the one hart
    trace_o : out   trace_port_t
  );
end entity lockstep_core;

architecture structural of lockstep_core is

begin

  i_neorv32 : entity neorv32.neorv32_top
    generic map (
      -- General
      clock_frequency => 50_000_000,
      trace_port_en   => trace_port_en,
      dual_core_en    => false,

      -- Boot
      boot_mode_select => boot_mode_select,
      boot_addr_custom => x"00000000",

      -- OCD
      ocd_en              => false,
      ocd_num_hw_triggers => 0,
      ocd_authentication  => false,
      ocd_jedec_id        => (others => '0'),

      -- RISC-V Extensions
      riscv_isa_c         => false,
      riscv_isa_e         => false,
      riscv_isa_m         => false,
      riscv_isa_u         => false,
      riscv_isa_zaamo     => false,
      riscv_isa_zalrsc    => false,
      riscv_isa_zba       => false,
      riscv_isa_zbb       => false,
      riscv_isa_zbc       => false,
      riscv_isa_zbkb      => false,
      riscv_isa_zbkc      => false,
      riscv_isa_zbkx      => false,
      riscv_isa_zbs       => false,
      riscv_isa_zcb       => false,
      riscv_isa_zcmop     => false,
      riscv_isa_zfinx     => false,
      riscv_isa_zibi      => false,
      riscv_isa_zicntr    => false,
      riscv_isa_zicond    => false,
      riscv_isa_zihpm     => false,
      riscv_isa_zimop     => false,
      riscv_isa_zknd      => false,
      riscv_isa_zkne      => false,
      riscv_isa_zknh      => false,
      riscv_isa_zksed     => false,
      riscv_isa_zksh      => false,
      riscv_isa_zmmul     => false,
      riscv_isa_smcntrpmf => false,
      riscv_isa_xcfu      => false,

      -- Tuning
      cpu_constt_br_en  => false,
      cpu_fast_mul_en   => false,
      cpu_fast_mul_regs => 1,
      cpu_fast_shift_en => false,
      cpu_rf_arch_sel   => 0,

      -- PMP
      pmp_num_regions     => 0,
      pmp_min_granularity => 4,
      pmp_tor_mode_en     => false,
      pmp_nap_mode_en     => false,

      -- HPM
      hpm_num_cnts  => 0,
      hpm_cnt_width => 64,

      -- IMEM
      imem_en        => true,
      imem_base      => x"00000000",
      imem_size      => 16384,
      imem_outreg_en => false,

      -- DMEM
      dmem_en        => false,
      dmem_base      => x"80000000",
      dmem_size      => 8192,
      dmem_outreg_en => false,

      -- Caches
      icache_en         => false,
      icache_num_blocks => 4,
      dcache_en         => false,
      dcache_num_blocks => 4,
      cache_block_size  => 64,
      cache_bursts_en   => true,
      cache_uc_base     => x"F0000000",

      -- SMC
      smc_en   => false,
      smc_base => x"E0000000",

      -- XBus
      xbus_en          => true,
      xbus_timeout     => 2048,
      xbus_regstage_en => false,

      -- GPIO
      io_gpio_num    => 0,
      io_gpio_dir_en => false,

      -- CLINT
      io_clint_en => false,

      -- UARTs
      io_uart0_en      => false,
      io_uart0_rx_fifo => 1,
      io_uart0_tx_fifo => 1,
      io_uart1_en      => false,
      io_uart1_rx_fifo => 1,
      io_uart1_tx_fifo => 1,

      -- SPI/SDI
      io_spi_en   => false,
      io_spi_fifo => 1,
      io_sdi_en   => false,
      io_sdi_fifo => 1,

      -- TWI/TWD
      io_twi_en      => false,
      io_twi_fifo    => 1,
      io_twd_en      => false,
      io_twd_rx_fifo => 1,
      io_twd_tx_fifo => 1,

      -- PWM
      io_pwm_num => 0,

      -- WDT
      io_wdt_en => false,

      -- TRNG
      io_trng_en       => false,
      io_trng_fifo     => 1,
      io_trng_num_ro   => 3,
      io_trng_num_inv  => 5,
      io_trng_num_rbit => 64,

      -- CFS
      io_cfs_en => false,

      -- NEOLED
      io_neoled_en      => false,
      io_neoled_tx_fifo => 1,

      -- GPTMR
      io_gptmr_num => 0,

      -- ONEWIRE
      io_onewire_en   => false,
      io_onewire_fifo => 1,

      -- DMA
      io_dma_en       => false,
      io_dma_dsc_fifo => 4,

      -- SLINK
      io_slink_en      => false,
      io_slink_rx_fifo => 1,
      io_slink_tx_fifo => 1,

      -- TRACER
      io_tracer_en        => false,
      io_tracer_buffer    => 1,
      io_tracer_simlog_en => false
    )
    port map (
      -- Global
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      rstn_ocd_o => open,
      rstn_wdt_o => open,

      -- Trace
      trace_cpu0_o => trace_o,
      trace_cpu1_o => open,

      -- JTAG (disabled)
      jtag_tck_i => '0',
      jtag_tdi_i => '0',
      jtag_tdo_o => open,
      jtag_tms_i => '0',

      -- SMC (disabled)
      smc_ioen_o => open,
      smc_sck_o  => open,
      smc_csn_o  => open,
      smc_sdo_o  => open,
      smc_sdi_i  => '0',

      -- XBus
      xbus_adr_o => xbus_adr_o,
      xbus_dat_o => xbus_dat_o,
      xbus_cti_o => open,
      xbus_tag_o => open,
      xbus_we_o  => xbus_we_o,
      xbus_sel_o => xbus_sel_o,
      xbus_stb_o => xbus_stb_o,
      xbus_cyc_o => open,
      xbus_dat_i => xbus_dat_i,
      xbus_ack_i => xbus_ack_i,
      xbus_err_i => xbus_err_i,

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
      gpio_dir_o => open,
      gpio_o     => open,
      gpio_i     => (others => '0'),

      -- UART0/1 (disabled)
      uart0_txd_o  => open,
      uart0_rxd_i  => '0',
      uart0_rtsn_o => open,
      uart0_ctsn_i => '0',
      uart1_txd_o  => open,
      uart1_rxd_i  => '0',
      uart1_rtsn_o => open,
      uart1_ctsn_i => '0',

      -- SPI (disabled)
      spi_clk_o => open,
      spi_dat_o => open,
      spi_dat_i => '0',
      spi_csn_o => open,

      -- SDI (disabled)
      sdi_clk_i => '0',
      sdi_dat_o => open,
      sdi_dat_i => '0',
      sdi_csn_i => '1',

      -- TWI (disabled)
      twi_sda_i => '1',
      twi_sda_o => open,
      twi_scl_i => '1',
      twi_scl_o => open,

      -- TWD (disabled)
      twd_sda_i => '1',
      twd_sda_o => open,
      twd_scl_i => '1',

      -- ONEWIRE (disabled)
      onewire_i => '1',
      onewire_o => open,

      -- PWM (disabled)
      pwm_o => open,

      -- CFS (disabled)
      cfs_in_i  => (others => '0'),
      cfs_out_o => open,

      -- NEOLED (disabled)
      neoled_o => open,

      -- CLINT (disabled)
      mtime_time_o => open,

      -- Interrupts
      irq_msi_i => irq_msi_i,
      irq_mti_i => irq_mti_i,
      irq_mei_i => irq_mei_i
    );

end architecture structural;
