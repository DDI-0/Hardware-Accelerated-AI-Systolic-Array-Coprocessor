--  Synchronous FIFO
--
-- First-word-fall-through (FWFT) style: rd_data shows the front element
-- combinationally.  Assert rd_en to advance to the next word.
--
-- Used for both input (Avalon-ST sink side) and output (Avalon-ST source
-- side) buffering.  DEPTH must be a power of 2.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sa_fifo is
    generic (
        WIDTH : natural := 32;
        DEPTH : natural := 32   -- must be power of 2
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        flush     : in  std_logic;

        -- Write interface
        wr_data   : in  std_logic_vector(WIDTH - 1 downto 0);
        wr_en     : in  std_logic;
        wr_full   : out std_logic;

        -- Read interface (FWFT)
        rd_data   : out std_logic_vector(WIDTH - 1 downto 0);
        rd_en     : in  std_logic;
        rd_empty  : out std_logic;

        -- Status
        level     : out std_logic_vector(7 downto 0);
        depth_out : out std_logic_vector(7 downto 0)
    );
end entity sa_fifo;

architecture rtl of sa_fifo is

    constant ADDR_W : natural := natural(ceil(log2(real(DEPTH))));

    type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
    signal mem : mem_t;

    signal wr_ptr  : unsigned(ADDR_W - 1 downto 0) := (others => '0');
    signal rd_ptr  : unsigned(ADDR_W - 1 downto 0) := (others => '0');
    signal count_r : unsigned(ADDR_W downto 0)      := (others => '0');

    signal full_i  : std_logic;
    signal empty_i : std_logic;

begin

    -- Status outputs
    full_i    <= '1' when count_r = to_unsigned(DEPTH, count_r'length) else '0';
    empty_i   <= '1' when count_r = 0 else '0';
    wr_full   <= full_i;
    rd_empty  <= empty_i;
    depth_out <= std_logic_vector(to_unsigned(DEPTH, 8));
    level     <= std_logic_vector(resize(count_r, 8));

    -- FWFT read: combinational output of front element
    rd_data <= mem(to_integer(rd_ptr));

    -- Main process
    process (clk)
        variable do_wr : boolean;
        variable do_rd : boolean;
    begin
        if rising_edge(clk) then
            if rst_n = '0' or flush = '1' then
                wr_ptr  <= (others => '0');
                rd_ptr  <= (others => '0');
                count_r <= (others => '0');
            else
                do_wr := (wr_en = '1') and (full_i = '0');
                do_rd := (rd_en = '1') and (empty_i = '0');

                -- Write
                if do_wr then
                    mem(to_integer(wr_ptr)) <= wr_data;
                    wr_ptr <= wr_ptr + 1;
                end if;

                -- Read (advance pointer)
                if do_rd then
                    rd_ptr <= rd_ptr + 1;
                end if;

                -- Count update
                if do_wr and not do_rd then
                    count_r <= count_r + 1;
                elsif do_rd and not do_wr then
                    count_r <= count_r - 1;
                -- else count stays same (both or neither)
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
