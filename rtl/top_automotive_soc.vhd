-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  lockstep-rv32-soc Reference Hardware Platform
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
  use neorv32.neorv32_package.all;

entity top_automotive_soc is
  generic (
    -- NEORV32 boot source: 0 = bootloader, 1 = custom address, 2 = IMEM image
    g_boot_mode : natural range 0 to 2 := 0;
    -- Both cores' execution trace ports, for verification only (roadmap R2.2)
    g_trace_en : boolean := false;
    -- RAM size profile, in 64-bit words: 15 is the 256 KB of HSI section 5, and
    -- a board too small for it takes fewer. The window above the RAM answers ERR.
    g_ram_addr_bits : positive range 4 to 15 := 15
  );
  port (
    -- --------------------------------------------------------------------
    -- Global Clock and Reset System
    -- --------------------------------------------------------------------
    -- Main system clock string
    clk_i : in    std_logic;
    -- External master hardware reset
    rst_n_i : in    std_logic;

    -- Independent on-chip RC oscillator for the watchdog (Rule CD-03)
    wd_clk_i : in    std_logic;

    -- --------------------------------------------------------------------
    -- Functional Automotive Interfaces
    -- --------------------------------------------------------------------
    -- Hardened CAN-Bus transmission line
    can_tx_o : out   std_logic;
    -- Hardened CAN-Bus reception line
    can_rx_i : in    std_logic;
    -- Safe UART diagnostic output
    uart_tx_o : out   std_logic;

    -- --------------------------------------------------------------------
    -- Safety Supervisor & Actuator Isolation Pins
    -- --------------------------------------------------------------------
    -- Diagnostic non-maskable interrupt flag
    nmi_fault_o : out   std_logic;
    -- Hardwired actuator lockdown control
    actuator_safe_o : out   std_logic;

    -- --------------------------------------------------------------------
    -- Read-only diagnostic port: the ECC first-fault record over SPI, for an
    -- external supervisor, without the system bus (HSI ECC-08). Unused, tie
    -- chip select high.
    -- --------------------------------------------------------------------
    diag_cs_n_i : in    std_logic;
    diag_sck_i  : in    std_logic;
    diag_sdo_o  : out   std_logic
  );
end entity top_automotive_soc;

architecture structural of top_automotive_soc is

  -- Traceability attribute tracking for ISO 26262 audit pipelines
  attribute requirement_id : string;
  attribute requirement_id of structural : architecture is "TSR_LOCKSTEP_001";

  -- Interconnect buses structured as explicit records to prevent routing bugs
  signal w_core_a_bus : t_rv_bus;
  signal w_core_b_bus : t_rv_bus;

  -- Core A's bus once it has been held back to meet core B's
  signal w_core_a_bus_late : t_rv_bus;

  -- What each core receives, and the one response to each accepted request
  signal w_core_a_in : t_core_inputs;
  signal w_core_b_in : t_core_inputs;
  signal w_bus_rsp   : t_bus_rsp;

  -- The comparator self-test
  signal w_test_flip        : t_rv_bus;
  signal w_test_fatal       : std_logic;
  signal w_core_b_compared  : t_rv_bus;
  signal w_comparator_rst_n : std_logic;
  signal w_self_test_passed : std_logic;
  signal w_self_test_failed : std_logic;

  signal w_safe_sys_bus : t_rv_bus;

  -- Internal safety status tracking wires. w_nmi follows the compare at once,
  -- for the self-test. w_fault is the registered fault for the pin and MEI.
  signal w_nmi       : std_logic;
  signal w_fault     : std_logic;
  signal w_bus_valid : std_logic;

  -- XBus signals from each NEORV32 instance
  signal w_core_a_xbus_addr : std_logic_vector(31 downto 0);
  signal w_core_b_xbus_addr : std_logic_vector(31 downto 0);
  signal w_core_a_xbus_data : std_logic_vector(31 downto 0);
  signal w_core_b_xbus_data : std_logic_vector(31 downto 0);
  signal w_core_a_xbus_we   : std_logic;
  signal w_core_b_xbus_we   : std_logic;
  signal w_core_a_xbus_stb  : std_logic;
  signal w_core_b_xbus_stb  : std_logic;
  signal w_core_a_xbus_sel  : std_logic_vector(3 downto 0);
  signal w_core_b_xbus_sel  : std_logic_vector(3 downto 0);

  -- Each core's retirement trace, for the benches (roadmap R2.2)
  signal w_core_a_trace : trace_port_t;
  signal w_core_b_trace : trace_port_t;

  -- Peripheral diagnostic signals
  signal w_cold_rst_n    : std_logic;
  signal w_wd_rst_n      : std_logic;
  signal w_wd_reset      : std_logic;
  signal w_rst_n_request : std_logic;
  signal w_rst_n         : std_logic;
  signal w_lockstep_safe : std_logic;
  signal w_can_irq       : std_logic;
  signal w_uart_irq      : std_logic;
  signal w_ecc_fatal     : std_logic;
  signal w_ram_rdata     : std_logic_vector(31 downto 0);
  signal w_wd_rdata      : std_logic_vector(31 downto 0);
  signal w_can_rdata     : std_logic_vector(31 downto 0);
  signal w_uart_rdata    : std_logic_vector(31 downto 0);
  signal w_ecc_telemetry : t_telemetry;

