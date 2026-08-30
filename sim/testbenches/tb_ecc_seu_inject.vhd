
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;

entity tb_ecc_seu_inject is
  generic (
    runner_cfg : string := ""
  );
end entity tb_ecc_seu_inject;

architecture tb of tb_ecc_seu_inject is

  constant clk_period  : time := 20 ns;
  signal   clk         : std_logic;
  signal   rst_n       : std_logic;
  signal   ecc_wr_en   : std_logic;
  signal   ecc_data_wr : std_logic_vector(63 downto 0);
  signal   ecc_rd_en   : std_logic;
  signal   ecc_data_rd : std_logic_vector(63 downto 0);
  signal   ecc_rd_ecc  : std_logic_vector(7 downto 0);
  signal   ecc_data_o  : std_logic_vector(63 downto 0);
  signal   ecc_out     : std_logic_vector(7 downto 0);
  signal   ecc_sbe     : std_logic;
  signal   ecc_dbe     : std_logic;

begin

  clk <= not clk after clk_period / 2;

  -- Entity instantiation for correct library binding
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

  p_test : process is

    variable v_sbe      : std_logic;
    variable v_dbe      : std_logic;
    variable v_good_ecc : std_logic_vector(7 downto 0);

  begin

    test_runner_setup(runner, runner_cfg);

    rst_n <= '0';
    wait for 100 ns;
    rst_n <= '1';
    wait for clk_period * 2;

    -- TEST 1: Clean write + read baseline
    report "TEST: Clean write+read baseline";
    ecc_wr_en   <= '1';
    ecc_data_wr <= (others => '0');
    wait until rising_edge(clk);
    ecc_wr_en   <= '0';
    wait for clk_period;

    ecc_rd_en   <= '1';
    ecc_data_rd <= (others => '0');
    ecc_rd_ecc  <= (others => '0');
    wait for 5 ns;
    v_sbe       := ecc_sbe;
    v_dbe       := ecc_dbe;
    check(v_sbe = '0', "clean: no SBE");
    check(v_dbe = '0', "clean: no DBE");
    ecc_rd_en   <= '0';
    ecc_data_rd <= (others => '0');
    ecc_rd_ecc  <= (others => '0');
    wait for clk_period;

    -- TEST 2: Single-bit flip data(1) — bit 1 IS covered by ECC
    report "TEST: SEU single-bit flip data(1)";
    ecc_wr_en   <= '1';
    ecc_data_wr <= x"0000000000000002";                                       -- bit 1 set
    wait until rising_edge(clk);
    v_good_ecc  := ecc_out;
    ecc_wr_en   <= '0';
    ecc_data_wr <= (others => '0');
    wait for clk_period;

    ecc_rd_en   <= '1';
    ecc_data_rd <= (others => '0');                                           -- bit 1 flipped
    ecc_rd_ecc  <= v_good_ecc;
    wait for 5 ns;
    v_sbe       := ecc_sbe;
    v_dbe       := ecc_dbe;
    check(v_sbe = '1', "SEU bit1: SBE detected");
    check(v_dbe = '0', "SEU bit1: no DBE");
    ecc_rd_en   <= '0';
    ecc_data_rd <= (others => '0');
    ecc_rd_ecc  <= (others => '0');
    wait for clk_period;

    -- TEST 3: Single-bit flip on ECC bit 0
    report "TEST: SEU single-bit flip ecc(0)";
    ecc_wr_en   <= '1';
    ecc_data_wr <= x"FFFFFFFFFFFFFFFF";
    wait until rising_edge(clk);
    v_good_ecc  := ecc_out;
    ecc_wr_en   <= '0';
    ecc_data_wr <= (others => '0');
    wait for clk_period;

    ecc_rd_en     <= '1';
    ecc_data_rd   <= x"FFFFFFFFFFFFFFFF";
    ecc_rd_ecc    <= v_good_ecc;
    ecc_rd_ecc(0) <= not v_good_ecc(0);
    wait for 5 ns;
    v_sbe         := ecc_sbe;
    v_dbe         := ecc_dbe;
    check(v_sbe = '1', "SEU ecc(0): SBE detected");
    check(v_dbe = '0', "SEU ecc(0): no DBE");
    ecc_rd_en     <= '0';
    ecc_data_rd   <= (others => '0');
    ecc_rd_ecc    <= (others => '0');
    wait for clk_period;

    -- TEST 4: Double-bit flip data(1)+data(2)
    report "TEST: SEU double-bit flip data(1)+data(2)";
    ecc_wr_en   <= '1';
    ecc_data_wr <= x"0000000000000006";                                       -- bits 1,2 set
    wait until rising_edge(clk);
    v_good_ecc  := ecc_out;
    ecc_wr_en   <= '0';
    ecc_data_wr <= (others => '0');
    wait for clk_period;

    ecc_rd_en   <= '1';
    ecc_data_rd <= (others => '0');                                           -- both bits flipped
    ecc_rd_ecc  <= v_good_ecc;
    wait for 5 ns;
    v_sbe       := ecc_sbe;
    v_dbe       := ecc_dbe;
    check(v_dbe = '1', "DBE data(1)+data(2): DBE detected");
    ecc_rd_en   <= '0';
    ecc_data_rd <= (others => '0');
    ecc_rd_ecc  <= (others => '0');
    wait for clk_period;

    -- TEST 5: Single-bit flip data(63)
    report "TEST: SEU single-bit flip data(63)";
    ecc_wr_en   <= '1';
    ecc_data_wr <= x"8000000000000000";
    wait until rising_edge(clk);
    v_good_ecc  := ecc_out;
    ecc_wr_en   <= '0';
    ecc_data_wr <= (others => '0');
    wait for clk_period;

    ecc_rd_en   <= '1';
    ecc_data_rd <= (others => '0');                                           -- bit 63 flipped
    ecc_rd_ecc  <= v_good_ecc;
    wait for 5 ns;
    v_sbe       := ecc_sbe;
    v_dbe       := ecc_dbe;
    check(v_sbe = '1', "SEU bit63: SBE detected");
    check(v_dbe = '0', "SEU bit63: no DBE");
    ecc_rd_en   <= '0';
    ecc_data_rd <= (others => '0');
    ecc_rd_ecc  <= (others => '0');
    wait for clk_period;

    -- TEST 6: SEU campaign bits 1-8
    report "TEST: SEU campaign bits 1-8";

    for dummy in 1 to 8 loop

      ecc_wr_en   <= '1';
      ecc_data_wr <= std_logic_vector(to_unsigned(2 ** dummy, 64));
      wait until rising_edge(clk);
      v_good_ecc  := ecc_out;
      ecc_wr_en   <= '0';
      ecc_data_wr <= (others => '0');
      wait for clk_period;

      ecc_rd_en   <= '1';
      ecc_data_rd <= (others => '0');
      ecc_rd_ecc  <= v_good_ecc;
      wait for 5 ns;
      v_sbe       := ecc_sbe;
      v_dbe       := ecc_dbe;
      check(v_sbe = '1', "campaign bit" & integer'image(dummy) & ": SBE");
      check(v_dbe = '0', "campaign bit" & integer'image(dummy) & ": no DBE");
      ecc_rd_en   <= '0';
      ecc_data_rd <= (others => '0');
      ecc_rd_ecc  <= (others => '0');
      wait for clk_period;

    end loop;

    test_runner_cleanup(runner);

  end process p_test;

end architecture tb;
