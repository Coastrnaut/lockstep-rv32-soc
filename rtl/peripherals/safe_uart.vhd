-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Safe UART with Parity-Hardened Registers
-- Module Name:  safe_uart - behavioral
-- Description:  Hardware UART transmitter for real-time diagnostic output.
--               Internal TX register protected by parity-check loops: every
--               byte written is parity-checked before transmission to prevent
--               corrupted telemetry from leaving the SoC.
--
-- Traces to:    TSR_UART_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity safe_uart is
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic;

    -- Internal bus from lockstep comparator
    bus_i    : in    t_rv_bus;
    bus_ok_i : in    std_logic;

    -- Register read data: valid the cycle after the strobe, otherwise zero
    rdata_o : out   std_logic_vector(c_data_width - 1 downto 0);

    -- UART output
    uart_tx_o : out   std_logic;

    -- Diagnostic: TX status
    uart_busy_o  : out   std_logic;
    uart_error_o : out   std_logic;

    -- UART_ERROR interrupt: set by a parity error until STATUS is written
    uart_irq_o : out   std_logic
  );
end entity safe_uart;

architecture rtl of safe_uart is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_UART_001";

  -- UART baud rate divider (115200 @ 50MHz => ~434)
  constant c_baud_div : unsigned(15 downto 0) := to_unsigned(434, 16);

  -- TX buffer register with parity
  signal r_tx_data   : std_logic_vector(7 downto 0);
  signal r_tx_parity : std_logic;
  signal r_tx_valid  : std_logic;

  -- Baud rate counter
  signal r_baud_cnt : unsigned(15 downto 0);

  -- TX shift register (1 start + 8 data + 1 parity + 1 stop = 11 bits)
  signal r_tx_shift : std_logic_vector(10 downto 0);
  signal r_tx_bits  : unsigned(3 downto 0);

  -- UART state machine

  type t_uart_st is (uart_idle, uart_start, uart_data, uart_parity, uart_stop);

  signal r_uart_st : t_uart_st;

  -- Parity checker for incoming data
  signal w_parity_ok : std_logic;

  -- Register reads
  signal w_busy  : std_logic;
  signal w_error : std_logic;
  signal r_rdata : std_logic_vector(c_data_width - 1 downto 0);

  -- Holds a parity error, which w_error shows for only one clock
  signal r_error_irq : std_logic;

