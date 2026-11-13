## ============================================================================
## lockstep-rv32-soc on the Digilent Arty A7-100T (xc7a100tcsg324-1)
## Pin locations from Digilent's Arty-A7-100-Master.xdc.
## ============================================================================

## Clock and reset
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk100mhz]
create_clock -name clk100 -period 10.000 [get_ports clk100mhz]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports ck_rst]

## USB UART: FPGA to the bridge
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]

## LEDs: actuator-safe, fault, MMCM lock, watchdog heartbeat
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## Pmod JA: CAN to an external transceiver, and probe points
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports can_tx_o]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports can_rx_i]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports probe_fault]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports probe_safe]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports probe_uart_tx]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports probe_wd_clk]

## Pmod JB: the read-only diagnostic SPI port (HSI ECC-08). CS idles high.
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports diag_cs_n]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports diag_sck]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports diag_sdo]

## ----------------------------------------------------------------------------
## Watchdog clock: the configuration oscillator. UG470 gives CFGMCLK as about
## 65 MHz with a wide tolerance; timing is closed for 100 MHz, its upper end.
## ----------------------------------------------------------------------------
create_clock -name cfgmclk -period 10.000 [get_pins i_startup/CFGMCLK]
create_generated_clock -name wd_clk -source [get_pins i_startup/CFGMCLK] -divide_by 64 \
  [get_pins {r_wd_div_reg[5]/Q}]

## ----------------------------------------------------------------------------
## Clock-domain crossings between the system clock and the watchdog clock.
## Each is a two-flop synchroniser, or bundled data that a handshake holds
## stable for at least two cycles of the receiving clock before it is sampled
## (watchdog_supervisor.vhd). Every such path must settle within one system
## clock period, which also bounds the skew within the status bundle.
## ----------------------------------------------------------------------------
set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins i_mmcm/CLKOUT0]] \
  -to [get_clocks wd_clk] 20.000
set_max_delay -datapath_only -from [get_clocks wd_clk] \
  -to [get_clocks -of_objects [get_pins i_mmcm/CLKOUT0]] 20.000

## Synchronisers: keep each chain together and out of shift registers
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *reset_sync*/r_stages_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_watchdog_supervisor/r_kick_sync_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_watchdog_supervisor/r_kick_ack_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_watchdog_supervisor/r_status_sync_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_watchdog_supervisor/r_status_ack_reg*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_telemetry_port/r_cs_sync_reg[0]* || NAME =~ *i_telemetry_port/r_cs_sync_reg[1]*}]
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *i_telemetry_port/r_sck_sync_reg[0]* || NAME =~ *i_telemetry_port/r_sck_sync_reg[1]*}]

## The reset button and the MMCM lock reach the SoC only through its reset
## synchronisers, which assert at once and release on a clock edge
set_false_path -from [get_ports ck_rst]
set_false_path -from [get_pins i_mmcm/LOCKED]

## The CAN receive input and the diagnostic port's inputs are synchronised
## inside their blocks
set_false_path -from [get_ports {can_rx_i diag_cs_n diag_sck}]

## Outputs: slow, and timed by the bench, not by the FPGA
set_false_path -to [get_ports {uart_rxd_out led[*] can_tx_o probe_* diag_sdo}]

## Configuration
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
