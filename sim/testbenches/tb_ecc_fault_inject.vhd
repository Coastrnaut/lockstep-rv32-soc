-- ============================================================================
-- Testbench: ECC — Stuck-At and Bit-Flip Fault Injection
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_ecc_fault_inject is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_ecc_fault_inject is
    signal s_clk       : std_logic := '0';
    signal s_rst_n     : std_logic := '0';
    signal s_wr_en     : std_logic := '0';
    signal s_rd_en     : std_logic := '0';
    signal s_data_wr   : std_logic_vector(63 downto 0) := (others => '0');
    signal s_data_rd   : std_logic_vector(63 downto 0) := (others => '0');
    signal s_ecc_rd    : std_logic_vector(7 downto 0)  := (others => '0');
    signal s_data_o    : std_logic_vector(63 downto 0);
    signal s_ecc_o     : std_logic_vector(7 downto 0);
    signal s_sbe       : std_logic;
    signal s_dbe       : std_logic;
begin
    s_clk <= not s_clk after 10 ns;

    i_ecc : entity lockstep.hamming_ecc_wrapper
        generic map (G_DATA_WIDTH => 64)
        port map (clk_i       => s_clk,
                  rst_n_i     => s_rst_n,
                  wr_en_i     => s_wr_en,
                  data_wr_i   => s_data_wr,
                  rd_en_i     => s_rd_en,
                  data_rd_i   => s_data_rd,
                  ecc_rd_i    => s_ecc_rd,
                  data_o      => s_data_o,
                  ecc_o       => s_ecc_o,
                  sbe_corrected_o => s_sbe,
                  dbe_fatal_o     => s_dbe);

    p_stim : process
        variable v_ecc_good : std_logic_vector(7 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        -- --- Reset ---
        s_rst_n <= '0';
        for dummy in 1 to 3 loop wait until rising_edge(s_clk); end loop;
        s_rst_n <= '1';
        wait until rising_edge(s_clk);

        -- --- Test 1: Encode data, then inject stuck-at-0 on ECC bit 0 ---
        -- Set data BEFORE enabling write so encoder sees the correct value
        s_data_wr <= x"00000000000000FF";
        wait for 0 ns;  -- let delta cycle settle
        s_wr_en   <= '1';
        s_rd_en   <= '0';
        wait until rising_edge(s_clk);  -- encoder computes ECC for 0xFF data
        s_wr_en   <= '0';
        wait for 0 ns;
        v_ecc_good := s_ecc_o;
        check(v_ecc_good /= x"00", "ECC non-zero for non-zero data");

        -- Read back with ECC bit 0 flipped (stuck-at-0)
        s_data_rd <= s_data_wr;
        s_ecc_rd  <= v_ecc_good;
        s_ecc_rd(0) <= not s_ecc_rd(0);  -- flip ECC bit 0
        s_rd_en   <= '1';
        wait for 0 ns;
        check(s_sbe = '1', "SBE detected on ECC bit-flip");
        check(s_dbe = '0', "not DBE on single ECC flip");
        s_rd_en <= '0';

        -- --- Test 2: Inject data bit-flip (stuck-at on data bit 0) ---
        s_data_rd <= x"00000000000000FF";
        s_data_rd(0) <= not s_data_rd(0);  -- flip data bit 0
        s_ecc_rd  <= v_ecc_good;  -- original ECC (mismatch)
        s_rd_en   <= '1';
        wait for 0 ns;
        check(s_sbe = '1', "SBE detected on data bit-flip");
        check(s_dbe = '0', "not DBE on single data flip");
        check(s_data_o(0) = s_data_wr(0), "corrected data bit 0 matches original");
        s_rd_en <= '0';

        -- --- Test 3: Double-bit error (flip 2 data bits) ---
        s_data_rd <= x"00000000000000FF";
        s_data_rd(0) <= not s_data_rd(0);
        s_data_rd(1) <= not s_data_rd(1);
        s_ecc_rd  <= v_ecc_good;
        s_rd_en   <= '1';
        wait for 0 ns;
        check(s_dbe = '1', "DBE detected on double bit-flip");
        check(s_sbe = '0', "SBE not set on double flip");
        s_rd_en <= '0';

        -- --- Test 4: Clean read (no error) ---
        s_data_rd <= s_data_wr;
        s_ecc_rd  <= v_ecc_good;
        s_rd_en   <= '1';
        wait for 0 ns;
        check(s_sbe = '0', "no SBE on clean read");
        check(s_dbe = '0', "no DBE on clean read");
        check(s_data_o = s_data_wr, "data passes through clean");
        s_rd_en <= '0';

        test_runner_cleanup(runner);
    end process;
end architecture rtl;