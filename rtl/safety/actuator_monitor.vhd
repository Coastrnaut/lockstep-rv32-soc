-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Actuator Output Monitor and Second Shutdown Channel
-- Module Name:  actuator_monitor - rtl
-- Description:  actuator_safe_o is the one pin between a fault and the
--               actuator. Without a read-back, a pin, pad or board driver
--               stuck at "permit" stays hidden until it is needed, and then
--               nothing removes the actuator's power (FMEDA FM-22). This block
--               closes that gap in two ways:
--
--               1. Read-back. fb_i is the actuator-safe line as the actuator's
--                  driver sees it. It is synchronised, and compared with the
--                  command delayed by the same two clocks. A difference that
--                  lasts g_filter_clocks is a fault, held until a cold reset.
--                  The reset holds the command at "safe", so the line is
--                  checked at every start as well as on every demand.
--               2. A second channel, enable_o, active high, of the opposite
--                  polarity to actuator_safe_o, so that one stuck level cannot
--                  look right on both: the actuator may only be powered while
--                  enable_o is high and actuator_safe_o is low. enable_o is a
--                  register of its own, from the comparators' bus permission
--                  rather than their safe-state output, and is cleared by a
--                  read-back fault, and by the SoC reset without a clock.
--
--               The fault also trips the comparators (top level), so the
--               fault pin reports it and the first channel commands "safe".
--
-- Traces to:    TSR_ACTUATOR_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

entity actuator_monitor is
  generic (
    -- Clocks the read-back may lag the command before it is a fault: the
    -- driver's own delay, at the system clock
    g_filter_clocks : positive range 2 to 1024 := 8
  );
  port (
    clk_i : in    std_logic;
    -- Cold reset, synchronous to clk_i: the only thing that clears the fault
    rst_n_i : in    std_logic;
    -- The SoC reset, which clears the second channel without a clock
    sys_rst_n_i : in    std_logic;

    -- The first channel as commanded: '1' safe
    safe_cmd_i : in    std_logic;
    -- The first channel read back from the driver, asynchronous: '1' safe
    fb_i : in    std_logic;
    -- The comparators permit the bus: the second channel may follow
    permit_i : in    std_logic;

    -- The second channel: '1' the actuator may be powered
    enable_o : out   std_logic;
    -- The read-back disagreed with the command, held until rst_n_i
    fault_o : out   std_logic
  );
end entity actuator_monitor;

architecture rtl of actuator_monitor is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_ACTUATOR_001";

  signal r_fb_sync  : std_logic_vector(1 downto 0);
  signal r_cmd_late : std_logic_vector(1 downto 0);
  signal r_count    : natural range 0 to g_filter_clocks;
  signal r_fault    : std_logic;
  signal r_permit   : std_logic;

  -- Synthesis must keep the second channel's register and the fault latch
  attribute dont_touch : string;
  attribute dont_touch of r_fault  : signal is "true";
  attribute dont_touch of r_permit : signal is "true";

begin

  -- ========================================================================
  -- 1. READ-BACK
  -- ========================================================================
  p_readback : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_fb_sync  <= r_fb_sync(0) & fb_i;
      r_cmd_late <= r_cmd_late(0) & safe_cmd_i;

      if (rst_n_i = '0') then
        r_count <= 0;
        r_fault <= '0';
      elsif (r_fb_sync(1) /= r_cmd_late(1)) then
        if (r_count = g_filter_clocks) then
          r_fault <= '1';
        else
          r_count <= r_count + 1;
        end if;
      else
        r_count <= 0;
      end if;
    end if;

  end process p_readback;

  -- ========================================================================
  -- 2. SECOND CHANNEL
  -- ========================================================================
  p_permit : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (sys_rst_n_i = '0' or r_fault = '1') then
        r_permit <= '0';
      else
        r_permit <= permit_i;
      end if;
    end if;

  end process p_permit;

  -- The reset and the fault take the channel down at once, the reset without
  -- a clock. Before the first clock the register holds no value: not enabled.
  enable_o <= '1' when (r_permit = '1' and sys_rst_n_i = '1' and r_fault /= '1') else
              '0';

  fault_o <= '1' when (r_fault = '1') else
             '0';

end architecture rtl;