begin

  -- ========================================================================
  -- 1. RESET NETWORK (Rule 1.4, Rule CD-04)
  -- ========================================================================
  -- The cold reset comes from the rst_n_i pin alone. It clears the comparator,
  -- whose fault latch must survive anything less, and the watchdog supervisor,
  -- which has to remember why it reset the SoC.
  --
  -- w_rst_n adds the watchdog's reset, and every other block takes that one. A
  -- pulse too short for a clock edge to catch still resets the blocks that only
  -- look at reset on a clock edge. It stays low until the comparator has passed
  -- its self-test, so the cores do not run on an untested comparator.
  -- ========================================================================
  i_cold_reset_sync : entity lockstep.reset_synchronizer
    port map (
      clk_i       => clk_i,
      rst_n_i     => rst_n_i,
      rst_n_syn_o => w_cold_rst_n
    );

  i_wd_reset_sync : entity lockstep.reset_synchronizer
    port map (
      clk_i       => wd_clk_i,
      rst_n_i     => rst_n_i,
      rst_n_syn_o => w_wd_rst_n
    );

  w_rst_n_request <= w_cold_rst_n and w_self_test_passed and not w_wd_reset;

  i_reset_sync : entity lockstep.reset_synchronizer
    port map (
      clk_i       => clk_i,
      rst_n_i     => w_rst_n_request,
      rst_n_syn_o => w_rst_n
    );

  -- ========================================================================
  -- 2. BUS RECORD PACKAGING
  -- ========================================================================
  -- Aggregate XBus output wires into clean records for the lockstep engine.
  -- ========================================================================
  w_core_a_bus.addr  <= w_core_a_xbus_addr;
  w_core_a_bus.data  <= w_core_a_xbus_data;
  w_core_a_bus.sel   <= w_core_a_xbus_sel;
  w_core_a_bus.we    <= w_core_a_xbus_we;
  w_core_a_bus.valid <= w_core_a_xbus_stb;

  w_core_b_bus.addr  <= w_core_b_xbus_addr;
  w_core_b_bus.data  <= w_core_b_xbus_data;
  w_core_b_bus.sel   <= w_core_b_xbus_sel;
  w_core_b_bus.we    <= w_core_b_xbus_we;
  w_core_b_bus.valid <= w_core_b_xbus_stb;

  -- ========================================================================
  -- 3. TEMPORAL DIVERSITY
  -- ========================================================================
  -- Core B runs two clocks behind core A, so that a glitch on both cannot do the
  -- same thing to both. Core A's bus is held back to meet core B's at the
  -- comparator, and only goes on to the system bus from there.
  -- ========================================================================
  w_core_a_in.rst_n <= w_rst_n;
  w_core_a_in.rdata <= w_bus_rsp.rdata;
  w_core_a_in.ack   <= w_bus_rsp.ack;
  w_core_a_in.err   <= w_bus_rsp.err;
  w_core_a_in.msi   <= w_can_irq;
  w_core_a_in.mti   <= w_uart_irq;
  -- A maskable notification only (HSI FLT-02): containment does not need it
  w_core_a_in.mei <= w_fault;

  i_temporal_diversity : entity lockstep.temporal_diversity
    port map (
      clk_i        => clk_i,
      core_a_bus_i => w_core_a_bus,
      core_a_bus_o => w_core_a_bus_late,
      core_a_in_i  => w_core_a_in,
      core_b_in_o  => w_core_b_in
    );

  -- A core strobes its bus and then waits. The response comes in the cycle after
  -- the strobe reaches the system bus, from the slave addressed only, with ACK or
  -- ERR (HSI section 8.1). A strobe the gate stops is never answered, and the
  -- core's own bus timeout ends it.
  i_bus_fabric : entity lockstep.soc_bus_fabric
    generic map (
      g_ram_addr_bits => g_ram_addr_bits
    )
    port map (
      clk_i        => clk_i,
      rst_n_i      => w_rst_n,
      bus_i        => w_safe_sys_bus,
      ram_rdata_i  => w_ram_rdata,
      wd_rdata_i   => w_wd_rdata,
      can_rdata_i  => w_can_rdata,
      uart_rdata_i => w_uart_rdata,
      ram_fatal_i  => w_ecc_fatal,
      rsp_o        => w_bus_rsp
    );

  -- ========================================================================
  -- 4. INSTANCE: MASTER CPU (CORE A)
  -- ========================================================================
  -- Both cores are the same lockstep_core, so their NEORV32 configuration is
  -- written once (rtl/lockstep_core.vhd) and cannot drift apart.
  i_cpu_master : entity lockstep.lockstep_core
    generic map (
      g_boot_mode => g_boot_mode,
      g_trace_en  => g_trace_en
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => w_core_a_in.rst_n,
      xbus_adr_o => w_core_a_xbus_addr,
      xbus_dat_o => w_core_a_xbus_data,
      xbus_we_o  => w_core_a_xbus_we,
      xbus_sel_o => w_core_a_xbus_sel,
      xbus_stb_o => w_core_a_xbus_stb,
      xbus_dat_i => w_core_a_in.rdata,
      xbus_ack_i => w_core_a_in.ack,
      xbus_err_i => w_core_a_in.err,
      irq_msi_i  => w_core_a_in.msi,
      irq_mti_i  => w_core_a_in.mti,
      irq_mei_i  => w_core_a_in.mei,
      trace_o    => w_core_a_trace
    );

  -- ========================================================================
  -- 5. INSTANCE: MIRROR CHECKER CPU (CORE B)
  -- ========================================================================
  i_cpu_checker : entity lockstep.lockstep_core
    generic map (
      g_boot_mode => g_boot_mode,
      g_trace_en  => g_trace_en
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => w_core_b_in.rst_n,
      xbus_adr_o => w_core_b_xbus_addr,
      xbus_dat_o => w_core_b_xbus_data,
      xbus_we_o  => w_core_b_xbus_we,
      xbus_sel_o => w_core_b_xbus_sel,
      xbus_stb_o => w_core_b_xbus_stb,
      xbus_dat_i => w_core_b_in.rdata,
      xbus_ack_i => w_core_b_in.ack,
      xbus_err_i => w_core_b_in.err,
      irq_msi_i  => w_core_b_in.msi,
      irq_mti_i  => w_core_b_in.mti,
      irq_mei_i  => w_core_b_in.mei,
      trace_o    => w_core_b_trace
    );

  -- ========================================================================
  -- 6. INSTANCE: HARDENED DUAL-CORE LOCKSTEP COMPARATOR
  -- ========================================================================
  i_lockstep_gate : entity lockstep.lockstep_comparator
    port map (
      clk_i       => clk_i,
      rst_n_syn_i => w_comparator_rst_n,

      -- Core Feeders
      core_a_bus_i => w_core_a_bus_late,
      core_b_bus_i => w_core_b_compared,

      -- Both cores read the same data from the RAM, so they cannot see a bad word
      fatal_fault_i => w_ecc_fatal or w_test_fatal,

      -- Safety Monitoring Outputs
      nmi_fault_o  => w_nmi,
      fault_o      => w_fault,
      safe_state_o => w_lockstep_safe,

      -- Gated System Infrastructure Connections
      sys_bus_o   => w_safe_sys_bus,
      bus_valid_o => w_bus_valid

    -- ========================================================================
    );

  -- 7. COMPARATOR SELF-TEST
  -- ========================================================================
  -- Runs after each cold reset, with the cores in reset. It reaches the
  -- comparator here, on the way in from core B, and the comparator's reset is
  -- otherwise the cold reset, so a watchdog reset leaves a trip latched.
  -- ========================================================================
  i_comparator_self_test : entity lockstep.comparator_self_test
    port map (
      clk_i         => clk_i,
      rst_n_i       => w_cold_rst_n,
      flip_bus_o    => w_test_flip,
      fatal_fault_o => w_test_fatal,
      rst_n_o       => w_comparator_rst_n,
      nmi_fault_i   => w_nmi,
      fault_i       => w_fault,
      safe_state_i  => w_lockstep_safe,
      bus_valid_i   => w_bus_valid,
      passed_o      => w_self_test_passed,
      failed_o      => w_self_test_failed
    );

  w_core_b_compared.addr  <= w_core_b_bus.addr xor w_test_flip.addr;
  w_core_b_compared.data  <= w_core_b_bus.data xor w_test_flip.data;
  w_core_b_compared.sel   <= w_core_b_bus.sel xor w_test_flip.sel;
  w_core_b_compared.we    <= w_core_b_bus.we xor w_test_flip.we;
  w_core_b_compared.valid <= w_core_b_bus.valid xor w_test_flip.valid;

  -- ========================================================================
  -- 8. AUTOMOTIVE BUS CONTROLLER INTEGRATION
  -- ========================================================================
  i_automotive_can : entity lockstep.automotive_can_controller
    port map (
      clk_i        => clk_i,
      rst_n_i      => w_rst_n,
      bus_i        => w_safe_sys_bus,
      bus_ok_i     => w_bus_valid,
      rdata_o      => w_can_rdata,
      can_tx_o     => can_tx_o,
      can_rx_i     => can_rx_i,
      can_busy_o   => open,
      can_status_o => open,
      can_irq_o    => w_can_irq

    -- ========================================================================
    );

  -- 9. SAFE UART DIAGNOSTIC INTERFACE
  -- ========================================================================
  i_safe_uart : entity lockstep.safe_uart
    port map (
      clk_i        => clk_i,
      rst_n_i      => w_rst_n,
      bus_i        => w_safe_sys_bus,
      bus_ok_i     => w_bus_valid,
      rdata_o      => w_uart_rdata,
      uart_tx_o    => uart_tx_o,
      uart_busy_o  => open,
      uart_error_o => open,
      uart_irq_o   => w_uart_irq

    );

  -- ========================================================================
  -- 10. WATCHDOG SUPERVISOR
  -- ========================================================================
  i_watchdog_supervisor : entity lockstep.watchdog_supervisor
    port map (
      clk_i       => clk_i,
      rst_n_i     => w_cold_rst_n,
      bus_i       => w_safe_sys_bus,
      bus_ok_i    => w_bus_valid,
      rdata_o     => w_wd_rdata,
      wd_clk_i    => wd_clk_i,
      wd_rst_n_i  => w_wd_rst_n,
      sys_reset_o => w_wd_reset
    );

  -- ========================================================================
  -- 11. ECC PROTECTED DATA RAM
  -- ========================================================================
  -- The cores have no memory of their own for data (dmem_en), so that every load
  -- and store goes through the comparator. This is the RAM those reach.
  -- ========================================================================
  i_ecc_ram : entity lockstep.ecc_data_ram
    generic map (
      g_addr_bits => g_ram_addr_bits
    )
    port map (
      clk_i       => clk_i,
      rst_n_i     => w_cold_rst_n,
      bus_rst_n_i => w_rst_n,
      bus_i       => w_safe_sys_bus,
      bus_ok_i    => w_bus_valid,
      rdata_o     => w_ram_rdata,
      dbe_fatal_o => w_ecc_fatal,
      telemetry_o => w_ecc_telemetry
    );

  -- The record goes out on its own pins, on the cold reset only, so a warm reset
  -- or a shut bus leaves it readable
  i_telemetry_port : entity lockstep.telemetry_port
    port map (
      clk_i       => clk_i,
      rst_n_i     => w_cold_rst_n,
      telemetry_i => w_ecc_telemetry,
      cs_n_i      => diag_cs_n_i,
      sck_i       => diag_sck_i,
      sdo_o       => diag_sdo_o
    );

  -- The self-test trips the comparator on purpose, which is nobody else's business.
  -- The pin keeps its name, but it is the registered fault indication, not a RISC-V
  -- NMI (HSI FLT-01).
  nmi_fault_o <= (w_fault and w_self_test_passed) or w_self_test_failed;

  -- Nothing supervises the actuators during a reset, so it holds them safe too
  actuator_safe_o <= w_lockstep_safe or not w_rst_n;

end architecture structural;
