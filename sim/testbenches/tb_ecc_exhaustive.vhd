-- ============================================================================
-- Testbench: ECC Exhaustive
-- ============================================================================
-- Flips every bit of the stored word, and every pair of bits, check bits
-- included. SECDED promises to correct all of the first and report all of the
-- second, so sampling a few bit positions is not enough to show that it does.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;

entity tb_ecc_exhaustive is
  generic (
    runner_cfg : string := ""
  );
end entity tb_ecc_exhaustive;

architecture tb of tb_ecc_exhaustive is

  constant c_data_width : positive := 64;
  constant c_code_width : positive := c_data_width + 8;
  constant c_settle     : time     := 1 ns;

  subtype t_data is std_logic_vector(c_data_width - 1 downto 0);

  subtype t_code is std_logic_vector(c_code_width - 1 downto 0);

  type t_data_list is array (natural range <>) of t_data;

  constant c_values : t_data_list :=
  (
    x"0000000000000000",
    x"FFFFFFFFFFFFFFFF",
    x"0000000000000001",
    x"8000000000000000",
    x"A5A5A5A55A5A5A5A",
    x"0123456789ABCDEF"
  );

  signal clk       : std_logic;
  signal rst_n     : std_logic;
  signal data_wr   : t_data;
  signal ecc_wr    : std_logic_vector(7 downto 0);
  signal data_rd   : t_data;
  signal ecc_rd    : std_logic_vector(7 downto 0);
  signal corrected : t_data;
  signal sbe       : std_logic;
  signal dbe       : std_logic;

begin

  clk   <= '0';
  rst_n <= '1';

  dut : entity lockstep.hamming_ecc_wrapper
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      wr_en_i         => '0',
      data_wr_i       => data_wr,
      rd_en_i         => '1',
      data_rd_i       => data_rd,
      ecc_rd_i        => ecc_rd,
      data_o          => corrected,
      ecc_o           => ecc_wr,
      sbe_corrected_o => sbe,
      dbe_fatal_o     => dbe
    );

  p_stim : process is

    variable v_code : t_code;

    procedure encode (
      constant value : in t_data
    ) is
    begin

      data_wr <= value;
      wait for c_settle;
      v_code  := ecc_wr & value;

    end procedure encode;

    procedure decode (
      constant code : in t_code
    ) is
    begin

      data_rd <= code(c_data_width - 1 downto 0);
      ecc_rd  <= code(c_code_width - 1 downto c_data_width);
      wait for c_settle;

    end procedure decode;

    procedure flip (
      variable code  : inout t_code;
      constant index : in natural
    ) is
    begin

      code(index) := not code(index);

    end procedure flip;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("clean_words_read_back_with_no_error") then

        for value in c_values'range loop

          encode(c_values(value));
          decode(v_code);
          check_equal(corrected, c_values(value), "data");
          check_equal(sbe, '0', "no single-bit error");
          check_equal(dbe, '0', "no double-bit error");

        end loop;

      elsif run("every_single_bit_flip_is_corrected") then

        for value in c_values'range loop

          for bit_a in 0 to c_code_width - 1 loop

            encode(c_values(value));
            flip(v_code, bit_a);
            decode(v_code);
            check_equal(corrected, c_values(value), "data after flipping bit " & integer'image(bit_a));
            check_equal(sbe, '1', "reported after flipping bit " & integer'image(bit_a));
            check_equal(dbe, '0', "not fatal after flipping bit " & integer'image(bit_a));

          end loop;

        end loop;

      elsif run("three_flips_that_name_no_bit_are_fatal") then
        -- Check bits at positions 1, 8 and 64 leave a syndrome of 73, and the
        -- highest position in the word is 71
        encode(c_values(0));
        flip(v_code, 64);
        flip(v_code, 67);
        flip(v_code, 70);
        decode(v_code);
        check_equal(dbe, '1', "fatal");
        check_equal(sbe, '0', "not corrected");
      elsif run("every_double_bit_flip_is_reported") then

        for value in c_values'range loop

          encode(c_values(value));

          for bit_a in 0 to c_code_width - 2 loop

            for bit_b in bit_a + 1 to c_code_width - 1 loop

              flip(v_code, bit_a);
              flip(v_code, bit_b);
              decode(v_code);
              check_equal(dbe, '1', "fatal after flipping bits " & integer'image(bit_a) & " and " &
                          integer'image(bit_b));
              check_equal(sbe, '0', "not corrected after flipping bits " & integer'image(bit_a) & " and " &
                          integer'image(bit_b));
              flip(v_code, bit_a);
              flip(v_code, bit_b);

            end loop;

          end loop;

        end loop;

      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
