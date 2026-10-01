-- Concurrently executes:
-- 1. LOADER SUB-FSM: Prefetches matrix operands A and B from input FIFO into
--    ping-pong register banks (bank 0 / bank 1).
-- 2. COMPUTE SUB-FSM: Orchestrates PE accumulator reset, skewed feeding of
--    active operands with runtime zero-injection, dynamic pipeline flush,
--    and result capture triggering.
--
-- Synchronization:
-- - bank_loaded[0..1]: asserted by Loader when bank is filled with valid data.
-- - bank_free[0..1]: asserted by Compute when bank has been fully processed.
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
        cfg_accumulate  : in  std_logic;
        cfg_last_tile   : in  std_logic;
        cfg_act_m       : in  std_logic_vector(4 downto 0);
        cfg_act_k       : in  std_logic_vector(4 downto 0);
        cfg_act_n       : in  std_logic_vector(4 downto 0);
        in_fifo_ready   : in  std_logic;      -- >= SA_WORDS_PER_TXN words buffered

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

    -- Sub-FSM state definitions
    type loader_state_t is (L_WAIT, L_LOAD_A, L_LOAD_B, L_READY);
    signal l_state : loader_state_t := L_WAIT;

    type compute_state_t is (C_IDLE, C_RESET_PE, C_COMPUTE, C_FLUSH, C_DONE);
    signal c_state : compute_state_t := C_IDLE;

    -- Ping-pong matrix register banks: 2 banks of SA_N rows x (SA_N * DATA_WIDTH) bits
    type mat_regs_t is array (0 to SA_N - 1) of std_logic_vector(SA_N * SA_DATA_WIDTH - 1 downto 0);
    type mat_bank_t is array (0 to 1) of mat_regs_t;
    signal a_banks : mat_bank_t;
    signal b_banks : mat_bank_t;

    -- Bank pointers
    signal load_bank   : natural range 0 to 1 := 0;  -- Bank currently targeted by Loader
    signal active_bank : natural range 0 to 1 := 0;  -- Bank currently read by Compute

    -- Bank handshake signals (persistent level flags)
    signal bank_loaded : std_logic_vector(1 downto 0) := "00";
    signal bank_free   : std_logic_vector(1 downto 0) := "11";

    -- Loader signals
    signal load_cnt    : unsigned(7 downto 0) := (others => '0');  -- counts 0..SA_WORDS_PER_MAT-1

    -- Compute signals
    signal t_cnt          : unsigned(7 downto 0) := (others => '0');  -- feed/flush cycle counter
    signal rst_cnt        : unsigned(0 downto 0) := (others => '0');  -- reset cycles
    signal cycle_cnt      : unsigned(31 downto 0) := (others => '0');
    signal start_pending  : std_logic := '0';

    -- Transaction / diagnostic counters
    signal txn_cnt_r   : unsigned(31 downto 0) := (others => '0');
    signal err_cnt_r   : unsigned(31 downto 0) := (others => '0');

    -- Tiling / accumulation tracking
    signal first_tile  : std_logic := '1';

    -- Latched runtime dimensions
    signal feed_cycles_r  : unsigned(7 downto 0) := to_unsigned(SA_FEED_CYCLES, 8);
    signal flush_cycles_r : unsigned(7 downto 0) := to_unsigned(SA_FLUSH_CYCLES, 8);
    signal act_m_r        : unsigned(4 downto 0) := to_unsigned(SA_N, 5);
    signal act_k_r        : unsigned(4 downto 0) := to_unsigned(SA_N, 5);
    signal act_n_r        : unsigned(4 downto 0) := to_unsigned(SA_N, 5);

    -- Decoupled result capture tracking (Phase 4 pipelining)
    signal cap_pending    : natural range 0 to 2 := 0;

