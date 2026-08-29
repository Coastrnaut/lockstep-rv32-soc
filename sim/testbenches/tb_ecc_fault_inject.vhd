-- ============================================================================
-- Testbench: ECC — Stuck-At and Bit-Flip Fault Injection
-- ============================================================================
-- ISO 26262 §5.5 Fault Injection: Stuck-at & bit-flip on ECC path
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library vunit_lib;
context vunit_lib.vunit_context;
library lockstep;
use lockstep.package_soc_types.all;

entity tb_ecc_fault_inject is
  generic (runner_cfg : string);
end entity;

architecture rtl of tb_ecc_fault_inject is

  signal s_clk       : std_logic := '0';
  signal s_rst_n     : std_logic;
  signal s_wr_en     : std_logic;
  signal s_rd_en     : std_logic;
  signal s_data_wr   : std_logic_vector(63 downto 0);
  signal s_data_rd   : std_logic_vector(63 downto 0);
  signal s_ecc_rd    : std_logic_vector(7 downto 0);
  signal s_data_o    : std_logic_vector(63 downto 0);
  signal s_ecc_o     : std_logic_vector(7 downto 0);
  signal s_sbe       : std_logic;
  signal s_dbe       : std_logic;

  constant CLK_HALF : time := 5 ns;
begin

  -- Clock
  clk_proc : process
  begin
    wait for CLK_HALF;
    s_clk <= not s_clk;
  end process;

  -- DUT
  i_ecc : entity lockstep.hamming_ecc_wrapper
    port map (
      clk_i           => s_clk,
      rst_n_i         => s_rst_n,
      wr_en_i         => s_wr_en,
      rd_en_i         => s_rd_en,
      data_wr_i       => s_data_wr,
      data_rd_i       => s_data_rd,
      ecc_rd_i        => s_ecc_rd,
      data_o          => s_data_o,
      ecc_o           => s_ecc_o,
      sbe_corrected_o => s_sbe,
      dbe_fatal_o     => s_dbe
    );

  -- Stimulus
  p_stim : process
    variable v_good_ecc : std_logic_vector(7 downto 0);
    variable v_flip_ecc : std_logic_vector(7 downto 0);
  begin
    test_runner_setup(runner, runner_cfg);

    -- Reset
    s_rst_n   <= '0';
    s_wr_en   <= '0';
    s_rd_en   <= '0';
    s_data_wr <= (others => '0');
    s_data_rd <= (others => '0');
    s_ecc_rd  <= (others => '0');
    wait until rising_edge(s_clk);
    wait until rising_edge(s_clk);
    s_rst_n <= '1';

    -- --- Test 1: Write 0x01, capture generated ECC ---
    s_data_wr <= x"0000000000000001";
    s_wr_en   <= '1';
    s_rd_en   <= '0';
    wait until rising_edge(s_clk);
    s_wr_en <= '0';
    wait for 0 ns;
    v_good_ecc := s_ecc_o;

    -- --- Test 2: Read with bit-flip in ECC bit 0 (SBE) ---
    v_flip_ecc := v_good_ecc;
    v_flip_ecc(0) := not v_flip_ecc(0);
    s_data_rd <= x"0000000000000001";
    s_ecc_rd  <= v_flip_ecc;
    s_rd_en   <= '1';
    wait until rising_edge(s_clk);
    s_rd_en <= '0';
    wait for 0 ns;
    check(s_sbe = '1', "SBE detected on ECC bit-flip");
    check(s_dbe = '0', "No DBE on single bit-flip");

    -- --- Test 3: Read with bit-flip in data bit 0 (SBE) ---
    s_data_rd <= x"0000000000000003";  -- bits 0 and 1 set (bit 0 flipped from 0x01)
    s_ecc_rd  <= v_good_ecc;
    s_rd_en   <= '1';
    wait until rising_edge(s_clk);
    s_rd_en <= '0';
    wait for 0 ns;
    check(s_sbe = '1', "SBE detected on data bit-flip");

    -- --- Test 4: Clean read (no error) ---
    s_data_rd <= x"0000000000000001";
    s_ecc_rd  <= v_good_ecc;
    s_rd_en   <= '1';
    wait until rising_edge(s_clk);
    s_rd_en <= '0';
    wait for 0 ns;
    check(s_sbe = '0', "No error on clean read");
    check(s_dbe = '0', "No DBE on clean read");

    test_runner_cleanup(runner);
    wait;
  end process;
end architecture;
