-- ============================================================================
-- Testbench: the bus fabric decodes exactly the registers in the register table
-- ============================================================================
-- tools/register_map.py is the one table of register addresses; it writes the
-- RTL's constants and, for this bench, sim/generated/register_map_pkg.vhd. The
-- fabric keeps its own lists of which addresses each block answers, so a
-- register added to the table but not to the fabric, or the other way round,
-- would go unseen by tests written with literal addresses. This bench takes
-- the table and walks the peripheral window: every register answers ACK, to
-- loads and stores and at every byte of its word, and every other word in each
-- block's 0x100 bytes answers ERR (HSI BUS-02, BUS-07, BUS-08).
--
-- Traces to:   TSR_BUS_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;
  use work.register_map_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_register_map is
  generic (
    g_test : string := ""
  );
end entity tb_register_map;

architecture tb of tb_register_map is

  constant c_clk_period : time := 20 ns;

  -- The peripheral window: the comparator's reserved block, then ECC,
  -- watchdog, CAN and UART, each 0x100 bytes
  constant c_window_base : unsigned(31 downto 0) := x"40000000";
  constant c_blocks      : positive              := 5;

  constant c_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  signal clk   : std_logic;
  signal rst_n : std_logic;
  signal req   : t_rv_bus;
  signal rsp   : t_bus_rsp;

  impure function in_table (
    constant addr : std_logic_vector(31 downto 0)
  ) return boolean is
  begin

    loop_reg : for lv_i in c_registers'range loop

      if (c_registers(lv_i).addr = addr) then
        return true;
      end if;

    end loop loop_reg;

    return false;

  end function in_table;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(1 ms);

  -- The fabric alone: the slaves' read data is a constant, which is enough to
  -- see which target answered
  i_fabric : entity lockstep.soc_bus_fabric
    port map (
      clk_i        => clk,
      rst_n_i      => rst_n,
      bus_i        => req,
      ram_rdata_i  => (others => '0'),
      wd_rdata_i   => (others => '0'),
      can_rdata_i  => (others => '0'),
      uart_rdata_i => (others => '0'),
      ram_fatal_i  => '0',
      rsp_o        => rsp
    );

  p_stim : process is

    variable v_answered : natural;

    -- One request, and the response in the next cycle: 1 for ACK, 2 for ERR

    procedure transfer (
      constant addr   : in std_logic_vector(31 downto 0);
      constant we     : in std_logic;
      variable answer : out natural
    ) is
    begin

      req    <=
      (
        addr  => addr,
        data  => (others => '0'),
        we    => we,
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      req    <= c_idle;
      wait for 1 ns;
      answer := 0;

      if (rsp.ack = '1') then
        answer := 1;
      end if;

      if (rsp.err = '1') then
        answer := answer + 2;
      end if;

      wait until rising_edge(clk);

    end procedure transfer;

    procedure check_answer (
      constant addr     : in std_logic_vector(31 downto 0);
      constant we       : in std_logic;
      constant expected : in natural;
      constant label_s  : in string
    ) is
    begin

      transfer(addr, we, v_answered);
      check_equal(v_answered, expected, label_s & " at 0x" & to_hstring(addr) & " (1 ACK, 2 ERR)");

    end procedure check_answer;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      req   <= c_idle;
      rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n <= '1';
      wait until rising_edge(clk);

      if run("every_register_in_the_table_answers_ack_to_loads_and_stores") then

        loop_reg : for lv_i in c_registers'range loop

          check_answer(c_registers(lv_i).addr, '0', 1, "load");
          check_answer(c_registers(lv_i).addr, '1', 1, "store");

        end loop loop_reg;

        info(integer'image(c_registers'length) & " table addresses answer ACK");
      elsif run("a_register_answers_at_every_byte_of_its_word") then

        loop_reg_byte : for lv_i in c_registers'range loop

          loop_byte : for lv_byte in 1 to 3 loop

            check_answer(std_logic_vector(unsigned(c_registers(lv_i).addr) + lv_byte), '0', 1, "byte " &
                         integer'image(lv_byte));

          end loop loop_byte;

        end loop loop_reg_byte;

      elsif run("every_other_word_in_the_peripheral_window_answers_err") then
        v_answered := 0;

        loop_word : for lv_word in 0 to c_blocks * 64 - 1 loop

          if (not in_table(std_logic_vector(c_window_base + lv_word * 4))) then
            check_answer(std_logic_vector(c_window_base + lv_word * 4), '0', 2, "unlisted word");
          end if;

        end loop loop_word;

        info("every unlisted word in 0x40000000 to 0x400004FF answers ERR");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
