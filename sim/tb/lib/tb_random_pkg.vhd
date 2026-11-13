-- ============================================================================
-- Package: tb_random_pkg, seeded random values and functional coverage
-- ============================================================================
-- Plain VHDL-2008 for GHDL and xsim alike, in place of the part of OSVVM the
-- benches used. Random values come from a Park-Miller generator, seeded from a
-- string (a bench passes its instance name), so a run repeats exactly, and
-- with integer arithmetic only, so GHDL and xsim draw the same numbers.
--
--   variable v_rand : t_random;           v_rand.init_seed("name");
--   v_rand.rand_int(0, 15)                v_rand.rand_slv(32)
--
-- Coverage models live in one store and are named by an id:
--
--   v_id := new_cover("name");            add_bins(v_id, gen_bin(0, 69));
--   add_cross(v_id, gen_bin(0, 1), gen_bin(0, 1));
--   sample(v_id, 5);  sample(v_id, (1, 0)); is_covered(v_id)
--   rand_uncovered(v_id)  a bin not yet hit, picked at random, while any is left
--   write_bins(v_id)      every bin's count, as TB INFO lines
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.math_real.all;

library work;
  use work.tb_pkg.all;

package tb_random_pkg is

  type t_random is protected

    procedure init_seed (
      constant name : in string
    );

    impure function rand_real return real;

    impure function rand_int (
      constant min_value : in integer;
      constant max_value : in integer
    ) return integer;

    impure function rand_slv (
      constant size : in positive
    ) return std_logic_vector;

  end protected t_random;

  type t_bin is record
    low  : integer;
    high : integer;
  end record t_bin;

  subtype t_cover_id is natural;

  function gen_bin (
    constant low  : in integer;
    constant high : in integer
  ) return t_bin;

  impure function new_cover (
    constant name : in string
  ) return t_cover_id;

  procedure add_bins (
    constant id  : in t_cover_id;
    constant bin : in t_bin
  );

  procedure add_cross (
    constant id    : in t_cover_id;
    constant bin_x : in t_bin;
    constant bin_y : in t_bin
  );

  procedure sample (
    constant id    : in t_cover_id;
    constant value : in integer
  );

  procedure sample (
    constant id    : in t_cover_id;
    constant point : in integer_vector
  );

  impure function is_covered (
    constant id : in t_cover_id
  ) return boolean;

  impure function rand_uncovered (
    constant id : in t_cover_id
  ) return integer;

  procedure write_bins (
    constant id : in t_cover_id
  );

end package tb_random_pkg;

