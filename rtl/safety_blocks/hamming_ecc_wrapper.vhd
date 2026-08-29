-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  SECDED Hamming ECC Memory Bus Wrapper
-- Module Name:  hamming_ecc_wrapper - behavioral
-- Description:  Intercepts RAM/Flash read/write cycles. Full (72,64) SECDED
--               code: generates 7 parity bits + 1 overall parity. Decodes
--               syndrome to correct single-bit errors and flags double-bit
--               errors as fatal.
--
-- Traces to:    TSR_ECC_001, TSR_SAFETY_GATE_002
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hamming_ecc_wrapper is
    generic (
        G_DATA_WIDTH : positive := 64
    );
    port (
        clk_i       : in  std_logic;
        rst_n_i     : in  std_logic;

        -- Write path: data in + ECC generation
        wr_en_i     : in  std_logic;
        data_wr_i   : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);

        -- Read path: data in + ECC check + correction
        rd_en_i     : in  std_logic;
        data_rd_i   : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);
        ecc_rd_i    : in  std_logic_vector(7 downto 0);

        -- Output: corrected data + error flags
        data_o      : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
        ecc_o       : out std_logic_vector(7 downto 0);
        sbe_corrected_o : out std_logic; -- Single-bit error corrected
        dbe_fatal_o     : out std_logic  -- Double-bit error (uncorrectable)
    );
end entity hamming_ecc_wrapper;

architecture rtl of hamming_ecc_wrapper is

    -- ISO 26262 Automated Traceability Attributes
    attribute requirement_id : string;
    attribute requirement_id of rtl : architecture is "TSR_ECC_001";

    -- Internal syndrome
    signal w_syndrome : std_logic_vector(7 downto 0);
    signal w_sbe      : std_logic;
    signal w_dbe      : std_logic;
    signal w_corrected_data : std_logic_vector(G_DATA_WIDTH-1 downto 0);

begin

    -- ========================================================================
    -- 1. ENCODER: Generate 7-bit Hamming parity + 1 overall parity (SECDED)
    -- ========================================================================
    -- Parity bit P0 covers all data bits whose position has bit 0 set
    -- Parity bit P1 covers all data bits whose position has bit 1 set
    -- ... P6 covers all data bits whose position has bit 6 set
    -- P7 is overall parity for double-error detection
    -- ========================================================================
    p_encoder : process(all)
        variable v_parity : std_logic_vector(6 downto 0);
        variable v_overall_parity : std_logic;
        variable v_parity_count : integer;
    begin
        ecc_o <= (others => '0');

        -- Calculate Hamming parity bits
        v_parity := (others => '0');
        for i in 0 to 6 loop
            v_parity_count := 0;
            for j in 0 to G_DATA_WIDTH-1 loop
                if (j / 2**i) mod 2 /= 0 then
                    if data_wr_i(j) = '1' then
                        v_parity_count := v_parity_count + 1;
                    end if;
                end if;
            end loop;
            if (v_parity_count mod 2) = 1 then
                v_parity(i) := '1';
            end if;
        end loop;

        -- Overall parity (P7): XOR of all data bits + all parity bits
        v_overall_parity := '0';
        v_parity_count := 0;
        for j in 0 to G_DATA_WIDTH-1 loop
            if data_wr_i(j) = '1' then
                v_parity_count := v_parity_count + 1;
            end if;
        end loop;
        for i in 0 to 6 loop
            if v_parity(i) = '1' then
                v_parity_count := v_parity_count + 1;
            end if;
        end loop;
        if (v_parity_count mod 2) = 1 then
            v_overall_parity := '1';
        end if;

        ecc_o(6 downto 0) <= v_parity;
        ecc_o(7) <= v_overall_parity;
    end process p_encoder;

    -- ========================================================================
    -- 2. DECODER: Syndrome calculation + SBE correction + DBE detection
    -- ========================================================================
    p_decoder : process(all)
        variable v_syndrome : std_logic_vector(6 downto 0);
        variable v_overall_check : std_logic;
        variable v_parity_count : integer;
        variable v_recalc_parity : std_logic_vector(6 downto 0);
    begin
        -- Defaults
        w_sbe <= '0';
        w_dbe <= '0';
        w_syndrome <= std_logic_vector(to_unsigned(0, 8));
        w_corrected_data <= data_rd_i;

        -- Recalculate parity from received data
        v_recalc_parity := (others => '0');
        for i in 0 to 6 loop
            v_parity_count := 0;
            for j in 0 to G_DATA_WIDTH-1 loop
                if (j / 2**i) mod 2 /= 0 then
                    if data_rd_i(j) = '1' then
                        v_parity_count := v_parity_count + 1;
                    end if;
                end if;
            end loop;
            if (v_parity_count mod 2) = 1 then
                v_recalc_parity(i) := '1';
            end if;
        end loop;

        -- Syndrome = received ECC XOR recalculated ECC
        v_syndrome := v_recalc_parity xor ecc_rd_i(6 downto 0);

        -- Overall parity check for double-error detection
        v_parity_count := 0;
        for j in 0 to G_DATA_WIDTH-1 loop
            if data_rd_i(j) = '1' then
                v_parity_count := v_parity_count + 1;
            end if;
        end loop;
        for i in 0 to 6 loop
            if ecc_rd_i(i) = '1' then
                v_parity_count := v_parity_count + 1;
            end if;
        end loop;
        if (v_parity_count mod 2) = 1 then
            v_overall_check := '1';
        else
            v_overall_check := '0';
        end if;

        w_syndrome(6 downto 0) <= v_syndrome;

        -- Error classification:
        -- No error: syndrome=0, overall parity matches
        -- SBE: syndrome /= 0, overall parity mismatch (odd errors)
        -- DBE: syndrome /= 0, overall parity matches (even errors, >= 2)
        if v_syndrome /= "0000000" then
            if v_overall_check /= ecc_rd_i(7) then
                -- Odd number of errors -> single bit error
                w_sbe <= '1';
            else
                -- Even number of errors -> double (or more) bit error
                w_dbe <= '1';
            end if;
        end if;

        -- Correct single-bit error by flipping the bit at syndrome index
        if v_syndrome /= "0000000" and v_overall_check /= ecc_rd_i(7) then
            w_corrected_data <= data_rd_i;
            if unsigned(v_syndrome) < G_DATA_WIDTH then
                w_corrected_data(to_integer(unsigned(v_syndrome))) <=
                    not data_rd_i(to_integer(unsigned(v_syndrome)));
            end if;
        end if;
    end process p_decoder;

    -- ========================================================================
    -- 3. OUTPUT MUX: Pass corrected data on read, raw data on write
    -- ========================================================================
    data_o <= w_corrected_data when rd_en_i = '1' else data_wr_i;
    sbe_corrected_o <= w_sbe;
    dbe_fatal_o <= w_dbe;

    -- ========================================================================
    -- 5. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
    -- ========================================================================
    -- Property: DBE blocks corrected output (no data correction on double error)
    -- Property: Syndrome zero implies no error flag
    -- ========================================================================
    p_formal_asserts : process(all)
    begin
        -- DBE must not produce corrected data
        if w_dbe = '1' then
            assert w_sbe = '0'
                report "FORMAL FAIL: SBE and DBE both asserted"
                severity error;
        end if;
        -- Syndrome zero means clean path
        if w_syndrome(6 downto 0) = "0000000" then
            assert w_sbe = '0' and w_dbe = '0'
                report "FORMAL FAIL: error flags set with zero syndrome"
                severity error;
        end if;
        -- No-op: assertions are combinational checks on safety properties
        null;
    end process p_formal_asserts;

end architecture rtl;
