-- ============================================================================
-- Package: tb_pkg, the test framework for every bench in this repository
-- ============================================================================
-- Plain VHDL-2008, so the same benches run on GHDL and on Vivado's xsim. It
-- gives the small part of a test framework the benches use:
--
--   test_runner_setup(g_test)   pick the test: the generic g_test if it is set,
--                               else the first line of tb_select.txt in the run
--                               folder, else the bench's first test
--   while test_suite loop       runs its body once
--   if run("name") then         true for the selected test
--   test_runner_cleanup         reports the result and ends the simulation
--   test_runner_watchdog(t)     fails the test if it is still running after t
--   check_equal, check          fail the test at once, saying what differed
--   info                        a line for the log, with the time in ns
--
-- Every line it writes starts with "TB ", so sim/run.py finds them in either
-- simulator's output, and compares them between simulators:
--
--   TB INFO <ns> <message>
--   TB PASS <test>
--   TB FAIL <ns> <message>
--   TB SKIP <test>: <reason>    (a test that cannot run here)
--
-- A failed check is a report of severity failure, which stops both
-- simulators. A bench that never reaches test_runner_cleanup has not passed.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library std;
  use std.textio.all;

package tb_pkg is

  -- The selected test, set up by test_runner_setup

  procedure test_runner_setup (
    constant test_name : in string
  );

  impure function test_suite return boolean;

  impure function run (
    constant name : in string
  ) return boolean;

  procedure test_runner_cleanup;

  -- xsim cannot simulate VHDL-2008 force, but its Tcl add_force can force a
  -- signal. When sim/run.py builds a bench for xsim it puts one of these in
  -- place of each force and release: the hierarchical path of the target, the
  -- target itself (which picks the overload) and the value. Each writes the
  -- request to tb_force.txt and pauses the simulation with std.env.stop; the
  -- run's Tcl script applies it with add_force or remove_forces and resumes.

  procedure tb_force (
    constant path   : in string;
    constant target : in std_ulogic;
    constant value  : in std_ulogic
  );

  procedure tb_force (
    constant path   : in string;
    constant target : in std_ulogic_vector;
    constant value  : in std_ulogic_vector
  );

  procedure tb_force (
    constant path   : in string;
    constant target : in unsigned;
    constant value  : in unsigned
  );

  procedure tb_force (
    constant path   : in string;
    constant target : in signed;
    constant value  : in signed
  );

  procedure tb_force (
    constant path   : in string;
    constant target : in integer;
    constant value  : in integer
  );

  procedure tb_release (
    constant path : in string
  );

  -- Called as a concurrent procedure; it never returns

  procedure test_runner_watchdog (
    constant timeout : in time
  );

  impure function selected_test return string;

  -- The selected test's name, by the name other frameworks use for it

  impure function running_test_case return string;

  procedure info (
    constant msg : in string
  );

  procedure fail (
    constant msg : in string
  );

  procedure check (
    constant condition : in boolean;
    constant msg       : in string := ""
  );

  procedure check (
    constant condition : in std_ulogic;
    constant msg       : in string := ""
  );

  procedure check_equal (
    constant got      : in std_ulogic;
    constant expected : in std_ulogic;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in std_ulogic_vector;
    constant expected : in std_ulogic_vector;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in unsigned;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in natural;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in natural;
    constant expected : in unsigned;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in signed;
    constant expected : in signed;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in signed;
    constant expected : in integer;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in integer;
    constant expected : in integer;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in boolean;
    constant expected : in boolean;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in character;
    constant expected : in character;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in time;
    constant expected : in time;
    constant msg      : in string := ""
  );

end package tb_pkg;

