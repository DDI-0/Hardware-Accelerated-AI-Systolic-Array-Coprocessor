-- Features:
-- 1. Double-buffered result storage (Buffer 0 / Buffer 1): can atomically
--    latch a new result from the systolic array via capture_start while
--    concurrently draining the previous result to the output FIFO.
-- 2. Runtime dimension support: serializes only the active sub-matrix of
--    ACT_M x ACT_N words, skipping unused padding.
-- 3. Independent drain engine: asserts capture_done as soon as a buffer has
--    been completely serialized, and automatically advances to the next buffer.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sa_avalon_pkg.all;

entity sa_result_capture is
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;

        -- Trigger from FSM
        capture_start : in  std_logic;
        capture_done  : out std_logic;

        -- Runtime dimensions (1..16)
        cfg_act_m     : in  std_logic_vector(4 downto 0);
        cfg_act_n     : in  std_logic_vector(4 downto 0);

        -- From systolic array (8192 bits for 16x16)
        result        : in  std_logic_vector(SA_RESULT_WIDTH - 1 downto 0);

        -- To output FIFO
        wr_data       : out std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
        wr_valid      : out std_logic;
        wr_ready      : in  std_logic
    );
end entity sa_result_capture;

architecture rtl of sa_result_capture is

    type cap_state_t is (CAP_IDLE, CAP_PUSH);
    signal state : cap_state_t := CAP_IDLE;

    -- Double-buffered result storage (2 buffers x SA_RESULT_WIDTH bits)
    type result_buf_t is array (0 to 1) of std_logic_vector(SA_RESULT_WIDTH - 1 downto 0);
    signal result_buffers : result_buf_t := (others => (others => '0'));

    -- Active dimensions stored per result buffer
    type dim_buf_t is array (0 to 1) of unsigned(4 downto 0);
    signal buf_act_m : dim_buf_t := (others => to_unsigned(SA_N, 5));
    signal buf_act_n : dim_buf_t := (others => to_unsigned(SA_N, 5));

    -- Buffer status flags
    signal buf_valid  : std_logic_vector(1 downto 0) := "00";
    signal wr_buf_idx : natural range 0 to 1 := 0;  -- Buffer targeted by next capture_start
    signal rd_buf_idx : natural range 0 to 1 := 0;  -- Buffer currently being drained

    -- Row and column serialization counters
    signal r_cnt : unsigned(4 downto 0) := (others => '0');
    signal c_cnt : unsigned(4 downto 0) := (others => '0');

    -- Unpacked 32-bit words for the active draining buffer
    type result_words_t is array (0 to SA_RESULT_WORDS - 1)
         of std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
    signal active_words : result_words_t;

begin

    -- Unpack active draining buffer into SA_RESULT_WORDS x 32-bit words
    gen_unpack : for i in 0 to SA_RESULT_WORDS - 1 generate
        active_words(i) <= result_buffers(rd_buf_idx)(
            (i + 1) * SA_ACC_WIDTH - 1 downto i * SA_ACC_WIDTH
        );
    end generate gen_unpack;

    -- Output multiplexer: reads row r_cnt, column c_cnt from the active draining buffer
    wr_data <= active_words(to_integer(r_cnt) * SA_N + to_integer(c_cnt));

    -- Write valid: asserted when pushing words from a valid buffer
    wr_valid <= '1' when (state = CAP_PUSH and buf_valid(rd_buf_idx) = '1') else '0';

    -- Concurrent Process: handles both Latching (write) and Draining (read)
    process (clk)
        variable m_val : unsigned(4 downto 0);
        variable n_val : unsigned(4 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state          <= CAP_IDLE;
                buf_valid      <= "00";
                wr_buf_idx     <= 0;
                rd_buf_idx     <= 0;
                r_cnt          <= (others => '0');
                c_cnt          <= (others => '0');
                capture_done   <= '0';
                buf_act_m      <= (others => to_unsigned(SA_N, 5));
                buf_act_n      <= (others => to_unsigned(SA_N, 5));
            else
                -- Default single-cycle pulse
                capture_done <= '0';

                -- 1. LATCH ENGINE (Triggered by capture_start)
                if capture_start = '1' and buf_valid(wr_buf_idx) = '0' then
                    result_buffers(wr_buf_idx) <= result;  -- Atomic capture from PE array

                    if unsigned(cfg_act_m) >= 1 and unsigned(cfg_act_m) <= SA_N then
                        m_val := unsigned(cfg_act_m);
                    else
                        m_val := to_unsigned(SA_N, 5);
                    end if;

                    if unsigned(cfg_act_n) >= 1 and unsigned(cfg_act_n) <= SA_N then
                        n_val := unsigned(cfg_act_n);
                    else
                        n_val := to_unsigned(SA_N, 5);
                    end if;

                    buf_act_m(wr_buf_idx) <= m_val;
                    buf_act_n(wr_buf_idx) <= n_val;
                    buf_valid(wr_buf_idx) <= '1';
                    wr_buf_idx            <= 1 - wr_buf_idx;
                end if;

                -- 2. DRAIN ENGINE (Streams words to output FIFO)
                case state is

                    when CAP_IDLE =>
                        r_cnt <= (others => '0');
                        c_cnt <= (others => '0');
                        if buf_valid(rd_buf_idx) = '1' then
                            state <= CAP_PUSH;
                        end if;

                    when CAP_PUSH =>
                        if wr_ready = '1' then
                            if c_cnt = buf_act_n(rd_buf_idx) - 1 then
                                c_cnt <= (others => '0');
                                if r_cnt = buf_act_m(rd_buf_idx) - 1 then
                                    -- Completed draining all active words for this buffer
                                    buf_valid(rd_buf_idx) <= '0';
                                    rd_buf_idx            <= 1 - rd_buf_idx;
                                    capture_done          <= '1';
                                    state                 <= CAP_IDLE;
                                else
                                    r_cnt <= r_cnt + 1;
                                end if;
                            else
                                c_cnt <= c_cnt + 1;
                            end if;
                        end if;

                end case;

            end if;
        end if;
    end process;

end architecture rtl;
