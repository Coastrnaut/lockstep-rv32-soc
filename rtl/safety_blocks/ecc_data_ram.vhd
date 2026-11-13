-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  ECC Protected Data RAM
-- Module Name:  ecc_data_ram - rtl
-- Description:  The SRAM of HSI section 5. It sits on the system bus behind the
--               lockstep comparator, so both cores share one copy of their data,
--               and every load and store is compared.
--
--               Words are 64 data bits and 8 check bits (HSR_ECC_001), and the
--               bus is 32 bits wide, so every store is a read-modify-write:
--
--                 Strobe:          read the word
--                 The clock after: correct it, merge the store, and write it back
--
--               The write comes after the comparator has judged the store, so a
--               store that the two cores disagree on never reaches the RAM. It
--               also repairs any single-bit error in the word on the way past.
--
--               A word that cannot be corrected is never returned or written
--               back. dbe_fatal_o trips the comparator, which locks the SoC, and
--               soc_bus_fabric answers that access with ERR (HSI BUS-09).
--
--               The error counters are cold-reset telemetry. The access held
--               between the strobe and the write is transaction state, which a
--               warm reset clears as well, so a store whose write would land in a
--               reset is dropped (HSI BUS-11).
--
--               Repair (roadmap R4.1, HSI ECC-05 to ECC-08). A load that finds a
--               single-bit error writes the corrected word back. In every clock
--               with no strobe, a patrol reads the next word in turn, and writes
--               it back corrected if it holds a single-bit error. A bus access
--               always has the read port, so the patrol never delays one. The
--               patrol reports an uncorrectable word but does not trip on it:
--               nothing has used the word yet, and an access that does trips as
--               before.
--
--               The first error since cold reset is kept with its cause, word
--               address, syndrome and time, for the registers and for
--               telemetry_o, which reaches the outside without the system bus.
--
-- Traces to:    TSR_ECC_001, TSR_SAFETY_GATE_002
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity ecc_data_ram is
  generic (
    -- Size in 64-bit words: 15 address bits are the 256 KB of HSI section 5
    g_addr_bits : positive range 4 to 15 := 15;
    -- The idle-cycle patrol (HSI ECC-06)
    g_patrol : boolean := true
  );
  port (
    clk_i       : in    std_logic;
    rst_n_i     : in    std_logic; -- Cold reset, so the error counts outlast a watchdog reset
    bus_rst_n_i : in    std_logic; -- Warm reset: drops an access in progress

    -- Internal bus from lockstep comparator
    bus_i    : in    t_rv_bus;
    bus_ok_i : in    std_logic;

    -- Read data: valid the cycle after the strobe, otherwise zero
    rdata_o : out   std_logic_vector(c_data_width - 1 downto 0);

    -- A word could not be corrected. High in the cycle after the strobe.
    dbe_fatal_o : out   std_logic;

    -- First-fault record, patrol state and error counts (HSI section 3.2)
    telemetry_o : out   t_telemetry
  );
end entity ecc_data_ram;