package body tb_pkg is

  constant c_name_length : positive := 200;

  type t_runner is protected

    procedure set_selected (
      constant name : in string
    );

    impure function get_selected return string;

    impure function first_suite_pass return boolean;

    impure function try (
      constant name : in string
    ) return boolean;

    impure function was_asked return boolean;

    impure function was_matched return boolean;

    procedure set_done;

    impure function is_done return boolean;

  end protected t_runner;

  type t_runner is protected body

    -- Each starts at its type's default: an empty name, 0 and false
    variable v_selected : string(1 to c_name_length);
    variable v_length   : natural;
    variable v_suite    : boolean;
    variable v_asked    : boolean;
    variable v_matched  : boolean;
    variable v_done     : boolean;

    procedure set_selected (
      constant name : in string
    ) is
    begin

      v_length                  := minimum(name'length, c_name_length);
      v_selected                := (others => ' ');
      v_selected(1 to v_length) := name(name'low to name'low + v_length - 1);

    end procedure set_selected;

    impure function get_selected return string is
    begin

      return v_selected(1 to v_length);

    end function get_selected;

    impure function first_suite_pass return boolean is
    begin

      if (v_suite) then
        return false;
      end if;

      v_suite := true;
      return true;

    end function first_suite_pass;

    impure function try (
      constant name : in string
    ) return boolean is
    begin

      v_asked := true;

      -- No test selected: the first one asked for is the one that runs
      if (v_length = 0 and not v_matched) then
        set_selected(name);
      end if;

      if (not v_matched and name = v_selected(1 to v_length)) then
        v_matched := true;
        return true;
      end if;

      return false;

    end function try;

    impure function was_asked return boolean is
    begin

      return v_asked;

    end function was_asked;

    impure function was_matched return boolean is
    begin

      return v_matched;

    end function was_matched;

    procedure set_done is
    begin

      v_done := true;

    end procedure set_done;

    impure function is_done return boolean is
    begin

      return v_done;

    end function is_done;

  end protected body t_runner;

  shared variable v_runner : t_runner;

  -- The time, in whole ns, the same way in every simulator

  impure function now_ns return string is
  begin

    return integer'image(now / 1 ns);

  end function now_ns;

  -- A time the same way on every simulator: time'image gives fs on GHDL and ps
  -- on xsim

  function time_image (
    constant value : in time
  ) return string is
  begin

    if (value mod 1 ns = 0 ns) then
      return integer'image(value / 1 ns) & " ns";
    else
      return integer'image(value / 1 ps) & " ps";
    end if;

  end function time_image;

  procedure test_runner_setup (
    constant test_name : in string
  ) is

    file f_select : text;
    variable v_status : file_open_status;
    variable v_line   : line;

  begin

    if (test_name'length > 0) then
      v_runner.set_selected(test_name);
    else
      file_open(v_status, f_select, "tb_select.txt", read_mode);

      if (v_status = open_ok) then
        if (not endfile(f_select)) then
          readline(f_select, v_line);

          -- Without trailing spaces or a carriage return
          loop_trim : while v_line'length > 0 loop

            exit loop_trim when v_line(v_line'right) /= ' ' and v_line(v_line'right) /= CR;
            v_line := new string'(v_line(v_line'left to v_line'right - 1));

          end loop loop_trim;

          if (v_line'length > 0) then
            v_runner.set_selected(v_line.all);
          end if;
        end if;

        file_close(f_select);
      end if;
    end if;

  end procedure test_runner_setup;

  impure function test_suite return boolean is
  begin

    return v_runner.first_suite_pass;

  end function test_suite;

  impure function run (
    constant name : in string
  ) return boolean is
  begin

    return v_runner.try(name);

  end function run;

  impure function selected_test return string is
  begin

    return v_runner.get_selected;

  end function selected_test;

  impure function running_test_case return string is
  begin

    return v_runner.get_selected;

  end function running_test_case;

  procedure test_runner_cleanup is
  begin

    if (v_runner.was_asked and not v_runner.was_matched) then
      fail("this bench has no test named '" & v_runner.get_selected & "'");
    end if;

    v_runner.set_done;

    if (v_runner.was_matched) then
      report "TB PASS " & v_runner.get_selected;
    else
      -- A bench with a single, unnamed test
      report "TB PASS all";
    end if;

    std.env.finish;

  end procedure test_runner_cleanup;

  procedure tb_force_request (
    constant request : in string
  ) is

    file f_request : text;
    variable v_line : line;

  begin

    file_open(f_request, "tb_force.txt", write_mode);
    write(v_line, request & " " & integer'image(now / 1 ns));
    writeline(f_request, v_line);
    file_close(f_request);
    std.env.stop;

  end procedure tb_force_request;

  procedure tb_force (
    constant path   : in string;
    constant target : in std_ulogic;
    constant value  : in std_ulogic
  ) is
  begin

    tb_force_request("force " & path & " bin " & to_string(value));

  end procedure tb_force;

  procedure tb_force (
    constant path   : in string;
    constant target : in std_ulogic_vector;
    constant value  : in std_ulogic_vector
  ) is
  begin

    tb_force_request("force " & path & " bin " & to_string(value));

  end procedure tb_force;

  procedure tb_force (
    constant path   : in string;
    constant target : in unsigned;
    constant value  : in unsigned
  ) is
  begin

    tb_force_request("force " & path & " bin " & to_string(value));

  end procedure tb_force;

  procedure tb_force (
    constant path   : in string;
    constant target : in signed;
    constant value  : in signed
  ) is
  begin

    tb_force_request("force " & path & " bin " & to_string(value));

  end procedure tb_force;

  procedure tb_force (
    constant path   : in string;
    constant target : in integer;
    constant value  : in integer
  ) is
  begin

    tb_force_request("force " & path & " dec " & integer'image(value));

  end procedure tb_force;

  procedure tb_release (
    constant path : in string
  ) is
  begin

    tb_force_request("release " & path);

  end procedure tb_release;

  procedure test_runner_watchdog (
    constant timeout : in time
  ) is
  begin

    wait for timeout;

    if (not v_runner.is_done) then
      fail("the test was still running after " & time_image(timeout));
    end if;

    wait;

  end procedure test_runner_watchdog;

  procedure info (
    constant msg : in string
  ) is
  begin

    report "TB INFO " & now_ns & " " & msg;

  end procedure info;

  procedure fail (
    constant msg : in string
  ) is
  begin

    report "TB FAIL " & now_ns & " " & msg
      severity failure;

  end procedure fail;

  procedure check (
    constant condition : in boolean;
    constant msg       : in string := ""
  ) is
  begin

    if (not condition) then
      fail(msg & " - check failed");
    end if;

  end procedure check;

  procedure check (
    constant condition : in std_ulogic;
    constant msg       : in string := ""
  ) is
  begin

    check(condition = '1', msg);

  end procedure check;

  procedure differ (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string
  ) is
  begin

    fail(msg & " - Got " & got & ". Expected " & expected & ".");

  end procedure differ;

  procedure check_equal (
    constant got      : in std_ulogic;
    constant expected : in std_ulogic;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(std_ulogic'image(got), std_ulogic'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in std_ulogic_vector;
    constant expected : in std_ulogic_vector;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(to_string(got), to_string(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in unsigned;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(to_string(got), to_string(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in natural;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(to_string(got), integer'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in natural;
    constant expected : in unsigned;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(integer'image(got), to_string(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in signed;
    constant expected : in signed;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(to_string(got), to_string(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in signed;
    constant expected : in integer;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(to_string(got), integer'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in integer;
    constant expected : in integer;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(integer'image(got), integer'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in boolean;
    constant expected : in boolean;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(boolean'image(got), boolean'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in character;
    constant expected : in character;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(character'image(got), character'image(expected), msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ("""" & got & """", """" & expected & """", msg);
    end if;

  end procedure check_equal;

  procedure check_equal (
    constant got      : in time;
    constant expected : in time;
    constant msg      : in string := ""
  ) is
  begin

    if (got /= expected) then
      differ(time_image(got), time_image(expected), msg);
    end if;

  end procedure check_equal;

end package body tb_pkg;
