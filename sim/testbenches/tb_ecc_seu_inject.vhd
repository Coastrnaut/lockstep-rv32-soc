-- ============================================================================
-- Design Name:  Transient SEU Single/Double Bit-Flip Injection
-- Description:  Drives hamming_ecc_wrapper with corrupted data+ecc pairs
--               to test single-bit and double-bit error detection/correction.
-- Traces to:    VERIFICATION_SPECIFICATION.md 3B
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library lockstep;
use lockstep.package_soc_types.all;

entity tb_ecc_seu_inject is
    generic ( runner_cfg : string );
end entity;

architecture tb of tb_ecc_seu_inject is
    constant CLK_PERIOD : time := 20 ns;
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';

    signal ecc_wr_en   : std_logic;
    signal ecc_data_wr : std_logic_vector(63 downto 0);
    signal ecc_rd_en   : std_logic;
    signal ecc_data_rd : std_logic_vector(63 downto 0);
    signal ecc_rd_ecc  : std_logic_vector(7 downto 0);

    signal ecc_data_o : std_logic_vector(63 downto 0);
    signal ecc_out    : std_logic_vector(7 downto 0);
    signal ecc_sbe    : std_logic;
    signal ecc_dbe    : std_logic;
begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity lockstep.hamming_ecc_wrapper
        port map (
            clk_i           => clk,
            rst_n_i         => rst_n,
            wr_en_i         => ecc_wr_en,
            data_wr_i       => ecc_data_wr,
            rd_en_i         => ecc_rd_en,
            data_rd_i       => ecc_data_rd,
            ecc_rd_i        => ecc_rd_ecc,
            data_o          => ecc_data_o,
            ecc_o           => ecc_out,
            sbe_corrected_o => ecc_sbe,
            dbe_fatal_o     => ecc_dbe
        );

    p_test : process
        variable v_sbe  : std_logic;
        variable v_dbe  : std_logic;
    begin
        test_runner_setup(runner, "SEU Single/Double Bit-Flip Injection");

        rst_n <= '0';
        wait for 100 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- TEST 1: Clean write + read baseline
        report "TEST: Clean write+read baseline";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"0123456789ABCDEF";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"0123456789ABCDEF";
        ecc_rd_ecc <= (others => '0');
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_sbe = '0', "clean: no SBE");
        check(v_dbe = '0', "clean: no DBE");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 2: Single-bit flip on data bit 0
        report "TEST: SEU single-bit flip data(0)";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"0000000000000001";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"0000000000000000";
        ecc_rd_ecc <= (others => '0');
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_sbe = '1', "SEU bit0: SBE detected");
        check(v_dbe = '0', "SEU bit0: no DBE");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 3: Single-bit flip on data bit 31
        report "TEST: SEU single-bit flip data(31)";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"8000000000000000";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"0000000000000000";
        ecc_rd_ecc <= (others => '0');
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_sbe = '1', "SEU bit31: SBE detected");
        check(v_dbe = '0', "SEU bit31: no DBE");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 4: Single-bit flip on ECC bit 0
        report "TEST: SEU single-bit flip ecc(0)";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"FFFFFFFFFFFFFFFF";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"FFFFFFFFFFFFFFFF";
        ecc_rd_ecc <= x"01";
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_sbe = '1', "SEU ecc(0): SBE detected");
        check(v_dbe = '0', "SEU ecc(0): no DBE");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 5: Double-bit flip (data bit 0 + bit 1)
        report "TEST: SEU double-bit flip data(0)+data(1)";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"0000000000000003";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"0000000000000000";
        ecc_rd_ecc <= (others => '0');
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_dbe = '1', "DBE data(0)+data(1): DBE detected");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 6: Double-bit flip (data + ECC)
        report "TEST: SEU double-bit flip data(0)+ecc(0)";
        ecc_wr_en <= '1';
        ecc_data_wr <= x"0000000000000001";
        wait until rising_edge(clk);
        ecc_wr_en <= '0';
        wait for CLK_PERIOD;

        ecc_rd_en <= '1';
        ecc_data_rd <= x"0000000000000000";
        ecc_rd_ecc <= x"01";
        wait for 0 ns;

        v_sbe := ecc_sbe;
        v_dbe := ecc_dbe;
        check(v_dbe = '1', "DBE data+ecc: DBE detected");
        ecc_rd_en <= '0';
        wait for CLK_PERIOD;

        -- TEST 7: SEU campaign bits 0-7
        report "TEST: SEU campaign bits 0-7";
        for dummy in 0 to 7 loop
            ecc_wr_en <= '1';
            ecc_data_wr <= std_logic_vector(to_unsigned(2**dummy, 64));
            wait until rising_edge(clk);
            ecc_wr_en <= '0';
            wait for CLK_PERIOD;

            ecc_rd_en <= '1';
            ecc_data_rd <= x"0000000000000000";
            ecc_rd_ecc <= (others => '0');
            wait for 0 ns;

            v_sbe := ecc_sbe;
            v_dbe := ecc_dbe;
            check(v_sbe = '1', "campaign bit" & integer'image(dummy) & ": SBE");
            check(v_dbe = '0', "campaign bit" & integer'image(dummy) & ": no DBE");
            ecc_rd_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        test_runner_cleanup(runner);
        wait;
    end process;

end architecture tb;
