-- ============================================================================
-- Testbench: UART TX Error Flag and Recovery
-- ============================================================================
-- Covers: TX busy state transitions, recovery after reset, safety gate
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_uart_tx_error is
  generic (
    runner_cfg : string := ""
  );
end entity tb_uart_tx_error;

architecture rtl of tb_uart_tx_error is

  constant clk_period : time := 20 ns;
  signal   clk        : std_logic;
  signal   rst_n      : std_logic;

  signal bus_i     : t_rv_bus;
  signal bus_ok    : std_logic;
  signal uart_tx   : std_logic;
  signal uart_err  : std_logic;
  signal uart_busy : std_logic;

  -- Component declarations (VSG compliance)
  component safe_uart is end component safe_uart;

begin

  clk <= not clk after clk_period / 2;

  i_uart : component safe_uart
    port map (
      clk_i        => clk,
      rst_n_i      => rst_n,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok,
      uart_tx_o    => uart_tx,
      uart_busy_o  => uart_busy,
      uart_error_o => uart_err

    );p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    rst_n  <= '0';
    bus_i  <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');
    bus_ok <= '1';
    wait for 100 ns;
    rst_n  <= '1';
    wait for clk_period * 2;

    -- --- Test 1: Idle baseline ---
    check(uart_busy = '0', "idle: not busy");
    check(uart_err = '0', "idle: no error");

    -- --- Test 2: TX triggers busy state ---
    -- Rising edge 1: r_tx_valid set to '1' in p_rx_regs
    bus_i       <= (addr => x"00000000", data => x"00000041", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    -- Rising edge 2: FSM sees r_tx_valid='1', transitions to UART_START
    wait until rising_edge(clk);
    -- Rising edge 3: uart_busy_o reflects new state (registered signal)
    wait until rising_edge(clk);
    wait for 0 ns;
    check(uart_busy = '1', "TX in progress: busy asserted");
    -- Wait for TX to complete (baud div = 434, ~10 bits => ~4340 cycles)
    wait for clk_period * 5000;
    wait for 0 ns;
    check(uart_busy = '0', "TX complete: idle");

    -- --- Test 3: TX while bus_ok dropped (safety gate) ---
    bus_ok      <= '0';
    bus_i       <= (addr => x"00000000", data => x"00000042", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 3;
    bus_ok      <= '1';
    wait for clk_period * 5;
    check(uart_busy = '0', "safety gate: returned to idle");

    -- --- Test 4: Recovery after reset ---
    rst_n <= '0';
    wait for 100 ns;
    rst_n <= '1';
    wait for clk_period * 2;
    check(uart_err = '0', "recovery: error cleared");
    check(uart_busy = '0', "recovery: not busy");

    -- --- Test 5: Back-to-back TX with proper wait ---
    for dummy in 0 to 1 loop

      bus_i       <= (addr => x"00000000", data => std_logic_vector(to_unsigned(dummy + 65, 32)), we => '1', valid => '1');
      wait until rising_edge(clk);
      bus_i.valid <= '0';
      wait for clk_period * 5000;

    end loop;

    check(uart_busy = '0', "back-to-back: idle after all tx");
    check(uart_err = '0', "back-to-back: no error");

    test_runner_cleanup(runner);
    wait;

  end process p_stim;

end architecture rtl;
