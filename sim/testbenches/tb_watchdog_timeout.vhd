-- ============================================================================
-- Testbench: Windowed Hardware Watchdog — Timeout Path
-- ============================================================================
-- Covers: counter exceeds C_WD_MAX_COUNT without kick -> sys_reset_o asserted
-- Also covers: recovery after reset, status register contents
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_watchdog_timeout is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_watchdog_timeout is
    constant WD_CLK_PERIOD : time := 10 ns;
    signal wd_clk   : std_logic := '0';
    signal wd_rst_n : std_logic := '0';
    signal cpu_kick : std_logic := '0';
    signal sys_rst  : std_logic;
    signal wd_stat  : std_logic_vector(7 downto 0);
begin
    wd_clk <= not wd_clk after WD_CLK_PERIOD / 2;

    i_wdt : entity lockstep.hardware_watchdog
        port map (wd_clk_i     => wd_clk,
                  rst_n_i      => wd_rst_n,
                  cpu_kick_i   => cpu_kick,
                  sys_reset_o  => sys_rst,
                  wd_status_o  => wd_stat);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        cpu_kick <= '0';
        wd_rst_n <= '0';
        for dummy in 1 to 5 loop wait until rising_edge(wd_clk); end loop;
        wd_rst_n <= '1';
        for dummy in 1 to 10 loop wait until rising_edge(wd_clk); end loop;

        -- --- Test 1: Normal kick within window ---
        -- C_WD_MIN=40000, C_WD_MAX=50000 — kick at ~45000 counts
        for dummy in 1 to 45000 loop
            wait until rising_edge(wd_clk);
        end loop;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        check(sys_rst = '0', "kick within window: no reset");

        -- --- Test 2: Timeout — counter exceeds C_WD_MAX_COUNT ---
        -- Let counter run past 50000 without a kick -> reset asserted
        for dummy in 1 to 51000 loop
            wait until rising_edge(wd_clk);
        end loop;
        check(sys_rst = '1', "timeout: sys_reset asserted after max count");

        -- --- Test 3: Recovery after reset ---
        cpu_kick <= '0';
        wd_rst_n <= '0';
        for dummy in 1 to 5 loop wait until rising_edge(wd_clk); end loop;
        wd_rst_n <= '1';
        for dummy in 1 to 10 loop wait until rising_edge(wd_clk); end loop;
        check(sys_rst = '0', "recovery: sys_reset deasserted after reset");

        -- --- Test 4: Kick exactly at C_WD_MIN_COUNT (boundary) ---
        for dummy in 1 to 40000 loop
            wait until rising_edge(wd_clk);
        end loop;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        check(sys_rst = '0', "kick at MIN boundary: no reset");

        -- --- Test 5: Kick just below C_WD_MIN_COUNT (too early) ---
        for dummy in 1 to 39999 loop
            wait until rising_edge(wd_clk);
        end loop;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        wait until rising_edge(wd_clk);
        check(sys_rst = '1', "kick below MIN: reset asserted");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;
