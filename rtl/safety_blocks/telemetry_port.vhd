-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Diagnostic Telemetry Port
-- Module Name:  telemetry_port - rtl
-- Description:  A read-only SPI target that shifts out the ECC block's
--               telemetry (roadmap R4.1, HSI ECC-08). It does not use the system
--               bus and has no way to write anything, so an external supervisor
--               can read the first-fault record while the comparator holds the
--               bus shut, without reopening it.
--
--               SPI mode 0, most significant bit first. Falling chip select takes
--               a snapshot of all 160 bits and puts the first on sdo_o; each
--               falling edge of sck_i then moves to the next. The controller
--               samples on the rising edge. Chip select and sck_i are
--               synchronised into clk_i, so sck_i runs at no more than a tenth
--               of clk_i (5 MHz at 50 MHz). sdo_o is low while chip select is
--               high.
--
-- Traces to:    TSR_ECC_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity telemetry_port is
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic; -- Cold reset

    -- What to send, sampled when chip select falls
    telemetry_i : in    t_telemetry;

    -- SPI target, asynchronous to clk_i
    cs_n_i : in    std_logic;
    sck_i  : in    std_logic;
    sdo_o  : out   std_logic
  );
end entity telemetry_port;

architecture rtl of telemetry_port is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_ECC_001";

  -- Two flip-flops for each asynchronous input, then one more to find edges
  signal r_cs_sync  : std_logic_vector(2 downto 0);
  signal r_sck_sync : std_logic_vector(2 downto 0);
  signal r_shift    : t_telemetry;

begin

  p_sync : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_cs_sync  <= (others => '1');
        r_sck_sync <= (others => '0');
      else
        r_cs_sync  <= r_cs_sync(1 downto 0) & cs_n_i;
        r_sck_sync <= r_sck_sync(1 downto 0) & sck_i;
      end if;
    end if;

  end process p_sync;

  p_shift : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_shift <= (others => '0');
      elsif (r_cs_sync(2) = '1' and r_cs_sync(1) = '0') then
        -- Chip select fell: the snapshot
        r_shift <= telemetry_i;
      elsif (r_cs_sync(1) = '0' and r_sck_sync(2) = '1' and r_sck_sync(1) = '0') then
        -- sck fell: the next bit
        r_shift <= r_shift(r_shift'high - 1 downto 0) & '0';
      end if;
    end if;

  end process p_shift;

  sdo_o <= r_shift(r_shift'high) when (r_cs_sync(2) = '0') else
           '0';

end architecture rtl;