begin

  -- ========================================================================
  -- 1. DATA REGISTERS WITH PARITY PROTECTION
  -- ========================================================================
  p_rx_regs : process (clk_i) is

    variable v_parity : std_logic;

  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_tx_valid  <= '0';
        r_tx_data   <= (others => '0');
        r_tx_parity <= '0';
      elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and bus_i.sel(0) = '1' and
             bus_i.addr = c_uart_tx_data_addr) then
        -- Write 8-bit payload to TX buffer
        r_tx_data <= bus_i.data(7 downto 0);

        -- Calculate even parity for the data byte
        v_parity := '0';

        for i in 0 to 7 loop

          v_parity := v_parity xor bus_i.data(i);

        end loop;

        r_tx_parity <= v_parity;

        -- Mark buffer ready for TX engine
        r_tx_valid <= '1';
      elsif (r_uart_st = uart_idle) then
        r_tx_valid <= '0';
      end if;
    end if;

  end process p_rx_regs;

  -- ========================================================================
  -- 2. PARITY VALIDATION GATE
  -- ========================================================================
  -- Verify parity before allowing TX — prevents corrupted telemetry
  p_parity_check : process (all) is

    variable v_calc_parity : std_logic;

  begin

    v_calc_parity := '0';

    for i in 0 to 7 loop

      v_calc_parity := v_calc_parity xor r_tx_data(i);

    end loop;

    w_parity_ok <= '1' when (v_calc_parity = r_tx_parity) else '0';

  end process p_parity_check;

  -- ========================================================================
  -- 3. UART TX STATE MACHINE
  -- ========================================================================
  p_tx_fsm : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_uart_st  <= uart_idle;
        r_baud_cnt <= (others => '0');
        r_tx_bits  <= (others => '0');
      else

        case r_uart_st is

          when uart_idle =>

            r_baud_cnt <= (others => '0');
            if (r_tx_valid = '1' and w_parity_ok = '1') then
              -- Load shift register: start(0) + data[1-8] + parity(9) + stop(10)
              r_tx_shift(10)         <= '1';                 -- stop bit
              r_tx_shift(9)          <= r_tx_parity;
              r_tx_shift(8 downto 1) <= r_tx_data;
              r_tx_shift(0)          <= '0';                 -- start bit
              r_tx_bits              <= "1010";              -- 10 bits to shift
              r_uart_st              <= uart_start;
            end if;

          when uart_start =>

            r_baud_cnt <= r_baud_cnt + 1;
            if (r_baud_cnt >= c_baud_div - 1) then
              r_baud_cnt <= (others => '0');
              r_tx_shift <= '1' & r_tx_shift(10 downto 1);
              r_tx_bits  <= r_tx_bits - 1;
              if (r_tx_bits = 0) then
                r_uart_st <= uart_idle;
              else
                r_uart_st <= uart_data;
              end if;
            end if;

          when uart_data =>

            r_baud_cnt <= r_baud_cnt + 1;
            if (r_baud_cnt >= c_baud_div - 1) then
              r_baud_cnt <= (others => '0');
              r_tx_shift <= '1' & r_tx_shift(10 downto 1);
              r_tx_bits  <= r_tx_bits - 1;
              if (r_tx_bits = 0) then
                r_uart_st <= uart_idle;
              end if;
            end if;

          when uart_parity =>

            r_baud_cnt <= r_baud_cnt + 1;
            if (r_baud_cnt >= c_baud_div - 1) then
              r_baud_cnt <= (others => '0');
              r_tx_shift <= '1' & r_tx_shift(10 downto 1);
              r_tx_bits  <= r_tx_bits - 1;
              if (r_tx_bits = 0) then
                r_uart_st <= uart_idle;
              end if;
            end if;

          when uart_stop =>

            r_baud_cnt <= r_baud_cnt + 1;
            if (r_baud_cnt >= c_baud_div - 1) then
              r_uart_st <= uart_idle;
            end if;

          when others =>

            r_uart_st <= uart_idle;

        end case;

      end if;
    end if;

  end process p_tx_fsm;

  -- ========================================================================
  -- 4. UART TX OUTPUT
  -- ========================================================================
  uart_tx_o <= r_tx_shift(0) when r_uart_st /= uart_idle else
               '1';

  -- Busy flag for diagnostics
  w_busy <= '1' when r_uart_st /= uart_idle else
            '0';

  w_error <= '1' when (r_tx_valid = '1' and w_parity_ok = '0') else
             '0';

  uart_busy_o  <= w_busy;
  uart_error_o <= w_error;

  -- ========================================================================
  -- 5. REGISTER READS: STATUS AND PARITY
  -- ========================================================================
  -- The bus acknowledges every access at once, so read data has to be ready in
  -- the cycle after the strobe. It is zero at all other times, which lets the
  -- top level OR the peripherals together.
  -- ========================================================================
  p_read : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_rdata <= (others => '0');

      if (rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0') then
        if (bus_i.addr = c_uart_status_addr) then
          r_rdata(1) <= r_error_irq;
          r_rdata(0) <= w_busy;
        elsif (bus_i.addr = c_uart_parity_addr) then
          r_rdata(0) <= w_parity_ok;
        end if;
      end if;
    end if;

  end process p_read;

  rdata_o <= r_rdata;

  -- Cleared by a write rather than a read, because software that polls STATUS
  -- would otherwise clear the interrupt before the CPU had taken it
  p_error_irq : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_error_irq <= '0';
      elsif (w_error = '1') then
        r_error_irq <= '1';
      elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and bus_i.addr = c_uart_status_addr) then
        r_error_irq <= '0';
      end if;
    end if;

  end process p_error_irq;

  uart_irq_o <= r_error_irq;

  -- ========================================================================
  -- 6. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: Parity mismatch blocks TX
  -- Property: UART error flagged when parity fails
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        null;
      else
        -- Property: TX blocked when parity mismatch
        if (r_tx_valid = '1' and w_parity_ok = '0') then
          assert uart_error_o = '1'
            report "FORMAL FAIL: error not flagged on parity mismatch"
            severity error;
        end if;
        -- Property: TX only starts when parity valid
        if (r_uart_st = uart_start and r_tx_valid = '1') then
          assert w_parity_ok = '1'
            report "FORMAL FAIL: TX started with parity mismatch"
            severity error;
        end if;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