package body tb_random_pkg is

  type t_random is protected body

    -- Park and Miller's minimal standard generator, x = 16807 x mod (2**31 - 1),
    -- by Schrage's method so that no product passes 2**31 - 1. Integer
    -- arithmetic only, so every simulator draws the same numbers.
    constant c_m : positive := 2147483647;
    constant c_a : positive := 16807;
    constant c_q : positive := 127773;
    constant c_r : positive := 2836;

    -- positive'left, 1, until init_seed
    variable v_state : positive;

    procedure init_seed (
      constant name : in string
    ) is

      variable v_hash : natural;

    begin

      v_hash := 7;

      loop_char : for lv_i in name'range loop

        v_hash := (v_hash * 31 + character'pos(name(lv_i))) mod 1000003;

      end loop loop_char;

      v_state := v_hash + 1;

    end procedure init_seed;

    impure function next_state return positive is

      variable v_test : integer;

    begin

      v_test := c_a * (v_state mod c_q) - c_r * (v_state / c_q);

      if (v_test > 0) then
        v_state := v_test;
      else
        v_state := v_test + c_m;
      end if;

      return v_state;

    end function next_state;

    impure function rand_real return real is
    begin

      return real(next_state) / real(c_m);

    end function rand_real;

    impure function rand_int (
      constant min_value : in integer;
      constant max_value : in integer
    ) return integer is
    begin

      return min_value + next_state mod (max_value - min_value + 1);

    end function rand_int;

    impure function rand_slv (
      constant size : in positive
    ) return std_logic_vector is

      variable v_result : std_logic_vector(size - 1 downto 0);

    begin

      -- The top bit of each draw
      loop_bit : for lv_i in v_result'range loop

        v_result(lv_i) := '1' when next_state >= 2 ** 30 else '0';

      end loop loop_bit;

      return v_result;

    end function rand_slv;

  end protected body t_random;

  function gen_bin (
    constant low  : in integer;
    constant high : in integer
  ) return t_bin is
  begin

    return (low => low, high => high);

  end function gen_bin;

  constant c_models : positive := 16;
  constant c_bins   : positive := 512;

  type t_counts is array (0 to c_bins - 1) of natural;

  type t_model is record
    x     : t_bin;
    y     : t_bin;
    cross : boolean;
    used  : boolean;
  end record t_model;

  type t_models is array (0 to c_models - 1) of t_model;

  type t_count_table is array (0 to c_models - 1) of t_counts;

  type t_store is protected

    impure function add_model return t_cover_id;

    procedure set_shape (
      constant id    : in t_cover_id;
      constant x     : in t_bin;
      constant y     : in t_bin;
      constant cross : in boolean
    );

    procedure hit (
      constant id    : in t_cover_id;
      constant index : in natural
    );

    impure function size (
      constant id : in t_cover_id
    ) return natural;

    impure function count (
      constant id    : in t_cover_id;
      constant index : in natural
    ) return natural;

    impure function shape (
      constant id : in t_cover_id
    ) return t_model;

    impure function pick (
      constant id : in t_cover_id
    ) return natural;

  end protected t_store;

  type t_store is protected body

    variable v_models : t_models;
    -- Every count, and the next id, start at natural'left, 0
    variable v_counts : t_count_table;
    variable v_next   : natural;
    variable v_rand   : t_random;

    impure function add_model return t_cover_id is
    begin

      assert v_next < c_models
        report "TB FAIL 0 too many coverage models"
        severity failure;
      v_models(v_next).used := true;
      v_next                := v_next + 1;
      return v_next - 1;

    end function add_model;

    procedure set_shape (
      constant id    : in t_cover_id;
      constant x     : in t_bin;
      constant y     : in t_bin;
      constant cross : in boolean
    ) is
    begin

      v_models(id).x     := x;
      v_models(id).y     := y;
      v_models(id).cross := cross;
      assert size(id) <= c_bins
        report "TB FAIL 0 a coverage model has more than " & integer'image(c_bins) & " bins"
        severity failure;

    end procedure set_shape;

    procedure hit (
      constant id    : in t_cover_id;
      constant index : in natural
    ) is
    begin

      v_counts(id)(index) := v_counts(id)(index) + 1;

    end procedure hit;

    impure function size (
      constant id : in t_cover_id
    ) return natural is

      variable v_x : natural;

    begin

      v_x := v_models(id).x.high - v_models(id).x.low + 1;

      if (v_models(id).cross) then
        return v_x * (v_models(id).y.high - v_models(id).y.low + 1);
      end if;

      return v_x;

    end function size;

    impure function count (
      constant id    : in t_cover_id;
      constant index : in natural
    ) return natural is
    begin

      return v_counts(id)(index);

    end function count;

    impure function shape (
      constant id : in t_cover_id
    ) return t_model is
    begin

      return v_models(id);

    end function shape;

    impure function pick (
      constant id : in t_cover_id
    ) return natural is

      variable v_left : natural;
      variable v_nth  : natural;

    begin

      v_left := 0;

      loop_count : for lv_i in 0 to size(id) - 1 loop

        if (v_counts(id)(lv_i) = 0) then
          v_left := v_left + 1;
        end if;

      end loop loop_count;

      if (v_left = 0) then
        return v_rand.rand_int(0, size(id) - 1);
      end if;

      v_nth := v_rand.rand_int(1, v_left);

      loop_find : for lv_i in 0 to size(id) - 1 loop

        if (v_counts(id)(lv_i) = 0) then
          v_nth := v_nth - 1;

          if (v_nth = 0) then
            return lv_i;
          end if;
        end if;

      end loop loop_find;

      return 0;

    end function pick;

  end protected body t_store;

  shared variable v_store : t_store;

  impure function new_cover (
    constant name : in string
  ) return t_cover_id is

    variable v_id : t_cover_id;

  begin

    v_id := v_store.add_model;
    info("coverage model " & integer'image(v_id) & ": " & name);
    return v_id;

  end function new_cover;

  procedure add_bins (
    constant id  : in t_cover_id;
    constant bin : in t_bin
  ) is
  begin

    v_store.set_shape(id, bin, bin, false);

  end procedure add_bins;

  procedure add_cross (
    constant id    : in t_cover_id;
    constant bin_x : in t_bin;
    constant bin_y : in t_bin
  ) is
  begin

    v_store.set_shape(id, bin_x, bin_y, true);

  end procedure add_cross;

  procedure sample (
    constant id    : in t_cover_id;
    constant value : in integer
  ) is

    variable v_model : t_model;

  begin

    v_model := v_store.shape(id);

    if (value >= v_model.x.low and value <= v_model.x.high) then
      v_store.hit(id, value - v_model.x.low);
    end if;

  end procedure sample;

  procedure sample (
    constant id    : in t_cover_id;
    constant point : in integer_vector
  ) is

    variable v_model : t_model;
    variable v_x     : integer;
    variable v_y     : integer;

  begin

    v_model := v_store.shape(id);
    v_x     := point(point'low);
    v_y     := point(point'low + 1);

    if (v_x >= v_model.x.low and v_x <= v_model.x.high and v_y >= v_model.y.low and v_y <= v_model.y.high) then
      v_store.hit(id, (v_x - v_model.x.low) * (v_model.y.high - v_model.y.low + 1) + (v_y - v_model.y.low));
    end if;

  end procedure sample;

  impure function is_covered (
    constant id : in t_cover_id
  ) return boolean is
  begin

    loop_bin : for lv_i in 0 to v_store.size(id) - 1 loop

      if (v_store.count(id, lv_i) = 0) then
        return false;
      end if;

    end loop loop_bin;

    return true;

  end function is_covered;

  impure function rand_uncovered (
    constant id : in t_cover_id
  ) return integer is
  begin

    -- One-dimensional models only
    return v_store.shape(id).x.low + v_store.pick(id);

  end function rand_uncovered;

  procedure write_bins (
    constant id : in t_cover_id
  ) is

    variable v_model : t_model;
    variable v_span  : natural;

  begin

    v_model := v_store.shape(id);
    v_span  := v_model.y.high - v_model.y.low + 1;

    loop_bin : for lv_i in 0 to v_store.size(id) - 1 loop

      if (v_model.cross) then
        info("bin (" & integer'image(v_model.x.low + lv_i / v_span) & ", " &
             integer'image(v_model.y.low + lv_i mod v_span) & "): " & integer'image(v_store.count(id, lv_i)));
      else
        info("bin " & integer'image(v_model.x.low + lv_i) & ": " & integer'image(v_store.count(id, lv_i)));
      end if;

    end loop loop_bin;

  end procedure write_bins;

end package body tb_random_pkg;
