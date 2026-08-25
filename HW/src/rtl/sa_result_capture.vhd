-- Result Capture: sa_result_capture
--
-- Latches the 512-bit result bus from the systolic array and sequentially
-- pushes 16 x 32-bit words into the output FIFO.
--
-- Ordering:  C[0][0], C[0][1], ..., C[0][3], C[1][0], ..., C[3][3]
--            (row-major, matches DMA read order)

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

        -- From systolic array
        result        : in  std_logic_vector(SA_RESULT_WIDTH - 1 downto 0);

        -- To output FIFO
        wr_data       : out std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
        wr_valid      : out std_logic;
        wr_ready      : in  std_logic
    );
end entity sa_result_capture;

architecture rtl of sa_result_capture is

    type cap_state_t is (CAP_IDLE, CAP_PUSH, CAP_DONE);
    signal state : cap_state_t := CAP_IDLE;

    -- Latched result (frozen when capture begins)
    signal result_latched : std_logic_vector(SA_RESULT_WIDTH - 1 downto 0);

    -- Word index counter
    signal word_idx : unsigned(3 downto 0) := (others => '0');  -- 0..15

    -- Unpacked result words (constant-indexed slicing)
    type result_words_t is array (0 to SA_RESULT_WORDS - 1)
         of std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
    signal result_words : result_words_t;

begin

    -- Unpack latched 512-bit bus into 16 x 32-bit words
    gen_unpack : for i in 0 to SA_RESULT_WORDS - 1 generate
        result_words(i) <= result_latched((i + 1) * SA_ACC_WIDTH - 1
                                          downto i * SA_ACC_WIDTH);
    end generate gen_unpack;

    -- Output mux
    wr_data <= result_words(to_integer(word_idx));

    -- FSM
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state        <= CAP_IDLE;
                word_idx     <= (others => '0');
                wr_valid     <= '0';
                capture_done <= '0';
            else
                -- Defaults
                wr_valid     <= '0';
                capture_done <= '0';

                case state is

                    when CAP_IDLE =>
                        if capture_start = '1' then
                            result_latched <= result;   -- atomic latch
                            word_idx       <= (others => '0');
                            state          <= CAP_PUSH;
                        end if;

                    when CAP_PUSH =>
                        wr_valid <= '1';
                        if wr_ready = '1' then
                            if word_idx = to_unsigned(SA_RESULT_WORDS - 1, 4) then
                                state <= CAP_DONE;
                            else
                                word_idx <= word_idx + 1;
                            end if;
                        end if;
                        -- If wr_ready='0', hold word_idx and keep asserting wr_valid

                    when CAP_DONE =>
                        capture_done <= '1';
                        state        <= CAP_IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
