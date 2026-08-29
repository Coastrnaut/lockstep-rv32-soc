-- ============================================================================
-- Testbench: CAN Controller — Frame TX + Safety Gate
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_can is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_can is
    constant CLK_PERIOD : time := 20 ns;
    signal tb_clk   : std_logic := '0';
    signal tb_rst_n : std_logic := '0';
    signal bus_i    : t_rv_bus := (addr => (others => '0'),
                                   data => (others => '0'),
                                   we   => '0',
                                   valid => '0');
    signal bus_ok   : std_logic := '1';
    signal can_tx   : std_logic;
    signal can_busy : std_logic;
begin
    tb_clk <= not tb_clk after CLK_PERIOD / 2;

    i_can : entity lockstep.automotive_can_controller
        port map (clk_i      => tb_clk,
                  rst_n_i    => tb_rst_n,
                  bus_i      => bus_i,
                  bus_ok_i   => bus_ok,
                  can_tx_o   => can_tx,
                  can_rx_i   => '1',
                  can_busy_o => can_busy);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        tb_rst_n <= '0';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;
        tb_rst_n <= '1';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;

        -- --- Test 1: Idle bus ---
        check(can_busy = '0', "CAN idle at start");

        -- --- Test 2: Load mailbox and TX frame ---
        -- Set data BEFORE the clock edge so p_mailbox sees it
        bus_i <= (addr  => (others => '0'),
                  data  => x"7FF08000",
                  we    => '1',
                  valid => '1');
        wait until rising_edge(tb_clk);  -- mailbox loads here
        bus_i <= (addr => (others => '0'),
                  data => (others => '0'),
                  we   => '0',
                  valid => '0');
        wait until rising_edge(tb_clk);  -- FSM sees mailbox_full, transitions
        wait until rising_edge(tb_clk);  -- extra cycle for FSM to settle
        check(can_busy = '1', "CAN busy after mailbox load");

        -- --- Test 3: Safety gate drops → TX forced recessive ---
        bus_ok <= '0';
        wait until rising_edge(tb_clk);
        check(can_tx = '1', "TX recessive when safety gate drops");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;