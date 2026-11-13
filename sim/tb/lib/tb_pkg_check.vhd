-- ============================================================================
-- Testbench: the test framework itself
-- ============================================================================
-- A test that cannot fail checks nothing (an OSVVM bench here once passed with
-- its expectations inverted). Each test below says in its name what sim/run.py
-- must make of it, and the runner counts it as passed only if that is what
-- happened, on every simulator: a passing test passes; a failed check, an
-- assertion of severity error, a test that never finishes, and a test name the
-- bench does not have all fail; a forced signal holds the forced value
-- until it is released, on both simulators.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;

entity tb_pkg_check is
  generic (
    g_test : string := ""
  );
end entity tb_pkg_check;

architecture tb of tb_pkg_check is

  signal trip   : std_logic;
  signal driven : std_logic;

begin

  test_runner_watchdog(1 us);

  -- Stands for an assertion in the RTL
  p_rtl_assert : process (trip) is
  begin

    assert trip /= '1'
      report "an assertion of severity error, as the RTL makes"
      severity error;

  end process p_rtl_assert;

  p_stim : process is
  begin

    test_runner_setup(g_test);
    trip <= '0';
    wait for 10 ns;

    loop_while : while test_suite loop

      if run("expect_pass_a_test_that_passes") then
        check_equal(std_logic_vector'("1010"), std_logic_vector'("1010"), "equal vectors");
        check(true, "a true condition");
        info("this line must match between simulators");
      elsif run("expect_fail_a_failed_check_equal") then
        check_equal(3, 4, "three is not four");
      elsif run("expect_fail_a_failed_check") then
        check(false, "a false condition");
      elsif run("expect_fail_an_assertion_of_severity_error") then
        trip <= '1';
        wait for 10 ns;
      elsif run("expect_fail_a_test_that_never_finishes") then
        wait;
      elsif run("expect_pass_a_forced_signal_holds_the_value_until_released") then
        driven <= '0';
        wait for 10 ns;
        driven <= force '1';
        wait for 10 ns;
        check_equal(driven, '1', "forced");
        driven <= 'L';
        wait for 10 ns;
        check_equal(driven, '1', "a new value from the driver does not lift the force");
        driven <= release;
        wait for 10 ns;
        check_equal(driven, 'L', "released to the driver's value");
        info("force and release work");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