begin

    -- Outputs
    perf_cycles  <= std_logic_vector(cycle_cnt);
    txn_count    <= std_logic_vector(txn_cnt_r);
    err_count    <= std_logic_vector(err_cnt_r);
    err_overflow <= '0';

    -- Coprocessor is busy when compute FSM is active, loader is busy, or drain is finishing
    busy <= '1' when (c_state /= C_IDLE or l_state /= L_WAIT or cap_pending > 0 or capture_done = '1') else '0';

    -- Combinational FIFO read enable: driven exclusively by Loader FSM
    fifo_rd_en <= '1' when (l_state = L_LOAD_A or l_state = L_LOAD_B) and (fifo_rd_empty = '0') else '0';

    -- Concurrent Sub-FSM Process (Loader + Compute)
    process (clk)
        variable k           : integer;
        variable act_feed    : unsigned(7 downto 0);
        variable act_flush   : unsigned(7 downto 0);
        variable v_cap_start : boolean;
    begin
        if rising_edge(clk) then
            if rst_n = '0' or soft_rst = '1' then
                -- Global Reset
                l_state        <= L_WAIT;
                load_bank      <= 0;
                load_cnt       <= (others => '0');

                c_state        <= C_IDLE;
                active_bank    <= 0;
                bank_loaded    <= "00";
                bank_free      <= "11";
                start_pending  <= '0';

                t_cnt          <= (others => '0');
                rst_cnt        <= (others => '0');
                cycle_cnt      <= (others => '0');
                txn_cnt_r      <= (others => '0');
                err_cnt_r      <= (others => '0');
                first_tile     <= '1';
                feed_cycles_r  <= to_unsigned(SA_FEED_CYCLES, 8);
                flush_cycles_r <= to_unsigned(SA_FLUSH_CYCLES, 8);
                act_m_r        <= to_unsigned(SA_N, 5);
                act_k_r        <= to_unsigned(SA_N, 5);
                act_n_r        <= to_unsigned(SA_N, 5);
                cap_pending    <= 0;

                sa_rst_n       <= '1';
                sa_compute_en  <= '0';
                sa_a_in        <= (others => '0');
                sa_b_in        <= (others => '0');
                capture_start  <= '0';
                done_pulse     <= '0';
            else
                v_cap_start   := false;
                capture_start <= '0';
                done_pulse    <= '0';

                -- Transaction completion on drain finish
                if capture_done = '1' then
                    done_pulse <= '1';
                    txn_cnt_r  <= txn_cnt_r + 1;
                end if;

                -- Latch external start pulse if issued
                if start = '1' then
                    start_pending <= '1';
                end if;

                -- 1. LOADER SUB-FSM (Fills ping-pong banks from input FIFO)
                case l_state is

                    -- L_WAIT: Wait until input FIFO has data and the target bank is free
                    when L_WAIT =>
                        if in_fifo_ready = '1' and bank_free(load_bank) = '1' and bank_loaded(load_bank) = '0' then
                            bank_free(load_bank) <= '0';  -- Claim bank for writing
                            load_cnt             <= (others => '0');
                            l_state              <= L_LOAD_A;
                        end if;

                    -- L_LOAD_A: Read SA_WORDS_PER_MAT words from FIFO into a_banks(load_bank)
                    when L_LOAD_A =>
                        if fifo_rd_empty = '0' then
                            a_banks(load_bank)(to_integer(load_cnt) / (SA_N / 4))(
                                ((to_integer(load_cnt) mod (SA_N / 4)) + 1) * 32 - 1
                                downto (to_integer(load_cnt) mod (SA_N / 4)) * 32
                            ) <= fifo_rd_data;

                            if load_cnt = to_unsigned(SA_WORDS_PER_MAT - 1, load_cnt'length) then
                                load_cnt <= (others => '0');
                                l_state  <= L_LOAD_B;
                            else
                                load_cnt <= load_cnt + 1;
                            end if;
                        end if;

                    -- L_LOAD_B: Read SA_WORDS_PER_MAT words from FIFO into b_banks(load_bank)
                    when L_LOAD_B =>
                        if fifo_rd_empty = '0' then
                            b_banks(load_bank)(to_integer(load_cnt) / (SA_N / 4))(
                                ((to_integer(load_cnt) mod (SA_N / 4)) + 1) * 32 - 1
                                downto (to_integer(load_cnt) mod (SA_N / 4)) * 32
                            ) <= fifo_rd_data;

                            if load_cnt = to_unsigned(SA_WORDS_PER_MAT - 1, load_cnt'length) then
                                load_cnt               <= (others => '0');
                                bank_loaded(load_bank) <= '1';  -- Bank loaded and ready
                                l_state                <= L_READY;
                            else
                                load_cnt <= load_cnt + 1;
                            end if;
                        end if;

                    -- L_READY: Bank is filled. Wait for Compute FSM to consume bank
                    when L_READY =>
                        if bank_loaded(load_bank) = '0' then
                            load_bank <= 1 - load_bank;  -- Toggle to opposite bank
                            l_state   <= L_WAIT;
                        end if;

                end case;

                -- 2. COMPUTE SUB-FSM (Orchestrates PE array computation & capture)
                case c_state is

                    -- C_IDLE: Wait for loaded bank and trigger (start pulse or continuous)
                    when C_IDLE =>
                        sa_compute_en <= '0';
                        sa_rst_n      <= '1';

                        if bank_loaded(active_bank) = '1' and
                           (start_pending = '1' or start = '1' or continuous = '1') then

                            start_pending            <= '0';
                            cycle_cnt                <= (others => '0');
                            bank_loaded(active_bank) <= '0';  -- Handshake: mark bank as consumed

                            if cfg_accumulate = '0' then
                                first_tile <= '1';
                            end if;

                            -- Latch runtime active dimensions (clamp/default to SA_N)
                            if unsigned(cfg_act_m) >= 1 and unsigned(cfg_act_m) <= SA_N then
                                act_m_r <= unsigned(cfg_act_m);
                            else
                                act_m_r <= to_unsigned(SA_N, 5);
                            end if;

                            if unsigned(cfg_act_k) >= 1 and unsigned(cfg_act_k) <= SA_N then
                                act_k_r <= unsigned(cfg_act_k);
                            else
                                act_k_r <= to_unsigned(SA_N, 5);
                            end if;

                            if unsigned(cfg_act_n) >= 1 and unsigned(cfg_act_n) <= SA_N then
                                act_n_r <= unsigned(cfg_act_n);
                            else
                                act_n_r <= to_unsigned(SA_N, 5);
                            end if;

                            -- Dynamic feed cycles: ACT_M + ACT_K - 1 (capped at SA_FEED_CYCLES)
                            act_feed := resize(unsigned(cfg_act_m) + unsigned(cfg_act_k) - 1, 8);
                            if act_feed > to_unsigned(SA_FEED_CYCLES, 8) or act_feed = 0 then
                                feed_cycles_r <= to_unsigned(SA_FEED_CYCLES, 8);
                            else
                                feed_cycles_r <= act_feed;
                            end if;

                            -- Dynamic flush cycles: ACT_M + ACT_N - 1 (capped at SA_FLUSH_CYCLES)
                            act_flush := resize(unsigned(cfg_act_m) + unsigned(cfg_act_n) - 1, 8);
                            if act_flush > to_unsigned(SA_FLUSH_CYCLES, 8) or act_flush = 0 then
                                flush_cycles_r <= to_unsigned(SA_FLUSH_CYCLES, 8);
                            else
                                flush_cycles_r <= act_flush;
                            end if;

                            if cfg_accumulate = '1' and first_tile = '0' then
                                -- Multi-tile accumulation: skip accumulator reset
                                t_cnt   <= (others => '0');
                                c_state <= C_COMPUTE;
                            else
                                -- Fresh run / first tile: clear PE accumulators
                                rst_cnt <= (others => '0');
                                c_state <= C_RESET_PE;
                            end if;
                        end if;

                    -- C_RESET_PE: Clear PE accumulators (2 cycles active-low sa_rst_n)
                    when C_RESET_PE =>
                        cycle_cnt <= cycle_cnt + 1;
                        sa_rst_n  <= '0';
                        sa_a_in   <= (others => '0');
                        sa_b_in   <= (others => '0');
                        if rst_cnt = "1" then
                            sa_rst_n   <= '1';
                            t_cnt      <= (others => '0');
                            first_tile <= '0';
                            c_state    <= C_COMPUTE;
                        else
                            rst_cnt <= rst_cnt + 1;
                        end if;

                    -- C_COMPUTE: Feed skewed data from active_bank for ACT_M + ACT_K - 1 cycles
                    when C_COMPUTE =>
                        cycle_cnt     <= cycle_cnt + 1;
                        sa_compute_en <= '1';

                        -- Feed skewed operands with boundary zero-injection
                        for i in 0 to SA_N - 1 loop
                            k := to_integer(t_cnt) - i;

                            if k >= 0 and k < to_integer(act_k_r) and i < to_integer(act_m_r) then
                                -- A[row i][col k]: byte k from a_banks(active_bank)(i)
                                sa_a_in((i + 1) * SA_DATA_WIDTH - 1 downto i * SA_DATA_WIDTH)
                                    <= a_banks(active_bank)(i)((k + 1) * SA_DATA_WIDTH - 1 downto k * SA_DATA_WIDTH);
                            else
                                sa_a_in((i + 1) * SA_DATA_WIDTH - 1 downto i * SA_DATA_WIDTH)
                                    <= (others => '0');
                            end if;

                            if k >= 0 and k < to_integer(act_k_r) and i < to_integer(act_n_r) then
                                -- B[row k][col i]: byte i from b_banks(active_bank)(k)
                                sa_b_in((i + 1) * SA_DATA_WIDTH - 1 downto i * SA_DATA_WIDTH)
                                    <= b_banks(active_bank)(k)((i + 1) * SA_DATA_WIDTH - 1 downto i * SA_DATA_WIDTH);
                            else
                                sa_b_in((i + 1) * SA_DATA_WIDTH - 1 downto i * SA_DATA_WIDTH)
                                    <= (others => '0');
                            end if;
                        end loop;

                        if t_cnt = feed_cycles_r - 1 then
                            t_cnt   <= (others => '0');
                            c_state <= C_FLUSH;
                        else
                            t_cnt <= t_cnt + 1;
                        end if;

                    -- C_FLUSH: Zero inputs, drain pipeline for ACT_M + ACT_N - 1 cycles
                    when C_FLUSH =>
                        cycle_cnt <= cycle_cnt + 1;
                        sa_a_in   <= (others => '0');
                        sa_b_in   <= (others => '0');

                        if t_cnt < flush_cycles_r - 1 then
                            sa_compute_en <= '1';
                            t_cnt         <= t_cnt + 1;
                        elsif t_cnt = flush_cycles_r - 1 then
                            sa_compute_en <= '0';
                            t_cnt         <= t_cnt + 1;
                        else
                            if cfg_accumulate = '0' or cfg_last_tile = '1' then
                                -- Check if result capture has room in double buffer
                                if cap_pending < 2 or capture_done = '1' then
                                    capture_start <= '1';
                                    v_cap_start   := true;
                                    first_tile    <= '1';  -- Reset for next series after capture
                                    c_state       <= C_DONE; -- Phase 4: Overlap drain with next compute!
                                end if;
                            else
                                -- Intermediate tile: retain accumulator values, proceed to complete tile
                                c_state       <= C_DONE;
                            end if;
                        end if;

                    -- C_DONE: Release processed input bank, advance active_bank pointer, return to C_IDLE
                    when C_DONE =>
                        if cfg_accumulate = '1' and cfg_last_tile = '0' then
                            done_pulse <= '1';
                            txn_cnt_r  <= txn_cnt_r + 1;
                        end if;
                        bank_free(active_bank) <= '1';  -- Release active input bank back to Loader
                        active_bank             <= 1 - active_bank; -- Toggle active bank pointer
                        c_state                 <= C_IDLE;

                end case;

                -- Update cap_pending using decision flag v_cap_start and capture_done
                if v_cap_start and capture_done = '0' then
                    if cap_pending < 2 then
                        cap_pending <= cap_pending + 1;
                    end if;
                elsif (not v_cap_start) and capture_done = '1' then
                    if cap_pending > 0 then
                        cap_pending <= cap_pending - 1;
                    end if;
                end if;

            end if;
        end if;
    end process;

end architecture rtl;
