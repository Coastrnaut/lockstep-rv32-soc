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
        clk_i      : in  std_logic;
        rst_n_i    : in  std_logic;

        -- Internal bus from lockstep comparator
        bus_i      : in  t_rv_bus;
        bus_ok_i   : in  std_logic;

        -- UART output
        uart_tx_o  : out std_logic;

        -- Diagnostic: TX status
        uart_busy_o  : out std_logic;
        uart_error_o : out std_logic
    );
end entity safe_uart;

architecture rtl of safe_uart is

    -- ISO 26262 Automated Traceability Attributes
    attribute requirement_id : string;
    attribute requirement_id of rtl : architecture is "TSR_UART_001";

    -- UART baud rate divider (115200 @ 50MHz => ~434)
    constant C_BAUD_DIV : unsigned(15 downto 0) := to_unsigned(434, 16);

    -- TX buffer register with parity
    signal r_tx_data    : std_logic_vector(7 downto 0);
    signal r_tx_parity  : std_logic;
    signal r_tx_valid   : std_logic;

    -- Baud rate counter
    signal r_baud_cnt   : unsigned(15 downto 0);

    -- TX shift register (1 start + 8 data + 1 parity + 1 stop = 11 bits)
    signal r_tx_shift   : std_logic_vector(10 downto 0);
    signal r_tx_bits    : unsigned(3 downto 0);

    -- UART state machine
    type t_uart_st is (UART_IDLE, UART_START, UART_DATA, UART_PARITY, UART_STOP);
    signal r_uart_st    : t_uart_st;

    -- Parity checker for incoming data
    signal w_parity_ok  : std_logic;

begin

    -- ========================================================================
    -- 1. DATA REGISTERS WITH PARITY PROTECTION
    -- ========================================================================
    p_rx_regs : process(clk_i)
        variable v_parity : std_logic;
    begin
        if rising_edge(clk_i) then
            if rst_n_i = '0' then
                r_tx_valid <= '0';
            elsif bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' then
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
            elsif r_uart_st = UART_IDLE then
                r_tx_valid <= '0';
            end if;
        end if;
    end process p_rx_regs;

    -- ========================================================================
    -- 2. PARITY VALIDATION GATE
    -- ========================================================================
    -- Verify parity before allowing TX — prevents corrupted telemetry
    p_parity_check : process(all)
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
    p_tx_fsm : process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n_i = '0' then
                r_uart_st   <= UART_IDLE;
                r_baud_cnt  <= (others => '0');
                r_tx_bits   <= (others => '0');
            else
                case r_uart_st is
                    when UART_IDLE =>
                        r_baud_cnt <= (others => '0');
                        if r_tx_valid = '1' and w_parity_ok = '1' then
                            -- Load shift register: start(0) + data + parity + stop(1)
                            r_tx_shift(10 downto 2) <= r_tx_data;
                            r_tx_shift(1)           <= r_tx_parity;
                            r_tx_shift(0)           <= '0'; -- start bit
                            r_tx_bits   <= "1010"; -- 10 bits to shift
                            r_uart_st   <= UART_START;
                        end if;

                    when UART_START =>
                        r_baud_cnt <= r_baud_cnt + 1;
                        if r_baud_cnt >= C_BAUD_DIV then
                            r_baud_cnt <= (others => '0');
                            r_tx_shift <= r_tx_shift(10 downto 1) & '1';
                            r_tx_bits  <= r_tx_bits - 1;
                            if r_tx_bits = 0 then
                                r_uart_st <= UART_IDLE;
                            else
                                r_uart_st <= UART_DATA;
                            end if;
                        end if;

                    when UART_DATA =>
                        r_baud_cnt <= r_baud_cnt + 1;
                        if r_baud_cnt >= C_BAUD_DIV then
                            r_baud_cnt <= (others => '0');
                            r_tx_shift <= r_tx_shift(10 downto 1) & '1';
                            r_tx_bits  <= r_tx_bits - 1;
                            if r_tx_bits = 0 then
                                r_uart_st <= UART_IDLE;
                            end if;
                        end if;

                    when UART_PARITY =>
                        r_baud_cnt <= r_baud_cnt + 1;
                        if r_baud_cnt >= C_BAUD_DIV then
                            r_baud_cnt <= (others => '0');
                            r_tx_shift <= r_tx_shift(10 downto 1) & '1';
                            r_tx_bits  <= r_tx_bits - 1;
                            if r_tx_bits = 0 then
                                r_uart_st <= UART_IDLE;
                            end if;
                        end if;

                    when UART_STOP =>
                        r_baud_cnt <= r_baud_cnt + 1;
                        if r_baud_cnt >= C_BAUD_DIV then
                            r_uart_st <= UART_IDLE;
                        end if;

                    when others =>
                        r_uart_st <= UART_IDLE;
                end case;
            end if;
        end if;
    end process p_tx_fsm;

    -- ========================================================================
    -- 4. UART TX OUTPUT
    -- ========================================================================
    uart_tx_o <= r_tx_shift(0) when r_uart_st /= UART_IDLE else '1';

    -- Busy flag for diagnostics
    uart_busy_o  <= '1' when r_uart_st /= UART_IDLE else '0';
    uart_error_o <= '1' when (r_tx_valid = '1' and w_parity_ok = '0') else '0';

end architecture rtl;
