-- ============================================================================
-- Testbench support: Retirement trace comparison (roadmap R2.2)
-- ============================================================================
-- Compares the two cores' NEORV32 execution traces, instruction by
-- instruction. Core B runs two clocks behind core A, so each event of core A
-- waits in a short queue until core B retires the instruction with the same
-- order number, and the two are then compared field by field.
--
-- Fields are normalised before the compare: register write data counts only
-- for a register other than x0, and memory data only in the byte lanes the
-- access enabled, since NEORV32 leaves the rest undefined. A reset starts a
-- new epoch on both cores, with order numbers from 0, and the queue drains
-- between them because core B has retired everything core A had.
--
-- This is a verification diagnostic. The XBus comparator stays the authority
-- for side effects, and nothing here claims RVFI compatibility.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library neorv32;
  use neorv32.neorv32_package.all;

entity trace_compare is
  port (
    clk_i     : in    std_logic;
    trace_a_i : in    trace_port_t;
    trace_b_i : in    trace_port_t;

    -- Events compared so far
    compared_o : out   natural;
    -- High from the first mismatch on
    mismatch_o : out   std_logic;
    -- Order number of the first mismatch
    first_o : out   natural;
    -- When core B retired it
    first_time_o : out   time;
    field_o      : out   string(1 to 9)
  );
end entity trace_compare;

architecture tb of trace_compare is

  type t_queue is array (0 to 15) of trace_port_t;

  function normalise (
    t : trace_port_t
  ) return trace_port_t is

    variable v_t : trace_port_t;

  begin

    v_t := t;

    if (unsigned(v_t.rd_addr) = 0) then
      v_t.rd_wdata := (others => '0');
    end if;

    loop_lane : for lv_lane in 0 to 3 loop

      if (v_t.mem_rmask(lv_lane) = '0') then
        v_t.mem_rdata(lv_lane * 8 + 7 downto lv_lane * 8) := (others => '0');
      end if;

      if (v_t.mem_wmask(lv_lane) = '0') then
        v_t.mem_wdata(lv_lane * 8 + 7 downto lv_lane * 8) := (others => '0');
      end if;

    end loop loop_lane;

    return v_t;

  end function normalise;

  -- The first field that differs, or spaces

  function differs (
    a : trace_port_t;
    b : trace_port_t
  ) return string is
  begin

    if (a.order /= b.order) then
      return "order    ";
    elsif (a.pc_rdata /= b.pc_rdata) then
      return "pc_rdata ";
    elsif (a.insn /= b.insn) then
      return "insn     ";
    elsif (a.trap /= b.trap or a.intr /= b.intr or a.halt /= b.halt or a.mode /= b.mode) then
      return "trap/intr";
    elsif (a.rd_addr /= b.rd_addr or a.rd_wdata /= b.rd_wdata) then
      return "rd       ";
    elsif (a.rs1_rdata /= b.rs1_rdata or a.rs2_rdata /= b.rs2_rdata) then
      return "rs       ";
    elsif (a.pc_wdata /= b.pc_wdata) then
      return "pc_wdata ";
    elsif (a.csr_addr /= b.csr_addr or a.csr_rdata /= b.csr_rdata or a.csr_wdata /= b.csr_wdata) then
      return "csr      ";
    elsif (a.mem_addr /= b.mem_addr or a.mem_rmask /= b.mem_rmask or a.mem_wmask /= b.mem_wmask or
           a.mem_rdata /= b.mem_rdata or a.mem_wdata /= b.mem_wdata) then
      return "memory   ";
    end if;

    return "         ";

  end function differs;

begin

  p_compare : process is

    variable v_queue    : t_queue;
    variable v_count    : natural;
    variable v_compared : natural;
    variable v_field    : string(1 to 9);
    variable v_mismatch : std_logic;

  begin

    v_count    := 0;
    v_compared := 0;
    v_mismatch := '0';
    mismatch_o <= '0';
    compared_o <= 0;
    first_o    <= 0;
    field_o    <= (others => ' ');

    loop_forever : loop

      wait until rising_edge(clk_i);

      -- Core B retires what core A retired two clocks before, so it reads the
      -- head of the queue before core A adds to its tail
      if (trace_b_i.valid = '1') then
        if (v_count = 0) then
          v_field := "no A     ";
        else
          v_field                        := differs(normalise(v_queue(0)), normalise(trace_b_i));
          v_queue(0 to v_queue'high - 1) := v_queue(1 to v_queue'high);
          v_count                        := v_count - 1;
        end if;

        v_compared := v_compared + 1;
        compared_o <= v_compared;

        if (v_field /= "         " and v_mismatch = '0') then
          v_mismatch   := '1';
          mismatch_o   <= '1';
          first_o      <= to_integer(unsigned(trace_b_i.order(31 downto 0)));
          first_time_o <= now;
          field_o      <= v_field;
        end if;
      end if;

      if (trace_a_i.valid = '1') then
        assert v_count < v_queue'length
          report "trace_compare: core B is more than 16 instructions behind"
          severity failure;
        v_queue(v_count) := trace_a_i;
        v_count          := v_count + 1;
      end if;

    end loop loop_forever;

  end process p_compare;

end architecture tb;
