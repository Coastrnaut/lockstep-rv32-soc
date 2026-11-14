-- ============================================================================
-- Testbench: the retirement comparator
-- ============================================================================
-- The bench plays core A: a seeded stream of retirement records, some clocks
-- with an instruction retired and some without. Core B gets the same stream
-- two clocks later, as it does in the SoC. Checked: the two in step are no
-- fault, with whatever is left in the fields between retirements; each
-- compared field that differs in one retirement is a fault in the next clock,
-- for that clock; memory fields are not compared; nothing is compared while
-- core B is in reset; and the cold reset clears the output.
--
-- Traces to:   TSR_LOCKSTEP_046
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;
  use work.tb_random_pkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;

entity tb_retire_comparator is
  generic (
    g_test : string := ""
  );
end entity tb_retire_comparator;

architecture tb of tb_retire_comparator is

  constant c_clk_period : time     := 20 ns;
  constant c_skew       : positive := 2;

  -- The fields the comparator compares, by number, and two it does not

  constant c_fields : positive := 9;

  type t_history is array (1 to c_skew) of trace_port_t;

  signal clk      : std_logic;
  signal clk_run  : boolean;
  signal rst_n    : std_logic;
  signal b_rst_n  : std_logic;
  signal trace_a  : trace_port_t;
  signal trace_b  : trace_port_t;
  signal fault    : std_logic;
  signal history  : t_history;
  signal flip     : natural;
  signal b_frozen : boolean;

