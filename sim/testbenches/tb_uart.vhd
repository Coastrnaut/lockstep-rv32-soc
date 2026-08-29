-- ============================================================================
-- Testbench: Safe UART — TX + Parity Protection
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_uart is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_uart is
    constant CLK_PERIOD : time := 20 ns;
    signal tb_clk   : std_logic := '0';
    signal tb_rst_n : std_logic := '0';
    signal bus_i    : t_rv_bus := (addr => (others => '0'),
                                   data => (others => '0'),
                                   we   => '0',
                                   valid => '0');
    signal bus_ok   : std_logic := '1';
    signal uart_tx  : std_logic;
    signal uart_busy: std_logic;
    signal uart_err : std_logic;
begin
    tb_clk <= not tb_clk after CLK_PERIOD / 2;

    i_uart : entity lockstep.safe_uart
        port map (clk_i      => tb_clk,
                  rst_n_i    => tb_rst_n,
                  bus_i      => bus_i,
                  bus_ok_i   => bus_ok,
                  uart_tx_o  => uart_tx,
                  uart_busy_o => uart_busy,
                  uart_error_o => uart_err);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        tb_rst_n <= '0';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;
        tb_rst_n <= '1';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;

        -- --- Test 1: Idle state ---
        check(uart_busy = '0', "UART idle at start");
        check(uart_tx   = '1', "TX recessive at idle");

        -- --- Test 2: Write valid data → TX starts ---
        bus_i <= (addr  => (others => '0'),
                  data  => x"00000041",
                  we    => '1',
                  valid => '1');
        wait until rising_edge(tb_clk);  -- p_rx_regs accepts write
        bus_i <= (addr => (others => '0'),
                  data => (others => '0'),
                  we   => '0',
                  valid => '0');
        wait until rising_edge(tb_clk);  -- FSM sees r_tx_valid, transitions
        wait until rising_edge(tb_clk);  -- extra cycle for FSM to settle
        check(uart_busy = '1', "UART busy after write");
        check(uart_err  = '0', "no parity error on valid write");

        -- --- Test 3: Wait for TX to finish ---
        for dummy in 1 to 5000 loop
            wait until rising_edge(tb_clk);
            if uart_busy = '0' then exit; end if;
        end loop;
        check(uart_busy = '0', "UART idle after TX complete");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;