-- ============================================================================
-- Testbench: ECC Write-Read Verification
-- ============================================================================
-- Covers: write data, read back with correct ECC, concurrent R/W,
--          ECC generation verification, clean path
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_ecc_write_read is
  generic (
    runner_cfg : string := ""
  );
end entity tb_ecc_write_read;

architecture rtl of tb_ecc_write_read is

  signal s_clk     : std_logic;
  signal s_rst_n   : std_logic;
  signal s_wr_en   : std_logic;
  signal s_rd_en   : std_logic;
  signal s_data_wr : std_logic_vector(63 downto 0);
  signal s_data_rd : std_logic_vector(63 downto 0);
  signal s_ecc_rd  : std_logic_vector(7 downto 0);
  signal s_data_o  : std_logic_vector(63 downto 0);
  signal s_ecc_o   : std_logic_vector(7 downto 0);
  signal s_sbe     : std_logic;
  signal s_dbe     : std_logic;

  constant clk_half : time := 5 ns;begin

  clk_proc : process is
  begin

    s_clk <= '0';
    wait for clk_half;

    loop

      s_clk <= not s_clk;
      wait for clk_half;

    end loop;

  end process clk_proc;

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

    );p_stim : process is

    variable v_good_ecc    : std_logic_vector(7 downto 0);
    variable v_ecc_nonzero : boolean;

  begin

    test_runner_setup(runner, runner_cfg);

    s_rst_n   <= '0';
    s_wr_en   <= '0';
    s_rd_en   <= '0';
    s_data_wr <= (others => '0');
    s_data_rd <= (others => '0');
    s_ecc_rd  <= (others => '0');
    wait until rising_edge(s_clk);
    wait until rising_edge(s_clk);
    s_rst_n   <= '1';

    -- --- Test 1: Write known pattern, capture ECC ---
    s_data_wr  <= x"DEADBEEFCAFEBABE";
    s_wr_en    <= '1';
    s_rd_en    <= '0';
    wait until rising_edge(s_clk);
    s_wr_en    <= '0';
    v_good_ecc := s_ecc_o;

    -- --- Test 2: Read back with correct ECC — no error ---
    s_data_rd <= x"DEADBEEFCAFEBABE";
    s_ecc_rd  <= v_good_ecc;
    s_rd_en   <= '1';
    wait for 0 ns;
    check(s_sbe = '0', "clean read: no SBE");
    check(s_dbe = '0', "clean read: no DBE");
    wait until rising_edge(s_clk);
    s_rd_en   <= '0';

    -- --- Test 3: Write all-ones, capture ECC ---
    s_data_wr  <= x"FFFFFFFFFFFFFFFF";
    s_wr_en    <= '1';
    wait until rising_edge(s_clk);
    s_wr_en    <= '0';
    v_good_ecc := s_ecc_o;

    -- --- Test 4: Read all-ones with correct ECC ---
    s_data_rd <= x"FFFFFFFFFFFFFFFF";
    s_ecc_rd  <= v_good_ecc;
    s_rd_en   <= '1';
    wait for 0 ns;
    check(s_sbe = '0', "all-ones clean: no SBE");
    wait until rising_edge(s_clk);
    s_rd_en   <= '0';

    -- --- Test 5: Write all-zeros, capture ECC ---
    s_data_wr  <= (others => '0');
    s_wr_en    <= '1';
    wait until rising_edge(s_clk);
    s_wr_en    <= '0';
    v_good_ecc := s_ecc_o;

    -- --- Test 6: Read all-zeros with correct ECC ---
    s_data_rd <= (others => '0');
    s_ecc_rd  <= v_good_ecc;
    s_rd_en   <= '1';
    wait for 0 ns;
    check(s_sbe = '0', "all-zeros clean: no SBE");
    wait until rising_edge(s_clk);
    s_rd_en   <= '0';

    -- --- Test 7: Write pattern, verify ECC is generated (non-zero) ---
    s_data_wr <= x"0000000000000001";  -- single bit, ECC must be non-zero
    s_wr_en   <= '1';
    wait until rising_edge(s_clk);
    s_wr_en   <= '0';
    -- Check ECC has at least one bit set
    v_ecc_nonzero := false;

    for i in 0 to 7 loop

      if (s_ecc_o(i) = '1') then
        v_ecc_nonzero := true;
      end if;

    end loop;

    check(v_ecc_nonzero, "ECC generated: non-zero for single-bit data");

    -- --- Test 8: Verify data output matches written data ---
    check(s_data_o = x"0000000000000001", "data output: matches written");

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process p_stim;

end architecture rtl;
