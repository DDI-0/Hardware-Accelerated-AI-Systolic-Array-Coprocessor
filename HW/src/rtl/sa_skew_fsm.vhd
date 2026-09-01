-- Central controller that orchestrates one matrix multiplication:
--
-- LOAD_A/B:  Reads 4+4 packed words from the input FIFO into local regs
-- RESET_PE:  Asserts array rst_n for 2 cycles to clear accumulators
-- COMPUTE:   Feeds skewed A/B streams for 2N-1 = 7 cycles
-- FLUSH:     Zeros inputs for N+1 = 5 cycles (pipeline drain)
-- CAPTURE:   Triggers result capture module, waits for done
-- DONE:      Asserts done_pulse, increments counters, loops if CONTINUOUS

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sa_avalon_pkg.all;

entity sa_skew_fsm is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Control from CSR
        start           : in  std_logic;
        soft_rst        : in  std_logic;
        continuous      : in  std_logic;
        in_fifo_ready   : in  std_logic;      -- >= 8 words buffered

        -- Input FIFO read interface (FWFT)
        fifo_rd_data    : in  std_logic_vector(31 downto 0);
        fifo_rd_empty   : in  std_logic;
        fifo_rd_en      : out std_logic;

        -- Systolic array interface
        sa_rst_n        : out std_logic;
        sa_compute_en   : out std_logic;
        sa_a_in         : out std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);
        sa_b_in         : out std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);

        -- Result capture interface
        capture_start   : out std_logic;
        capture_done    : in  std_logic;

        -- Status outputs
        busy            : out std_logic;
        done_pulse      : out std_logic;
        perf_cycles     : out std_logic_vector(31 downto 0);
        txn_count       : out std_logic_vector(31 downto 0);
        err_count       : out std_logic_vector(31 downto 0);
        err_overflow    : out std_logic
    );
end entity sa_skew_fsm;

architecture rtl of sa_skew_fsm is

    signal state : sa_fsm_state_t := S_IDLE;

    -- Local matrix register banks
    type mat_regs_t is array (0 to SA_N - 1) of std_logic_vector(31 downto 0);
    signal a_regs : mat_regs_t;
    signal b_regs : mat_regs_t;

    -- Counters
    signal load_cnt   : unsigned(1 downto 0) := (others => '0');  -- 0..3
    signal t_cnt      : unsigned(3 downto 0) := (others => '0');  -- feed/flush cycle
    signal rst_cnt    : unsigned(0 downto 0) := (others => '0');  -- reset cycles
    signal cycle_cnt  : unsigned(31 downto 0) := (others => '0');

    -- Transaction / error counters
    signal txn_cnt_r  : unsigned(31 downto 0) := (others => '0');
    signal err_cnt_r  : unsigned(31 downto 0) := (others => '0');

begin

    -- Outputs
    perf_cycles <= std_logic_vector(cycle_cnt);
    txn_count   <= std_logic_vector(txn_cnt_r);
    err_count   <= std_logic_vector(err_cnt_r);
    err_overflow <= '0'; 

    -- Main FSM
    process (clk)
        variable k : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '0' or soft_rst = '1' then
                state         <= S_IDLE;
                load_cnt      <= (others => '0');
                t_cnt         <= (others => '0');
                rst_cnt       <= (others => '0');
                cycle_cnt     <= (others => '0');
                txn_cnt_r     <= (others => '0');
                err_cnt_r     <= (others => '0');
                sa_rst_n      <= '1';
                sa_compute_en <= '0';
                sa_a_in       <= (others => '0');
                sa_b_in       <= (others => '0');
capture_start <= '0';
                busy          <= '0';
                done_pulse    <= '0';
            else
                -- Defaults
capture_start <= '0';
                done_pulse    <= '0';

                case state is

                    -- IDLE: wait for trigger
                    when S_IDLE =>
                        busy <= '0';
                        sa_compute_en <= '0';
                        sa_rst_n      <= '1';

                        if start = '1' or (continuous = '1' and in_fifo_ready = '1') then
                            if in_fifo_ready = '1' then
                                busy      <= '1';
                                cycle_cnt <= (others => '0');
                                load_cnt  <= (others => '0');
                                state     <= S_LOAD_A;
                            end if;
                        end if;

                    -- LOAD_A: read 4 packed words from FIFO into a_regs
                    when S_LOAD_A =>
                        cycle_cnt <= cycle_cnt + 1;
                        if fifo_rd_empty = '0' then
                            a_regs(to_integer(load_cnt)) <= fifo_rd_data;
