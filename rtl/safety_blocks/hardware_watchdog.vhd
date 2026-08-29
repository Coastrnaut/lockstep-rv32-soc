-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Windowed Hardware Watchdog & Clock Monitor
-- Module Name:  hardware_watchdog - rtl
-- Description:  Independent watchdog running on a separate RC oscillator.
--               Windowed timing: kick must arrive between MIN and MAX count.
--               Early kicks (too soon) and late kicks (timeout) both trigger
--               a hard reset.
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
    signal w_early_violation  : std_logic;
    signal w_late_violation   : std_logic;
    signal r_timeout_latched  : std_logic;

begin

    -- ========================================================================
    -- 1. WATCHDOG COUNTER WITH WINDOWED CHECK (Rule 1.2, 2.1, 2.2)
    -- ========================================================================
    p_wd_counter : process(wd_clk_i)
    begin
        if rising_edge(wd_clk_i) then
            if rst_n_i = '0' then
                r_counter         <= (others => '0');
                r_timeout_latched <= '0';
            elsif r_timeout_latched = '0' then
                -- Only count when not already in fault state
                if cpu_kick_i = '1' then
                    -- CPU checked in — evaluate window
                    if r_counter < C_WD_MIN_COUNT then
                        -- Early kick: CPU is running too fast / loop too tight
                        r_timeout_latched <= '1';
                    else
                        -- Kick is within window — reset counter
                        r_counter <= (others => '0');
                    end if;
                else
                    -- Normal count-up
                    if r_counter < C_WD_MAX_COUNT then
                        r_counter <= r_counter + 1;
                    else
                        -- Late kick: CPU missed the window
                        r_timeout_latched <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process p_wd_counter;

    -- ========================================================================
    -- 2. VIOLATION FLAGS (Rule 2.1)
    -- ========================================================================
    p_violation : process(all)
    begin
        w_early_violation <= '0';
        w_late_violation  <= '0';

        if cpu_kick_i = '1' and r_counter < C_WD_MIN_COUNT and r_timeout_latched = '0' then
            w_early_violation <= '1';
        end if;

        if r_counter >= C_WD_MAX_COUNT and r_timeout_latched = '0' then
            w_late_violation <= '1';
        end if;
    end process p_violation;

    -- ========================================================================
    -- 3. OUTPUT DRIVERS
    -- ========================================================================
    sys_reset_o <= r_timeout_latched or w_early_violation or w_late_violation;

    -- Diagnostic status: upper nibble = fault code, lower = counter MSB
    wd_status_o(7) <= r_timeout_latched;
    wd_status_o(6) <= w_early_violation;
    wd_status_o(5) <= w_late_violation;
    wd_status_o(4 downto 0) <= std_logic_vector(r_counter(15 downto 11));

end architecture rtl;