begin

  p_clk : process is
  begin

    clk <= '0';

    if (not clk_run) then
      wait until clk_run;
    end if;

    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(2 ms);

  i_dut : entity lockstep.retire_comparator
    generic map (
      g_cycles => c_skew
    )
    port map (
      clk_i          => clk,
      rst_n_i        => rst_n,
      core_b_rst_n_i => b_rst_n,
      trace_a_i      => trace_a,
      trace_b_i      => trace_b,
      fault_o        => fault
    );

  -- Core B: core A two clocks ago, with one field changed when flip says so
  p_history : process (clk) is
  begin

    if rising_edge(clk) then
      history(1) <= trace_a;

      loop_i : for lv_i in 2 to c_skew loop

        history(lv_i) <= history(lv_i - 1);

      end loop loop_i;

    end if;

  end process p_history;

  p_core_b : process (all) is

    variable v_t : trace_port_t;

  begin

    v_t := history(c_skew);

    case flip is

      when 1 =>

        v_t.valid := not v_t.valid;

      when 2 =>

        v_t.insn(7) := not v_t.insn(7);

      when 3 =>

        v_t.pc_rdata(2) := not v_t.pc_rdata(2);

      when 4 =>

        v_t.pc_wdata(31) := not v_t.pc_wdata(31);

      when 5 =>

        v_t.trap := not v_t.trap;

      when 6 =>

        v_t.intr := not v_t.intr;

      when 7 =>

        v_t.rd_addr(4) := not v_t.rd_addr(4);

      when 8 =>

        v_t.rd_wdata(0) := not v_t.rd_wdata(0);

      when 9 =>

        v_t.csr_wdata(15) := not v_t.csr_wdata(15);

      -- Not compared

      when 10 =>

        v_t.mem_addr(3) := not v_t.mem_addr(3);

      when 11 =>

        v_t.order(0) := not v_t.order(0);

      when others =>

        null;

    end case;

    if (not b_frozen) then
      trace_b <= v_t;
    end if;

  end process p_core_b;

  p_stim : process is

    variable v_random : t_random;

    -- One clock of core A: a retirement, or none with junk in the fields

    procedure retire (
      constant valid : in std_ulogic
    ) is

      variable v_t : trace_port_t;

    begin

      v_t           := trace_port_terminate_c;
      v_t.valid     := valid;
      v_t.order     := v_random.rand_slv(32) & v_random.rand_slv(32);
      v_t.insn      := v_random.rand_slv(32);
      v_t.pc_rdata  := v_random.rand_slv(32);
      v_t.pc_wdata  := v_random.rand_slv(32);
      v_t.trap      := v_random.rand_slv(1)(0);
      v_t.intr      := v_random.rand_slv(1)(0);
      v_t.rd_addr   := v_random.rand_slv(5);
      v_t.rd_wdata  := v_random.rand_slv(32);
      v_t.csr_wdata := v_random.rand_slv(32);
      v_t.mem_addr  := v_random.rand_slv(32);
      trace_a       <= v_t;
      wait until rising_edge(clk);

    end procedure retire;

    procedure run_clocks (
      constant count : in natural
    ) is
    begin

      loop_clocks : for lv_i in 1 to count loop

        if (v_random.rand_int(0, 2) = 0) then
          retire('0');
        else
          retire('1');
        end if;

      end loop loop_clocks;

    end procedure run_clocks;

  begin

    test_runner_setup(g_test);
    v_random.init_seed("tb_retire_comparator");

    loop_while : while test_suite loop

      clk_run  <= true;
      flip     <= 0;
      b_frozen <= false;
      rst_n    <= '0';
      b_rst_n  <= '0';
      trace_a  <= trace_port_terminate_c;
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n    <= '1';
      b_rst_n  <= '1';

      if run("retirements_in_step_are_no_fault") then

        loop_i : for lv_i in 1 to 2000 loop

          retire(v_random.rand_slv(1)(0));
          check_equal(fault, '0', "no fault in step, clock " & integer'image(lv_i));

        end loop loop_i;

      elsif run("each_compared_field_that_differs_is_a_fault_in_the_next_clock") then

        loop_field : for lv_f in 1 to c_fields loop

          run_clocks(5);
          -- A retirement on both, then core B's differs in one field
          retire('1');
          retire('1');
          flip <= lv_f;
          wait for 1 ns;
          check_equal(fault, '0', "no fault yet, field " & integer'image(lv_f));
          retire('1');
          flip <= 0;
          wait for 1 ns;
          check_equal(fault, '1', "fault, field " & integer'image(lv_f));
          retire('1');
          wait for 1 ns;
          check_equal(fault, '0', "for one clock, field " & integer'image(lv_f));

        end loop loop_field;

      elsif run("memory_fields_and_fields_between_retirements_are_not_compared") then
        -- The order number and the memory access differ in a retirement
        run_clocks(5);
        retire('1');
        retire('1');

        loop_f : for lv_f in 10 to 11 loop

          flip <= lv_f;
          retire('1');
          wait for 1 ns;
          check_equal(fault, '0', "not compared: field " & integer'image(lv_f));

        end loop loop_f;

        flip <= 0;

        -- Every compared field but valid differs in a clock without a retirement
        retire('0');
        retire('0');

        loop_f_2 : for lv_f in 2 to c_fields loop

          flip <= lv_f;
          retire('0');
          wait for 1 ns;
          check_equal(fault, '0', "no retirement, field " & integer'image(lv_f));

        end loop loop_f_2;

        flip <= 0;
        retire('0');
        wait for 1 ns;
        check_equal(fault, '0', "no fault after");
      elsif run("nothing_is_compared_while_core_b_is_in_reset") then
        -- Core B stops, in reset, while core A goes on
        b_rst_n  <= '0';
        b_frozen <= true;
        run_clocks(50);

        loop_i_2 : for lv_i in 1 to 20 loop

          retire('1');
          check_equal(fault, '0', "core B in reset, clock " & integer'image(lv_i));

        end loop loop_i_2;

      elsif run("the_cold_reset_clears_the_fault") then
        run_clocks(5);
        retire('1');
        retire('1');
        flip  <= 8;
        retire('1');
        flip  <= 0;
        wait for 1 ns;
        check_equal(fault, '1', "fault");
        rst_n <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        check_equal(fault, '0', "cleared by the cold reset");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