architecture rtl of ecc_data_ram is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_ECC_001, TSR_SAFETY_GATE_002";

  -- 71:64 are the check bits and 63:0 the data

  subtype t_word is std_logic_vector(71 downto 0);

  subtype t_index is unsigned(g_addr_bits - 1 downto 0);

  type t_memory is array (0 to 2 ** g_addr_bits - 1) of t_word;

  -- STATUS values
  constant c_status_sbe : std_logic_vector(1 downto 0) := "01";
  constant c_status_dbe : std_logic_vector(1 downto 0) := "10";

  -- FIRST_INFO causes
  constant c_cause_sbe_access : std_logic_vector(1 downto 0) := "00";
  constant c_cause_sbe_patrol : std_logic_vector(1 downto 0) := "01";
  constant c_cause_dbe_access : std_logic_vector(1 downto 0) := "10";
  constant c_cause_dbe_patrol : std_logic_vector(1 downto 0) := "11";

  -- Bus address decode, and the access held for the clock after the strobe
  signal w_selected : std_logic;
  signal w_index    : t_index;
  signal w_rd_index : t_index;
  signal r_index    : t_index;
  signal r_upper    : std_logic;
  signal r_read     : std_logic;
  signal r_write    : std_logic;
  signal w_commit   : std_logic;
  signal r_data     : std_logic_vector(c_data_width - 1 downto 0);
  signal r_sel      : std_logic_vector(3 downto 0);

  -- The word read from the RAM, and what the ECC makes of it
  signal r_word      : t_word;
  signal w_corrected : std_logic_vector(63 downto 0);
  signal w_syndrome  : std_logic_vector(7 downto 0);
  signal w_sbe_found : std_logic;
  signal w_dbe_found : std_logic;
  signal w_sbe       : std_logic;
  signal w_dbe       : std_logic;
  signal w_ram_rdata : std_logic_vector(c_data_width - 1 downto 0);

  -- The patrol: the next word, a word read last clock, and what it found
  signal w_patrol_rd   : std_logic;
  signal r_patrol      : t_index;
  signal r_scrub       : std_logic;
  signal w_scrub_sbe   : std_logic;
  signal w_scrub_dbe   : std_logic;
  signal w_repair      : std_logic;
  signal r_passes      : unsigned(15 downto 0);
  signal r_latent_dbe  : std_logic;
  signal w_error       : std_logic;
  signal w_error_cause : std_logic_vector(1 downto 0);

  -- First-fault record, and the clock count since cold reset
  signal r_time       : unsigned(31 downto 0);
  signal r_ff_valid   : std_logic;
  signal r_ff_cause   : std_logic_vector(1 downto 0);
  signal r_ff_index   : t_index;
  signal r_ff_syn     : std_logic_vector(7 downto 0);
  signal r_ff_time    : unsigned(31 downto 0);
  signal w_first_info : std_logic_vector(31 downto 0);
  signal w_first_addr : std_logic_vector(31 downto 0);
  signal w_patrol_reg : std_logic_vector(31 downto 0);

  -- The word to write back
  signal w_merged     : std_logic_vector(63 downto 0);
  signal w_merged_ecc : std_logic_vector(7 downto 0);

  -- Registers
  signal r_sbe_count  : unsigned(15 downto 0);
  signal r_dbe_count  : unsigned(15 downto 0);
  signal r_last_error : std_logic_vector(7 downto 0);
  signal r_status     : std_logic_vector(1 downto 0);
  signal r_reg_rdata  : std_logic_vector(c_data_width - 1 downto 0);