if load_cnt = 3 then
                                load_cnt <= (others => '0');
                                state    <= S_LOAD_B;
                            else
                                load_cnt <= load_cnt + 1;
                            end if;
                        end if;

                    -- LOAD_B: read 4 packed words from FIFO into b_regs
                    when S_LOAD_B =>
                        cycle_cnt <= cycle_cnt + 1;
                        if fifo_rd_empty = '0' then
                            b_regs(to_integer(load_cnt)) <= fifo_rd_data;
if load_cnt = 3 then
                                load_cnt <= (others => '0');
                                rst_cnt  <= (others => '0');
                                state    <= S_RESET_PE;
                            else
                                load_cnt <= load_cnt + 1;
                            end if;
                        end if;

                    -- RESET_PE: clear accumulators (2 cycles with rst_n low)
                    when S_RESET_PE =>
                        cycle_cnt <= cycle_cnt + 1;
                        sa_rst_n  <= '0';
                        sa_a_in   <= (others => '0');
                        sa_b_in   <= (others => '0');
                        if rst_cnt = "1" then
                            sa_rst_n <= '1';
                            t_cnt    <= (others => '0');
                            state    <= S_COMPUTE;
                        else
                            rst_cnt <= rst_cnt + 1;
                        end if;

                    -- COMPUTE: feed skewed data for 2*N-1 = 7 cycles
                    when S_COMPUTE =>
                        cycle_cnt     <= cycle_cnt + 1;
                        sa_compute_en <= '1';

                        -- Generate skewed a_in and b_in
                        for i in 0 to SA_N - 1 loop
                            k := to_integer(t_cnt) - i;
                            if k >= 0 and k < SA_N then
                                -- A[row i][col k]: byte k from a_regs(i)
                                sa_a_in((i + 1) * SA_DATA_WIDTH - 1
                                         downto i * SA_DATA_WIDTH)
                                    <= a_regs(i)((k + 1) * SA_DATA_WIDTH - 1
                                                  downto k * SA_DATA_WIDTH);
                                -- B[row k][col i]: byte i from b_regs(k)
                                sa_b_in((i + 1) * SA_DATA_WIDTH - 1
                                         downto i * SA_DATA_WIDTH)
                                    <= b_regs(k)((i + 1) * SA_DATA_WIDTH - 1
                                                  downto i * SA_DATA_WIDTH);
                            else
                                sa_a_in((i + 1) * SA_DATA_WIDTH - 1
                                         downto i * SA_DATA_WIDTH)
                                    <= (others => '0');
                                sa_b_in((i + 1) * SA_DATA_WIDTH - 1
                                         downto i * SA_DATA_WIDTH)
                                    <= (others => '0');
                            end if;
                        end loop;

                        if t_cnt = to_unsigned(SA_FEED_CYCLES - 1, 4) then
                            t_cnt <= (others => '0');
                            state <= S_FLUSH;
                        else
                            t_cnt <= t_cnt + 1;
                        end if;

                    -- FLUSH: zero inputs, keep compute_en high (N+1 cycles)
                    --        followed by 1 settling cycle before capture
                    when S_FLUSH =>
                        cycle_cnt <= cycle_cnt + 1;
                        sa_a_in   <= (others => '0');
                        sa_b_in   <= (others => '0');

                        if t_cnt < to_unsigned(SA_FLUSH_CYCLES - 1, 4) then
                            sa_compute_en <= '1';
                            t_cnt         <= t_cnt + 1;
                        elsif t_cnt = to_unsigned(SA_FLUSH_CYCLES - 1, 4) then
                            sa_compute_en <= '0';
                            t_cnt         <= t_cnt + 1;
                        else
                            capture_start <= '1';
                            state         <= S_CAPTURE;
                        end if;

                    -- CAPTURE: wait for result capture to push all words
                    when S_CAPTURE =>
                        cycle_cnt <= cycle_cnt + 1;
                        if capture_done = '1' then
                            state <= S_DONE;
                        end if;

                    -- DONE: report completion, loop or return to idle
                    when S_DONE =>
                        done_pulse <= '1';
                        txn_cnt_r  <= txn_cnt_r + 1;

                        if continuous = '1' and in_fifo_ready = '1' then
                            -- Back-to-back: start next immediately
                            cycle_cnt <= (others => '0');
                            load_cnt  <= (others => '0');
                            state     <= S_LOAD_A;
                        else
                            state <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Combinational FIFO read enable
    fifo_rd_en <= '1' when (state = S_LOAD_A or state = S_LOAD_B) and (fifo_rd_empty = '0') else '0';

end architecture rtl;




