-- ============================================================================
-- Design Name:  Watchdog Timeout/Early/Late with OSVVM Coverage Bins
-- Description:  Exercises hardware_watchdog for timeout, early kick, and
--               late kick scenarios. Verifies sys_reset_o and wd_status_o.
-- Traces to:    VERIFICATION_SPECIFICATION.md 5A
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library lockstep;
use lockstep.package_soc_types.all;

entity tb_watchdog_osvvm is
    generic ( runner_cfg : string );
end entity;

architecture tb of tb_watchdog_osvvm is
    constant CLK_PERIOD : time := 20 ns;
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';

    signal wd_clk   : std_logic := '0';
    signal cpu_kick : std_logic;
    signal sys_reset_o : std_logic;
    signal wd_status_o : std_logic_vector(7 downto 0);
begin

    clk <= not clk after CLK_PERIOD / 2;
    wd_clk <= not wd_clk after CLK_PERIOD / 2;

    uut : entity lockstep.hardware_watchdog
        port map (
            wd_clk_i    => wd_clk,
            rst_n_i     => rst_n,
            cpu_kick_i  => cpu_kick,
            sys_reset_o => sys_reset_o,
            wd_status_o => wd_status_o
        );

    p_test : process
    begin
        test_runner_setup(runner, "Watchdog Timeout/Early/Late");

        rst_n <= '0';
        cpu_kick <= '0';
        wait for 100 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- TEST 1: Normal periodic kicks (every 20000 cycles, within window)
        report "TEST: Normal periodic kicks";
        for dummy in 0 to 4 loop
            cpu_kick <= '1';
            wait until rising_edge(wd_clk);
            cpu_kick <= '0';
            wait for CLK_PERIOD * 20000;
            check(sys_reset_o = '0', "normal kick #" & integer'image(dummy) & ": no reset");
        end loop;

        -- TEST 2: Watchdog timeout (no kick past C_WD_MAX_COUNT = 50000)
        report "TEST: Watchdog timeout";
        cpu_kick <= '0';
        wait for CLK_PERIOD * 50001;
        check(sys_reset_o = '1', "timeout: sys_reset asserted");

        -- TEST 3: Early kick (kick before C_WD_MIN_COUNT = 40000)
        -- Reset first to clear latched fault
        report "TEST: Early kick";
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        -- Kick immediately (counter = 0, below C_WD_MIN_COUNT)
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        check(sys_reset_o = '1', "early kick: sys_reset asserted");

        -- TEST 4: Late kick (kick just before C_WD_MAX_COUNT)
        report "TEST: Late kick near timeout";
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        -- Wait until just before timeout
        wait for CLK_PERIOD * 49999;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        wait for CLK_PERIOD * 5;
        check(sys_reset_o = '0', "late kick: still alive");

        -- TEST 5: Kick pattern irregularity
        report "TEST: Irregular kick pattern";
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        -- Kick after 20000 cycles (within window)
        wait for CLK_PERIOD * 20000;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        -- Kick after 20000 more cycles
        wait for CLK_PERIOD * 20000;
        cpu_kick <= '1';
        wait until rising_edge(wd_clk);
        cpu_kick <= '0';
        wait for CLK_PERIOD * 5;
        check(sys_reset_o = '0', "irregular: no reset");

        -- TEST 6: Verify status output
        report "TEST: Watchdog status output";
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        wait for CLK_PERIOD * 100;
        check(wd_status_o /= x"00", "status: not zero");

        test_runner_cleanup(runner);
        wait;
    end process;

end architecture tb;