begin

  -- ========================================================================
  -- 1. ACCESS CAPTURE
  -- ========================================================================
  w_selected <= '1' when (bus_ok_i = '1' and bus_i.valid = '1' and
                           bus_i.addr(c_addr_width - 1 downto g_addr_bits + 3) =
                           c_ram_base_addr(c_addr_width - 1 downto g_addr_bits + 3)) else
                '0';

  w_index <= unsigned(bus_i.addr(g_addr_bits + 2 downto 3));

  -- A bus access always has the read port. The patrol has it in any other clock
  -- out of cold reset, so it never delays an access (HSI ECC-07).
  w_patrol_rd <= '1' when (g_patrol and rst_n_i = '1' and w_selected = '0') else
                 '0';
  w_rd_index  <= w_index when (w_selected = '1') else
                 r_patrol;

  p_capture : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0' or bus_rst_n_i = '0') then
        r_read  <= '0';
        r_write <= '0';
      else
        r_read  <= w_selected and not bus_i.we;
        r_write <= w_selected and bus_i.we;
      end if;

      r_index <= w_rd_index;
      r_upper <= bus_i.addr(2);
      r_data  <= bus_i.data;
      r_sel   <= bus_i.sel;
    end if;

  end process p_capture;

  -- ========================================================================
  -- 2. THE RAM
  -- ========================================================================
  -- A variable, because a simulator keeps far less for each bit of one than for
  -- each bit of a signal, and this is over two million bits.
  --
  -- All zeros is a valid word: zero data has zero check bits. An FPGA starts up
  -- that way. An ASIC would have to clear the RAM first (HSI section 5).
  -- ========================================================================
  p_ram : process (clk_i) is

    -- vsg_off variable_007
    variable v_memory : t_memory := (others => (others => '0'));
  -- vsg_on variable_007

  begin

    if rising_edge(clk_i) then
      if (w_commit = '1' or w_repair = '1') then
        v_memory(to_integer(r_index)) := w_merged_ecc & w_merged;
      end if;

      r_word <= v_memory(to_integer(w_rd_index));
    end if;

  end process p_ram;

  -- ========================================================================
  -- 3. ECC CHECK ON THE WAY OUT, AND ECC GENERATION ON THE WAY IN
  -- ========================================================================
  i_ecc_decoder : entity lockstep.hamming_ecc_wrapper
    port map (
      clk_i           => clk_i,
      rst_n_i         => rst_n_i,
      wr_en_i         => '0',
      data_wr_i       => x"0000000000000000",
      rd_en_i         => '1',
      data_rd_i       => r_word(63 downto 0),
      ecc_rd_i        => r_word(71 downto 64),
      data_o          => w_corrected,
      sbe_corrected_o => w_sbe_found,
      dbe_fatal_o     => w_dbe_found,
      syndrome_o      => w_syndrome
    );

  i_ecc_encoder : entity lockstep.hamming_ecc_wrapper
    port map (
      clk_i     => clk_i,
      rst_n_i   => rst_n_i,
      wr_en_i   => '1',
      data_wr_i => w_merged,
      rd_en_i   => '0',
      data_rd_i => x"0000000000000000",
      ecc_rd_i  => x"00",
      ecc_o     => w_merged_ecc
    );

  -- The write-commit edge of a store (HSI BUS-05): the word could be corrected,
  -- the gate is still open, and no reset has arrived since the strobe. bus_ok_i
  -- falls the clock after a store that the cores disagree on.
  w_commit <= '1' when (r_write = '1' and bus_ok_i = '1' and w_dbe = '0' and bus_rst_n_i = '1') else
              '0';

  -- r_word is only a word from the RAM the clock after an access or a patrol read
  w_sbe       <= w_sbe_found and (r_read or r_write);
  w_dbe       <= w_dbe_found and (r_read or r_write);
  w_scrub_sbe <= w_sbe_found and r_scrub;
  w_scrub_dbe <= w_dbe_found and r_scrub;

  -- Write a corrected word back after a load or a patrol read that found a
  -- single-bit error (HSI ECC-05, ECC-06). A store repairs its word anyway. A
  -- patrol read is never in the clock after a strobe, so the two never meet.
  w_repair <= (r_read and w_sbe_found) or w_scrub_sbe;

  p_patrol : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_patrol <= (others => '0');
        r_scrub  <= '0';
        r_passes <= (others => '0');
      else
        r_scrub <= w_patrol_rd;

        if (w_patrol_rd = '1') then
          r_patrol <= r_patrol + 1;

          if (r_patrol = 2 ** g_addr_bits - 1 and r_passes /= x"FFFF") then
            r_passes <= r_passes + 1;
          end if;
        end if;
      end if;
    end if;

  end process p_patrol;

  p_merge : process (all) is

    variable v_word : std_logic_vector(63 downto 0);
    variable v_low  : natural range 0 to 56;

  begin

    v_word := w_corrected;

    for i in 0 to 3 loop

      v_low := i * 8;

      if (r_upper = '1') then
        v_low := v_low + 32;
      end if;

      if (r_write = '1' and r_sel(i) = '1') then
        v_word(v_low + 7 downto v_low) := r_data(i * 8 + 7 downto i * 8);
      end if;

    end loop;

    w_merged <= v_word;

  end process p_merge;

  -- ========================================================================
  -- 4. ERROR REGISTERS (HSI section 3.2)
  -- ========================================================================
  -- A double-bit error shuts the bus, and with it the RAM, so DBE_COUNT cannot go
  -- past one, and only SBE_COUNT has to stop at its limit. DBE_COUNT and STATUS
  -- are about accesses; an uncorrectable word the patrol finds sets the latent
  -- flag in PATROL instead. A single-bit error counts wherever it is found.
  -- ========================================================================
  w_error       <= w_sbe or w_dbe or w_scrub_sbe or w_scrub_dbe;
  w_error_cause <= c_cause_dbe_access when (w_dbe = '1') else
                   c_cause_sbe_access when (w_sbe = '1') else
                   c_cause_dbe_patrol when (w_scrub_dbe = '1') else
                   c_cause_sbe_patrol;

  p_errors : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_time       <= (others => '0');
        r_ff_valid   <= '0';
        r_ff_cause   <= (others => '0');
        r_ff_index   <= (others => '0');
        r_ff_syn     <= (others => '0');
        r_ff_time    <= (others => '0');
        r_latent_dbe <= '0';
      else
        r_time <= r_time + 1;

        -- The first error is kept; later ones do not overwrite it
        if (w_error = '1' and r_ff_valid = '0') then
          r_ff_valid <= '1';
          r_ff_cause <= w_error_cause;
          r_ff_index <= r_index;
          r_ff_syn   <= w_syndrome;
          r_ff_time  <= r_time;
        end if;

        if (w_scrub_dbe = '1') then
          r_latent_dbe <= '1';
        end if;
      end if;

      if (rst_n_i = '0') then
        r_sbe_count  <= (others => '0');
        r_dbe_count  <= (others => '0');
        r_last_error <= (others => '0');
        r_status     <= (others => '0');
      elsif (w_dbe = '1') then
        r_last_error <= w_syndrome;
        r_status     <= c_status_dbe;
        r_dbe_count  <= r_dbe_count + 1;
      elsif (w_sbe = '1' or w_scrub_sbe = '1') then
        r_last_error <= w_syndrome;

        if (r_status /= c_status_dbe) then
          r_status <= c_status_sbe;
        end if;

        if (r_sbe_count /= x"FFFF") then
          r_sbe_count <= r_sbe_count + 1;
        end if;
      end if;
    end if;

  end process p_errors;

  p_read : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_reg_rdata <= (others => '0');

      if (rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0') then
        if (bus_i.addr = c_ecc_sbe_count_addr) then
          r_reg_rdata(15 downto 0) <= std_logic_vector(r_sbe_count);
        elsif (bus_i.addr = c_ecc_dbe_count_addr) then
          r_reg_rdata(15 downto 0) <= std_logic_vector(r_dbe_count);
        elsif (bus_i.addr = c_ecc_syndrome_addr) then
          r_reg_rdata(7 downto 0) <= r_last_error;
        elsif (bus_i.addr = c_ecc_status_addr) then
          r_reg_rdata(1 downto 0) <= r_status;
        elsif (bus_i.addr = c_ecc_first_info_addr) then
          r_reg_rdata <= w_first_info;
        elsif (bus_i.addr = c_ecc_first_addr_addr) then
          r_reg_rdata <= w_first_addr;
        elsif (bus_i.addr = c_ecc_first_time_addr) then
          r_reg_rdata <= std_logic_vector(r_ff_time);
        elsif (bus_i.addr = c_ecc_patrol_addr) then
          r_reg_rdata <= w_patrol_reg;
        end if;
      end if;
    end if;

  end process p_read;

  -- ========================================================================
  -- 5. OUTPUTS
  -- ========================================================================
  w_ram_rdata <= (others => '0') when (r_read = '0' or w_dbe = '1') else
                 w_corrected(63 downto 32) when (r_upper = '1') else
                 w_corrected(31 downto 0);

  rdata_o     <= w_ram_rdata or r_reg_rdata;
  dbe_fatal_o <= w_dbe;

  -- FIRST_INFO: 31 valid, 9:8 cause, 7:0 syndrome. FIRST_ADDR: the word's first
  -- byte. PATROL: 31:16 completed passes, 0 the patrol found an uncorrectable word.
  w_first_info <= r_ff_valid & 21x"0" & r_ff_cause & r_ff_syn;
  w_first_addr <= std_logic_vector(unsigned(c_ram_base_addr) + shift_left(resize(r_ff_index, 32), 3))
                  when (r_ff_valid = '1') else
                  (others => '0');
  w_patrol_reg <= std_logic_vector(r_passes) & 15x"0" & r_latent_dbe;

  telemetry_o <= w_first_info & w_first_addr & std_logic_vector(r_ff_time) & w_patrol_reg &
                 std_logic_vector(r_sbe_count) & std_logic_vector(r_dbe_count);

  -- ========================================================================
  -- 6. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: An uncorrectable word never reaches the bus
  -- Property: A word is never both corrected and reported as fatal
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '1') then
        if (w_dbe = '1') then
          assert w_ram_rdata = x"00000000"
            report "FORMAL FAIL: uncorrectable word on the bus"
            severity error;
          assert w_sbe = '0'
            report "FORMAL FAIL: word both corrected and fatal"
            severity error;
        end if;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
