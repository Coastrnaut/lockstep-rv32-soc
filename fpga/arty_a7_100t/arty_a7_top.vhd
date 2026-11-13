-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  lockstep-rv32-soc on the Digilent Arty A7-100T
-- Module Name:  arty_a7_top - board
-- Description:  Board wrapper for the first FPGA target (roadmap R3.1).
--
--               System clock: the board's 100 MHz oscillator through an MMCM,
--               50 MHz, the frequency the SoC's UART and CAN dividers assume.
--
--               Watchdog clock: the FPGA's internal configuration oscillator
--               (STARTUPE2 CFGMCLK, about 65 MHz) divided by 64, about 1 MHz.
--               It shares no source with the board oscillator, so a stopped
--               system clock does not stop the watchdog. Its frequency is only
--               loosely specified, which moves the kick window in time; the
--               board firmware kicks by the watchdog's own counter, so that
--               does not matter to it.
--
--               Reset: the reset button, held until the MMCM has locked.
--
--               Pins: the UART to the USB bridge, CAN TX and RX on Pmod JA for
--               an external transceiver, and the fault and actuator-safe
--               outputs, the UART and the watchdog clock on Pmod JA as probe
--               points for a logic analyser (roadmap R3.2). The LEDs show
--               actuator-safe, the fault, MMCM lock and a watchdog heartbeat.
--
-- Traces to:    TSR_LOCKSTEP_001, TSR_WD_001, TSR_RESET_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library unisim;
  use unisim.vcomponents.all;

library lockstep;

entity arty_a7_top is
  port (
    clk100mhz : in    std_logic;                    -- E3
    ck_rst    : in    std_logic;                    -- C2, low while pressed

    uart_rxd_out : out   std_logic;                 -- D10, to the USB UART bridge
    led          : out   std_logic_vector(3 downto 0);

    -- Pmod JA
    can_tx_o      : out   std_logic;                -- JA1
    can_rx_i      : in    std_logic;                -- JA2, pulled up
    probe_fault   : out   std_logic;                -- JA3
    probe_safe    : out   std_logic;                -- JA4
    probe_uart_tx : out   std_logic;                -- JA7
    probe_wd_clk  : out   std_logic                 -- JA8
  );
end entity arty_a7_top;

architecture board of arty_a7_top is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of board : architecture is "TSR_LOCKSTEP_001, TSR_WD_001, TSR_RESET_001";

  signal w_clkfb      : std_logic;
  signal w_clk50_mmcm : std_logic;
  signal w_clk50      : std_logic;
  signal w_locked     : std_logic;
  signal w_rst_n      : std_logic;

  signal w_cfgmclk     : std_logic;
  signal w_cfgmclk_buf : std_logic;
  signal r_wd_div      : unsigned(5 downto 0) := (others => '0');
  signal w_wd_clk      : std_logic;
  signal r_heartbeat   : unsigned(18 downto 0) := (others => '0');

  signal w_uart_tx       : std_logic;
  signal w_nmi_fault     : std_logic;
  signal w_actuator_safe : std_logic;

  -- vsg_off
  signal w_cfgclk : std_logic;
  signal w_eos    : std_logic;
  signal w_preq   : std_logic;
  -- vsg_on

begin

  -- ========================================================================
  -- 1. SYSTEM CLOCK: 100 MHz to 50 MHz
  -- ========================================================================
  i_mmcm : mmcme2_base
    generic map (
      clkin1_period    => 10.0,
      clkfbout_mult_f  => 10.0,  -- VCO 1000 MHz
      clkout0_divide_f => 20.0,  -- 50 MHz
      divclk_divide    => 1
    )
    port map (
      clkin1   => clk100mhz,
      clkfbin  => w_clkfb,
      clkfbout => w_clkfb,
      clkout0  => w_clk50_mmcm,
      locked   => w_locked,
      pwrdwn   => '0',
      rst      => '0'
    );

  i_clk50_buf : bufg
    port map (
      i => w_clk50_mmcm,
      o => w_clk50
    );

  -- The SoC synchronises the reset release into both of its clock domains
  w_rst_n <= ck_rst and w_locked;

  -- ========================================================================
  -- 2. WATCHDOG CLOCK: the configuration oscillator, divided by 64
  -- ========================================================================
  i_startup : startupe2
    generic map (
      prog_usr      => "FALSE",
      sim_cclk_freq => 0.0
    )
    port map (
      cfgclk    => w_cfgclk,
      cfgmclk   => w_cfgmclk,
      eos       => w_eos,
      preq      => w_preq,
      clk       => '0',
      gsr       => '0',
      gts       => '0',
      keyclearb => '1',
      pack      => '0',
      usrcclko  => '0',
      usrcclkts => '1',  -- Leave the configuration clock pin alone
      usrdoneo  => '1',
      usrdonets => '1'   -- and the DONE pin
    );

  i_cfgmclk_buf : bufg
    port map (
      i => w_cfgmclk,
      o => w_cfgmclk_buf
    );

  p_wd_div : process (w_cfgmclk_buf) is
  begin

    if rising_edge(w_cfgmclk_buf) then
      r_wd_div <= r_wd_div + 1;
    end if;

  end process p_wd_div;

  i_wd_clk_buf : bufg
    port map (
      i => r_wd_div(5),
      o => w_wd_clk
    );

  -- About 0.5 s on, 0.5 s off at 1 MHz: the watchdog clock is running
  p_heartbeat : process (w_wd_clk) is
  begin

    if rising_edge(w_wd_clk) then
      r_heartbeat <= r_heartbeat + 1;
    end if;

  end process p_heartbeat;

  -- ========================================================================
  -- 3. THE SOC, booting the board image (fpga/arty_a7_100t/board_firmware.py)
  -- ========================================================================
  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2
    )
    port map (
      clk_i           => w_clk50,
      rst_n_i         => w_rst_n,
      wd_clk_i        => w_wd_clk,
      can_tx_o        => can_tx_o,
      can_rx_i        => can_rx_i,
      uart_tx_o       => w_uart_tx,
      nmi_fault_o     => w_nmi_fault,
      actuator_safe_o => w_actuator_safe
    );

  uart_rxd_out  <= w_uart_tx;
  probe_uart_tx <= w_uart_tx;
  probe_fault   <= w_nmi_fault;
  probe_safe    <= w_actuator_safe;
  probe_wd_clk  <= w_wd_clk;

  led(0) <= w_actuator_safe;
  led(1) <= w_nmi_fault;
  led(2) <= w_locked;
  led(3) <= r_heartbeat(r_heartbeat'high);

end architecture board;
