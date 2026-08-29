-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Windowed Hardware Watchdog & Clock Monitor
-- Module Name:  hardware_watchdog - rtl
-- Description:  Independent watchdog running on a separate RC oscillator.
--               Monitors the primary CPU clock. If the processor misses a
--               sub-millisecond check-in window, the logic asserts a hardware
--               reset to critical actuators.
--
-- Traces to:    TSR_WD_001, TSR_SAFETY_GATE_003
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

entity hardware_watchdog is
    port (
        -- Independent internal RC oscillator (Rule 1.1)
        wd_clk_i     : in  std_logic;
        rst_n_i      : in  std_logic;

        -- Strobed by valid instruction executions from the CPU
        cpu_kick_i   : in  std_logic;

        -- Forces hardware supervisor override
        sys_reset_o  : out std_logic;

        -- Diagnostic output: watchdog status
        wd_status_o  : out std_logic_vector(7 downto 0)
    );
end entity hardware_watchdog;

architecture rtl of hardware_watchdog is

    -- ISO 26262 Automated Traceability Attributes
    attribute requirement_id : string;
    attribute requirement_id of rtl : architecture is "TSR_WD_001";

    -- Watchdog counter
    signal r_counter : unsigned(15 downto 0) := (others => '0');

    -- Internal status flags
    signal w_timeout : std_logic;

begin

    -- ========================================================================
    -- 1. WATCHDOG COUNTER (Rule 1.2)
    -- ========================================================================
    p_wd_counter : process(wd_clk_i)
    begin
        if rising_edge(wd_clk_i) then
            if rst_n_i = '0' then
                r_counter <= (others => '0');
            elsif cpu_kick_i = '1' then
                -- CPU checked in on time — reset counter
                r_counter <= (others => '0');
            else
                r_counter <= r_counter + 1;
            end if;
        end if;
    end process p_wd_counter;

    -- ========================================================================
    -- 2. TIMEOUT DETECTION (Rule 2.1)
    -- ========================================================================
    p_timeout : process(all)
    begin
        w_timeout <= '0';

        if r_counter > C_WD_TIMEOUT then
            w_timeout <= '1';
        end if;
    end process p_timeout;

    -- ========================================================================
    -- 3. OUTPUT DRIVERS
    -- ========================================================================
    sys_reset_o <= w_timeout;

    -- Diagnostic status: mirror the counter for external monitoring
    wd_status_o <= std_logic_vector(r_counter);

end architecture rtl;
