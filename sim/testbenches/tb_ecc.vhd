-- ============================================================================
-- Testbench: Hamming ECC — SBE/DBE Injection (Combinational DUT)
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_ecc is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_ecc is
    constant C_DW : positive := 64;
    signal data_wr_i : std_logic_vector(C_DW-1 downto 0);
    signal data_rd_i : std_logic_vector(C_DW-1 downto 0);
    signal ecc_rd_i  : std_logic_vector(7 downto 0);
    signal data_o    : std_logic_vector(C_DW-1 downto 0);
    signal ecc_o     : std_logic_vector(7 downto 0);
    signal sbe_o     : std_logic;
    signal dbe_o     : std_logic;
begin
    i_ecc : entity lockstep.hamming_ecc_wrapper
        generic map (G_DATA_WIDTH => C_DW)
        port map (clk_i => '0', rst_n_i => '1',
                  wr_en_i => '1', data_wr_i => data_wr_i,
                  rd_en_i => '1', data_rd_i => data_rd_i,
                  ecc_rd_i => ecc_rd_i,
                  data_o => data_o, ecc_o => ecc_o,
                  sbe_corrected_o => sbe_o, dbe_fatal_o => dbe_o);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        -- Clean: write=0, read=0, ecc matches
        data_wr_i <= (others => '0');
        data_rd_i <= (others => '0');
        wait for 10 ns;
        ecc_rd_i <= ecc_o;
        wait for 10 ns;
        check(sbe_o = '0', "no SBE on clean");
        check(dbe_o = '0', "no DBE on clean");

        -- Inject SBE (flip bit 5 in read data)
        data_rd_i <= (others => '0');
        data_rd_i(5) <= '1';
        wait for 10 ns;
        check(sbe_o = '1', "SBE detected");
        check(dbe_o = '0', "no DBE on SBE");

        -- Inject DBE (flip bits 3,7 in read data)
        data_rd_i <= (others => '0');
        data_rd_i(3) <= '1';
        data_rd_i(7) <= '1';
        wait for 10 ns;
        check(dbe_o = '1', "DBE detected");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;
