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
    constant C_DW : positive := 64;
    signal data_wr_i : std_logic_vector(C_DW-1 downto 0) := (others => '0');
    signal data_rd_i : std_logic_vector(C_DW-1 downto 0) := (others => '0');
    signal ecc_rd_i  : std_logic_vector(7 downto 0)     := (others => '0');
    signal data_o    : std_logic_vector(C_DW-1 downto 0);
    signal ecc_o     : std_logic_vector(7 downto 0);
    signal sbe_o     : std_logic;
    signal dbe_o     : std_logic;
begin
    i_ecc : entity lockstep.hamming_ecc_wrapper
        generic map (G_DATA_WIDTH => C_DW)
        port map (clk_i             => '0',
                  rst_n_i           => '1',
                  wr_en_i           => '1',
                  data_wr_i         => data_wr_i,
                  rd_en_i           => '1',
                  data_rd_i         => data_rd_i,
                  ecc_rd_i          => ecc_rd_i,
                  data_o            => data_o,
                  ecc_o             => ecc_o,
                  sbe_corrected_o   => sbe_o,
                  dbe_fatal_o       => dbe_o);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        -- --- Fault 1: Stuck-at-0 on ECC parity bit ---
        data_wr_i <= x"FFFFFFFFFFFFFFFF";
        wait for 10 ns;
        data_rd_i <= x"FFFFFFFFFFFFFFFF";
        ecc_rd_i  <= (others => '0');  -- Force all-parity-zero (stuck at 0)
        wait for 10 ns;
        check(sbe_o = '1', "SBE on stuck-at-0 parity");

        -- --- Fault 2: Stuck-at-1 on ECC parity bit ---
        ecc_rd_i <= (others => '1');  -- Force all-parity-one (stuck at 1)
        wait for 10 ns;
        check(sbe_o = '1', "SBE on stuck-at-1 parity");

        -- --- Fault 3: Multi-bit data corruption (DBE) ---
        data_rd_i <= (others => '0');
        data_rd_i(0) <= '1';
        data_rd_i(1) <= '1';
        data_rd_i(2) <= '1';
        wait for 10 ns;
        check(dbe_o = '1', "DBE on triple-bit corruption");

        -- --- Fault 4: Random single-bit at each position ---
        for i in 0 to 63 loop
            data_rd_i <= (others => '0');
            data_rd_i(i) <= '1';
            wait for 10 ns;
            check(sbe_o = '1', "SBE detected at bit " & integer'image(i));
        end loop;

        test_runner_cleanup(runner);
    end process;
end architecture rtl;